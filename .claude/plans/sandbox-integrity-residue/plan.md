# Plan: tyrex v0.4.0 — Review Residue

**Slug:** `sandbox-integrity-residue`
**Created:** 2026-08-15
**Input:** `.claude/plans/sandbox-integrity-fixes/reviews/` (8-agent panel over `f134c25`), minus the five blockers fixed in `27bb9df`
**Research:** none spawned — the panel's reports are the research. Findings marked VERIFIED were reproduced on this machine, either during the review or while writing this plan.

## Problem

The v0.4.0 branch is two commits: the sandbox work, and the fixes for a 23-finding
review of it. An 8-agent panel then reviewed the result and found five blockers —
all now fixed and each verified red-then-green. What remains is 61 raw findings,
deduplicating to **38 real items**.

Two of them matter more than their severity labels suggest, because they are the
release's own thesis turned back on it:

1. **`allow_import` is decorative.** VERIFIED. `PermissionedModuleLoader` delegates
   to `FsModuleLoader`, which loads only `file:` URLs, so *no* permission set makes
   a remote import succeed — `allow_all`, `allow_import: true` and
   `[allow_import: true, allow_net: true, allow_read: true]` all produce
   `Provided module specifier "https://..." is not a file URL.` `deny_import` is
   live but only changes the *error text*. The README section written in the last
   pass to close "documented controls that silently do nothing" presents the pair
   as a two-way control. That is a new instance of the exact bug class, introduced
   by the fix for the old one.
2. **`kill/1` is inert on the one case it exists for.** VERIFIED. It is documented
   in three places as working, "unlike `stop/1`", on a runtime wedged in a guest
   that never yields — but it is a `GenServer.call`, needing the same mailbox
   `stop/1` needs. Against a `blocking: true` runaway: `kill → :ok after 5002ms,
   alive? true`; `stop → :ok after 5002ms, alive? false`. The documented
   relationship is inverted, and `catch :exit, _ -> :ok` reports the no-op as
   success.

The rest is honest residue: controls that cannot fire, tests that cannot fail,
docs that overstate, and Rust hardening that is real but bounded.

### The uncomfortable one

Three separate agents independently flagged
`assert {:ok, "undefined"} = Tyrex.eval("typeof Deno?.core?.ops?.op_apply", ...)`
as vacuous — the chain short-circuits at `Deno.core`, which is `undefined` in every
runtime, so the assertion is satisfied by every op name. It was raised by name in
the *previous* review's per-agent security report, never made that review's
consolidated 23, and so was never assigned a task. It has now survived two full
audit passes untouched. Any process that lets a named finding evaporate between
the per-agent reports and the consolidated list will do it again.

## Scope decision

**Phase 1 gates the tag. Phases 2–3 gate the PR. Phases 4–5 do not.**

Phase 1 is docs-only and small, but it is the phase that makes the branch's claims
true, which is the whole premise of v0.4.0. Phase 2 is the tests that cannot fail —
cheap, and the thing most likely to be skipped. Phase 3 is real behavioural work
with a design fork in it. Phases 4–5 are hardening and release mechanics that
nothing depends on until `mix hex.publish` runs.

If context pressure forces a split, split after Phase 2.

---

## Decision required before task 3.1

`kill/1` must reach the isolate without traversing the GenServer mailbox. Three
honest options; pick one and record it in the scratchpad.

**Option A — brutal kill (simplest).** `kill/1` becomes
`Process.exit(pid, :kill)`, and reclamation rides on `Runtime::drop`, which
terminates the isolate when the `ResourceArc` refcount hits zero. Works today —
the review measured `Runtime::drop` alone reclaiming the thread. In-flight callers
receive `:killed` exits, which `dead_runtime_exit?/1` now maps to
`dead_runtime_error`, so `kill/1`'s documented contract survives. Cost:
`terminate/2` never runs, so the drain is by exit-mapping rather than by reply.

**Option B — reach the isolate directly (recommended).** Publish each runtime's
`IsolateHandle` where `kill/1` can find it without the mailbox — an ETS table or
`:persistent_term` keyed by pid, written at `init/1`. `kill/1` terminates the
isolate first, which unwedges the guest, then the GenServer services the call
normally and `terminate/2` drains in-flight callers properly. Cost: one more piece
of out-of-band state to keep in sync with runtime lifetime.

