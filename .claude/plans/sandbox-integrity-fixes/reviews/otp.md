# Process & Thread Lifecycle Review — v0.4.0 sandbox integrity

**Verdict:** REQUIRES CHANGES

**Scope reviewed:** `lib/tyrex.ex` (`init/1`, `handle_call/3`, `handle_info/2`, `terminate/2`, `stop/1`, `kill/1`, `dead_runtime_exit?/1`, `fail_inflight/2`, `arm_deadline/3`), `lib/tyrex/pool.ex` (supervisor structure), `native/tyrex/src/lib.rs` (`start_runtime`, `terminate_runtime`, `eval`, `eval_blocking`, panic containment), `native/tyrex/src/runtime.rs` (`Runtime::drop`), `native/tyrex/src/worker.rs` (`run`'s break paths, slab removal, promise drain), `native/tyrex/src/runtimes.rs`, `test/tyrex_lifecycle_test.exs` (CPU probe, pool recovery).

Non-goals honoured: no permissions, no Rust memory safety, no Elixir idiom nits.

**How verified:** eight probe scripts in `/tmp/otpprobe/`, run against the committed arm64 build with `TYREX_BUILD=true mix run`. No repo file was modified.

| Probe | What it established |
|---|---|
| `p1.exs` | `Tyrex` runs with `trap_exit: false`; an in-flight `eval/2` caller **exits** `{:shutdown, {GenServer, :call, …}}` on supervisor shutdown |
| `p2.exs` | `:erlang.trace/3` + `trace_pattern({Tyrex, :terminate, 2})` across four teardowns: terminate/2 runs for `Tyrex.stop/1` and the eval deadline, **not** for supervisor `:shutdown` or `Process.exit(:kill)` |
| `p3.exs` | A deadline on `p3.Runtime.0` restarted **all four** pool runtimes; an unrelated in-flight caller on `Runtime.3` exited `{:shutdown, …}` |
| `p4.exs` | 5 eval deadlines in 3.5 s took the **pool supervisor down** (`DOWN … :shutdown`) |
| `p5.exs` | A 6 s allowlisted MFA made `eval(timeout: 500)` **exit** `{:timeout, …}` at 1504 ms with the runtime still alive; re-entrant `Tyrex.eval` on the same runtime is caught by OTP's `:calling_self` guard |
| `p6.exs` | `Process.exit(:kill)` → caller exits `{:killed, …}`; `Atomics.wait` **is** interruptible — thread count returned to baseline |
| `p7/p8.exs` | Controlled thread-count measurement: 5 normal start/stop cycles Δ0 threads; 5 `startup_timeout: 1` aborted inits Δ0 threads — **no leak on the init-abort path** |
| `p9.exs` | One stray `send/2` to a pooled runtime restarted every runtime in the pool |

Crate sources read: `v8-146.4.0/src/isolate.rs:967-1000,1965-2050` (`IsolateHandle` mutex + null-check contract), `deno_core-0.391.0`, `rustler-0.38.0`. Git history read: `git show master:lib/tyrex.ex` to confirm which behaviours the diff introduces.

---

## 1. The ownership chain, scenario by scenario

**The chain is sound in every direction. Nothing leaks a thread or an isolate on any path I could construct.** The redundancy is real and I judge it deliberate and worth keeping — but the *comments* have the primacy backwards, and so does the test suite. See W-2.

`terminate/2` runs only for `{:stop, …}` returns, callback exceptions, and `GenServer.stop/3`. `Tyrex` never sets `trap_exit`, so an external `exit(pid, :shutdown)` or `exit(pid, :kill)` kills the process outright and `terminate/2` is skipped (traced, `p2.exs`). `Runtime::drop` is therefore not a backstop — it is the *only* mechanism on the two most common production teardowns.

| Scenario | `terminate/2` runs? | What reclaims isolate + OS thread | Left behind |
|---|---|---|---|
| `Tyrex.stop/1` graceful | **yes** (traced) | `terminate/2` → `Native.terminate_runtime` (terminate + `Stop`); then `Runtime::drop` on process exit, redundantly | nothing |
| `stop/1` escalating to `Process.exit(pid, :kill)` (`lib/tyrex.ex:255`) | **no** (traced) | `Runtime::drop` alone, on process-heap release | nothing — but in-flight callers exit `{:killed, …}` (B-2) |
| `Tyrex.kill/1` | **yes** | `handle_call(:kill)` terminates explicitly, `fail_inflight` drains, then `terminate/2`, then `Drop` — three times over | nothing |
| eval deadline, non-blocking | **yes** (traced) | `handle_info({:deadline, …})` → `terminate_runtime`; worker's `Eval` arm sees `termination_error`, does `try_remove` + `drain_pending_promises`, breaks | nothing — but the GenServer stops, see B-1 |
| eval deadline, `blocking: true` | **yes** | `eval_blocking`'s own `tokio::time::timeout` arm terminates + sends `Stop` from the dirty-IO thread (`lib.rs:239-244`), then `blocking_eval/3` returns `{:stop, …}` | nothing |
| heap trip | **yes** | near-heap-limit closure terminates; the `Eval` arm attributes it, drains, breaks; `{:stop, {:shutdown, :heap_limit_error}}` | nothing |
| supervisor `:shutdown` (normal child shutdown, and every VM shutdown) | **NO** (traced) | `Runtime::drop` **alone** | in-flight callers exit rather than getting `dead_runtime_error` (B-2); `fail_inflight` never runs |
| supervisor `:brutal_kill` | **no** | `Runtime::drop` **alone** | same |
| owning process crashes (exception in a callback) | **yes** | `terminate/2`, then `Drop` | nothing |
| `ResourceArc` merely GC'd / `init/1` aborted before it lands | n/a | the temporary `ResourceArc` in `lib.rs:85-88` is dropped as soon as `send_to_pid` returns to a dead pid → `Drop` queues `Stop` → `worker::run` breaks on its first `recv` | nothing (measured: Δ0 threads over 5 aborted inits, `p8.exs`) |
| worker thread panic | no | `catch_unwind` (`lib.rs:64,101`) does `try_remove`; the unwind drops `MainWorker` (isolate disposed), the receiver, and the promise slab | a **zombie GenServer** until the next call — S-1 |
| `System.halt/0` | no | OS process teardown | nothing |

Three specific "this is fine, and here is why" answers:

- **`terminate/2` and `Runtime::drop` are not mutually dependent.** They can run in either order, or one without the other, safely. `IsolateHandle::terminate_execution` takes `isolate_mutex` and null-checks (`v8-146.4.0/src/isolate.rs:1973-1979`), and `Isolate::dispose_annex` nulls that pointer under the same mutex (`:994-997`) — so terminating an already-disposed isolate returns `false` rather than touching freed memory. Sending `Stop` on a closed channel is `let _ =`'d. Idempotent in both directions.
- **The slab id cannot leak through an `init/1` abort.** Every `worker::run` break path and both `worker::new` failure paths call `try_remove(runtime_id)`, and `catch_unwind` covers the rest. The only remaining window is a panic of `std::thread::spawn` itself between `insert` (`lib.rs:21`) and the closure starting — a thread-creation failure, at which point a leaked `LocalPid` is the least of the node's problems.
- **`Atomics.wait` does not park the worker outside V8's reach.** I expected this to be a hole (a futex wait is not JavaScript). It is not: `terminate_execution` interrupts it, the deadline fires normally, and the thread count returned to baseline (`p6.exs`).

**On the orchestrator's datapoint.** Removing `Native.terminate_runtime/1` from `terminate/2` leaves the CPU probe green because `Runtime::drop` covers `Tyrex.stop/1`. The converse is also true and more dangerous: **removing `Runtime::drop` also leaves the probe green**, because the probe's only teardown is `Tyrex.stop/1` (`test/tyrex_lifecycle_test.exs:286`) — the one path where `terminate/2` runs. So the release's headline regression test cannot fail for either half of the pair, while `Drop` is single-covered for supervisor shutdown and brutal kill. That is W-2.

---

## Blockers

### B-1. One runtime's eval deadline restarts the whole pool, and a burst of deadlines takes the pool supervisor down

- **Where:** `lib/tyrex.ex:564` (`{:stop, {:shutdown, :timeout}, …}`), `lib/tyrex/pool.ex:92` (`strategy: :rest_for_one`, no `max_restarts`/`max_seconds`), doc claim at `README.md:371-372`.
- **What:** This diff makes an eval deadline, a heap trip and `kill/1` **stop the GenServer**. `git show master:lib/tyrex.ex` confirms the pre-0.4.0 `handle_call({:eval, …})` had no deadline and no `{:stop, …}` for timeouts — a timeout was a caller-local `GenServer.call` giveaway. So v0.4.0 converts an ordinary, guest-triggered, caller-local condition into a **supervisor restart event**, and does so under a `:rest_for_one` pool with default intensity (`max_restarts: 3`, `max_seconds: 5`).
- **Why it matters:** two compounding effects, both measured.
  1. **Blast radius.** `:rest_for_one` restarts every child ordered after the failing one. With the Registry first, a deadline on `Runtime.0` tears down and rebuilds *all* runtimes. Probe `p3.exs`: `restarted: [true, true, true, true]`. Sibling runtimes are independent — one guest's `for(;;){}` has no bearing on another's isolate — so this is pure collateral damage, and it takes unrelated in-flight callers with it (see B-2).
  2. **Intensity.** Probe `p4.exs`, size-2 pool, `timeout: 200`, one runtime tripped repeatedly:
     ```
     trip 1 at  203ms -> :error, pool sup alive: true
     trip 2 at  582ms -> :error, pool sup alive: true
     trip 3 at  963ms -> :error, pool sup alive: true
     trip 4 at 1341ms -> :error, pool sup alive: true
     trip 5 at 3541ms -> :error, pool sup alive: false
     pool supervisor DOWN: :shutdown
     ```
     Five guest timeouts in 3.5 seconds destroy the pool. `Tyrex.Pool` is documented to live in the application supervision tree (`README.md:543-546`), where its `:shutdown` then counts against *that* supervisor's intensity. Untrusted or merely slow guest code — the population this release exists to serve — reaches this trivially. A single stray `send/2` to a pooled runtime does the same thing (`p9.exs`), because the module defines `handle_info/2` clauses and so overrides `use GenServer`'s log-and-ignore default.
- **Evidence:** `p3.exs`, `p4.exs`, `p9.exs` above; `git show master:lib/tyrex.ex` for the pre-existing behaviour. `README.md:371-372` — "Under a supervision tree or a `Tyrex.Pool` the runtime is replaced automatically, so callers only have to retry" — is new in this diff (it appears as an addition in `git diff master -- README.md`) and is false in both respects.
- **Suggested direction:** the runtime children are genuinely independent; only the Registry needs ordering. Nest them — a two-child `:one_for_all` (or `:rest_for_one`) tree of `{Registry, runtime_supervisor}` where the runtime supervisor is `:one_for_one` — so a deadline replaces exactly one runtime. Then set an explicit `max_restarts`/`max_seconds` on the runtime supervisor, sized against the fact that *the guest chooses the failure rate*; the default of 3-in-5 is a policy for code faults, not for a deadline that fires on purpose. Do **not** reach for `restart: :transient`: it would make `{:shutdown, :timeout}` delete the child permanently rather than replace it. Whatever is chosen, `README.md:371` and the `Tyrex` moduledoc's "under a supervisor the child is simply replaced" need to state the real blast radius and the intensity ceiling.

### B-2. `dead_runtime_exit?/1` misses `:shutdown` and `:killed`, so `eval/2`'s `@spec` and its new documented guarantee are false on the paths that dominate production

- **Where:** `lib/tyrex.ex:634-638`; claim at `lib/tyrex.ex:365-370`; `@spec` at `lib/tyrex.ex:384`; same for `Tyrex.Pool.eval/3` (`lib/tyrex/pool.ex:104`).
- **What:** task 2.4 added `dead_runtime_exit?/1` covering `:noproc`, `:normal`, `{:shutdown, _reason}`. It does not cover **bare `:shutdown`**, which is what `supervisor.erl` sends to a child with an integer `:shutdown` spec (the default 5000), nor **`:killed`**, which is what `:brutal_kill` and `Tyrex.stop/1`'s own escalation branch (`lib/tyrex.ex:255`) produce. `{:shutdown, _reason}` and `:shutdown` are different terms; only the former matches.
- **Why it matters:** the docs at `:365-370` state the guarantee categorically — "returns `{:error, %Tyrex.Error{name: :dead_runtime_error}}` rather than exiting, so the `@spec` holds" — and W5/task 2.3 promises that "every terminal path drains in-flight callers". Neither holds for supervisor-initiated teardown, because `terminate/2` (and therefore `fail_inflight/2`) does not run at all without `trap_exit`. Combined with B-1, a *healthy* runtime's in-flight caller is exited by a *different* runtime's deadline. Measured, `p3.exs`: `A) sibling in-flight caller observed: {:exited, {:shutdown, {...}}}`.
- **Evidence:**
  - `p1.exs`: `trapping exits? {:trap_exit, false}` / `in-flight caller observed: {:exited, {:shutdown, {...}}}` under `Supervisor.stop/1`.
  - `p2.exs` trace: `(a) supervisor :shutdown -> terminate/2 called? false`, `(c) Process.exit(:kill) -> terminate/2 NOT called`, versus `(b)`/`(d)` where it is called.
  - `p6.exs`: `in-flight caller after Process.exit(:kill): {:exited, {:killed, {...}}}`.
- **Suggested direction:** two honest answers, and the codebase's own standard is that silence is not one of them. Either **widen the predicate** — add `:shutdown` unconditionally, and `:killed` if `stop/1`'s escalation is to keep its current shape — or **narrow the documentation** to "tyrex-initiated terminal states only; a supervisor tearing the runtime down still exits the caller, as OTP intends." I lean to widening for `:shutdown` (a supervisor shutdown is unambiguously "the runtime was already gone") and narrowing the doc for `:killed`. Note the tempting third option — `Process.flag(:trap_exit, true)` in `init/1` so `terminate/2` always runs — is a **trap**: `init/1` uses `Task.async`, so the GenServer would then receive `{:EXIT, task_pid, :normal}`, and because the module defines its own `handle_info/2` clauses the `use GenServer` default is overridden and that message is a `FunctionClauseError` crash. Verified in shape by `p9.exs`, where any unmatched message crashes the runtime.

---

## Warnings

### W-1. A blocking allowlisted MFA suspends the eval deadline entirely; refusing `blocking: true` does not cover this direction

- **Where:** `lib/tyrex.ex:506-524` (`handle_info({:apply, …})` invokes the MFA inline), deadline armed at `lib/tyrex.ex:640-643`, refusal at `lib/tyrex.ex:664-672`.
- **What:** the `:blocking_with_apply` refusal blocks *one* direction of the reentrancy — the GenServer parking inside the NIF while the bridge needs it. The other direction is unguarded: the MFA runs inside `handle_info`, so while it runs the GenServer cannot process its own `{:deadline, from}` message. The deadline is not a deadline; it is a deadline *plus however long the bridge is busy*.
- **Why it matters:** probe `p5.exs`, `apply: [{P5, :slow, 1}]` sleeping 6000 ms, `eval(timeout: 500)`:
  ```
  A) eval(timeout: 500) with a 6s allowlisted MFA
     -> {:EXIT, {:timeout, ...}} after 1504ms
  A) runtime still alive right after? true
  A) runtime alive 6.5s later? false
  ```
  The caller exits with exactly the `{:timeout, {GenServer, :call, …}}` that `lib/tyrex.ex:368-370` describes as meaning "the server-side deadline lost its race, which is a bug and must not be swallowed" — reached here not by a race but structurally, from a documented, supported configuration. The runtime is only terminated when the MFA finally returns, five seconds past its deadline, and the pool slot is held for the whole time. This is not the 299.6% CPU class (the worker thread is parked awaiting the reply, not spinning), but it is a hole in "deadlines are real."
- **Evidence:** `p5.exs` output above. Note the release's own test suite already relies on this behaviour to wedge a runtime — `test/tyrex_api_test.exs:152-171` uses `apply: [{Process, :sleep, 1}]` precisely because "the bridge runs the allowlisted MFA *inside* the GenServer, which is the only way to wedge the process itself." The mechanism is understood; its effect on `:timeout` is not written down anywhere.
- **Suggested direction:** either run the allowlisted MFA off the message loop (a monitored `Task` whose completion is delivered as a message, so `{:deadline, …}` stays serviceable), or — if keeping it inline is the deliberate trade for the bridge's simplicity — say so under `:apply` and under `:timeout`: allowlisted functions must not block, because bridge time is not covered by the eval deadline. Cross-runtime cycles (runtime A's MFA calls `Tyrex.eval` on runtime B, whose MFA calls back into A) are the same defect at a larger radius and are covered by the same fix or the same sentence.

