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

      # 300ms deadlines against sub-millisecond work, so the window in which a
      # stale timer could fire is *inside* this test. With `timeout: 5_000` the
      # uncancelled timer fired ~4.8s after the test had already finished, and
      # deleting `cancel_timer(timer)` from the `:eval_reply` clause left this
      # green.
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid, timeout: 300)
      assert {:ok, 4} = Tyrex.eval("2 + 2", pid: pid, timeout: 300)

      # The `{:deadline, from}` clause drops a `from` it no longer holds, so a
      # stale timer leaves no other outward mark — tracing receives is how we
      # see the timer itself. This waits longer than the deadline above, so a
      # timer that was going to fire has fired by the time we stop tracing.
      :erlang.trace(pid, true, [:receive])
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

      assert {:error, %Tyrex.Error{name: :dead_runtime_error}} = Task.await(caller, 10_000)
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

      # `kill/1` ends in `catch :exit, _ -> :ok`, so the `:ok` above is true of
      # a wedged runtime that never answered as well as of an interrupted one.
      # Promptness is the property that catch-all hides: the interrupt reaches
      # into the isolate from outside and must not wait on the guest, which
      # never yields, nor on `kill/1`'s own 5s call timeout.
      assert elapsed < 2_000, "kill/1 to :DOWN took #{elapsed}ms"
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

    test "rejects a nonsense cap" do
      assert_raise ArgumentError, ~r/positive integer/, fn ->
        Tyrex.start(permissions: :none, max_heap_mb: 0)
      end
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

      # The supervisor rebuilds the child. The pool is :rest_for_one, so the
      # sibling is torn down and replaced too; calls during that window exit
      # with :noproc rather than returning an error tuple.
      assert eventually(fn ->
               try do
                 match?({:ok, 2}, Tyrex.Pool.eval(:recovery_pool, "2"))
               catch
                 :exit, _ -> false
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
