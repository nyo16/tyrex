# Elixir Review — v0.4.0 sandbox integrity

**Verdict:** REQUIRES CHANGES

**Scope reviewed:** `lib/tyrex.ex`, `lib/tyrex/pool.ex`, `lib/tyrex/runtime.ex`,
`lib/tyrex/error.ex`, `lib/tyrex/native.ex`, `mix.exs`. Rust, CI mechanics, test
quality and the permission model are out of scope and left to siblings.

**How verified:**
- `git diff master -- lib mix.exs` read in full; whole post-image of `lib/tyrex.ex`
  read (949 lines).
- Prior review `.claude/plans/sandbox-integrity/reviews/sandbox-integrity-review.md`
  and `.claude/plans/sandbox-integrity-fixes/plan.md` read for W3/W4/W5/W6 intent.
- Five standalone OTP experiments on this machine (Elixir 1.20.2 / OTP 29,
  arm64), no NIF required, sources in `/tmp/exp*.exs`. Each reproduces a
  mechanism, not tyrex itself; the tyrex code path that reaches the mechanism is
  cited separately. Outputs quoted inline below.
- `Mix.Task.run_alias/6` + `join_args/3` read at
  `~/.asdf/installs/elixir/1.20.2-otp-29/lib/mix/lib/mix/task.ex:568-609`.
- `RustlerPrecompiled.__using__/2` and `find_checksum/3` read at
  `deps/rustler_precompiled/lib/rustler_precompiled.ex:184-266,786-801`, and
  `deps/rustler_precompiled/lib/mix/tasks/rustler_precompiled.download.ex`.
- Rust read only where it settles an Elixir-side question:
  `native/tyrex/src/lib.rs:13-22` (which pid the startup reply targets) and
  `native/tyrex/src/atoms.rs` (the complete set of error names).

---

## Blockers

### A malformed `:timeout` still reaches — and still kills — the runtime (PERSISTENT W4)

- **Where:** `lib/tyrex.ex:618-626` (`validate_timeout!/1`), `lib/tyrex.ex:640-643`
  (`arm_deadline/3`), `lib/tyrex.ex:607` (`call_timeout/1`), doc claim at
  `lib/tyrex.ex:350-352`.
- **What:** `validate_timeout!/1` checks sign and integer-ness but not the two
  ranges its downstream consumers enforce. Two bands get through:

  **Band 1 — `timeout > 9_223_372_034_790`.** `Process.send_after/3` raises
  `:badarg` *inside the GenServer*, at `arm_deadline/3`. The runtime dies. This is
  W4's defect verbatim, and it is the defect the comment directly above
  `validate_timeout!/1` (`lib/tyrex.ex:609-613`) says the function exists to
  prevent: "raises *inside the GenServer* and kills the runtime — and under
  `Tyrex.Pool`'s `:rest_for_one` supervision, every runtime ordered after it."

  **Band 2 — `4_294_966_296 ≤ timeout ≤ 9_223_372_034_790`.** `call_timeout/1`
  adds 1000 and hands the result to `GenServer.call/3`, whose `receive after`
  ceiling is 4_294_967_295. The caller raises `ErlangError{original: :timeout_value}`
  — but only *after* `gen:call` has already sent the request. The server accepts
  it, arms a deadline decades out, and runs the guest with no caller left to
  receive the reply and a permanently leaked `inflight` entry.
- **Why it matters:** Band 1 is a live recurrence of a WARNING the plan records as
  fixed (task 2.2), with the pool blast radius the comment itself names. Band 2 is
  the exact condition task 2.1 refused `timeout: :infinity` to prevent — "a
  runaway guest burns a per-runtime OS thread at 100% for the life of the VM"
  (`lib/tyrex.ex:677-683`) — reachable with a plain positive integer, e.g. a
  5-second deadline accidentally expressed in nanoseconds (`5_000_000_000`).
  Separately, the docstring at `lib/tyrex.ex:350-352` states "anything else raises
  `ArgumentError` in the calling process, **so a malformed value cannot reach — and
  kill — the runtime**." That sentence is false as written, which is the bug class
  this release exists to eliminate.