### W-2. `Runtime::drop`'s comment calls it a fallback; it is the sole reclamation path for supervisor shutdown and brutal kill, and no test covers those

- **Where:** `native/tyrex/src/runtime.rs:18-31`; `lib/tyrex.ex:569-585`; `test/tyrex_lifecycle_test.exs:258-304`.
- **What:** `Runtime::drop` opens with "Best-effort shutdown if the Elixir GenServer never got to terminate the runtime (e.g. the `ResourceArc` was simply GC'd, or the owning process was brutally killed)" — framing it as an exceptional path. It is the primary path. `terminate/2`'s `Native.terminate_runtime` call, conversely, is redundant for reclamation in **100% of the cases where it runs**: `Drop` follows it microseconds later on the same teardown, and the plan's own Phase-4 verify table records that deleting it leaves the CPU probe green.
- **Why it matters:** the asymmetry runs the opposite way from what the comments say, and the test suite cannot correct the record. The CPU probe's only teardown is `Enum.each(pids, &Tyrex.stop(pid: &1))` (`test/tyrex_lifecycle_test.exs:286`) — the doubly-protected path. Deleting `Runtime::drop` alone leaves it **green** while breaking supervisor shutdown and brutal kill, i.e. every VM shutdown and every `stop/1` escalation. A maintainer reading `runtime.rs:19-21` and looking for something to simplify has been pointed at the load-bearing half.
- **Evidence:** `p2.exs` trace results (terminate/2 absent for `:shutdown` and `:kill`, present for `stop/1` and the deadline); `test/tyrex_lifecycle_test.exs:286`; plan Phase 4 verify table, row 4.3.
- **Suggested direction:** keep both — the redundancy is cheap, the orderings are provably safe, and `terminate/2` running `fail_inflight` before the native call is worth keeping for its own reasons. Invert the two comments so they state which is primary and why (`Tyrex` does not trap exits, so `terminate/2` is skipped by every externally-signalled teardown). Then extend the CPU probe with two more teardown cases — `Supervisor.stop/1` and `Process.exit(pid, :kill)` — so `Runtime::drop` is defended by a test that can go red. Today it is not.

