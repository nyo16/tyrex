# Elixir / OTP review — v0.4.0 `sandbox-integrity`

Scope: `lib/tyrex.ex`, `lib/tyrex/native.ex`, `lib/tyrex/runtime.ex`, `lib/tyrex/pool.ex`, `lib/tyrex/error.ex`.
Read-only review; no source or test file was modified. Rust and tests were read only as far as needed to
resolve Elixir-side questions (`Drop`, `env.pid()`, dispatch of the new stop reasons).

**Verdict: no BLOCKER.** The in-flight state machine is sound — I traced every add/remove path and could
not construct a leak or a double reply. The findings below are seven WARNINGs, all with discrete fixes,
plus suggestions. The two most consequential are W1 (`timeout: :infinity` silently disables the very
deadline this release exists to add) and W2 (`stop/1` and the blocking stop path skip `fail_inflight/2`).

---

## What is correct as written (recorded so it is not re-litigated)

- **The `:absent` sentinel is handled consistently.** `arm_deadline/3` (`lib/tyrex.ex:535-542`) is the only
  writer of `nil`, and it writes `nil` *only* on the `:infinity` clause, which arms no timer. Therefore
  `handle_info({:deadline, from})` (`:477`) can never observe a `nil` timer, and `handle_info({:eval_reply,
  ...})` (`:455`) routes it through `cancel_timer(nil)` (`:544`). `Map.pop/3` with `:absent` correctly
  distinguishes "no entry" from "entry with no timer" in both handlers.
- **No entry can leak and no caller can be replied to twice.** Every handler removes the entry from
  `inflight` *before* replying, and `fail_inflight/2` (`:551`) then operates on the already-reduced map:
  `:kill` (`:435`), eval_reply (`:465-473`), deadline (`:490-499`), apply-reply failure (`:451`). A
  `Process.cancel_timer/1` that loses the race leaves a `{:deadline, from}` in the mailbox, which the
  `:absent` branch discards. `from` is `{pid, ref}` with a fresh ref per call, so keys cannot collide.
- **The 1000 ms grace is applied on every caller path.** `eval/1` delegates to `eval/2`; `eval!/1,2`
  delegate to `eval/2`; `Tyrex.Pool.eval/3` forwards opts into `Tyrex.eval/2` (`lib/tyrex/pool.ex:110`).
  There is no path that reaches `GenServer.call` without `call_timeout/1`. `timeout: 0` behaves sanely
  (`send_after(_, _, 0)` fires immediately, the isolate is terminated, `:timeout` is returned).
- **`stop/1` calling `server(opts)` twice (`:210` and `:220`) is required, not a slip.** Bindings made in a
  `try` body are not in scope in its `catch` clauses. Worth a one-line comment so a future reader does not
  "fix" it into a compile error.
- **No shutdown path regressed by deleting `stop_runtime`.** `terminate/2` (`:502`) is *not* reached on
  supervisor shutdown — `Tyrex` does not trap exits, so `exit(pid, :shutdown)` kills it outright — nor on
  `stop/1`'s brutal-kill escalation. Both are covered by `impl Drop for Runtime`
  (`native/tyrex/src/runtime.rs:17-32`), which calls `terminate_execution()` *before* sending `Stop`. The
  old cooperative `stop_runtime` would not have covered the runaway case at all, so this is a strict
  improvement. See S6 for a doc nit.
- **`init/1`'s `pid = self()` is not a misrouted reply.** `start_runtime` replies to `env.pid()` — the
  `Task` — and uses the passed `pid` only to register the bridge's `{:apply, ...}` target
  (`native/tyrex/src/lib.rs:24, 36`). The `receive` inside the `Task` is correct.
- **`authorize/3` (`:625`) is the right shape.** Guest strings are only ever used as a map key; the module
  and function come from the allowlist. Deleting `to_module/1`/`to_atom/1` closes the
  `String.to_existing_atom/1` module-existence oracle as a side effect. Checking the allowlist before the
  arity/export check is the correct order.

---

## WARNING

### W1 — `timeout: :infinity` silently disables the deadline on the default (non-blocking) path
`lib/tyrex.ex:532`, `:535-537`, doc at `:318-325`