- **Evidence:** OBSERVED. `/tmp/exp5.exs` replicates exactly `eval/2`'s
  `validate_timeout! → GenServer.call(…, call_timeout(t))` and the server's
  `handle_call({:eval, …}) → arm_deadline/3`:

  ```
  --- timeout: 10000000000000 ---
  caller: {:rescued, ErlangError, "Erlang error: :timeout_value"}
  runtime terminate reason: {:badarg, [{:erlang, :send_after,
      [10000000000000, #PID<…>, {:deadline, {#PID<…>, [:alias|#Reference<…>]}}, []],
      [error_info: %{cause: :time, module: :erl_erts_errors}]},
    {Process, :send_after, 4, …}, {Rt, :handle_call, 3, …}, …]}
  runtime alive?: false
  --- timeout: 5000000000 ---
  caller: {:rescued, ErlangError, "Erlang error: :timeout_value"}
  runtime alive?: true
  ```

  Band boundaries measured, not assumed: `/tmp/exp4.exs` binary-searches
  `Process.send_after/3`'s ceiling to `9_223_372_034_790` (first bad
  `9_223_372_034_791`); `/tmp/exp.exs` shows `GenServer.call(pid, msg, 4_294_968_296)`
  raising `ErlangError :timeout_value` in the caller while the server is
  demonstrably already inside `handle_call` (`server current_function:
  {Process, :sleep, 1}`, `message_queue_len: 0`) — i.e. the request was delivered
  before the caller blew up.
- **Suggested direction:** Give `validate_timeout!/1` an upper bound and reject
  above it with the same `ArgumentError`. The natural bound is the one
  `GenServer.call/3` will accept after the grace is added — `timeout + @deadline_grace_ms
  <= 4_294_967_295` — which is comfortably inside `send_after`'s ceiling and closes
  both bands with one guard. `4_294_966_295 ms` is ~49 days, so nothing legitimate
  is lost. Fold the bound into the error message and into the `:timeout` docstring.

### A guest-triggered eval deadline restarts every later pool runtime, and four in five seconds take the pool down

- **Where:** `lib/tyrex/pool.ex:92` (`Supervisor.init(…, strategy: :rest_for_one)`),
  `lib/tyrex.ex:564` (`{:stop, {:shutdown, :timeout}, …}`), `lib/tyrex.ex:535`
  (`{:stop, {:shutdown, name}, …}` for `:heap_limit_error`), moduledoc claim at
  `lib/tyrex.ex:53-57`.
- **What:** This release makes an eval deadline or a heap trip stop the GenServer
  (new — on `master` the non-blocking path returned `{:noreply, state}` and armed
  nothing). `Tyrex.Pool` supervises its runtimes `:rest_for_one` with
  `Supervisor.init/2`'s default restart intensity and no passthrough for
  `:max_restarts` / `:max_seconds`. Three consequences, all guest-reachable via a
  guest that simply does not finish:
  1. One runtime's timeout terminates and restarts **every runtime ordered after
     it**. In a `size: 32` pool one runaway guest destroys 31 healthy isolates and
     serialises 31 V8 boots inside the supervisor.
  2. Those siblings are killed with an exit signal, and `Tyrex` never traps exits
     (`Process.flag(:trap_exit, true)` appears only in
     `lib/tyrex/pool/registry.ex:22`), so their `terminate/2` — and therefore the
     `fail_inflight/2` added by task 2.3 — does not run at all. Their in-flight
     callers exit instead (see the first warning below).
  3. The **fourth** such event inside five seconds exceeds the default intensity
     and the pool supervisor exits `:shutdown`, taking down whatever supervises it.
     With round-robin dispatch the four events need not even hit the same runtime.
- **Why it matters:** The premise of this release is running untrusted JavaScript.
  A guest hitting its deadline is the *expected* outcome, not an exception — and
  four of them in five seconds is a complete denial of service of the pool and the
  tree above it, triggerable by the sandboxed party, with no knob for the operator
  to raise the intensity. It is also invisible: `{:shutdown, term}` child
  terminations are not logged, so the churn leaves no trace until the supervisor
  itself dies. `lib/tyrex.ex:53-57` tells the reader "under a supervisor the child
  is simply replaced", which is true under `:one_for_one` and materially
  understates what `Tyrex.Pool` actually does.