---

## Suggestions

### S-1. A panicked worker leaves a zombie GenServer that reports `alive?` and is a valid pool target

`native/tyrex/src/lib.rs:103-118` catches the unwind, removes the slab entry and exits the thread — but nothing tells the owning GenServer. Calls are *not* lost: `worker_sender.send` fails and both `eval` (`lib.rs:180-185`) and `eval_blocking` (`lib.rs:233-237`) short-circuit to `dead_runtime_error`, and in-flight callers get it from the dropped oneshot senders. So the state is consistent, and item 5's worse case — "accepting calls that will never be answered" — does not occur. What does occur is *lazy* discovery: if the worker panics while the GenServer is idle, the process stays alive holding a `ResourceArc` to a departed thread, `Process.alive?/1` says `true`, and the pool's strategy will route the next request to it. That request is burned (and, under B-1, its `{:stop, …}` then restarts the rest of the pool). The panic handler already has the owning pid available — it is the `pid` argument inserted into the slab at `lib.rs:21` — so sending it a notification there would make the GenServer stop immediately instead of waiting to be discovered. Small change, removes a state that is hard to reason about.

### S-2. The panic path can `try_remove` a slab id that has been reused by a different runtime

`native/tyrex/src/lib.rs:106` calls `runtimes::lock_or_recover().try_remove(runtime_id)` unconditionally on unwind, but every break path inside `worker::run` has already called it (`worker.rs:594, 629, 702, 715, 722`). If a panic occurs *after* one of those — during `drain_pending_promises`, or during `MainWorker`'s isolate disposal as the frame unwinds — the id has already been freed, and `slab::Slab` reuses freed slots densely, so a concurrent `start_runtime` may have taken it. The second `try_remove` then evicts the *new* runtime's pid; its guest's `Tyrex.apply` calls hit `op_apply`'s `None` arm (`worker.rs:41-46`), log "dropping reply", and the JS promise never settles until the eval deadline. Narrow, but the codebase already has the right idiom for it two lines up: `startup_reported: Cell<bool>` exists for exactly this class of double-reporting. A `removed: Cell<bool>` shared with the break paths, or having `run` return whether it removed, closes it.

