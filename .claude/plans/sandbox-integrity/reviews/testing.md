# Testing review — v0.4.0 `sandbox-integrity`

Scope: `test/tyrex_lifecycle_test.exs` (new, 282 lines), `test/tyrex_permissions_test.exs` (+199),
`test/tyrex_test.exs` (+13). Read-only review; no file modified. 141 tests pass — the question
answered here is whether they *defend* the contract or merely *execute* it.

Verdict: the suite covers every bullet of plan task 2.8, and the new permission tests are
materially better than the ones they sit beside. But two assertions are written so that the
exact regression they exist to catch would pass green, and the CPU probe — the assertion the
plan names as most-likely-to-be-dropped — is the one most likely to go red for reasons
unrelated to a leak on this project's only CI runner. Both are cheap to fix.

---

## BLOCKER

### B1. `max_heap_mb` test accepts `:timeout`, which is the failure mode it must catch
`test/tyrex_lifecycle_test.exs:166-167`

```elixir
assert {:error, %Tyrex.Error{name: name}} = Tyrex.eval(code, pid: pid, timeout: 30_000)
assert name in [:heap_limit_error, :timeout]
```

The heap path is deterministic, not racy. `near_heap_limit_callback`
(`native/tyrex/src/worker.rs:281-296`) sets `tripped`, calls `terminate_execution()`, and
returns `current_heap_limit + 8MB`; `tripped` is what turns the subsequent uncatchable
termination into `:heap_limit_error`. Against a 64 MB cap, the guest allocates 8 MB per
iteration, so the callback fires in well under a second — three orders of magnitude inside
the 30 s deadline. `:timeout` is therefore not a legitimate outcome of a *working*
implementation.

It is, however, exactly the outcome of a plausible regression: if a refactor drops the
`state.handle.terminate_execution()` line and keeps only the slack grant, V8 raises its own
limit each time the callback fires and the guest allocates indefinitely — until the eval
deadline kills it and returns `:timeout`. The test passes, the heap cap does nothing, and the
only guard against `abort()`-ing the BEAM is silently gone. Same for any change that stops
`tripped` being propagated into the error name via a path that also happens to be slow.

Note the asymmetry that makes the loose form tempting but wrong: a regression in
`create_params` wiring (`worker.rs:319-322`) aborts the whole VM and takes the suite with it —
loud. A regression in the *callback body* is silent, and `:timeout` is the tell.

```suggestion
      assert {:error, %Tyrex.Error{name: :heap_limit_error}} =
               Tyrex.eval(code, pid: pid, timeout: 30_000)

      refute Process.alive?(pid), "a heap-capped runtime is dead by contract"
```