- **Evidence:** OBSERVED, `/tmp/exp2.exs` — four permanent children under
  `:rest_for_one`, child 1 stopping `{:shutdown, :timeout}`:

  ```
  --- child 1 stops with {:shutdown, :timeout} ---
  {:terminated, 1}
  {:started, 1}
  {:started, 2}          # siblings restarted…
  {:started, 3}
  sup alive after 1 stop: true
  …
  --- one more (4th) ---
  {:terminated, 1}
  {:EXIT, #PID<0.104.0>, :shutdown}
  sup alive after 4 stops in <5s: false
  ```

  Note the absence of `{:terminated, 2}` / `{:terminated, 3}`: the siblings are
  signalled, not stopped, so their `terminate/2` is skipped — that is point (2)
  above, observed. Silence confirmed separately in `/tmp/exp3.exs`: a
  `{:shutdown, :timeout}` stop logs nothing, while `:boom` from the same child
  logs `[error] GenServer :d0 terminating`. The "no operator knob" claim is from
  reading `lib/tyrex/pool.ex:58-92`, which reads only `:name`, `:size`,
  `:strategy` and the runtime opts.
- **Suggested direction:** The runtime children want `:one_for_one`; only the
  Registry→runtimes edge wants `:rest_for_one`. A small nested supervisor
  (Registry, then a `:one_for_one` supervisor owning the runtimes) preserves the
  documented Registry invariant at `lib/tyrex/pool.ex:88-91` while removing the
  sibling amplification. Independently, expose `:max_restarts` / `:max_seconds` on
  `Tyrex.Pool.start_link/1` and pick a default that reflects "a stopped runtime is
  the normal outcome of a hostile guest", and say so in the `Tyrex.Pool` moduledoc
  and at `lib/tyrex.ex:53-57`.

---

## Warnings

### Supervisor `:shutdown` and `:killed` exits still bypass `dead_runtime_exit?/1` (partially PERSISTENT W6)

- **Where:** `lib/tyrex.ex:634-638`, reached from `lib/tyrex.ex:393-406`.
- **What:** `dead_runtime_exit?/1` maps `:noproc`, `:normal` and `{:shutdown, _}`.
  It does not map the bare atom `:shutdown` (what a supervisor sends when
  terminating a child, including every sibling restart in the blocker above, and
  what `Supervisor.terminate_child/2` and application shutdown produce) nor
  `:killed` (what `stop/1`'s own escalation branch at `lib/tyrex.ex:255` produces
  via `Process.exit(pid, :kill)`, and what `shutdown: :brutal_kill` produces).
  Because `Tyrex` does not trap exits, none of those paths run `terminate/2`, so
  `fail_inflight/2` does not cover them either — the caller simply exits.
- **Why it matters:** W6's fix restores `eval/2`'s `@spec` for the three windows
  the docstring names (deadline, heap trip, `kill/1`) but not for the ordinary
  supervised-shutdown path, which the pool blocker shows is routine rather than
  exotic. The docstring at `lib/tyrex.ex:366-370` is honest about "every other exit
  reason still propagates", so this is a code gap and not a false claim.
- **Evidence:** OBSERVED, `/tmp/exp.exs` section B — an in-flight
  `GenServer.call` caller against a non-trapping server:

  ```
  signal -> caller exit reason: {:shutdown, :shutdown}   # Process.exit(pid, :shutdown)
  signal -> caller exit reason: {:kill, :killed}         # Process.exit(pid, :kill)
  ```

  Both unwrap (via `lib/tyrex.ex:634`) to `:shutdown` / `:killed`, which fall to
  `lib/tyrex.ex:638` and are re-raised.
- **Suggested direction:** Add `dead_runtime_exit?(:shutdown)` and
  `dead_runtime_exit?(:killed)`. Both mean "someone else already tore this runtime
  down", which is exactly what `:dead_runtime_error` describes; neither can hide a
  server-side deadline losing its race, which is the reason `:timeout` is
  deliberately excluded.

### `kill/1` reports `:ok` for a runtime it did not kill