**Option C — disclaim it.** Document that `kill/1` and `stop/1` have identical
reachability, and that `stop/1` is the one that escalates. Cheapest, and leaves the
library with no working answer to a wedged runtime other than `stop/1`'s 5-second
timeout.

Option B is recommended: it is the only one that makes the three existing doc
claims true rather than rewriting them, and the handle is already cloned into
`Runtime` for exactly this purpose. Option A is a legitimate fallback if the
out-of-band state proves awkward under `Tyrex.Pool`.

---

## Phase 1 — Make the documentation true `[docs]`

Every item is a claim the code contradicts. All are trivial individually; the
phase matters because this is the failure class the release is named for.

- [x] **1.1 State that non-`file:` module loading is unsupported** `[docs]` — README key-table row + a `allow_import` grants nothing warning block naming the three probed permission sets and the vendor-to-disk workaround; `lib/tyrex.ex` key list says deny-only
      VERIFIED. `README.md:237` (key table), `README.md:246-249`, `lib/tyrex.ex:180-183`.
      Say plainly: remote/`data:`/`blob:` imports do not work at all; `deny_import`
      changes the failure from "not a file URL" to an explicit permission denial;
      `allow_import` cannot make one succeed. Do not delete the keys — they are
      real `PermissionsOptions` fields and `deny_import` is live — but stop
      presenting the pair as symmetric.
- [x] **1.2 Correct the CHANGELOG's "the server always wins the race"** `[docs]` — rewritten to say the grace covers scheduler jitter but not GenServer occupancy; re-probed (queued caller exits :timeout)
      `CHANGELOG.md:41`. The 1s `@deadline_grace_ms` covers scheduler jitter, not
      GenServer *occupancy*: `arm_deadline/3` runs inside `handle_call`, so a
      caller queued behind a blocking eval has no deadline armed while its own call
      timeout expires. OBSERVED: with a background `blocking: true` runaway,
      `Tyrex.eval("1+1", timeout: 100)` exits `:timeout` rather than returning an
      error tuple. `lib/tyrex.ex:368-370` already documents this correctly — the
      CHANGELOG contradicts the module it describes.
- [x] **1.3 Fix the OTP floor** `[docs]` — NIF 2.16 -> OTP 24 (min_erts confirmed in the artifact), effective floor OTP 25 from elixir ~> 1.18, stated separately
      `README.md:689-693` says OTP 27+ *and now attributes it to NIF 2.16*. NIF
      2.16 is **OTP 24** — `rustler-0.38.0/src/codegen_runtime.rs:145-156` maps
      `nif_version_2_16` to `b"OTP-24.0"`, confirmed on the built artifact with
      `strings -a … | grep -x 'OTP-24.0'`. Also contradicts `mix.exs:11`
      (`elixir: "~> 1.18"` admits OTP 25). State the NIF floor and the effective
      floor separately; if OTP 27 is required for another reason, name it.
- [x] **1.4 Stop understating the pool blast radius** `[docs]` — `Tyrex` moduledoc now names the retry, the dead_runtime_error window and the restart ceiling
      `README.md:371` and the `Tyrex` moduledoc still say a pooled runtime is
      "replaced automatically, so callers only have to retry". After `27bb9df` a
      sibling is no longer restarted, but a caller whose own runtime died still has
      to retry, a call landing in the restart window gets `dead_runtime_error`, and
      the new `:max_restarts`/`:max_seconds` ceiling is undocumented outside
      `Tyrex.Pool`'s `@doc`.
- [x] **1.5 Qualify "pinned so the drift cannot silently recur"** `[docs]` — CHANGELOG now names what is pinned vs kept in agreement by hand
      Only one side is pinned. Name what is pinned (`rustler = "=0.38.0"`, the
      `nif_version_2_16` feature) and what is not (the `NIF_VERSION` label in
      `release.yml`, `nif_versions:` in `lib/tyrex/native.ex`), and that they are
      kept in agreement by hand.