### S-3. `init/1`'s `Task.async` + `Task.await` is unidiomatic but correct; the cost is a 31-second supervisor stall, not a leak

Answering the assignment's four sub-questions directly, since three of them turn out to be non-issues:

- **A `Task` linked to a process still inside `init/1`** is fine. If the task crashes, the link kills the initialising GenServer and `:gen.start` reports `{:error, reason}` to the caller — the same outcome as `{:stop, reason}`.
- **`Task.await` timeout** leaves the task running, but only for microseconds: `Task.await/2` exits the caller, the caller is still inside `init/1`, and the abnormal exit propagates over the link and kills the task. The inner `after startup_timeout` clause normally fires first anyway.
- **The NIF delivering to a dead pid** is handled, and this is the part I most expected to be broken. The `ResourceArc` built at `lib.rs:85-88` is a temporary; when `send_to_pid` fails, nothing else holds it, so `Runtime::drop` runs immediately, terminates the isolate and queues `Stop` — which `worker::run` then reads on its very first `recv`. Measured against a control: 5 normal start/stop cycles Δ0 threads, 5 `startup_timeout: 1` aborted inits Δ0 threads (`p8.exs`). No leak.
- **The slab id inserted before the thread spawns** cannot leak on any `init/1` abort, for the same reason.