- **Where:** `lib/tyrex.ex:290-293`, docs at `lib/tyrex.ex:272-279`.
- **What:** `kill/1` catches **every** exit reason and returns `:ok`, including the
  `:timeout` its own `GenServer.call/3` raises when the runtime cannot service the
  `:kill` message within 5_000 ms. A runtime executing `Tyrex.eval(code, blocking:
  true, timeout: 30_000)` is parked inside a dirty NIF and cannot dequeue anything,
  so `kill/1` returns `:ok` while the guest keeps running for up to another 25
  seconds.
- **Why it matters:** The docstring promises "Interrupt whatever the runtime is
  executing and shut it down" and "this works on a runtime that is wedged inside a
  guest that never yields". For the blocking path that is not true, and the `:ok`
  actively misreports it — a caller has no way to tell success from a silent
  timeout. It is the same reasoning `eval/2` applies in the opposite direction at
  `lib/tyrex.ex:368-370`: a `:timeout` from the call itself is a real signal and
  "must not be swallowed". `stop/1` (`lib/tyrex.ex:242-260`) is a milder instance:
  it escalates to `Process.exit(pid, :kill)`, which the plan's own task 4.6 note
  records as *deferred* while the target is in a dirty NIF, yet it too returns
  `:ok` unconditionally.
- **Evidence:** Code reading of `lib/tyrex.ex:290-293` (the catch-all is
  unambiguous) plus the plan's own measured note under task 4.6: "`blocking: true`
  parks it in a dirty NIF where `Process.exit(:kill)` is deferred, so neither
  reaches the escalation path". Not reproduced against the NIF; the reachability of
  a parked dirty-scheduler runtime is [INFERENCE] from that note and from
  `Native.eval_blocking/3`'s documented semantics (`lib/tyrex/native.ex:57-62`).
- **Suggested direction:** Narrow the catch to the reasons that mean "already
  gone" — reuse `dead_runtime_exit?/1` — and let `:timeout` distinguish itself,
  either by propagating or by returning something other than `:ok`. If `:ok` must
  stay for source compatibility, the docstring has to say that `:ok` does not imply
  the runtime is dead on the `blocking: true` path.

### The publish guard prints a remediation command that cannot run

- **Where:** `mix.exs:110-126`, specifically the instruction at `mix.exs:121`.
- **What:** `assert_checksums_current!/1` fires precisely when
  `checksum-Elixir.Tyrex.Native.exs` has no `-v0.4.0-nif-` entry, and tells the
  operator to run `mix checksums.after_release`. That alias
  (`mix.exs:98`) runs `rustler_precompiled.download`, which runs `Mix.Task.run("app.config")`
  and `Code.ensure_compiled(Tyrex.Native)`. With no v0.4.0 checksum entry and
  `force_build: false`, `use RustlerPrecompiled` takes the
  `download_or_reuse_nif_file` error branch and `raise`s at compile time — the same
  B4 mechanism the guard exists to announce. The command only works as
  `TYREX_BUILD=true mix checksums.after_release`, which is exactly how `README.md:738`
  writes it, with `README.md:742-744` explaining why. The `mix.exs` message omits it.
- **Why it matters:** The one instruction a maintainer will copy verbatim, at the
  one moment it is printed, fails with an unrelated-looking compile error. That
  turns a mechanism (the point of task 3.2, chosen over prose) back into a runbook
  step the operator has to already know.
- **Evidence:** Source reading, not execution — running it would have written
  `checksum-Elixir.Tyrex.Native.exs`. `rustler_precompiled.ex:248-266` builds the
  error and `:209` raises it; `:786-801` is the `find_checksum` miss that produces
  it; the download task's `app.config` + `Code.ensure_compiled` are at
  `mix/tasks/rustler_precompiled.download.ex:41-55`. Marked [INFERENCE] only in
  that I did not execute the failing command.
- **Suggested direction:** Put `TYREX_BUILD=true` in the printed command, and say
  in one clause why (the checksum map for the new version does not exist yet, so
  `Tyrex.Native` has to build from source) — the README sentence is already
  written and can be echoed.

---

## Suggestions