- [x] **1.6 Correct the `Cross.toml` deletion rationale and orphan its Dockerfile** `[docs]` — correction recorded in the fixes plan; orphaned Dockerfile deleted
      VERIFIED WRONG, and the error is mine.
      `.claude/plans/sandbox-integrity-fixes/plan.md:277-283` and `f134c25`'s commit
      message both say `Cross.toml`'s only stanza "referenced a Dockerfile that does
      not exist". `native/tyrex/Dockerfile.aarch64-unknown-linux-gnu` exists, is
      332 bytes, and was tracked at `master`. The deletion is still right for W12's
      actual reason — packaged without its Dockerfile, and nothing invokes `cross` —
      but the recorded reason is false and the Dockerfile is now an orphan with no
      referent. Correct the plan note, and either delete the Dockerfile or record
      that it was kept deliberately.
- [x] **1.7 De-qualify the Option A decision** `[docs]` — scratchpad records Option A as CONFIRMED and shipped, plus the allow_import caveat found this pass
      `.claude/plans/sandbox-integrity-fixes/scratchpad.md:61-63` still reads
      "pending user confirmation" over shipped, tested code, and the plan's own
      Decision block was never annotated with the outcome. A reader of either
      document alone cannot tell the decision is closed.

**Verify:** re-read each claim against the code it describes. For 1.1 and 1.2,
re-run the probes named above and paste the output into the scratchpad — both are
claims about behaviour, so reading is not sufficient.

## Phase 2 — Make the remaining controls able to fail `[elixir]`

The panel's highest-signal class, and the one with a two-pass survival record.

- [x] **2.1 The in-flight drain tests cannot fail** `[elixir]` — both `test/tyrex_api_test.exs` drain tests now assert `message =~ "in flight"` and `refute message =~ "already gone"`; confirmed red by deleting the `fail_inflight/2` call in `terminate/2` (both failed with `left: "the runtime was already gone when this call was made, or died before it could reply"`), `lib/tyrex.ex` restored byte-identically (sha256 `57e2676d…`). The lifecycle test is the *other* producer now: since 3.1 made `kill/1` a brutal `Process.exit(pid, :kill)`, `terminate/2` never runs there, so it pins `message =~ "already gone"` instead — confirmed red by deleting `dead_runtime_exit?(:killed)` (caller exits `** (EXIT) killed` through `Task.await`)
      `test/tyrex_api_test.exs:96-99,113`, `test/tyrex_lifecycle_test.exs:81`.
      They assert only `name: :dead_runtime_error`. Task 2.4's `dead_runtime_exit?/1`
      *manufactures* that same value from an undrained `:normal`/`{:shutdown, _}`
      exit, so deleting both `fail_inflight/2` calls leaves all three green —
      demonstrated with a stub GenServer driven through the real `Tyrex.eval/2`.
      The two producers differ only in `:message`. Assert `message =~ "in flight"`.
      Confirm red by deleting the `fail_inflight/2` call in `terminate/2`.
- [x] **2.2 Replace the vacuous op-reachability assertion and pin the op table** `[elixir]` — split into three tests: bridge-off and bridge-on both assert `typeof Deno[Deno.internal].core.ops.op_apply == "undefined"` behind a positive control (`typeof …core.ops == "object"`, `op_base64_encode` is a `"function"`) and pin the whole table via `assert_op_table_pinned/1`; the `ext:` import refusal is now its own test. Vacuity of the old form re-measured: `typeof Deno?.core?.ops?.op_base64_encode -> "undefined"` while `typeof Deno[Deno.internal].core.ops.op_base64_encode -> "function"`, i.e. the old assertion was satisfied by a present op
      `test/tyrex_permissions_test.exs:314-318`. Flagged by three agents this pass
      and by name in the previous review's per-agent security report. Assert against
      `Deno[Deno.internal].core.ops`, which is where deno actually exposes ops, on an
      `apply: false` runtime — the current test starts with the bridge *on*,
      contradicting its own name. Additionally pin the table contents
      (`["op_base64_encode","op_napi_open","op_set_exit_code"]`) and a positive
      control, so a deno bump that re-exposes ops fails loudly. This is not
      hypothetical: re-exposure would also restore `op_import_sync`, which is an
      unchecked file read (see 4.1).
