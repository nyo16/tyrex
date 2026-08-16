defmodule TyrexApiTest do
  @moduledoc """
  Contract tests for the `Tyrex.eval/2` API boundary.

  The review of the v0.4.0 work found every promise below unenforced.
  `:timeout` was taken on trust, so `timeout: -1` reached the server and raised
  inside the GenServer — killing the runtime it was passed to and, under
  `Tyrex.Pool`'s `:rest_for_one` supervision, every runtime ordered after it.
  `timeout: :infinity` armed no deadline at all, reinstating through a
  documented option the uncapped 100%-CPU OS thread this release exists to
  eliminate. `eval/2`'s `@spec` promised an error tuple while the dead-runtime
  window handed callers an exit instead. And two terminal paths dropped their
  in-flight callers rather than draining them.

  Each test fails if the guard it covers is removed, not merely if the runtime
  misbehaves in general.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @runaway "for(;;){}"

  describe "timeout: :infinity is refused" do
    test "on the default path, and the runtime survives the refusal" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{name: :unsupported_option, message: message}} =
               Tyrex.eval("1 + 2", pid: pid, timeout: :infinity)

      assert message =~ "finite :timeout"

      # A refused option is a caller error, not a runtime fault.
      assert Process.alive?(pid)
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)

      Tyrex.stop(pid: pid)
    end

    test "on the blocking path too, so both paths agree" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:error, %Tyrex.Error{name: :unsupported_option}} =
               Tyrex.eval("1 + 2", pid: pid, blocking: true, timeout: :infinity)

      assert Process.alive?(pid)
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid, blocking: true)

      Tyrex.stop(pid: pid)
    end

    test "by the server too, for anyone calling the GenServer directly" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      # `handle_call({:eval, ...})` puts `timeout == :infinity` first in its
      # `cond` on purpose, but `eval/2` refuses `:infinity` before the call, so
      # nothing else in the suite reaches that clause — it was defence-in-depth
      # that no test could see. Delete it and this call dispatches the eval and
      # then arms its deadline with `Process.send_after(self(), _, :infinity)`,
      # which raises inside the GenServer: an uncapped runaway thread, which is
      # exactly what refusing `:infinity` exists to prevent.
      assert {:error, %Tyrex.Error{name: :unsupported_option, message: message}} =
               GenServer.call(pid, {:eval, "1 + 1", [timeout: :infinity]}, 5_000)

      assert message =~ "finite :timeout"

      # The guard replied rather than crashing, so the runtime is still serving.
      assert Process.alive?(pid)
      assert {:ok, 2} = Tyrex.eval("1 + 1", pid: pid)

      Tyrex.stop(pid: pid)
    end
  end

  describe "a malformed :timeout stays with the caller" do
    test "each bad value raises ArgumentError and leaves the runtime alive" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      # Both bands, not just the negative one. The upper bound was missed on the
      # first pass and the review caught it still live: `10_000_000_000_000`
      # raised `:badarg` inside `Process.send_after/3` and left
      # `Process.alive?/1` false, and anything above the `GenServer.call`
      # `receive after` ceiling raised in the caller *after* the eval had
      # already been dispatched — a runaway guest with no effective deadline,
      # which is exactly what refusing `:infinity` exists to prevent.
      for bad <- [-1, 0, 5.5, nil, "5", 4_294_967_295, 5_000_000_000, 10_000_000_000_000] do
        assert_raise ArgumentError, ~r/:timeout must be a positive integer/, fn ->
          Tyrex.eval("1 + 2", pid: pid, timeout: bad)
        end

        # This is the whole point: `call_timeout(-1) = 999` is a legal
        # `GenServer.call` timeout, so the value used to reach the server and
        # raise inside `Process.send_after/3`, taking the runtime with it.
        # `5.5` and `nil` used to raise `FunctionClauseError` naming a private
        # function.
        assert Process.alive?(pid), "timeout: #{inspect(bad)} killed the runtime"
        assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
      end

      Tyrex.stop(pid: pid)
    end

    test "a finite timeout is still honoured" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid, timeout: 1_000)

      Tyrex.stop(pid: pid)
    end
  end

  describe "in-flight callers are drained on every terminal path" do
    test "a plain stop/1 replies dead_runtime_error rather than leaving the caller to exit" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      caller = Task.async(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 30_000) end)

      # Let the guest actually enter the loop, so the call is genuinely in flight.
      Process.sleep(300)
      Tyrex.stop(pid: pid)

      # The `:name` alone cannot fail: `dead_runtime_exit?/1` manufactures
      # `:dead_runtime_error` from the plain `:normal` exit an *undrained*
      # caller receives, so deleting `fail_inflight/2` from `terminate/2` left
      # this green. The `:message` is the only thing that names the producer —
      # "in flight" comes from `fail_inflight/2` (the runtime replied), while
      # "already gone" comes from `eval/2`'s `catch` (the caller exited).
      assert {:error, %Tyrex.Error{name: :dead_runtime_error, message: message}} =
               Task.await(caller, 10_000)

      assert message =~ "in flight"
      refute message =~ "already gone"
      refute Process.alive?(pid)
    end

    test "every concurrent caller is drained, not just the first" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      callers =
        for _ <- 1..3 do
          Task.async(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 30_000) end)
        end

      Process.sleep(300)
      Tyrex.stop(pid: pid)

      for caller <- callers do
        # Same reasoning as above: the message selects `fail_inflight/2` as the
        # producer, so an undrained caller laundered by `dead_runtime_exit?/1`
        # can no longer satisfy this assertion.
        assert {:error, %Tyrex.Error{name: :dead_runtime_error, message: message}} =
                 Task.await(caller, 10_000)

        assert message =~ "in flight"
      end

      refute Process.alive?(pid)
    end
  end

  describe "calls into the dead-runtime window" do
    test "eval/2 returns dead_runtime_error instead of exiting" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      ref = Process.monitor(pid)
      :ok = Tyrex.kill(pid: pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      # Every deadline, heap trip and `kill/1` opens this window. The `@spec`
      # promises `{:ok, term} | {:error, Error.t()}`; before this fix the call
      # exited with `:noproc`, which is why the suite had to wrap pool calls in
      # `catch :exit, _`.
      assert {:error, %Tyrex.Error{name: :dead_runtime_error, message: message}} =
               Tyrex.eval("1", pid: pid)

      assert message =~ "already gone"
    end

    test "a call timeout is not laundered into a dead-runtime error" do
      # A process that is not a GenServer never replies, so `GenServer.call`
      # exits with `:timeout`. That reason means the server-side deadline lost
      # its race — a bug worth seeing, not a state callers should handle.
      sleeper = spawn(fn -> Process.sleep(:infinity) end)

      assert {:timeout, {GenServer, :call, _args}} =
               catch_exit(Tyrex.eval("1", pid: sleeper, timeout: 100))

      Process.exit(sleeper, :kill)
    end
  end

  describe "stop/1 escalation" do
    test "a wedged runtime is brutally killed rather than waited on" do
      # The bridge runs the allowlisted MFA *inside* the GenServer, which is the
      # only way to wedge the process itself rather than its worker thread: a
      # process parked in a dirty NIF cannot be killed promptly either.
      {:ok, pid} = Tyrex.start(permissions: :none, apply: [{Process, :sleep, 1}])

      spawn(fn ->
        Tyrex.eval(~s|Tyrex.apply("Process", "sleep", [10000])|, pid: pid, timeout: 30_000)
      end)

      # Let the bridge call reach handle_info and park the GenServer.
      Process.sleep(500)

      ref = Process.monitor(pid)
      Tyrex.stop(pid: pid, timeout: 1)

      # `:killed` is the evidence that the escalation branch ran. A graceful
      # stop reports `:normal`, and `stop/1`'s catch-all returns `:ok` either
      # way, so the return value proves nothing.
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
      refute Process.alive?(pid)
    end
  end

  describe "apply: []" do
    test "collapses to a disabled bridge" do
      {:ok, pid} = Tyrex.start(permissions: :none, apply: [])

      # An empty allowlist authorizes nothing, so installing the bridge would
      # only enlarge the surface guest code can reach.
      assert {:ok, "undefined"} = Tyrex.eval("typeof globalThis.Tyrex", pid: pid)

      Tyrex.stop(pid: pid)
    end
  end

  describe "the missing-:permissions warning" do
    test "is emitted once per VM" do
      # The warning is one-shot per VM, so any earlier test may have consumed
      # it. This test re-arms it by erasing the flag, and therefore owns
      # putting it back.
      #
      # The ordering is load-bearing in two ways, so do not "simplify" either:
      #
      #   * `on_exit` rather than a trailing `:persistent_term.put/2` — every
      #     assertion below can fail, and a restore that never runs leaves the
      #     warning armed for whatever test starts a runtime next, where it
      #     lands in an unrelated `with_log`/`capture_log` assertion as a
      #     surprise extra line.
      #   * registered *before* the `erase` — if it were registered after, a
      #     failure between the two would erase without ever queueing the
      #     restore, which is the same leak by a narrower window.
      on_exit(fn -> :persistent_term.put({Tyrex, :permissions_warned}, true) end)

      {{:ok, first}, log} =
        with_log(fn ->
          :persistent_term.erase({Tyrex, :permissions_warned})
          Tyrex.start()
        end)

      assert log =~ "without an explicit :permissions option"
      assert log =~ "the default is :none"

      {{:ok, second}, second_log} = with_log(fn -> Tyrex.start() end)

      refute second_log =~ "without an explicit :permissions option"

      Tyrex.stop(pid: first)
      Tyrex.stop(pid: second)
    end
  end
end