The blocking path *refuses* `:infinity` with an explicit `:unsupported_option` whose message is "an
unbounded park would consume a dirty-IO scheduler thread for the life of the VM" (`:413-430`, `:238-245`).
The non-blocking path accepts it: `call_timeout(:infinity)` returns `:infinity` and `arm_deadline/3` stores
`from => nil` with no timer. The consequence is strictly worse than the case that was refused — a
non-yielding guest burns the per-runtime OS thread at 100% with no cap and no scheduler-utilisation
signal, which is the exact defect this release exists to close — and the caller blocks forever.

`eval/2`'s docs describe `:timeout` as "Wall-clock deadline in milliseconds... On expiry the V8 isolate is
terminated" and never mention that `:infinity` opts out. Via `Tyrex.Pool.eval(pool, code, timeout:
:infinity)` this permanently consumes a pool slot.

It is recoverable (`kill/1` still works, because the GenServer is idle), which is why this is not a
BLOCKER. Pick one and state it: refuse `:infinity` on both paths for symmetry, or document loudly under
`:timeout` that `:infinity` disables the kill switch and the runaway is then only reclaimable via
`kill/1`/`stop/1`. The current silence is the worst of the three.

### W2 — `stop/1` and `blocking_eval/3` skip `fail_inflight/2`, so in-flight callers exit instead of getting an error tuple
`lib/tyrex.ex:512-526`, `:502-510`

Every terminal path calls `fail_inflight/2` except two:

1. `blocking_eval/3`'s three `{:stop, {:shutdown, name}, error, state}` returns pass `state` **unchanged**
   (`:517-521`). Blocking and non-blocking evals can coexist on one runtime — the non-blocking path
   returns `{:noreply, ...}` immediately — so a blocking timeout/heap-limit tears the process down while
   pending non-blocking callers are still in `inflight`. They receive nothing and exit with
   `{{:shutdown, :timeout}, {GenServer, :call, ...}}`.
2. `terminate/2` does not call it either, so a plain `Tyrex.stop/1` with an eval in flight leaves that
   caller to exit with `{:normal, {GenServer, :call, ...}}` — while `kill/1`'s docs explicitly promise
   "Any in-flight `eval` callers receive `{:error, %Tyrex.Error{name: :dead_runtime_error}}`" (`:230-233`)
   for what is otherwise the same situation.

One fix covers both: call `fail_inflight(state, :dead_runtime_error)` at the top of `terminate/2`. The
handlers that already call it leave `inflight: %{}` in the returned state, so there is no double reply, and
`GenServer.reply/2` is still valid during `terminate/2`. That also makes the invariant "every stop path
drains `inflight`" structural rather than something each new `{:stop, ...}` return has to remember.

No test covers a mixed blocking/non-blocking runtime.

### W3 — `eval/2` exits rather than returning `{:error, ...}` when the runtime is dead, and v0.4.0 makes death routine
`lib/tyrex.ex:337-342`, `lib/tyrex/pool.ex:104-110`

`@spec eval(binary(), Keyword.t()) :: {:ok, term()} | {:error, Error.t()}` — but a `GenServer.call` to a
dead or not-yet-restarted named runtime exits `:noproc`. Before this patch a timeout left the runtime
alive, so this was rare. The new contract is "terminate => dead => caller restarts", so *every* deadline,
heap-limit and `kill/1` now produces a window in which the next `Tyrex.eval/2` or `Tyrex.Pool.eval/3`
exits instead of returning. The patch's own test acknowledges this and works around it
(`test/tyrex_lifecycle_test.exs:189-195`: "calls during that window exit with `:noproc` rather than
returning an error tuple", wrapped in `catch :exit, _ -> false`). A consumer following the documented
"under a supervisor the child is simply replaced" advice now has to handle two error channels.

Fix: wrap the `GenServer.call` in `catch :exit, {reason, {GenServer, :call, _}} when reason in [:noproc,
:normal] or elem-shape `{:shutdown, _}` -> {:error, %Error{name: :dead_runtime_error}}`. That restores the
spec and gives callers a single channel. Leave a caller-side `:timeout` exit propagating, since with the
grace in place it means the server itself is wedged.

### W4 — an unvalidated `:timeout` crashes the shared runtime, and in a pool takes its siblings with it
`lib/tyrex.ex:532-533`, `:539-542`, `lib/tyrex/pool.ex:92`

`:timeout` is never validated. `Tyrex.eval(code, pid: p, timeout: -1)` passes `call_timeout(-1) = 999` (a
legal call timeout), reaches the server, and `Process.send_after(self(), {:deadline, from}, -1)` raises
`ArgumentError` **inside the GenServer** — the runtime dies. Through `Tyrex.Pool.eval/3` the pool is
`:rest_for_one` with the runtimes after the registry, so one caller's bad argument restarts every runtime
ordered after the selected one. `timeout: 5.5` or `timeout: nil` raises a `FunctionClauseError` naming a
private function (`Tyrex.call_timeout/1`) in the caller — noisy, but harmless by comparison.

Given `validate_opts!/1` validates every *start* option eagerly and with a written explanation, `:timeout`
deserves the same treatment: add `when is_integer(timeout) and timeout >= 0` to `call_timeout/2`'s clause
and a raising fallback that names the option. That keeps the failure in the caller, where it belongs.

### W5 — the 1000 ms grace assumes a responsive mailbox, but the bridge runs arbitrary code *inside* the GenServer
`lib/tyrex.ex:75`, `:439-441`, `:654-668`

`handle_info({:apply, ...})` calls `authorize_and_apply/4` -> `invoke/3` -> `apply/3` synchronously in the
GenServer. Any allowlisted function that takes longer than `@deadline_grace_ms` — an HTTP client, an Ecto
query, a large `File.read!` — blocks the `{:deadline, from}` message for its whole duration. The caller's
`GenServer.call` timeout (`deadline + 1000`) can then expire first, and the caller exits with `:timeout`
instead of receiving `{:error, %Tyrex.Error{name: :timeout}}`. That is the pre-0.4.0 failure mode,
reachable precisely on the runtimes that opted into the bridge — the ones most likely to be running
untrusted code.

The isolate *is* still terminated once the apply returns, so the CPU leak stays bounded; what is lost is
the guaranteed error tuple, which is the headline deliverable. The comment at `:72-75` ("the server-side
deadline must win the race") states an invariant the bridge can violate.

Fix: run `invoke/3` in a `Task` and reply to the worker asynchronously (keeping the GenServer free to
service deadlines), or at minimum document that a slow allowlisted MFA can cost you the deadline
guarantee, since head-of-line blocking is inherent to running guest-triggered code in the mailbox owner.

### W6 — `stop/1` returns `:ok` without confirming the process actually died
`lib/tyrex.ex:209-231`

The escalation branch fires `Process.exit(pid, :kill)` and returns `:ok` immediately. A process parked
inside `Native.eval_blocking/3` — a dirty-IO NIF — cannot be killed until the NIF returns, so `stop/1`
reports success while the runtime, its OS thread, and its registered name are all still live, for up to
the caller's blocking `:timeout`. A subsequent `Tyrex.start_link(name: same_name)` then gets
`{:error, {:already_started, pid}}`.

This release's own thesis is that "`stop/1` returning `:ok` is not evidence of reclamation"
(plan.md, Phase 2 preamble); this branch reintroduces exactly that property on the one path where the
escalation is needed. Fix: `ref = Process.monitor(pid)`, `Process.exit(pid, :kill)`, then a bounded
`receive {:DOWN, ^ref, ...}` before returning.

Also note this branch is **untested**. The lifecycle test "defaults to a finite timeout rather than
`:infinity`" (`test/tyrex_lifecycle_test.exs:89-104`) drives a *non-blocking* runaway, where the GenServer
is idle and `GenServer.stop/3` succeeds normally — so `refute Process.alive?(pid)` there is asserting the
graceful path, not the escalation. A test that starts a `blocking: true` eval with a long timeout and then
calls `stop/1` would exercise it.

### W7 — `kill/1` reports `:ok` when it did nothing
`lib/tyrex.ex:257-261`

`catch :exit, _reason -> :ok` swallows the `:timeout` exit from the 5 s `GenServer.call` just as readily as
`:noproc`. The doc claims "Unlike `stop/1` this works on a runtime that is wedged inside a guest that never
yields" — true on the default async path (the GenServer is idle while the guest spins), false when the
GenServer is parked in `Native.eval_blocking/3`, and in that case the caller cannot tell the difference.

Since `kill/1` is the API's stated escape hatch for a wedged runtime, "I could not reach the server" and
"the server is already gone" should not collapse to the same answer. Narrow the catch to `:noproc` /
`:normal` / `{:shutdown, _}` and let a genuine `:timeout` exit surface, or document the limitation next to
the claim.

### W8 — unknown top-level options are still silently dropped, in a release that rejects unknown permission keys
`lib/tyrex.ex:672-680`, `:282`

`validate_opts!/1` builds a fresh keyword list by `Keyword.get`ting five known keys, so anything else
vanishes. The patch argues the opposite position one screen away, for permission keys: "A typo in a
permission key is silently permissive, so it is rejected rather than dropped" (`:702-706`). The same
reasoning applies here:

- `Tyrex.start(permisions: :allow_all)` -> `:none` plus the migration warning. Fails closed; annoying.
- `Tyrex.start(aply: [{Enum, :sum, 1}])` -> bridge silently off; the guest gets `permission_denied` and
  the operator has no signal.
- `Tyrex.start(permissions: :none, max_heap: 64)` -> **heap cap silently absent**, and per `start/1`'s own
  docs the consequence is "a guest that exhausts memory `abort()`s the entire BEAM". That one fails *open*
  on the exact hazard `:max_heap_mb` was added for.

Fix: raise on `Keyword.keys(opts) -- @runtime_opts` inside `validate_opts!/1`.

On the brief's question: the `start/1` vs `start_link/1` asymmetry is **not** a bug. `Keyword.take(opts,
@runtime_opts)` at `:282` only strips `:name` (which `validate_opts!/1` would ignore anyway), so today it
is redundant. It becomes load-bearing the moment you add the unknown-key check above — keep it, and add
`:name` to the take list explicitly rather than relying on `@runtime_opts` happening to exclude it.

### W9 — `warn_missing_permissions/0`: read-then-put is racy, and the cost is global
`lib/tyrex.ex:694-718`

The `get`/`put` pair is not atomic, so two processes starting runtimes concurrently can both log and both
call `:persistent_term.put/2`. That matters more than the duplicate log line: inserting a *new*
`persistent_term` key triggers a global literal-area GC that scans every process on the node. Once at boot
is a fair price; the race makes "once per VM" (as the warning text itself claims) best-effort. Note also
that it runs in the *caller's* process — for `Tyrex.Pool` that is inside `Supervisor.init/1`.

The pool case is safe in practice (children start serially), so this is low severity. Two cheap
improvements: guard with a `:persistent_term.get/1` inside a `try` and accept the race explicitly in a
comment, and — since this is a one-release migration aid — record the v0.5.0 removal somewhere durable so
the key and the branch do not outlive their purpose.

---

## SUGGESTION

- **S1 — `decode_promise_rejection/1` no longer does what its name says.** `lib/tyrex.ex:584-594`. It now
  also decodes `{:ok, json}` and is called on the whole reply at `:465` and `:524`. Rename to
  `decode_reply/1`. Secondary: `{:ok, json} when is_binary(json)` falls through to `_ -> error` for a
  non-binary, silently returning an undecoded `{:ok, term}` to the caller. The NIF only ever sends
  binaries, so either the guard or the fallthrough is dead — make it explicit which.

- **S2 — `invoke/3`'s breadth is justified; its silence is not.** `lib/tyrex.ex:654-668`. Rescuing
  everything *and* `catch kind, reason` is correct here: a guest can trigger a `raise`, a `throw`, or an
  `exit` out of an allowlisted function, and none of those should destroy a shared runtime. Two gaps:
  (a) `__STACKTRACE__` is discarded and nothing is logged, so a genuine *host* bug inside an allowlisted
  function is invisible to the operator and visible only to the guest — add
  `Logger.warning(Exception.format(:error, exception, __STACKTRACE__))` before rejecting;
  (b) `Exception.message/1` is serialised straight into guest JavaScript. In a release about sandbox
  integrity, host exception messages routinely carry filesystem paths, SQL, or connection strings from
  third-party libraries. Consider a generic guest-facing string plus the full detail host-side.
  Minor: `encode_json(apply(...))` sits inside the rescue, so a `Jason.Encoder` implementation that raises
  is attributed to the callee. Defensible, but worth knowing.

- **S3 — `build_apply_allowlist(nil)` is dead code that weakens a strict validator.** `lib/tyrex.ex:721`.
  Nothing can pass `nil`: `Keyword.get(opts, :apply, false)` defaults to `false` and `Keyword.take/2` omits
  absent keys. Every other shape raises with a paragraph of explanation; `apply: nil` silently disables the
  bridge. Delete the clause.

- **S4 — `@runtime_opts` is duplicated verbatim in the pool.** `lib/tyrex.ex:77` and
  `lib/tyrex/pool.ex:64`. This patch had to add `:apply` and `:max_heap_mb` in both places; the next option
  will too, and forgetting the pool copy silently drops the option (see W8 for what that costs). Expose it
  (`@doc false def runtime_opts`) or move it to a shared module.

- **S5 — no catch-all `handle_info/2`.** `lib/tyrex.ex:439-500`. Any unexpected message crashes the runtime
  with a `FunctionClauseError`. Nothing in the current code sends one (`Task.await/2` flushes its own
  `:DOWN`, and the startup reply goes to the `Task`), so this is defensive — but this process now owns the
  only kill switch for an uncapped OS thread, and it is a two-line insurance policy.

- **S6 — narrow `stop/1`'s catch, and fix the `terminate/2` comment.** `lib/tyrex.ex:214-231`, `:502-510`.
  `catch :exit, _reason` also swallows a crash raised *by* `terminate/2` and any custom `:reason` the
  caller passed, so `stop/1` can never report failure. Narrow to `:noproc` and `:timeout`. Separately, the
  comment in `terminate/2` reads as though `terminate/2` were what prevents the thread leak; it is not
  reached on supervisor shutdown or brutal kill (no `trap_exit`), where `impl Drop for Runtime` is the
  actual defence. Either point the comment at `Drop`, or set `Process.flag(:trap_exit, true)` in `init/1`
  so supervisor shutdown becomes deterministic and `fail_inflight/2` (per W2) gets to run there too.

- **S7 — `lib/tyrex.ex` is now 835 lines and ~35 private functions across three concerns.** The audit
  already deferred "`Tyrex` god module" to the arch plan; this patch roughly doubles the private surface,
  so that follow-up should be re-scoped rather than inherited as-is. Two clean seams:
  `Tyrex.Permissions` (`encode_permissions/1`, `validate_permission_key!/1`, `validate_permission_value!/2`,
  `@permission_keys`) and `Tyrex.Bridge` (`authorize/4`, `invoke/3`, `decode_args/1`, `reject/1`,
  `build_apply_allowlist/1`, `js_module_name/1`). Both are pure, and both are currently only testable
  through a live V8 isolate — the permission-validation tests all pay a runtime startup to assert an
  `ArgumentError` that never reaches Rust.

- **S8 — `@spec`/`@doc` do not mention that `start/1` and `start_link/1` raise.** `lib/tyrex.ex:178-181`,
  `:278-285`. Six distinct `ArgumentError`s are reachable. `:apply` and `:permissions` are documented as
  raising; `:max_heap_mb` is not. Add a `## Raises` line, or fold it into the `:max_heap_mb` bullet.

