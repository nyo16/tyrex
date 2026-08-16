defmodule TyrexLifecycleTest do
  @moduledoc """
  Regression tests for the v0.4.0 termination work.

  Every test here corresponds to a defect that was reproduced on real hardware
  before the fix: a runaway that no timeout could stop, a `blocking: true` call
  that deadlocked the runtime permanently, and a leaked OS thread that kept
  spinning after `stop/1` returned `:ok`.
  """

  use ExUnit.Case, async: false

  @runaway "for(;;){}"

  describe "eval deadlines are real" do
    test "a runaway returns :timeout within the deadline" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      started = System.monotonic_time(:millisecond)

      assert {:error, %Tyrex.Error{name: :timeout}} =
               Tyrex.eval(@runaway, pid: pid, timeout: 1_000)

      elapsed = System.monotonic_time(:millisecond) - started

      # The deadline must beat the caller's own call timeout, not race it.
      assert elapsed < 3_000, "deadline took #{elapsed}ms"
    end

    test "the runtime is deterministically dead afterwards" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Tyrex.start_link(name: :deadline_dead, permissions: :none)

      assert {:error, %Tyrex.Error{name: :timeout}} =
               Tyrex.eval(@runaway, pid: pid, timeout: 500)

      # terminate => dead => caller restarts. No half-alive brick.
      assert_receive {:EXIT, ^pid, {:shutdown, :timeout}}, 5_000
      refute Process.alive?(pid)
    end

    test "a deadline does not fire for work that finishes in time" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      # The `{:deadline, from}` clause drops a `from` it no longer holds, so a
      # stale timer leaves no other outward mark — tracing receives is how we
      # see the timer itself.
      #
      # Arm it *before* the evals. Armed afterwards, a `{:deadline, _}`
      # delivered between the second eval's reply and `:erlang.trace/3` is
      # never recorded, so `refute_receive` below passes by not looking rather
      # than by observing nothing — the test stops testing instead of going
      # red, which is the fail-closed failure this whole file exists to catch.
      # The extra `$gen_call` and `:eval_reply` trace messages this collects do
      # not match the refute pattern and are skipped by the selective receive.
      :erlang.trace(pid, true, [:receive])

      # The trace dies with the traced process, so stopping the runtime however
      # this test exits is what keeps the flag from following the pid into a
      # later test.
      on_exit(fn -> Tyrex.stop(pid: pid) end)

      # 300ms deadlines against sub-millisecond work, so the window in which a
      # stale timer could fire is *inside* this test. With `timeout: 5_000` the
      # uncancelled timer fired ~4.8s after the test had already finished, and
      # deleting `cancel_timer(timer)` from the `:eval_reply` clause left this
      # green.
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid, timeout: 300)
      assert {:ok, 4} = Tyrex.eval("2 + 2", pid: pid, timeout: 300)

      # This waits longer than the deadline above, so a timer that was going to
      # fire has fired by the time we stop tracing.
      refute_receive {:trace, ^pid, :receive, {:deadline, _}}, 600
      :erlang.trace(pid, false, [:receive])

      # A stale timer firing would have killed a healthy runtime, so require it
      # both alive and still serving.
      assert Process.alive?(pid)
      assert {:ok, 5} = Tyrex.eval("2 + 3", pid: pid)

      Tyrex.stop(pid: pid)
    end

    test "in-flight callers are told the runtime died under them" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      caller =
        Task.async(fn ->
          Tyrex.eval(@runaway, pid: pid, timeout: 30_000)
        end)

      # Let the guest actually enter the loop before killing it.
      Process.sleep(300)
      :ok = Tyrex.kill(pid: pid)

      # The `:name` alone cannot fail — `dead_runtime_exit?/1` manufactures it
      # from any dead-runtime exit, so this assertion held even with
      # `fail_inflight/2` deleted from `terminate/2`. The `:message` names the
      # producer, and for `kill/1` the producer is deliberately the *exit
      # mapping*, not the drain: `kill/1` is an untrappable
      # `Process.exit(pid, :kill)`, so `terminate/2` never runs and there is
      # nobody left to reply. Pinning "already gone" is what makes this a claim
      # about `dead_runtime_exit?/1` covering `:killed` — drop `:killed` from it
      # and this caller exits instead of getting a tuple. The reply-side drain
      # is pinned by the "in flight" message in test/tyrex_api_test.exs.
      assert {:error, %Tyrex.Error{name: :dead_runtime_error, message: message}} =
               Task.await(caller, 10_000)

      assert message =~ "already gone"
    end
  end

  describe "kill/1" do
    test "interrupts a guest that never yields" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      spawn(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 60_000) end)
      Process.sleep(300)

      ref = Process.monitor(pid)
      started = System.monotonic_time(:millisecond)

      assert :ok = Tyrex.kill(pid: pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      elapsed = System.monotonic_time(:millisecond) - started

      # `kill/1` ends in an untrappable exit, but it used to be a
      # `GenServer.call` — which this non-blocking case could still serve,
      # because the GenServer is idle while the guest spins. That is why this
      # test passed against a `kill/1` that was inert on the case its docstring
      # actually promises; see the `blocking: true` test below, which is the one
      # that could not be served.
      assert elapsed < 2_000, "kill/1 to :DOWN took #{elapsed}ms"
    end

    # The case `kill/1`'s docstring is *about*, and the case it silently failed.
    #
    # With `blocking: true` the GenServer parks inside `Native.eval_blocking/3`,
    # so a `GenServer.call(:kill)` can never be served. Measured against the old
    # implementation: `kill/1` returned `:ok` after 5002ms with the runtime still
    # alive, because `catch :exit, _ -> :ok` reported its own call timeout as
    # success. Asserting `:ok` alone cannot catch that — hence the liveness and
    # promptness assertions.
    test "interrupts a guest wedged inside the blocking NIF" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      spawn(fn -> Tyrex.eval(@runaway, pid: pid, blocking: true, timeout: 60_000) end)
      Process.sleep(500)

      assert {:current_function, {Tyrex.Native, :eval_blocking, 3}} =
               Process.info(pid, :current_function)

      ref = Process.monitor(pid)
      started = System.monotonic_time(:millisecond)

      assert :ok = Tyrex.kill(pid: pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      elapsed = System.monotonic_time(:millisecond) - started

      refute Process.alive?(pid)

      # Well under the 5s that the old call-timeout no-op took.
      assert elapsed < 2_000, "kill/1 on a blocking wedge took #{elapsed}ms"
    end

    test "is safe to call on an already-dead runtime" do
      {:ok, pid} = Tyrex.start(permissions: :none)
      Tyrex.stop(pid: pid)
      refute Process.alive?(pid)

      started = System.monotonic_time(:millisecond)
      assert :ok = Tyrex.kill(pid: pid)
      elapsed = System.monotonic_time(:millisecond) - started

      # Same tautology: `catch :exit, _ -> :ok` returns `:ok` for a dead pid, an
      # unregistered name, and a call that sat out the whole 5s default. A call
      # to a dead pid exits with `:noproc` immediately, so anything approaching
      # that default means we waited on something.
      assert elapsed < 1_000, "kill/1 on a dead runtime took #{elapsed}ms"
    end
  end

  describe "stop/1" do
    test "defaults to a finite timeout rather than :infinity" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      spawn(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 60_000) end)
      Process.sleep(300)

      started = System.monotonic_time(:millisecond)
      assert :ok = Tyrex.stop(pid: pid)
      elapsed = System.monotonic_time(:millisecond) - started

      # Before v0.4.0 this hung forever on a wedged runtime.
      assert elapsed < 10_000, "stop/1 took #{elapsed}ms"
      refute Process.alive?(pid)
    end
  end

  describe "blocking: true" do
    test "is refused when the apply bridge is enabled" do
      {:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

      # Before v0.4.0 this deadlocked the runtime permanently: the GenServer
      # parked in the NIF while op_apply needed that same GenServer.
      assert {:error, %Tyrex.Error{name: :unsupported_option}} =
               Tyrex.eval("1 + 2", pid: pid, blocking: true)

      # Crucially, the runtime is still usable.
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)

      assert {:ok, 6} =
               Tyrex.eval(
                 ~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|,
                 pid: pid
               )

      Tyrex.stop(pid: pid)
    end

    test "is refused without a finite deadline" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{name: :unsupported_option}} =
               Tyrex.eval("1 + 2", pid: pid, blocking: true, timeout: :infinity)

      Tyrex.stop(pid: pid)
    end

    test "still works on a bridge-free runtime" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:ok, 42} = Tyrex.eval("42", pid: pid, blocking: true)

      Tyrex.stop(pid: pid)
    end

    test "a runaway hits its deadline instead of parking forever" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{name: :timeout}} =
               Tyrex.eval(@runaway, pid: pid, blocking: true, timeout: 1_000)
    end
  end

  describe "max_heap_mb" do
    test "a guest that exhausts the heap is terminated, not the BEAM" do
      {:ok, pid} = Tyrex.start(permissions: :none, max_heap_mb: 64)

      code = """
      const chunks = [];
      for (;;) { chunks.push(new Array(1_000_000).fill(7)); }
      """

      # Without a cap this aborts the whole VM, but merely getting a reply is
      # not the assertion: drop `terminate_execution()` from the near-heap-limit
      # callback and keep the slack grant, and the guest allocates until the
      # eval deadline returns `:timeout` — a green test with the BEAM-abort
      # protection gone. Hence equality on the name. If 30s ever proves tight
      # the fix is a longer timeout, never a wider set of accepted names.
      ref = Process.monitor(pid)

      assert {:error, %Tyrex.Error{name: :heap_limit_error}} =
               Tyrex.eval(code, pid: pid, timeout: 30_000)

      # A heap trip is terminal by contract: the reply is sent from the clause
      # that stops the runtime, so the exit follows the reply.
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :heap_limit_error}}, 5_000
      refute Process.alive?(pid)
    end

    # The floor is the whole of the fix for "a small cap aborts the BEAM inside
    # bootstrap". Asserting only against 0 does not test it: 0 was rejected by
    # the old `mb > 0` guard too, and both guards produce a message containing
    # "positive integer". Only the rows either side of the floor discriminate,
    # so those are the rows asserted.
    test "rejects a cap below the measured bootstrap floor" do
      assert_raise ArgumentError, ~r/at least 32/, fn ->
        Tyrex.start(permissions: :none, max_heap_mb: 31)
      end

      assert_raise ArgumentError, ~r/at least 32/, fn ->
        Tyrex.start(permissions: :none, max_heap_mb: 1)
      end

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Tyrex.start(permissions: :none, max_heap_mb: 0)
      end
    end

    test "accepts the floor itself" do
      {:ok, pid} = Tyrex.start(permissions: :none, max_heap_mb: 32)
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
      Tyrex.stop(pid: pid)
    end

    test "a main module that blows the cap fails start with :heap_limit_error" do
      # The near-heap-limit callback is installed, and its sticky flag live,
      # before `worker::new` evaluates the main module — but both of that
      # function's fallible steps used to map straight to :execution_error, so
      # an operator whose `:main_module_path` blew a tight cap got V8's
      # uninformative post-termination message with no hint of the cause.
      # Equality on the name is the point: revert the flag consult in
      # `worker::new` and this reports :execution_error instead.
      assert {:error, %Tyrex.Error{name: :heap_limit_error} = error} =
               Tyrex.start(
                 permissions: :none,
                 max_heap_mb: 32,
                 main_module_path: "test/support/heap_hog.js"
               )

      assert error.message =~ ":max_heap_mb"
    end
  end

  describe "pool recovery" do
    test "a killed runtime is replaced and the pool keeps serving" do
      {:ok, _sup} = Tyrex.Pool.start_link(name: :recovery_pool, size: 2, permissions: :none)

      assert {:ok, 1} = Tyrex.Pool.eval(:recovery_pool, "1")

      victim = Process.whereis(:"recovery_pool.Runtime.0")
      assert is_pid(victim)

      ref = Process.monitor(victim)
      :ok = Tyrex.kill(pid: victim)
      assert_receive {:DOWN, ^ref, :process, ^victim, _}, 5_000

      # `Tyrex.Pool.RuntimeSupervisor` rebuilds the killed child in place. That
      # layer is :one_for_one since 27bb9df, so the sibling is never torn down
      # and keeps answering throughout; only a call the strategy routes at the
      # dead name during the restart window is affected. Since task 2.4 of the
      # previous plan those no longer exit either — `Tyrex.eval/2`'s
      # `dead_runtime_exit?/1` maps the :noproc to
      # {:error, %Tyrex.Error{name: :dead_runtime_error}}.
      #
      # So there is deliberately no `catch :exit` here: nothing this loop can
      # provoke is still supposed to escape as an exit, and a `catch` wide
      # enough to swallow one would also swallow the regression where that
      # mapping is lost. Any other return value is a CaseClauseError, on
      # purpose.
      assert eventually(fn ->
               case Tyrex.Pool.eval(:recovery_pool, "2") do
                 {:ok, 2} -> true
                 {:error, %Tyrex.Error{name: :dead_runtime_error}} -> false
               end
             end)

      # Both runtimes are back.
      assert is_pid(Process.whereis(:"recovery_pool.Runtime.0"))
      assert is_pid(Process.whereis(:"recovery_pool.Runtime.1"))

      Supervisor.stop(:"recovery_pool.Supervisor")
    end
  end

  # The audit's leak probe, turned into an assertion. Three runaways were
  # measured at 299.6% CPU *after* every runtime was stopped and every Elixir
  # process was dead: `stop/1` returning :ok was not evidence of reclamation,
  # because the per-runtime OS thread is not a dirty scheduler and nothing was
  # interrupting it.
  describe "terminated runtimes release their OS thread" do
    @tag timeout: 120_000
    test "CPU returns to baseline after stop/1" do
      baseline = cpu_cores_used(2_000)

      pids =
        for _ <- 1..3 do
          {:ok, pid} = Tyrex.start(permissions: :none)
          spawn(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 120_000) end)
          pid
        end

      # The burn assertion below runs before the explicit stops, and it is
      # designed to go red on an under-provisioned runner. Without this, one
      # honest red leaves three `for(;;){}` runtimes burning a core each for
      # the rest of the VM, and every later CPU measurement is shifted by ~1.0
      # core per surviving runaway: with the leak live, this test's own baseline
      # was measured at 4.01 cores instead of 0.005, so `running > burn_floor`
      # then passes or fails for a reason unrelated to what it is testing.
      # Cleanup has to survive the failure, so it is registered here
      # rather than trailing the assertions. The explicit `stop/1` further down
      # stays: it is the measurement, not the cleanup.
      on_exit(fn -> Enum.each(pids, &Tyrex.stop(pid: &1)) end)

      Process.sleep(1_000)

      running = cpu_cores_used(1_000)

      # Three runaways can accrue at most min(3, vCPU) cores per second of wall
      # clock, and they share those cores with the BEAM's own schedulers. The
      # old fixed `baseline + 1.0` sat right at the margin on a 2-vCPU runner
      # and could not pass at all on 1 vCPU, so scale the expectation to the
      # runner and keep 40% of it as headroom for scheduling loss.
      burners = min(3, System.schedulers_online())
      burn_floor = burners * 0.6

      assert running > baseline + burn_floor,
             "expected the runaways to burn CPU (baseline #{baseline}, " <>
               "running #{running}, floor #{baseline + burn_floor} for #{burners} burners)"

      Enum.each(pids, &Tyrex.stop(pid: &1))
      refute Enum.any?(pids, &Process.alive?/1)

      # Let the worker threads finish unwinding.
      Process.sleep(1_000)

      # A long window on purpose: it is what buys the coarse `ps` path enough
      # resolution to clear the ceiling below.
      after_stop = cpu_cores_used(4_000)

      ceiling = idle_cpu_ceiling()

      assert after_stop < ceiling,
             "CPU did not return to baseline after stop/1 " <>
               "(baseline #{baseline}, running #{running}, after #{after_stop}, " <>
               "ceiling #{ceiling}) — the per-runtime OS thread leaked"
    end

    # The same probe on the `blocking: true` path, which the test above cannot
    # reach — and the distinction is the whole point. With `blocking: false`
    # the GenServer is idle while the guest spins, so `terminate/2` runs, drops
    # the last `ResourceArc` reference, and `Runtime::drop` reclaims the
    # thread. With `blocking: true` the GenServer is parked *inside*
    # `Native.eval_blocking/3`, holding a reference in a NIF call frame that
    # nothing can unwind while the worker never yields: `stop/1` escalates to a
    # brutal kill, the process dies, and the refcount still never reaches zero.
    #
    # Cores still burning after every runtime was stopped and every Elixir
    # process was dead, three runaways:
    #
    #     path                      before   after
    #     blocking: false, stop/1    0.00     0.00   <- the test above
    #     blocking: true,  stop/1    3.00     0.00
    #     blocking: true,  kill/1    2.97     0.00
    #
    # The fix is `Runtime`'s `rustler::Resource::down` owner-death monitor
    # (`native/tyrex/src/runtime.rs`), which fires whatever the owner was
    # executing. Revert `IMPLEMENTS_DOWN`/`down` and this test goes red at
    # ~3.0 cores while the rest of the suite stays green — which is exactly why
    # these two tests must not be consolidated: the non-blocking one was green
    # across the entire life of the leak.
    @tag timeout: 120_000
    test "CPU returns to baseline after stop/1 on the blocking path" do
      baseline = cpu_cores_used(2_000)

      pids =
        for _ <- 1..3 do
          {:ok, pid} = Tyrex.start(permissions: :none)

          # 120s, deliberately far longer than this test runs. `eval_blocking`
          # terminates the isolate itself when its own deadline expires, so a
          # short timeout reclaims the thread for the wrong reason and leaves
          # this test green against the unfixed code. The deadline must not be
          # able to fire before the assertions below.
          spawn(fn -> Tyrex.eval(@runaway, pid: pid, blocking: true, timeout: 120_000) end)

          pid
        end

      # Same hazard as the probe above. Note this is complementary to the
      # owner-death monitor, not redundant with it: `on_exit` guarantees
      # `stop/1` is *called* on every exit path, the monitor is what makes that
      # call actually reclaim the thread. With the monitor reverted this
      # cleanup runs and the threads still leak.
      on_exit(fn -> Enum.each(pids, &Tyrex.stop(pid: &1)) end)

      Process.sleep(1_000)

      # Pin that the runtimes really are parked in the NIF. If `blocking: true`
      # ever stops parking the GenServer, this test silently degrades into a
      # duplicate of the non-blocking one and stops covering the leak.
      assert Enum.all?(pids, fn pid ->
               Process.info(pid, :current_function) ==
                 {:current_function, {Tyrex.Native, :eval_blocking, 3}}
             end)

      running = cpu_cores_used(1_000)

      burners = min(3, System.schedulers_online())
      burn_floor = burners * 0.6

      assert running > baseline + burn_floor,
             "expected the blocking runaways to burn CPU (baseline #{baseline}, " <>
               "running #{running}, floor #{baseline + burn_floor} for #{burners} burners)"

      # Monitor before stopping: the parked GenServer cannot service the
      # shutdown, so each `stop/1` spends its whole timeout before escalating
      # and the process death is asynchronous to `stop/1` returning.
      refs = Enum.map(pids, &Process.monitor/1)
      Enum.each(pids, &Tyrex.stop(pid: &1))

      Enum.each(refs, fn ref ->
        assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 10_000
      end)

      # Let the worker threads finish unwinding.
      Process.sleep(1_000)

      after_stop = cpu_cores_used(4_000)
      ceiling = idle_cpu_ceiling()

      assert after_stop < ceiling,
             "CPU did not return to baseline after stop/1 on a blocking eval " <>
               "(baseline #{baseline}, running #{running}, after #{after_stop}, " <>
               "ceiling #{ceiling}) — the owner-death monitor did not reclaim the thread"
    end
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  # Cores of CPU consumed by this OS process over `window_ms` of wall clock.
  # A leaked runaway shows up as ~1.0 per runaway; an idle VM sits near 0.
  defp cpu_cores_used(window_ms) do
    os = :os.type()
    before = process_cpu_seconds(os)
    Process.sleep(window_ms)
    (process_cpu_seconds(os) - before) / (window_ms / 1_000)
  end

  # One leaked runaway is ~1.0 core; an idle BEAM churns tens of milliseconds
  # of CPU per second, under 0.05 cores. The old `baseline + 1.0` needed *two*
  # leaked threads to trip, which is the whole reason for pinning an absolute
  # ceiling here instead: 0.35 is an order of magnitude above idle churn and a
  # third of a single leak.
  #
  # Darwin pays for `ps`'s whole-second resolution: over the 4s window above,
  # quantization alone is worth ±0.25 cores, so the ceiling has to clear that.
  # 0.5 still fails on one leaked thread, which measures 0.75 or more there.
  defp idle_cpu_ceiling do
    case :os.type() do
      {:unix, :linux} -> 0.35
      _ -> 0.5
    end
  end

  # sysconf(_SC_CLK_TCK), conventionally 100 on Linux — 10ms resolution.
  @clock_ticks_per_second 100

  # Linux: /proc/self/stat fields 14 (utime) and 15 (stime), in clock ticks.
  # `ps -o time=` works here too but prints whole seconds, and that ±1s
  # measurement error is the same size as the one-leaked-thread signal this
  # probe exists to catch — so /proc is read, on Linux only, for its
  # resolution. `/proc/self` needs no pid lookup. Field 2 (comm) is
  # parenthesised and may contain spaces, so fields are counted from after the
  # final ')', which puts field 3 (state) at index 0.
  defp process_cpu_seconds({:unix, :linux}) do
    fields =
      "/proc/self/stat"
      |> File.read!()
      |> String.split(")")
      |> List.last()
      |> String.trim()
      |> String.split(" ")

    utime = String.to_integer(Enum.at(fields, 11))
    stime = String.to_integer(Enum.at(fields, 12))

    (utime + stime) / @clock_ticks_per_second
  end

  # macOS/BSD: `ps -o time=` prints [[DD-]HH:]MM:SS[.ss] — each field is 60x
  # the next.
  defp process_cpu_seconds(_os_type) do
    {output, 0} = System.cmd("ps", ["-o", "time=", "-p", System.pid()])

    output
    |> String.trim()
    |> String.split(["-", ":"])
    |> Enum.map(fn part ->
      {value, _rest} = Float.parse(part)
      value
    end)
    |> Enum.reduce(0.0, fn part, acc -> acc * 60 + part end)
  end
end