If 30 s ever proves tight on a slow runner, raise the timeout — do not widen the accepted
name. Also delete the comment on line 164-165 ("merely getting a reply here is the
assertion"); it documents the weaker contract and will be used to justify keeping the loose
form.

### B2. CPU probe: `running > baseline + 1.0` is the wrong shape for this CI, and `ps` resolution undermines both bounds
`test/tyrex_lifecycle_test.exs:217-244`, helpers at `:262-281`

The load-bearing assertion (`after_stop < baseline + 1.0`, line 241) MUST survive — agreed,
and nothing below proposes weakening or deleting it. The problem is the *other* three
mechanisms in the same test, each of which can turn this into a red build that someone then
deletes wholesale.

**(a) Hard-coded 3 runaways vs. runner core count.** `.github/workflows/ci.yml` runs a single
`ubuntu-latest` job. Three spinning threads can only accrue `min(3, vCPU)` cores of CPU per
wall second. On a 2-vCPU runner the *entire OS process* — BEAM schedulers included — is
capped at 2.0, so the observed delta sits right at the margin of `> baseline + 1.0`; on a
1-vCPU runner or a `--cpus=1` container it is ~1.0 and the assertion fails outright, with a
message that reads "the runaways didn't burn CPU" when in fact the machine is small. Scale the
expectation to the box:

```suggestion
      cores = System.schedulers_online()
      runaways = max(1, min(3, cores - 1))

      pids =
        for _ <- 1..runaways do
          {:ok, pid} = Tyrex.start(permissions: :none)
          spawn(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 120_000) end)
          pid
        end
```
and then `assert running > baseline + 0.5 * runaways`.

**(b) `ps -o time=` has one-second resolution on Linux.** macOS `ps` prints `MM:SS.ss`; procps
`ps -o time=` documents its format as `[DD-]HH:MM:SS` with no fractional field. [INFERENCE,
from the documented format string — not executed here, since the box is macOS.] Over the
1000 ms window at line 217 and 228 that quantises every reading to whole cores: `baseline` is
0.0 or 1.0, `running` is an integer, `after_stop` over 2000 ms is 0.0 or 0.5. A single
leaked runaway contributes 1.0 and the guard is `< baseline + 1.0` — i.e. the quantisation
error is the same size as the signal the test is looking for. Two independent hardenings, both
of which strengthen rather than relax the assertion:

```suggestion
  # Cores of CPU consumed by this OS process over `window_ms` of wall clock.
  # A leaked runaway shows up as ~1.0 per runaway; an idle VM sits near 0.
  #
  # Linux `ps -o time=` only reports whole seconds, so on Linux read
  # /proc/self/stat directly (utime+stime, in 100Hz clock ticks) for the two
  # decimal places macOS `ps` already gives us.
  defp process_cpu_seconds do
    case File.read("/proc/self/stat") do
      {:ok, stat} -> proc_stat_cpu_seconds(stat)
      {:error, _} -> ps_cpu_seconds()
    end
  end
```
with `proc_stat_cpu_seconds/1` summing fields 14 and 15 (after the `comm` field, which may
contain spaces — split on `") "` first) and dividing by 100. Independently, widen the windows
to 3000 ms so even the `ps` fallback carries ≤0.33 cores of quantisation error.

**(c) The idle bound can then be tightened to catch a *single* leaked thread.** At
`+ 1.0`, one leaked runaway lands on the boundary and passes or fails by sampling luck; the
test only reliably catches all-three-leaked, which is not the regression shape a partial
refactor produces. With sub-second resolution restored, `assert after_stop < baseline + 0.5`
detects one leaked thread deterministically. This is the strengthening the plan's self-check
is asking for.

**(d) `{output, 0} = System.cmd("ps", ...)` raises `MatchError` where `procps` is absent**
(`:271`). Debian/Ubuntu `-slim` images do not ship it. Not a CI problem today, but the failure
is an unreadable `MatchError` in a helper rather than "ps unavailable". The `/proc` primary
path above removes the dependency on Linux entirely, which is the same fix.

**(e) The day field in the parser is 60×, not 24×** (`:280`, comment at `:269`). `Enum.reduce(0.0,
fn part, acc -> acc * 60 + part end)` turns `2-03:04:05` into `2*60³ + …` instead of
`2*86400 + …`. Unreachable — the test process never accrues 24 h of CPU — but the comment
"each field is 60x the next" is stated as fact and is wrong, so the next person to touch this
inherits a false premise. Fold the `DD-` field in separately, or drop `"-"` from the split
list and let it raise loudly.

**(f) `async: false` on line 11 is load-bearing for this test** and nothing says so. ExUnit
runs sync modules serially after all async modules, so the probe is safe today
(`test/tyrex_strategy_test.exs:2` is the only `async: true` file and starts no runtimes). The
plan defers "3 of 5 test files could be async" to a test-hygiene plan; that pass will flip
files without knowing this one measures process-global CPU. One comment on line 11 prevents
a very confusing future flake.

---

## WARNING

### W1. "a deadline does not fire for work that finishes in time" does not test stale timers
`test/tyrex_lifecycle_test.exs:42-53`

The comment on line 48 names the bug precisely — "A stale timer firing later would kill a
healthy runtime" — and then the test makes it impossible to observe. The evals use
`timeout: 5_000`, so an uncancelled `Process.send_after` timer would fire ~4.8 s after the
`Process.sleep(200)` on line 49, long after line 50 has asserted and line 52 has stopped the
runtime. If `cancel_timer/1` (`lib/tyrex.ex:539-544`) were removed from the `:eval_reply`
clause entirely, this test would still be green. Make the sleep outlive the deadline:

```suggestion
      assert {:ok, 3} = Tyrex.eval("1 + 2", pid: pid, timeout: 300)
      assert {:ok, 4} = Tyrex.eval("2 + 2", pid: pid, timeout: 300)

      # A stale timer firing later would kill a healthy runtime, so wait past
      # the deadline the two completed calls armed.
      Process.sleep(600)
      assert Process.alive?(pid)
      assert {:ok, 5} = Tyrex.eval("2 + 3", pid: pid)
```

### W2. `elapsed < 3_000` cannot fail
`test/tyrex_lifecycle_test.exs:22-27`

With `timeout: 1_000`, `call_timeout/1` (`lib/tyrex.ex:534`) gives the caller
`1_000 + @deadline_grace_ms = 2_000`. Either the server replies inside 2000 ms — in which case
`elapsed < 3_000` is arithmetically guaranteed — or `GenServer.call` exits and the assertion on
line 23-24 never runs. The stated intent ("the deadline must beat the caller's own call
timeout") is already fully enforced by the preceding assert; line 27 adds no falsifiable
content. The *unasserted* half of the contract is that the deadline does not fire **early**,
which nothing currently checks:

```suggestion
      # Fires at the deadline, not before it, and beats the caller's own call
      # timeout of timeout + @deadline_grace_ms.
      assert elapsed >= 1_000, "deadline fired early: #{elapsed}ms"
      assert elapsed < 2_000, "deadline took #{elapsed}ms"
```

### W3. `assert :ok = Tyrex.kill(...)` is unfalsifiable; one test consists of nothing else
`test/tyrex_lifecycle_test.exs:78` and `:84-89`

`Tyrex.kill/1` ends in `catch :exit, _reason -> :ok` (`lib/tyrex.ex:262`), so it returns `:ok`
on every input — dead pid, unregistered name, wedged runtime, timeout. `assert :ok = ...` is a
tautology. At line 78 it is harmless decoration next to a real `assert_receive {:DOWN, ...}`.
At `:84-89` it is the test's **only** assertion, so "is safe to call on an already-dead
runtime" cannot fail for any implementation of `kill/1` that returns at all. Give it content
by pinning the precondition and the promptness that the `catch` is hiding:

```suggestion
    test "is safe to call on an already-dead runtime" do
      {:ok, pid} = Tyrex.start(permissions: :none)
      Tyrex.stop(pid: pid)
      refute Process.alive?(pid)

      started = System.monotonic_time(:millisecond)
      assert :ok = Tyrex.kill(pid: pid)

      # A dead server must fail the call immediately, not park for the full
      # @default_stop_timeout before the catch-all converts the exit to :ok.
      assert System.monotonic_time(:millisecond) - started < 500
    end
```

### W4. `stop/1`'s 10 s bound cannot distinguish graceful stop from brutal-kill escalation
`test/tyrex_lifecycle_test.exs:99-105`

`stop/1` waits `@default_stop_timeout = 5_000` and only then escalates to
`Process.exit(pid, :kill)` (`lib/tyrex.ex:218-227`). Both paths finish under 10 s, so
`elapsed < 10_000` passes whether `terminate/2`'s `Native.terminate_runtime/1` unwinds the
runaway in 50 ms (the contract) or does nothing at all and the escalation cleans up 5 s later.
That degradation is precisely a Phase-2 regression. Split the two:

```suggestion
      # The graceful path must succeed on its own — reaching the 5s escalation
      # would mean terminate/2 no longer unwinds the guest.
      assert elapsed < 2_000, "stop/1 took #{elapsed}ms"
```

The escalation branch itself (`lib/tyrex.ex:220-226`, task 2.6's "escalates to brutal kill")
is then untested. It is cheaply reachable — `Tyrex.stop(pid: pid, timeout: 0)` forces the
`catch :exit` clause deterministically — and worth its own test asserting
`assert eventually(fn -> not Process.alive?(pid) end)`.

### W5. Pool forwarding of `:apply` and `:max_heap_mb` is untested
`lib/tyrex/pool.ex:66-67`; no coverage in `test/tyrex_pool_test.exs` or
`test/tyrex_permissions_test.exs:319-337`

`Keyword.take(opts, [:main_module_path, :permissions, :startup_timeout, :apply, :max_heap_mb])`
gained two entries in this diff. Only `:permissions` is exercised (`permissions_test.exs:320`).
Failure modes are asymmetric and one of them is a real safety regression:

- dropping `:apply` from that list fails closed (bridge off) — annoying, not dangerous;
- dropping `:max_heap_mb` removes the heap cap from every pooled runtime, restoring the
  `abort()`-the-BEAM behaviour that task 2.7 exists to fix, with nothing to catch it.

Two tests, both short, mirroring the existing `pool with permissions` shape:

```suggestion
    test "pool forwards :apply to every runtime" do
      {:ok, _} =
        Tyrex.Pool.start_link(name: :apply_pool, size: 2, apply: [{Enum, :sum, 1}])

      for _ <- 1..4 do
        assert {:ok, 6} =
                 Tyrex.Pool.eval(
                   :apply_pool,
                   ~s|(async () => await Tyrex.apply("Enum", "sum", [[1,2,3]]))()|
                 )
      end

      Supervisor.stop(:"apply_pool.Supervisor")
    end
```
plus a `max_heap_mb: 64` pool whose guest exhausts the heap and gets `:heap_limit_error`
(size 1 keeps dispatch deterministic).

### W6. Fail-closed permission tests assert only `%Tyrex.Error{}` — a `TypeError` satisfies them
`test/tyrex_permissions_test.exs:250` (`allow_run: false` under `allow_all: true`) and `:262`
(`allow_read: []`)

These two are the direct regression tests for audit CRITICALs 1.2 (the `allow_X: false`
inversion and the empty-list-grants-everything bug). Each does catch its *specific* original
bug, because under the bug the eval would have succeeded. But the assertion accepts any error
at all, so a change that stops `Deno.Command` or `Deno.readTextFileSync` existing, or that
breaks the runtime's ability to run either snippet, leaves the test green while proving
nothing about permissions. Pin the denial. These raise synchronously, so the shape is
`:execution_error` with the denial in `message` [INFERENCE — confirm against a local run and
pin whichever name actually comes back rather than accepting a list]:

```suggestion
      assert {:error, %Tyrex.Error{name: name, message: message}} =
               Tyrex.eval("Deno.readTextFileSync('mix.exs')", pid: pid)

      assert name == :execution_error
      assert message =~ ~r/NotCapable|PermissionDenied|read access/
```

Same treatment for `:250`. The neighbouring bridge tests (`:189-197`, `:203-211`) already do
this correctly with `assert value =~ "permission_denied"` — that is the standard to match, and
it is the reason those tests are convincing and these two are not.

### W7. `deny_import` test cannot distinguish denial from a network failure, and asserts an either/or
`test/tyrex_permissions_test.exs:109-125`

Two problems in one test. First, `assert err.name in [:promise_rejection, :execution_error]`
(`:122`) accepts both possible answers to a deterministic question; whichever one the runtime
actually produces should be pinned, or the test does not notice if that changes. Second — and
this is the substantive one — if `deny_import` regressed, the `import('https://deno.land/...')`
would attempt a **real outbound request**, which on a locked-down or offline runner fails and
produces an error of one of those two names. The test goes green on the regression it exists
to detect, having also made the suite depend on `deno.land` being up. The rejection message is
what separates the two cases:

```suggestion
      assert {:error, %Tyrex.Error{name: :promise_rejection, value: value}} = result
      # Distinguishes a permission denial from deno.land simply being unreachable.
      assert value =~ ~r/NotCapable|import access|dynamic import/
```

### W8. Cleanup runs only on the happy path; `Tyrex.start/1` is unlinked
`test/tyrex_lifecycle_test.exs:52, 127, 137, 145`; `test/tyrex_permissions_test.exs:9, 22, 30,
51, 59, 74, 82, 94, 106, 124, 136, 158, 171, 184, 198, 212, 230, 257, 264`

Every one of these tests ends in a bare `Tyrex.stop(pid: pid)` as the last statement. `start/1`
(not `start_link/1`) does not link, so any assertion that fails earlier in the body skips that
line permanently and leaves a live GenServer holding a V8 isolate and its own OS thread for
the remainder of the run. `test/tyrex_test.exs` already uses the right pattern
(`on_exit(fn -> Tyrex.stop(pid: pid) end)` at `:202`, `:359`), so this is an inconsistency
within the diff, not a new convention.

Ordinarily a leaked runtime on a failing run is tolerable. Here it is not: `cpu_cores_used/1`
measures the whole OS process, so a runtime leaked by an earlier failure in the same file
lands in the CPU probe's `baseline` — and if it is a *runaway* (lines 75, 96, 221 all spawn
unlinked callers with 60–120 s timeouts), it adds ~1.0 core to `baseline`, at which point
`running > baseline + 1.0` needs three cores of headroom it may not have. One failing test
cascades into a confusing failure in the probe that the plan most wants to keep. The fix is
mechanical:

```suggestion
      {:ok, pid} = Tyrex.start(permissions: :none)
      on_exit(fn -> Tyrex.stop(pid: pid) end)
```

Tests whose runtime is dead by contract (`:16`, `:30`, `:147`, `:156`) do not need it —
`stop/1` on a dead pid is already a no-op — but adding it is harmless and keeps the file
uniform.

### W9. `fail_inflight/2` is never exercised with more than one in-flight caller
`lib/tyrex.ex:546-559`; `test/tyrex_lifecycle_test.exs:55-68`

The in-flight map is the centrepiece of task 2.4, and `fail_inflight/2` iterates it — but every
test puts exactly one entry in it, so the `Enum.each` never runs twice and a bug that replied
to only the first (or head) entry would go unnoticed. Callers queued behind a runaway are the
realistic case: the worker is single-threaded, so a second `eval` sits in `inflight` while the
first spins. Deterministic and quick to assert:

```elixir
    test "every in-flight caller is answered when the deadline kills the runtime" do
      {:ok, pid} = Tyrex.start(permissions: :none)

      first = Task.async(fn -> Tyrex.eval(@runaway, pid: pid, timeout: 1_000) end)
      second = Task.async(fn -> Tyrex.eval("1 + 1", pid: pid, timeout: 30_000) end)

      assert {:error, %Tyrex.Error{name: :timeout}} = Task.await(first, 10_000)
      assert {:error, %Tyrex.Error{name: :dead_runtime_error}} = Task.await(second, 10_000)
    end
```
(Order the two `Task.async` calls with a short poll on `:sys.get_state/1` if the queueing
proves racy — see S4.)

### W10. The one-time `:permissions` warning has no test, and is order-dependent by construction
`lib/tyrex.ex:481-497`

Task 1.4 lists the one-time `Logger.warning` as the mitigation for a silently breaking change,
and the risk section calls it out explicitly. It is `:persistent_term`-backed
(`{Tyrex, :permissions_warned}`), so whichever `Tyrex.start` without `:permissions` runs first
in the VM consumes it — today that is an incidental call in
`test/tyrex_test.exs:412` or `test/tyrex_pool_test.exs:15`, depending on ordering and
`--seed`. Nothing asserts the warning fires, nothing asserts it fires *once*, and no test
clears the key, so the behaviour is untestable as currently arranged rather than merely
untested. Make it deterministic by taking ownership of the key:

```elixir
    test "omitting :permissions warns exactly once per VM" do
      key = {Tyrex, :permissions_warned}
      previous = :persistent_term.get(key, false)
      :persistent_term.erase(key)
      on_exit(fn -> :persistent_term.put(key, previous) end)

      first = ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} = Tyrex.start()
        on_exit(fn -> Tyrex.stop(pid: pid) end)
      end)

      assert first =~ "started without an explicit :permissions option"

      second = ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} = Tyrex.start()
        on_exit(fn -> Tyrex.stop(pid: pid) end)
      end)

      assert second == ""
    end
```

This is also the only test that would notice if the default silently reverted to `:allow_all` —
`resolve_permissions/1` and `warn_missing_permissions/0` are a single code path.

---

## SUGGESTION

### S1. `apply: []` collapsing to "bridge off" is undocumented by any test
`lib/tyrex.ex:585` (`defp build_apply_allowlist([]), do: nil`)

A settled decision with a deliberate comment ("an empty allowlist grants nothing, so installing
the bridge would only enlarge the reachable surface"), and one line to lock in next to
`permissions_test.exs:131`:
`{:ok, pid} = Tyrex.start(apply: []); assert {:ok, "undefined"} = Tyrex.eval("typeof globalThis.Tyrex", pid: pid)`.

### S2. `ext:` import test asserts only that *something* failed
`test/tyrex_permissions_test.exs:168-169`

The falsifiable content of this test is line 165 (`typeof Deno?.core?.ops?.op_apply` is
`"undefined"`); line 168's bare `%Tyrex.Error{}` would also pass if the module specifier were
merely malformed. Assert the reason: `assert value =~ "ext:"` (or `=~ "only allowed from"`),
matching the exact TypeError the plan quotes.

### S3. `blocking: true` runaway test does not assert the post-condition
`test/tyrex_lifecycle_test.exs:147-152`

`blocking_eval/3` (`lib/tyrex.ex:501-507`) stops the runtime on `:timeout`. The test asserts
the reply and stops there; one line — `refute Process.alive?(pid)` — pins the
"terminate => dead" contract on the blocking path the way `:30-40` does for the async path.
The absence of a trailing `Tyrex.stop/1` here also silently depends on that contract holding.

### S4. Replace `Process.sleep(300)` with a poll on the in-flight map
`test/tyrex_lifecycle_test.exs:64, 76, 97`

Each of these waits for a spawned caller's `eval` to reach the GenServer before killing it.
The wait is observable rather than guessable: `handle_call({:eval, ...})` returns `{:noreply,
...}` immediately after inserting into `state.inflight`, so `:sys.get_state/1` is serviced
right behind it. The file already has the helper:

```suggestion
      assert eventually(fn -> :sys.get_state(pid).inflight != %{} end)
```

This removes the sleep's dependence on scheduler latency (a loaded runner can exceed 300 ms for
process spawn plus runtime warm-up) and makes the intent explicit. Keep a short fixed sleep
after it if you want confidence that V8 has actually entered `execute_script` — the poll
guarantees the request was *registered*, which is what the `:dead_runtime_error` assertion at
`:67` actually depends on, but not that the isolate is executing.

### S5. `Task.async` turns a `:noproc` race into a test-process crash
`test/tyrex_lifecycle_test.exs:58-61`

`Task.async` links. If `kill/1` were ever handled before the eval reached the server, the
caller's `GenServer.call` exits `:noproc`, the task dies, and the link kills the test process —
reported as an exit rather than as the assertion failure it is. `Task.Supervisor.async_nolink`
(or `spawn_monitor` plus `assert_receive`) yields a readable failure. Low likelihood, near-zero
cost; combines naturally with S4.

### S6. "in-flight callers are told the runtime died under them" is filed under the wrong describe
`test/tyrex_lifecycle_test.exs:55` sits in `describe "eval deadlines are real"` but exercises
`kill/1` (line 65) and never arms a deadline — the eval's `timeout: 30_000` is deliberately
long enough never to fire. It belongs in `describe "kill/1"` at `:71`. Otherwise the `describe`
grouping is good: one block per public entry point plus one per new option, which reads well
and makes the coverage gaps above easy to spot.

### S7. Pool recovery does not assert the replacement is a *new* process
`test/tyrex_lifecycle_test.exs:200-201`

`assert is_pid(Process.whereis(:"recovery_pool.Runtime.0"))` would also pass if the name were
somehow still registered to the victim. `refute Process.whereis(:"recovery_pool.Runtime.0") == victim`
states the actual claim. (The `catch :exit, _ -> false` at `:193-195` is correct as written —
`:persistent_term.get/1` raises `ArgumentError` rather than exiting, but under `:rest_for_one`
the Registry is the first child and is never restarted by a runtime crash, so that entry
survives the rebuild window and the raise is unreachable.)

### S8. `eventually/2` fails with no diagnostics
`test/tyrex_lifecycle_test.exs:248-259`

On exhaustion it returns `false`, so `assert eventually(...)` reports "Expected truthy, got
false" with no indication of what was being waited on or for how long (5 s at the default 50
attempts). A `message` argument threaded into the `assert` — or raising with the description on
exhaustion — turns a puzzling CI failure into a legible one. Worth doing before the helper
picks up the three extra callers suggested in S4.

### S9. Native-parser tests fail slowly and leave the parked runtime unowned
`test/tyrex_permissions_test.exs:288-316`

These bypass the GenServer and call `Tyrex.Native.start_runtime/5` directly — correct, and the
right way to test the Rust parser as the last line of defence. Two small costs: each
`assert_receive ..., 30_000` means a fail-open regression costs 30 s per test (150 s across the
five) before reporting; and on that same regression the runtime starts successfully with no
Elixir owner, so its OS thread lives until the `ResourceArc` is collected. Both are
regression-only paths. A 5 s receive timeout is ample — the failure mode being tested is a
message that arrives promptly or a runtime that wrongly booted — and turns a slow red build
into a fast one.

---

## Coverage against plan task 2.8

| Requirement | Covered | Where |
|---|---|---|
| Runaway returns `:timeout` within the deadline | yes | `lifecycle:16-28` (tighten per W2) |
| Runtime usable-or-deterministically-dead afterwards | yes, and pinned | `lifecycle:30-40` — `assert_receive {:EXIT, ^pid, {:shutdown, :timeout}}` is the strongest assertion in the file; it pins the exact stop reason, not just death |
| CPU returns to idle after `stop/1` | yes | `lifecycle:214-246` (harden per B2) |
| Worker crash + pool recovery | yes | `lifecycle:177-210` |
| `:dead_runtime_error` | yes | `lifecycle:55-68` |
| `:unsupported_option` (both variants) | yes | `lifecycle:110-128`, `:130-137` — both discriminated by `:name`, and `:110` also asserts the runtime survives the refusal, which is the right shape |
| `:heap_limit_error` | nominally | `lifecycle:156-168` — see B1; as written the path may never be exercised |
| Pool `:apply` / `:max_heap_mb` forwarding | **no** | see W5 |
| One-time `:permissions` warning (task 1.4) | **no** | see W10 |
| `apply: []` ⇒ bridge off | **no** | see S1 |
| `stop/1` escalation to brutal kill (task 2.6) | **no** | see W4 |
| Multiple in-flight callers (`fail_inflight/2`) | **no** | see W9 |

`test/tyrex_test.exs:344-354` — the `:apply` allowlist added to the bridge `setup` is exactly
right: the four MFAs match the four tests that use them, and the two "non-existent
module/function" tests below (`:396`, `:404`) still pass because a non-allowlisted name now
rejects for a *different* reason than before. Both assert only
`%Tyrex.Error{name: :promise_rejection}`, so they no longer distinguish "no such function" from
"not on the allowlist" — the dedicated tests at `permissions_test.exs:186-198` cover the
allowlist path with `value =~ "permission_denied"`, so this is acceptable, but a
`refute value =~ "permission_denied"` on `tyrex_test.exs:396` would keep the two paths honest.

## Not over-mocked

No mocks, no Mox, no test doubles anywhere in the diff. Every assertion runs against a real V8
isolate, a real NIF, and real `ps` output. For a sandbox-integrity release that is the correct
call — a mocked permission container would prove nothing — and it is why the flakiness surface
is worth the attention above rather than an argument for faking anything.

## PRE-EXISTING (unchanged code, noted not counted)

- `test/tyrex_permissions_test.exs:44` — `permissions: :none` "cannot read files" asserts bare `%Tyrex.Error{}`; same weakness as W6.
- `test/tyrex_permissions_test.exs:56` — "cannot access env", same.
- `test/tyrex_permissions_test.exs:100` — `deny_net` test passes on any error, including a genuine network failure; would make a real request to `example.com` if the permission regressed.
- `test/tyrex_permissions_test.exs:332` — `pool with permissions` asserts bare `%Tyrex.Error{}`.
- `test/tyrex_test.exs:412,421,437` — `Tyrex.start()` with no `:permissions`; harmless post-change, but these are what consume the one-time warning non-deterministically (see W10).