---

## PRE-EXISTING (not introduced by this patch)

- `lib/tyrex.ex:455` — `Jason.decode!/1` on worker output inside `handle_info/2` crashes the runtime on
  malformed JSON; there is no `Jason.decode/1` fallback. PRE-EXISTING.
- `lib/tyrex/pool.ex:107` — `:persistent_term.get/1` raises `ArgumentError` for an unknown pool name rather
  than returning `{:error, %Tyrex.Error{}}`, contradicting `@spec eval/3`. PRE-EXISTING.
- `lib/tyrex/error.ex:26-38` — `@enforce_keys [:name]` with `defexception`, so a bare `raise Tyrex.Error`
  produces a `KeyError` from `exception/1` rather than a useful message. PRE-EXISTING, harmless.

---

## On the sufficiency of the verification already performed

The escape script and the 3-runaway CPU probe are the right evidence for Phases 1 and 2 and I would not
ask for more there. The gaps are in *combinations*, not in the headline vectors:

1. A blocking eval and a non-blocking eval in flight on the same runtime (W2).
2. `stop/1` against a runtime parked in `eval_blocking` — the only case that reaches the escalation branch
   at all (W6).
3. `timeout: :infinity` on the non-blocking path: no test asserts what happens, which is how W1 stayed
   invisible.
4. A slow allowlisted MFA versus a deadline (W5) — an `apply: [{Process, :sleep, 1}]` runtime with
   `timeout: 1_000` would demonstrate it in one test.

None of these needs a rebuild to reason about, but 1, 2 and 4 are cheap regression tests and all three
guard invariants this release is specifically selling.