- **`:timeout`'s two rejection styles will trip callers.** `lib/tyrex.ex:386-388`
  returns `{:error, %Error{name: :unsupported_option}}` for `:infinity` while
  `lib/tyrex.ex:622-626` raises `ArgumentError` for everything else malformed. The
  split is defensible on its own terms — `:infinity` is well-formed and refused as
  policy, the rest are caller bugs, and `:max_heap_mb` raises because `start/1`'s
  `on_start` type has nowhere to put a structured error — but a caller whose
  `:timeout` comes from config or a request parameter now needs both a `case` and a
  `rescue`. At minimum, `lib/tyrex.ex:350-351` ("Must be a positive integer;
  anything else raises `ArgumentError`") is contradicted by `lib/tyrex.ex:356-358`
  two paragraphs later, which documents `:infinity` returning a tuple; the first
  sentence should say "any other **malformed** value".
- **`Tyrex.Pool.eval/3`'s `:timeout` doc is stale.** `lib/tyrex/pool.ex:101` still
  says "Timeout for the call". As of this release it is a wall-clock deadline whose
  expiry terminates the isolate and (per the second blocker) churns the pool. That
  docstring list was edited in this commit for `:apply` and `:max_heap_mb`
  (`lib/tyrex/pool.ex:48-49`) and this line was left behind.
- **`mix hex.publish docs` is blocked by a checksum guard that does not apply to
  it.** `Mix`'s `join_args/3` (`mix/lib/mix/task.ex:608-609`) appends alias args to
  the last element only, so `mix hex.publish docs` runs
  `assert_checksums_current!([])` first and then `hex.publish docs`. Publishing
  docs does not ship the checksum file. Guarding on `args == []` or on
  `"docs" not in args` would keep the docs-only path usable.
- **`handle_info/2` has no catch-all clause.** `lib/tyrex.ex:506,522,544` cover
  `{:apply, …}`, `{:eval_reply, …}` and `{:deadline, …}`; any other message crashes
  the runtime with a `FunctionClauseError`. Under the pool that is one more
  (loggable, unlike `{:shutdown, _}`) route into the restart-intensity budget. A
  clause that logs and returns `{:noreply, state}` is the usual defence.
- **`Tyrex.Error`'s `:unsupported_option` entry** (`lib/tyrex/error.ex:18-20`)
  names only the `blocking: true` + `:apply` case. The `timeout: :infinity` refusal
  added by task 2.1 is the other producer. The "e.g." makes this incomplete rather
  than wrong, so it is a one-line addition, not a defect.

---

## Verified correct (recorded because the prior review's lesson was that finished
## tasks hide defects)

- **The three dead-code removals are genuinely unreachable, including for a direct
  `GenServer.call`.** `call_timeout/1` (`:607`) is called only from
  `lib/tyrex.ex:390`, inside the `timeout ->` branch that `:infinity` cannot enter.
  `arm_deadline/3` (`:640`) is called only from `lib/tyrex.ex:488`, which sits
  *below* the `timeout == :infinity` guard at `lib/tyrex.ex:484` — moving that
  guard to the top of the `cond` is what preserves the direct-caller defence the
  removed clause used to provide, so nothing was lost. `cancel_timer/1` (`:645`) is
  reached only from `lib/tyrex.ex:529` (the non-`:absent` branch of
  `Map.pop/3`) and `lib/tyrex.ex:657` (values of `inflight`), and the only writer of
  `inflight` is `arm_deadline/3`, which always stores a `Process.send_after/3`
  reference. That also settles the `%Tyrex.Runtime{}` typespec narrowing at
  `lib/tyrex/runtime.ex:31-35`: no `nil` can be stored.
- **No caller can be replied to twice, and none is missed on the paths that run
  `terminate/2`.** `handle_info({:eval_reply, …})` (`:522-542`) and
  `handle_info({:deadline, …})` (`:544-566`) both remove their `from` from
  `inflight` *before* calling `fail_inflight/2`; `handle_call(:kill, …)` (`:500-502`)
  and `handle_info({:apply, …})`'s error arm (`:517`) pass an already-drained state
  into `{:stop, …}`; `blocking_eval/3`'s stops (`:596`) pass the undrained
  state, but a blocking caller is never in `inflight`, so `terminate/2`'s
  `fail_inflight/2` (`:576`) cannot double-reply it. `GenServer.reply/2` to a dead
  caller is a plain `send`, so replying from `terminate/2` is safe.
- **`:erlang.raise(:exit, reason, __STACKTRACE__)`** at `lib/tyrex.ex:404` is the
  correct three-argument form: class, original reason, and the stacktrace captured
  at the original raise site inside `:gen.do_call/4`, so re-raised exits are
  indistinguishable from un-caught ones.
- **`dead_runtime_exit?/1`'s accepted set is narrow enough to not hide a bug.**
  `{:shutdown, _}` can only come from tyrex's own `{:stop, …}` returns or an
  explicit `GenServer.stop/3`; `:normal` covers `Tyrex.stop/1`'s default reason
  racing an unprocessed call; and `:timeout` is deliberately excluded, so a
  server-side deadline losing its race still surfaces.
- **`init/1`'s `Task.async` is not the bug it looks like.** `Native.start_runtime/5`
  is handed the GenServer's pid but replies to `env.pid()` — the *calling* process,
  i.e. the Task (`native/tyrex/src/lib.rs:13-22`). The `pid` argument is retained
  for the later `{:apply, …}` messages. So the `receive` at `lib/tyrex.ex:453-462`
  does match, and no stray `{:ok, reference}` can land in the GenServer's mailbox
  to hit the missing `handle_info` catch-all.
- **`mix.exs`'s self-named alias is sound.** `"hex.publish": [&fun/1, "hex.publish"]`
  does not recurse: `Mix.Task.run_alias/6` special-cases an element naming the
  original task and invokes the task module directly
  (`mix/lib/mix/task.ex:568-573`). The anonymous-function element is not last, so
  `join_args/3` (`:608-609`) hands it `[]` and appends the user's args to
  `hex.publish` — arguments compose correctly. A consumer never runs this alias;
  aliases are project-local and `hex.publish` is a maintainer task.
- **W3 and W5 are closed.** `timeout: :infinity` is refused at both the API
  boundary (`lib/tyrex.ex:386-388`) and the server (`lib/tyrex.ex:484-485`);
  `terminate/2` calls `fail_inflight/2` first (`lib/tyrex.ex:576`), which covers
  `blocking_eval/3`'s three stops and `Tyrex.stop/1` — on every path where
  `terminate/2` actually runs (see the first warning for where it does not).
- **`Tyrex.Error`'s documented `:name` set is complete.** Cross-checked against
  `native/tyrex/src/atoms.rs`; the permission-parse failures added by task 2.5 reuse
  `execution_error` (`native/tyrex/src/worker.rs:183-188`), which is documented.

---

## Persistent prior findings

- **PERSISTENT W4** — still present at `lib/tyrex.ex:618-626`. `validate_timeout!/1`
  rejects negatives and non-integers, but a positive integer above
  `9_223_372_034_790` still raises inside `Process.send_after/3` at
  `lib/tyrex.ex:641` and kills the runtime — the exact mechanism, and the exact
  pool blast radius, that the comment at `lib/tyrex.ex:609-613` claims to have
  closed. Reproduced (`/tmp/exp5.exs`). See the first blocker.
- **PARTIALLY PERSISTENT W6** — `lib/tyrex.ex:634-638`. `:noproc`, `:normal` and
  `{:shutdown, _}` are mapped; the bare `:shutdown` and `:killed` that supervised
  shutdown and `stop/1`'s own escalation produce are not, so an in-flight `eval/2`
  caller still exits on those paths. Reproduced (`/tmp/exp.exs` section B). See the
  first warning.
- W3 and W5: fixed, verified above. W1, W2, W7–W12, B1–B5 and S1–S6 are outside
  this review's scope.

---

## Pre-existing (one line each)

- `lib/tyrex/pool.ex:110` — `Tyrex.eval(code, Keyword.merge(opts, name: …))`, but
  `server/1` (`lib/tyrex.ex:604`) prefers `:pid`, so `Tyrex.Pool.eval(pool, code,
  pid: p)` silently bypasses the pool's dispatch. PRE-EXISTING.
- `lib/tyrex.ex:467-473` — `init/1`'s `case` handles only `{:ok, reference}` and
  `{:error, error}`; any other shape the NIF sends becomes a `CaseClauseError`
  rather than a startup error. PRE-EXISTING.