So `handle_continue` would buy no correctness. What it would buy is not blocking the parent supervisor for up to `startup_timeout + 1_000` (31 s by default) per child — and `Tyrex.Pool` starts its children sequentially, so a size-8 pool can stall its parent for four minutes in the worst case, during which the supervisor cannot process its own shutdown. That is a real operational cost, but it is **pre-existing** (`git show master:lib/tyrex.ex` has the identical `Task.async`/`Task.await` shape) and the diff only changed the arguments passed through it. I would not gate this release on it; I would note it as the one place where the current design has a cost and `handle_continue` has a name.

### S-4. The pool-recovery test's `catch :exit, _ -> false` now masks the exits B-2 is about

`test/tyrex_lifecycle_test.exs:237-243` retries through `catch :exit, _ -> false`, with a comment saying "calls during that window exit with `:noproc` rather than returning an error tuple". After task 2.4, `:noproc` *is* converted (`lib/tyrex.ex:635`) — so the comment is stale, and the surviving exits the catch is actually swallowing are the `:shutdown` ones from B-2. Tightening it to catch only what it means to catch would have surfaced B-2 during Phase 4.

---

## Persistent prior findings

None. Every prior finding in my area — W3 (`timeout: :infinity`), W4 (`timeout: -1`), W5 (terminal-path drain), W6 (`:noproc` exits), W9 (CPU probe), W10 (panic containment) — is genuinely addressed by the code as committed. B-2 is not W6 recurring: W6 named `:noproc` and `:noproc` is fixed; `:shutdown` and `:killed` are gaps in the *new* predicate, reachable only because the same diff made supervisor restarts a routine event.

## Pre-existing (one line each)

- `lib/tyrex.ex:437-473` — `Task.async`/`Task.await` in `init/1` blocks the parent supervisor for up to `startup_timeout + 1_000`; PRE-EXISTING (identical on `master`), see S-3.
- `lib/tyrex.ex:506-566` — no catch-all `handle_info/2`, so `use GenServer`'s log-and-ignore default is overridden and any stray message crashes the runtime; PRE-EXISTING in shape, newly amplified by `:rest_for_one` (see B-1, probe `p9.exs`).
- `lib/tyrex/pool.ex:92` — `:rest_for_one` over independent runtime children; PRE-EXISTING choice, newly consequential because this diff makes runtimes stop on deadline (see B-1).