- [x] **2.3 Give blocker B5 a regression test** `[elixir]` — two tests: `typeof Tyrex._runtimeId`/`typeof globalThis.Tyrex._runtimeId` are `"undefined"` with the bridge on (plus `Object.keys(globalThis.Tyrex).sort() == ["_applications","_applyReply","apply"]`, so absence of the id is not absence of the bridge); and a spoof test with disjoint allowlists — A `{Enum,:sum,1}`, B `{String,:upcase,1}` — where a guest on A writes nine values into `Tyrex._runtimeId` and `globalThis.Tyrex._runtimeId` and every `Tyrex.apply("String","upcase",…)` is refused with `permission_denied: String.upcase/1 is not in the :apply allowlist`, then A's own `Enum.sum/1` still returns 6 and B's own `String.upcase/1` still returns `"X"`
      Grep-confirmed: nothing asserts a guest cannot reach or influence the runtime
      id. The fix shipped untested. Assert `typeof Tyrex._runtimeId === "undefined"`
      with the bridge on, and that setting it does not redirect an `:apply` call —
      two runtimes with disjoint allowlists, guest sets the sibling's id, call is
      still refused against its own allowlist.
- [x] **2.4 Pin the remaining untested fixes** `[elixir]` — `{"allow_all": ["/tmp"]}` through `Tyrex.Native.start_runtime/5` asserting `"allow_all must be true or false, not a list"` and `"baseline"`; a `trampoline.js` inside the granted dir that statically imports a sibling `tyrex_forbidden_*/outside.js`, whose guest `import()` is denied naming the outside path (the `is_dynamic_import`-propagation property the loader's exemption rests on); and `GenServer.call(pid, {:eval, "1 + 1", [timeout: :infinity]})` reaching the server-side guard directly for `:unsupported_option`
      `allow_all: [list]` rejection (task 2.5, Rust-side, reachable via
      `Tyrex.Native.start_runtime/5` like the other native-parser tests); a guest
      `import()` of a permitted file that statically imports a forbidden one
      (verified denied today, unpinned); and the server-side `timeout == :infinity`
      guard, currently unreachable from the tests because `eval/2` refuses first.
- [x] **2.5 Fix the test-suite hazards the panel found** `[elixir]` — all four fixed; plus a new `blocking: true` sibling to the CPU probe, which caught a live 3.0-core leak the non-blocking probe was green over (fixed by `Resource::down` in `runtime.rs`)
      The CPU probe leaks three runaway runtimes when its *first* assertion fails,
      poisoning every later test in the VM; the receive trace in the stale-timer
      test is armed after the evals rather than before (fail-closed); the
      pool-recovery test's `catch :exit, _ -> false` is over-broad and its comment
      still blames `:noproc`, which task 2.4 removed; and the `on_exit`-before-erase
      ordering in the `Logger.warning` test is load-bearing and unrecorded.

**Verify:** `TYREX_BUILD=true mix test`, plus `--seed 0` and `--seed 999999` for
order dependence. For 2.1 and 2.2, confirm each new assertion **fails** when the
production line it defends is reverted.

## Phase 3 — The deadline and lifecycle holes `[elixir]`

- [x] **3.1 Make `kill/1` do what it documents** `[elixir]` — **Option A, chosen on measurement not theory.** Probed all three: `Process.exit(pid, :kill)` reaches a process parked in the dirty NIF in 0ms where the old `GenServer.call` was a 5002ms no-op. Option B (out-of-band `IsolateHandle`) turned out unnecessary. `kill/1` is now an untrappable exit plus a `:DOWN` wait; the `handle_call(:kill, ...)` clause is deleted as dead. NOTE: brutal kill alone leaked the worker thread (2.97 cores) until the `Resource::down` monitor landed — see the new blocker below
      VERIFIED, and blocked on the decision above. Whichever option is chosen, also
      narrow `catch :exit, _reason -> :ok` so a `:timeout` exit is not reported as
      success — that is what turned a 5-second no-op into `:ok`.
- [x] **3.2 Keep the eval deadline serviceable while an allowlisted MFA runs** `[elixir]` — **Documented, not moved.** Authorization lives in the GenServer precisely so it is outside the isolate blast radius; running the MFA on a task would move execution away from the process holding that decision and let one guest fan out unbounded Elixir work. A 19-line comment on the `:apply` handler states the boundary with the measured numbers (6000ms MFA, `timeout: 500` caller exiting at ~1504ms) and says to keep allowlisted functions fast
      `handle_info({:apply, ...})` invokes the MFA inline, so the GenServer cannot
      process its own `{:deadline, from}` while bridge code runs. The
      `:blocking_with_apply` refusal guards only the inverse direction. OBSERVED
      with `apply: [{P5, :slow, 1}]` sleeping 6000ms: `Tyrex.eval(timeout: 500)`
      exited `{:timeout, {GenServer, :call, ...}}` at 1504ms with the runtime alive,
      and the runtime was terminated only at ~6s when the MFA returned — reached
      structurally from a documented configuration, holding a pool slot throughout.
      Either run the MFA off the message loop, or document that bridge time is not
      covered by the eval deadline. Cross-runtime allowlist cycles are the same
      defect at larger radius.
- [x] **3.3 Narrow `stop/1`'s catch-all and add one to `handle_info/2`** `[elixir]` — `stop/1` now escalates only on `:timeout` plus `dead_runtime_exit?/1`'s reasons via a new `stop_escalation_reason?/1`, and re-raises anything else, so a crashing `terminate/2` is no longer invisible. `handle_info/2` gained a logging catch-all
      `stop/1`'s `catch :exit, _reason` also swallows a `terminate/2` that raises
      and any abnormal stop reason, then reports `:ok`. Reuse `dead_runtime_exit?/1`
      so the two paths classify consistently. Separately, `handle_info/2` has no
      catch-all clause, so an unexpected message crashes the runtime.
- [x] **3.4 Reconcile the two `:timeout` rejection styles** `[elixir]` — Kept both, and documented the rule instead of flattening it: malformed shape raises `ArgumentError` (a caller bug, must not be pattern-matched past), `:infinity` returns `:unsupported_option` (well-formed, refused on policy, and the answer the blocking path already gave pre-v0.4.0). `Tyrex.Error` now names both `:unsupported_option` producers
      `:infinity` returns `{:error, %Error{name: :unsupported_option}}` while a
      malformed value raises `ArgumentError`, and the `eval/2` docstring
      contradicts itself about which happens. Pick one story and make the docs
      match. Also `Tyrex.Pool.eval/3`'s `:timeout` doc is stale, and
      `Tyrex.Error`'s `:unsupported_option` entry names only one of its two
      producers.
- [x] **3.5 Decide what a panicked worker leaves behind** `[elixir] [rust]` — Brought down, not documented. The panic path now sends `{:worker_panicked, reason}` to the owning GenServer (new atom), which logs and stops with `{:shutdown, :dead_runtime_error}` after draining, so the supervisor replaces it instead of leaving a pool-dispatchable zombie. `Runtime::drop`'s comment no longer calls itself a fallback
      A worker-thread panic leaves the GenServer alive and reporting
      `Process.alive?/1` true, still a valid pool dispatch target, answering every
      call with `dead_runtime_error`. Either have the panic path bring the
      GenServer down so the supervisor replaces it, or document the zombie state.
      Related: `Runtime::drop`'s comment calls itself a "best-effort" fallback, but
      it is the *sole* reclamation path for supervisor shutdown and brutal kill —
      the review measured `terminate/2`'s removal leaving the CPU probe green
      because `Runtime::drop` covered it. No test covers either path.

**Verify:** `TYREX_BUILD=true mix test`, plus new coverage for 3.1–3.3. For 3.1,
the proof is the wedge probe: `blocking: true` runaway, then `kill/1` must actually
kill it, promptly, and say so.

## Phase 4 — Rust hardening `[rust]`

Nothing here is a live hole; each is a latent one or a misreport.

- [x] **4.1 Make the `import()` exemption positive** `[rust]` — `PermissionedModuleLoader` gained a `bootstrap_complete: Cell<bool>` latch, flipped after `execute_main_module` returns (on the error path too). `must_check/1` is `is_dynamic || bootstrap_complete`, so the `LoadInit::Side` / `op_import_sync` shape can no longer bypass both hooks and the guarantee stops depending on deno `removeImportedOps()`. Probed: main module + static graph still load under `:none` (42), guest import of a new file denied, guest re-import of the main module's own dep now denied too, `allow_read` grant still loads
      Today the loader checks when `ResolutionKind::DynamicImport` or
      `options.is_dynamic_import` — a *negative* test that holds only because
      nothing guest-reachable creates a `LoadInit::Side` load. `op_import_sync`
      drives exactly that shape (`ops_builtin.rs:511-523` →
      `RecursiveModuleLoad::side` → `recursive_load.rs:202-204,248`, resolving as
      `ResolutionKind::Import` with `is_dynamic_import: false`) and would bypass
      both hooks. It is unreachable today only because deno's `removeImportedOps()`
      strips it — an upstream invariant tyrex neither states nor pins. A `Cell<bool>`
      set once `execute_main_module` returns turns the predicate into
      "bootstrap complete ⇒ check everything", which is structurally what the doc
      comment already claims.
- [x] **4.2 Make slab removal exactly-once** `[rust]` — New `runtimes::Registration` owns the slab entry and removes it in `Drop`; moved into the worker thread so its lifetime is the thread's. All seven manual `try_remove` sites deleted (5 in `worker::run`, 2 in `lib.rs`), so the panic path can no longer unregister a reused id belonging to a different, live runtime
      The unwind handler's `try_remove(runtime_id)` is unconditional while
      `worker::run` already removes on every exit path, and `slab` reuses vacated
      keys — so a panic during teardown can unregister a *different, live* runtime,
      whose `op_apply` then silently drops every reply. `[INFERENCE]`: no panic was
      constructed; the reachability rests on `run` removing before `worker` drops.
      An RAII guard owning the slab entry fixes it and removes five call sites.
      Note the adjacent `send_to_pid` on the same path *is* guarded — double
      reporting was reasoned about, double removal was not.
- [x] **4.3 Report a startup heap trip as `:heap_limit_error`** `[rust]` — `startup_error/3` consults the sticky flag via `termination_error/2` on all three post-install fallible steps; pinned by a new test with a `main_module_path` fixture that blows a 32MB cap, confirmed red (`:execution_error`, "Uncaught (in promise) Error: execution terminated") on revert
      `worker::new`'s two remaining fallible steps map to `execution_error` without
      consulting `heap_limit_tripped`, so an operator whose `:main_module_path`
      blows a tight cap gets V8's uninformative message at `Tyrex.start/1`. Fails
      closed; misreports.
- [x] **4.4 Decide whether to close stdio** `[rust] [docs]` — **stdin closed, stdout/stderr left inherited.** The asymmetry follows from where each capability lives, established by reading rather than assumed: `console.log` does not use these rids at all — it reaches `op_print`, which writes to Rust's own `stdout()` directly (`deno_core-0.391.0/ops_builtin.rs:219-231`). So piping rid 1 would have stopped `Deno.stdout.writeSync` while leaving a guest free to forge host output through `console.log`: half a fix, at the cost of the most useful debugging affordance JavaScript has. Output forging is inherent to in-process embedding and is now documented as unclosable rather than papered over. stdin, by contrast, has no legitimate guest use and is pointed at the null device, so `Deno.stdin.readSync` returns EOF instead of the operator's keyboard on an attached `iex`. Verified: stdin `READ null`, `console.log` still prints, `Deno.stdout.writeSync` still returns `WROTE 16`. Pinned by a `describe "the host's standard streams"` block that asserts the split in both directions, so a later "make `:none` consistent" change breaks a test instead of `console.log`.
      The docs half landed in `27bb9df`. The code option remains:
      `WorkerOptions.stdio` accepts piped/null handles, which would make
      `permissions: :none` mean what it says rather than what it now discloses.
      One field. Weigh against operators who legitimately want guest `console.log`
      on the host's stdout.
- [x] **4.5 Small, safe cleanups** `[rust]` — done: `catch_unwind` boundary named at `lib.rs:65-77` (Main folds the `Resource::down` path in above it); `_handleApplicationResult` deleted; `ascii_str!` on two constant bootstrap scripts instead of a built `String`. Left: `encode_json/1` (Elixir, owned by Phase 3); worker diagnostics stay `eprintln!` — routing them needs a receiving clause in `handle_info/2`, i.e. a log-forwarding design decision, so `op_apply` now carries a comment saying they are host-invisible and why
      Name the `catch_unwind` boundary in the comment at `lib.rs:52-64` — it does
      **not** cover panics inside V8 callbacks (`op_apply`, the loader hooks, the
      heap closure), which is what blocker #1 of the last review proved. Delete
      `Tyrex._handleApplicationResult`, a dead entry point on the privileged bridge
      that also throws on an unknown id. Stop `encode_json/1` returning the
      un-encodable *value* to the guest. Route worker diagnostics through something
      the host can see rather than `eprintln!`. Use `ascii_str!` for the one
      allocated constant.

**Verify:** `cargo clippy --release`, `TYREX_BUILD=true mix test`. For 4.1, pin the
new invariant with the op-table test from 2.2 — the two findings are the same
upstream dependency seen from opposite ends.

## Phase 5 — Release mechanics `[ci]`

- [x] **5.1 Make the CI checksum guard's pass condition reachable** `[ci]` — step renamed to "Report whether the checksum file covers this version"; `exit 1` dropped for `::notice` + a `$GITHUB_STEP_SUMMARY` block stating the release and its four archives ARE published and the remaining step is local; the comment now names the local `assert_checksums_current!/0` as the actual gate
      It greps the tree checked out *at the tag* for checksums derived from archives
      the same job just uploaded, so the tagged commit cannot contain them and a
      re-run fails identically. Every successful release therefore ends red, which
      erases the signal for a genuine failure of the tag or count guard. The
      release-then-verify *ordering* is right; implementing a notification as a
      permanent failure is not. Emit `::notice` plus `$GITHUB_STEP_SUMMARY`, or move
      a hard failure to a master-push check that can go green.
- [x] **5.2 Harden the two version guards** `[ci]` — feature grep anchored to `^rustler = .*"$FEATURE"` (2.16 matches, 2.15 no longer matches the comment); "Package NIF archive" now asserts rustler's `min_erts` on the built `.so` via a `NIF_VERSION`-driven case table, with a `grep -a` fallback where `strings(1)` is absent; both checksum guards now require all four `build_nif` targets
      Anchor the workflow's feature grep to the dependency line
      (`grep -q "^rustler = .*\"$FEATURE\"" Cargo.toml`) — with `NIF_VERSION=2.16`
      it is not currently vacuous, but `Cargo.toml:10`'s comment contains
      `["nif_version_2_15"]`, so a 2.15 label would pass on prose alone. Assert the
      ABI on the built artifact (`strings -a "$SRC" | grep -qx 'OTP-24.0'`), which
      is the only check that proves what was *built* rather than what was
      *requested*. Have both checksum guards require the full four-target set
      rather than one matching line.
- [x] **5.3 Fix the publish guard's ergonomics** `[ci]` — raise text now says `TYREX_BUILD=true mix checksums.after_release` and explains why; alias collapsed to a single `&hex_publish/1` (Mix only threads CLI args to the *last* alias element, so the two-element form could never see `docs`), which skips the guard for `mix hex.publish docs`
      Its raise text names a command that cannot run without `TYREX_BUILD=true`, and
      the guard also blocks `mix hex.publish docs`, which does not ship the checksum
      file and should not be gated on it.
- [x] **5.4 Pre-existing CI items, if cheap** `[ci]` — README consumer-side `{:rustler, ">= 0.0.0", optional: true}` added to both source-build sections: DONE. `paths`/tags: NO DEFECT — GitHub docs, *Triggering a workflow*: "Path filters are not evaluated for pushes of tags"; documented in the `on.push` block so it is not re-filed. `docker-build.sh`: MISREPORT — `:69-72` writes `/v8build/.cargo/config.toml` (the rusty_v8 clone, after `cd /v8build:67`) and that container never mounts the repo, so `native/tyrex/.cargo/config.toml` is untouched; recorded in a comment there
      `on.push`'s `paths` filter may gate tag pushes; `docker-build.sh` overwrites
      the packaged cargo config; the source-build instructions omit the
      consumer-side `{:rustler, ">= 0.0.0", optional: true}` a `force_build`
      consumer needs.

**Verify:** `mix hex.build` and inspect the tarball; exercise each guard standalone
against the real tree, as the last pass did. 5.1 only fully proves itself on a tag.

---

## Completeness check

38 deduplicated items. Source counts before dedup: rust-nif 4, security 7,
elixir+otp 16, testing 11, release 8, iron-laws 12, requirements 3.

| Area | Items | Phase |
|---|---|---|
| Docs contradicting code | 7 | 1 |
| Tests that cannot fail | 5 | 2 |
| Deadline / lifecycle defects | 5 | 3 |
| Rust hardening | 5 | 4 |
| Release mechanics | 4 | 5 |
| Pre-existing, folded in where cheap | 12 | 1, 3, 5 |

Deliberately **not** planned: `examples/` and `bench/` (deferred twice, still
broken by v0.4.0 defaults — they need a pass of their own); the stale
`checksum-Elixir.Tyrex.Native.exs` (by design); `pool.ex` duplicating `Tyrex`'s
`@runtime_opts` (real, but the fix is for `Tyrex` to own and export the list, which
is an API change); and the deno lockstep bump.

## Phase 6 — `examples/` and `bench/` (added during execution) `[elixir]`

Deferred by three consecutive plans and excluded from this one's scope, then done
anyway because it was the only remaining *user-visible* defect: anyone following
the examples on v0.4.0 hit an error.

- [x] **6.1 Make every example and benchmark run on v0.4.0 defaults** `[elixir]` — Ran all seven
      examples rather than reasoning about them, which narrowed the problem
      considerably: the plan and its predecessors assumed "several use
      `Tyrex.apply`, so they are broken", but only **one** file actually failed.
      `examples/basic.exs` died with `MatchError` on
      `{:error, %Tyrex.Error{name: :promise_rejection}}` because it calls
      `Tyrex.apply` with no `:apply` allowlist, so the bridge was never installed.
      Fixed with `apply: [{Enum, :sum, 1}, {Enum, :reverse, 1}]` plus a comment
      explaining that the bridge is opt-in and per-MFA, and a new final section
      showing a non-allowlisted call being refused — the example now teaches the
      security model instead of tripping over it.
      Every other example ran clean, but eight `Tyrex.start()`/`Pool.start_link`
      call sites omitted `:permissions` and so logged the v0.4.0 upgrade warning.
      Documentation that emits a warning teaches that the warning is normal, so
      all eight now pass `permissions: :none` explicitly, with a comment at the
      first one saying why. `bench/` likewise.
      Verified: all seven examples `exit=0` with **zero** upgrade warnings, and
      `bench/startup_bench.exs` requires cleanly.

## Risks

- **3.1 is the only task with real design risk.** All three options change a
  documented contract. Option B adds out-of-band state whose lifetime must match
  the runtime's or `kill/1` acts on a stale handle — which is worse than acting on
  none. Write the wedge probe as a test before choosing.
- **3.2 may not have a good answer.** Running an allowlisted MFA off the message
  loop means it no longer runs in the GenServer, which is where the release
  deliberately put authorization ("a guard inside the isolate would be inside the
  blast radius"). Documenting the gap may be the honest outcome; decide on
  evidence, not on tidiness.
- **4.1 touches the enforcement path that blocker B1 was about.** The six import
  tests must all still pass, and the main-module-under-`:none` case is the one that
  breaks if the `Cell<bool>` is set at the wrong moment.
- **Phase 1 looks free and is not.** Each item is one sentence, but each is a claim
  someone will rely on. 1.1 in particular should say what *is* supported, not just
  what is not, or the next reader re-adds the symmetric description.

### Self-check

- *What would make this plan wrong?* If Option C is chosen for `kill/1`, task 3.1
  collapses into a docs edit and Phase 3 loses its only hard task — in which case
  Phase 3 should merge into Phase 1 and the plan is four phases, not five.
- *What is most likely to be skipped under pressure?* 2.5, because it is
  test hygiene with no user-visible payoff, and 4.2, because its finding is
  `[INFERENCE]` and no reproduction exists. Note that 2.5's CPU-probe leak is the
  one that silently poisons every later test in the VM.
- *What did the review not look at?* `examples/` and `bench/`, for the third
  consecutive pass. Also `lib/tyrex/inline.ex`, `lib/tyrex/sigil.ex` and the
  strategy modules — untouched by the diff, so out of scope every time, and
  therefore never read by anyone.
- *What is the process failure here?* A named finding from the previous review's
  per-agent security report never reached that review's consolidated list and so
  was never assigned a task; it is task 2.2 in this plan, two passes later. The
  consolidation step loses findings, and nothing currently checks the per-agent
  files against the consolidated one.
