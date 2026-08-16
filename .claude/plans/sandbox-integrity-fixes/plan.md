# Plan: tyrex v0.4.0 — Review Fixes

**Slug:** `sandbox-integrity-fixes`
**Created:** 2026-08-14
**Input:** `.claude/plans/sandbox-integrity/reviews/sandbox-integrity-review.md` (6-agent panel over the uncommitted v0.4.0 diff)
**Research:** none spawned — the review findings are the research (Iron Law #7). Four findings were reproduced on this machine during the review and are marked VERIFIED below.

## Problem

The v0.4.0 sandbox-integrity work is functionally complete: 18/19 plan tasks MET,
141 tests green, and all five of the original audit's escape vectors are closed
with the 299.6% CPU leak returning to 0.00. A six-agent review then found 23
issues, of which five are blocking.

Three of them are ours — introduced by the very patch that was supposed to close
the sandbox:

1. **A use-after-free.** `heap_limit_state` is declared after `worker`, so on
   `worker::new`'s error paths the `Arc` is freed before the isolate that still
   holds a raw pointer into it.
2. **A confused deputy.** `:apply` allowlists are per-runtime, but `op_apply`
   trusts a guest-writable `Tyrex._runtimeId` to pick which runtime's GenServer
   authorizes the call. Spoofing bought nothing before this release; the patch
   creates the boundary it violates.
3. **A doc inversion that grants permissions.** `false` is documented as
   "deny all" for all sixteen keys, but for the eight `deny_*` keys `false`
   means "deny nothing".

The other two are pre-existing but land badly in a release whose entire premise
is that tyrex stopped overclaiming:

4. **`import()` bypasses every read permission** and `deny_import` is inert.
5. **`RUSTLER_NIF_VERSION` is inert** — we would ship NIF 2.15 binaries labelled
   `nif-2.16`, with a CHANGELOG entry claiming a fix that does not exist.

### The uncomfortable one

Finding 4 is the same *class* of bug this release exists to eliminate: a
documented security control that silently does nothing. `permissions: :none`
denies `Deno.readTextFileSync` while `import("file:///etc/passwd", {with:{type:"json"}})`
succeeds. Shipping v0.4.0 with `allow_import`/`deny_import` still in the
permission table would re-commit the original sin at a new address.

## Scope decision

**Phase 1 gates the PR. Phases 2–4 do not.** Phase 1 is the set of things that
make the branch's security claims true; it is a coherent, independently
shippable unit. Phase 3 gates the *tag*, not the PR — nothing there can hurt
anyone until `mix hex.publish` runs.

If context pressure forces a split, split after Phase 1 and run Phases 2–4 as a
second pass. Do not split within Phase 1.

---

## Decision required before task 1.1

`import()` reads any file the BEAM user can read, under any permission set.
Two honest answers; pick one and record it in the scratchpad.

**Option A — enforce it (recommended).** Wrap `FsModuleLoader` in a newtype whose
`load/4` calls `PermissionsContainer::check_read` before delegating. The
container is already in scope at `worker.rs:341`.

**Option B — disclaim it.** Delete `allow_import`/`deny_import` from the
documented key set, reject them in `encode_permissions/1`, and state in the
README that module loading is unrestricted and untrusted code must be given no
importable filesystem.

Option A is recommended because Option B leaves `permissions: :none` unable to
honestly describe itself. But A has a trap, spelled out in 1.1.

---

## Phase 1 — Close what this release opened `[rust] [elixir] [docs]`

- [x] **1.1 Make module loading respect read permissions** `[rust]` — `PermissionedModuleLoader` wraps `FsModuleLoader` and calls `PermissionsContainer::check_specifier` (which *does* exist in the pinned crates, at `deno_permissions-0.97.0/lib.rs:3908`, and is what deno itself uses) with `CheckSpecifierKind::Dynamic`. The exemption is not a specifier match but `ModuleLoadOptions::is_dynamic_import` / `ResolutionKind::DynamicImport`, i.e. deno's own static-vs-dynamic boundary: `RecursiveModuleLoad` derives the flag from `LoadInit` and propagates it to every transitive dependency, so the main module *and its whole static graph* stay loadable under `:none` while every guest `import()` is checked. Checked in **both** `resolve` and `load`: `ModuleMap::load_dynamic_import` resolves before consulting the module map (`map.rs:1291`), so `resolve` is the only hook that sees an `import()` of an already-loaded specifier — without it a guest could re-import the main module's static graph with no `load` and no check. `import_meta_resolve` is overridden to stay unchecked (pure URL arithmetic, reads nothing).
      Review B1, VERIFIED. `deno_core::FsModuleLoader` receives no
      `PermissionsContainer` and ends in a bare `std::fs::read`; `check_import`
      exists nowhere in the pinned `deno_core-0.391.0` / `deno_runtime-0.246.0`.
      - **Trap:** the main module is loaded through the same loader. A naive
        `check_read` on every load breaks
        `Tyrex.start(permissions: :none, main_module_path: ...)`, which works
        today. The main module is operator-supplied and loaded once at
        bootstrap; dynamic `import()` is guest-supplied. Exempt the former
        (match on the resolved main-module specifier captured at construction),
        enforce on everything else.
      - Reproduce first, then fix. Under `permissions: :none`:
        `import("file:///tmp/x.js")` returns the module and
        `import("file:///tmp/x.json", {with:{type:"json"}})` returns parsed
        JSON. `type:"text"` is *not* a valid module type — do not use it as the
        probe, it fails for an unrelated reason and looks like a pass.
      *Docs half done (DocsPass)* — new README section "Dynamic `import()` vs.
      the main module" states the enforced split (`file:` specifier → read
      permissions, non-`file:` → `allow_import`/`deny_import`, main module and
      its static graph exempt, and why that exemption is the operator's
      boundary), plus a Security Scope bullet, an "Upgrading from 0.3.x" bullet,
      corrected `allow_read`/`allow_import` key-table rows, and a CHANGELOG
      entry. Rust enforcement itself remains.
- [x] **1.2 Replace the false-positive `deny_import` test** `[elixir]` — replaced with a `describe "dynamic import() respects permissions"` block of six tests. Deno reports a rejected dynamic import as an `Error` whose `code` is `ERR_MODULE_NOT_FOUND` and whose `message` is not an own enumerable property, so it does not survive serialization into `Tyrex.Error.value`; the tests therefore read `e.message` inside the isolate via an `import_message/2` helper, which is also the only way to distinguish a denial from a missing file. Asserts: `file:` import denied under `:none` with `"Requires read access"` naming the file; JSON import (`type: "json"`, not the invalid `type: "text"`) denied; the same file imports fine under `allow_read`; main module **and its static import graph** still load under `:none`; the exemption is not a general read primitive (guest `import()` of the main module's own path is denied); `deny_import` blocks a non-`file:` specifier with `"Requires import access"`. 35/35 green.
      Review B1. `test/tyrex_permissions_test.exs:109-128` uses an `https:`
      specifier that `FsModuleLoader` rejects as "not a file URL" regardless of
      permissions, and asserts only
      `err.name in [:promise_rejection, :execution_error]`. It would pass
      against a completely unguarded loader. Rewrite against a `file:` specifier
      with a fixture, asserting the read is denied and that the same file is
      readable under `allow_read`.
- [x] **1.3 Remove the unsafe heap-limit callback entirely** `[rust]` — `HeapLimitState`, the `Arc::as_ptr`, and the `unsafe extern "C" fn` are gone. `Worker` now holds only `heap_limit_tripped: Option<Arc<AtomicBool>>`; the closure passed to `JsRuntime::add_near_heap_limit_callback` captures a clone of that `Arc` plus the `IsolateHandle`, and deno boxes it into `JsRuntime::allocations`, which is declared after `inner`. The "field order is load-bearing" comment and the explicit `drop(worker); drop(heap_limit_state);` at the end of `run` are both deleted. Re-verified against the original probe rather than assumed equivalent: `max_heap_mb: 64` + an allocation loop still yields `%Tyrex.Error{name: :heap_limit_error}`, the runtime is dead afterwards, and the BEAM survives.
      Review B2. Drop `HeapLimitState`, the `Arc`, `Arc::as_ptr`, and the
      `unsafe extern "C"` fn. Use `JsRuntime::add_near_heap_limit_callback`
      (`jsruntime.rs:1851`), which takes a safe `FnMut(usize, usize) -> usize`
      and stores the boxed closure in `self.allocations` — a field declared
      after `inner` precisely so it outlives the isolate. Capture an
      `Arc<AtomicBool>` in the closure for the sticky `tripped` flag and keep a
      clone in `Worker` for `termination_error/2`.
      Delete the now-vacuous "field order is load-bearing" comment on `Worker`
      and the explicit `drop(worker); drop(heap_limit_state);` at the end of
      `run` — both were compensating for the hand-rolled invariant.
- [x] **1.4 Take the runtime id out of guest reach** `[rust]` — id moved into per-runtime `OpState` via `extension!`'s `options = { runtime_id: usize }` + `state` closure (a newtype `RuntimeId`, so `state.borrow::<RuntimeId>()` cannot collide with another `usize` in the state map); `op_apply` now takes `state: &mut OpState` and no longer accepts `#[string] runtime_id`, so the `parse::<usize>()` failure branch is gone with it. `Tyrex._runtimeId` deleted from `extension/main.js` (both the field and the `op_apply` argument). The bridge-on branch of the bootstrap `execute_script` is deleted entirely — with the id in `OpState` there is nothing left to inject — while the `delete globalThis.Tyrex` half is kept for the bridge-off case, verified still returning `"undefined"`. Cross-runtime spoof probed: a guest that sets `Tyrex._runtimeId` to a sibling's id gets `permission_denied` against its own allowlist.
      Review B5, consensus (rust-nif + security). Put the id in per-runtime
      `OpState` via the `deno_core::extension!` `state` closure and read it with
      `state: &mut OpState` inside `op_apply`, instead of accepting
      `#[string] runtime_id` from JS. Then delete `Tyrex._runtimeId` from
      `extension/main.js`, the `_runtimeId` bootstrap `execute_script` in
      `worker::new`, and the `parse::<usize>()` failure branch.
      Note the bootstrap script still has a second job when the bridge is
      disabled (`delete globalThis.Tyrex`) — keep that half.
- [x] **1.5 Fix the inverted `false` (deny all) documentation** `[docs]` — `README.md:184` replaced with a per-direction split (`allow_x` / `deny_x` against `true` / `false` / `[]`), mirroring `worker.rs:139-147`: `false` is the absence of a rule in whichever direction the key names, and an empty list allows nothing but denies nothing. CHANGELOG entry added; `lib/tyrex.ex` half landed separately (now correct at `:166-168`). No third occurrence in either doc. The `lib/tyrex.ex` half spells out `true` / `false` / `[]` for each direction explicitly (`allow_x: []` grants nothing, `deny_x: false` and `deny_x: []` deny nothing, with `deny_read: false` named as the reproduced case), makes the trailing fail-closed sentence direction-aware, and retitles the `:allow_import` / `:deny_import` row to "dynamic `import()` of non-`file:` specifiers" now that `file:` dynamic imports answer to the read permissions and the static graph is exempt (1.1).
      Review W1, VERIFIED — and this was v0.4.0 task 1.5's explicitly named
      target, missed. `lib/tyrex.ex:141` and `README.md:184` both say
      "`false` (deny all)". True for the eight `allow_*` keys; inverted for the
      eight `deny_*` keys, where `deny_read: false` reads the file. Split the
      sentence by direction. The Rust side already documents the split
      correctly at `worker.rs:90-92` — mirror that wording.
- [x] **1.6 Enforce a measured `:max_heap_mb` floor** `[rust] [elixir] [docs]` — Elixir half only. `@min_heap_mb 32` and `@measured_min_heap_mb 14` are module attributes carrying the measurement in a comment; `validate_max_heap_mb!/1` now requires `is_integer(mb) and mb >= @min_heap_mb`. The `ArgumentError` names both numbers and why the floor is not the measured minimum: the near-heap-limit callback cannot be armed until the isolate exists, so deno's bootstrap and snapshot deserialization always run under V8's default `abort()`, which takes down the whole BEAM rather than the guest. "positive integer" is retained in the message so `test/tyrex_lifecycle_test.exs`'s existing `~r/positive integer/` assertion against `max_heap_mb: 0` still holds. `start/1`'s `:max_heap_mb` doc states the minimum and the reason. Verified the message and the accept/reject boundary (31 rejected, 32 accepted, `nil` accepted) by evaluating the two clauses standalone. README/CHANGELOG halves belong to other agents.
      Review W2. `create_params` applies the cap at isolate creation, but the
      near-heap-limit callback is only installed after
      `bootstrap_from_options` has run deno's bootstrap and snapshot
      deserialization — the heaviest allocation phase in a runtime's life, under
      V8's default `abort()`. `validate_max_heap_mb!/1` accepts any `mb > 0`, so
      `max_heap_mb: 8` kills the BEAM at `Tyrex.start/1`: exactly what the option
      exists to prevent. Measure the bootstrap high-water mark, enforce a floor
      with a message naming the measured minimum, and document it.
- [x] **1.7 Contain panics on the worker thread** `[rust]` — the thread body in `start_runtime` is wrapped in `catch_unwind(AssertUnwindSafe(..))` around `tokio_rt.block_on`, so `try_remove(runtime_id)` still runs on an unwind instead of leaking the slab entry forever. Two additions beyond the plan text: a `Cell<bool>` records whether startup already reported an outcome, so a panic *during* `worker::new` sends an `{:error, _}` to the waiting `init/1` instead of making it sit out its full 30s `:startup_timeout`; and the oneshot `RecvError` arms in `eval`/`eval_blocking` now report `:dead_runtime_error` rather than `:execution_error`, since a sender dropped without replying only happens when the worker died. In-flight callers therefore need no explicit drain — unwinding drops the promise slab, and the slab is declared after `worker` so the `v8::Global`s drop while the isolate is still alive.
      Review W10. This release made termination asynchronous and arbitrary
      (`terminate_runtime`, `Runtime::drop`, the `eval_blocking` timeout arm,
      the heap callback) where it was previously observed only between
      operations. Under a pending termination V8 returns empty `MaybeLocal`s and
      `serde_v8` unwraps them — upstream marks these "fixme: this unwrap is not
      safe". The worker runs on a bare `std::thread::spawn`, outside rustler's
      `catch_unwind`, so a panic skips `try_remove(runtime_id)` (slab leak) and
      `drain_pending_promises` (callers hang). Wrap the worker body in
      `catch_unwind(AssertUnwindSafe(..))` so cleanup still runs.

**Verify:** `TYREX_BUILD=true mix compile --warnings-as-errors && mix format --check-formatted && TYREX_BUILD=true mix test`, plus a re-run of the review's escape probes — the `import()` read must now be denied, and the cross-runtime `_runtimeId` spoof must fail.

*Done.* Compile, format and the full suite are all clean (see Phase 4's verify block for the numbers). The escape probes were re-run against the built NIF:

| Probe | Before | After |
|---|---|---|
| `:none` + `import("file:///…/secret.js")` | `{:ok, "SECRET-FROM-DISK"}` | `{:error, %Tyrex.Error{name: :promise_rejection}}`, message `Requires read access to "…/secret.js"` |
| `:none` + `import(…secret.json, {with:{type:"json"}})` | `{:ok, %{"secret" => "json-secret"}}` | denied |
| `allow_read: ["…/imp"]` + same import | n/a | `{:ok, "SECRET-FROM-DISK"}` — enforcement is a check, not a blanket ban |
| `allow_all: true, deny_import: true` + `https:` import | `{:ok, module}` | denied, `Requires import access to "deno.land:443"` |
| `:none` + `main_module_path` with a static `import` | works | still works (`{:ok, 42}`) |
| guest `import()` of the main module's own path | n/a | denied — closed by the `resolve` check after the first round showed it resolving from the module map |
| cross-runtime `_runtimeId` spoof | authorized against the sibling's allowlist | `typeof Tyrex._runtimeId` is `"undefined"`; setting it changes nothing, the call is refused with `permission_denied: String.upcase/1 is not in the :apply allowlist` |
| bridge off | — | `typeof globalThis.Tyrex` still `"undefined"` (v0.4.0 task 1.1 intact) |
| `max_heap_mb: 64` + allocation loop | `:heap_limit_error`, BEAM alive | unchanged after the callback rewrite: `:heap_limit_error`, runtime dead, BEAM alive |

The `:max_heap_mb` floor was measured, not guessed: in a fresh OS process per attempt, `13` aborts with `v8::base::FatalOOM` during `bootstrap_from_options` and `14` boots (5/5 runs). `8`, as named in task 1.6, kills the BEAM. Floor set to 32.

## Phase 2 — API hardening `[elixir] [rust]`

- [x] **2.1 Decide `timeout: :infinity` on the non-blocking path** `[elixir]` — refused on both paths. `eval/2` returns `{:error, %Tyrex.Error{name: :unsupported_option}}` before any `GenServer.call`, and the server-side `timeout == :infinity` clause moved to the *top* of `handle_call({:eval, ...})`'s `cond` so it guards the non-blocking path too for anyone calling the GenServer directly. `unsupported_option(:blocking_without_deadline)` is renamed `:without_deadline` and its message is now path-neutral, covering the uncapped 100%-CPU worker thread as well as the parked dirty-IO scheduler. With `:infinity` unreachable the dead code is gone: `call_timeout(:infinity)`, `arm_deadline/3`'s `:infinity` clause, and `cancel_timer(nil)` — nothing stores a `nil` timer any more, so `arm_deadline/3` and `cancel_timer/1` are single-clause.
      Review W3. The blocking path refuses `:infinity` with
      `:unsupported_option`; the default path accepts it, arms no timer, and so
      reintroduces v0.4.0's headline defect — an uncapped 100%-CPU OS thread,
      invisible to scheduler monitoring — through a documented option. Via
      `Pool.eval/3` it permanently consumes a pool slot. Refuse it on both paths
      (consistent, recommended) or document the opt-out under `:timeout`.
- [x] **2.2 Validate `:timeout`** `[elixir]` — `validate_timeout!/1` runs inside `eval/2` before the `GenServer.call`: a positive integer passes, `:infinity` passes through to the refusal above, everything else raises `ArgumentError` in the calling process with `":timeout must be a positive integer number of milliseconds or :infinity, got: <value>"`. Confirmed for `-1`, `0`, `5.5`, `nil`, `"5"` by evaluating the clauses standalone. The new tests assert the runtime is still alive and still serving after each rejection, which is the defect rather than the exception type.
      Review W4. `timeout: -1` passes `call_timeout(-1) = 999` (a legal call
      timeout), reaches the server, and raises `ArgumentError` inside
      `Process.send_after/3`, killing the runtime. Under `Pool`'s
      `:rest_for_one` that restarts every runtime after the selected one, so one
      caller's bad argument is a multi-runtime outage. `timeout: 5.5` or `nil`
      raises `FunctionClauseError` naming a private function. Validate in
      `eval/2` so the failure stays with the caller.
- [x] **2.3 Drain in-flight callers on every terminal path** `[elixir]` — `terminate/2` now calls `fail_inflight(state, :dead_runtime_error)` before `Native.terminate_runtime/1`, so it covers `blocking_eval/3`'s three `{:stop, ...}` returns and a plain `Tyrex.stop/1` in one place; the reason there is no double reply (handlers that already drained leave `inflight: %{}`) is written into the comment. Draining before the native call also means the replies do not wait on isolate teardown. Covered by two new tests in `test/tyrex_api_test.exs`, one of them with three concurrent in-flight callers — which is also 4.6's multi-caller `fail_inflight/2` gap.
      Review W5. `blocking_eval/3`'s three `{:stop, ...}` returns and
      `terminate/2` both skip `fail_inflight/2`, so a blocking timeout or a
      plain `Tyrex.stop/1` leaves pending non-blocking callers to exit rather
      than receive the `dead_runtime_error` that `kill/1`'s docs promise for the
      same situation. Calling `fail_inflight(state, :dead_runtime_error)` at the
      top of `terminate/2` covers both; handlers that already call it leave
      `inflight: %{}`, so there is no double reply.
- [x] **2.4 Map `:noproc` exits to the documented error tuple** `[elixir]` — `eval/2` catches `:exit` and routes the reason through `dead_runtime_exit?/1`, which unwraps `GenServer.call`'s `{reason, {GenServer, :call, args}}` wrapper and answers true only for `:noproc`, `:normal` and `{:shutdown, _}`; anything else is re-raised via `:erlang.raise(:exit, reason, __STACKTRACE__)`, keeping the original `:gen.do_call/4` stacktrace. Verified against a stub GenServer: dead pid, unregistered name, and mid-call `:normal` / `{:shutdown, :timeout}` stops all return `dead_runtime_error`, while a genuine `GenServer.call` `:timeout` and an abnormal `:badness` stop still propagate — swallowing those would hide a server-side deadline that lost its race.
      Review W6. `@spec` promises `{:ok, term} | {:error, Error.t()}`, but the
      new terminate ⇒ dead contract means every deadline, heap trip and `kill/1`
      opens a window where the next call exits instead of returning. The v0.4.0
      test suite already works around this
      (`test/tyrex_lifecycle_test.exs:189-195`, `catch :exit, _ -> false`),
      which is the tell. Catch `:noproc` / `:normal` / `{:shutdown, _}` and
      return `dead_runtime_error`.
- [x] **2.5 Reject a non-boolean `allow_all`** `[rust]` — the `matches!(..., PermValue::True)` is replaced with an exhaustive `match`: `True`/`False` as before, `List(_)` returns a `permissions_error` explaining that `allow_all` is a baseline for every other key, so a list of paths or hosts has no meaning there. The runtime now refuses to start rather than silently reinterpreting the shape it was handed, which is what the `PERMISSION_KEYS` rationale directly above it already promised.
      Review S1. `allow_all: ["/tmp"]` parses to `PermValue::List` and
      `matches!(..., True)` quietly yields false. It fails closed, so it is not
      a hole — but it is the one place in the rewritten parser that silently
      reinterprets a shape it was handed, contradicting the rationale written
      directly above it at `worker.rs:59-61`.
- [x] **2.6 Bound the heap-limit slack** `[rust]` — one-shot grant. The closure keeps a `granted` flag and returns `current + 8MB` on the first invocation only, `current_heap_limit` thereafter, so total growth is bounded at +8MB instead of ratcheting by 8MB per call. Chosen over deno's `current * 2` because execution is already terminated by the time the slack is handed out: it funds teardown, and doubling a 64MB ceiling to fund teardown is a worse trade than a fixed 8MB.
      Review S2. Each callback invocation returns `current + 8MB`, so the
      ceiling ratchets by 8MB per invocation rather than overshooting by a
      bounded amount. deno's own usage returns `current * 2`. Either that or a
      one-shot "if already tripped, return `current_heap_limit`" is easier to
      reason about.

**Verify:** `TYREX_BUILD=true mix test`, plus new coverage for 2.1–2.4.

*Done.* New coverage lives in `test/tyrex_api_test.exs` (11 tests, all green). The load-bearing assertion for 2.2 is not that the bad argument is rejected but that **the runtime is still alive afterwards** — `timeout: -1` previously raised inside `Process.send_after/3`, killing the runtime, and under `Pool`'s `:rest_for_one` every sibling after it. 2.4's coverage also pins that a genuine `GenServer.call` `:timeout` still *propagates* rather than being laundered into `dead_runtime_error`, so the new `catch` cannot silently widen.

## Phase 3 — Release mechanics `[ci] [rust] [docs]`

Nothing in this phase can hurt a user until `mix hex.publish` runs, but every
item here is load-bearing at tag time.

- [x] **3.1 Build against the NIF version we advertise** `[rust] [docs]` — CI/script half: workflow `env:` renamed `RUSTLER_NIF_VERSION` -> `NIF_VERSION` (now documented as a *label* only, feeding the archive name and rust-cache key), step-level re-export and `echo` deleted, `-e RUSTLER_NIF_VERSION=2.16` dropped from `scripts/docker-build.sh` (nothing inside that container read it), and the build step now asserts `nif_version_${NIF_VERSION//./_}` appears in `native/tyrex/Cargo.toml` so a label/ABI mismatch fails the build; the `features = ["nif_version_2_16"]` half landed separately
      *Rust half done (Main)* — `native/tyrex/Cargo.toml` now reads
      `rustler = { version = "=0.38.0", features = ["nif_version_2_16"] }`, with a
      comment naming the two places the label must stay in step (`nif_versions:`
      in `lib/tyrex/native.ex`, `NIF_VERSION` in the release workflow). Verified
      rather than assumed: `cargo tree -p rustler -f "{p} {f}"` now reports
      `default,nif_version_2_14,nif_version_2_15,nif_version_2_16`, where before
      the edit it stopped at `nif_version_2_15`. That is B3 closed.
      *Docs half done (DocsPass)* — `README.md:627` now says the NIF level is
      selected by the `nif_version_2_16` Cargo feature on the crate's `rustler`
      dependency and that `RUSTLER_NIF_VERSION` has had no effect since rustler
      0.30. The false CHANGELOG entry is rewritten rather than deleted: it now
      describes what ships (feature enabled, so the binaries match the
      `nif-2.16` label they have carried since v0.3.0) and records that the
      env var was inert everywhere, including `release.yml`.
      Review B3, VERIFIED. rustler removed env-var NIF selection in 0.30; it is
      a Cargo feature now, and `rustler-0.38.0` declares
      `default = ["nif_version_2_15"]`. `rustler = "=0.38.0"` requests no
      features, so we compile 2.15 and label it `nif-2.16`. v0.4.0 task 3.2's
      entire plumbing — workflow `env:`, the step re-export, `Cross.toml`,
      `docker-build.sh:123` — is dead code.
      Add `features = ["nif_version_2_16"]` (or relabel everything 2.15), then
      delete whichever plumbing is left inert. Correct `README.md:627` and the
      CHANGELOG entry, which currently claims a fix that does not exist.
- [x] **3.2 Write the checksum-regeneration step into the release runbook** `[ci] [docs]` — mechanism, not prose: `mix checksums.after_release` alias regenerates the file (`rustler_precompiled.download Tyrex.Native --all --print`), `mix hex.publish` is aliased behind a guard that `Mix.raise`s when the checksum file has no `-v<@version>-nif-` entry, and the `publish` job re-checks it after attaching the archives (pre-release gating would deadlock: the checksums come from a release that does not exist yet) with a message stating the archives ARE published and the remaining step is local
      *Docs half done (DocsPass)* — new README `## Releasing` section names the
      four steps in order (tag push → `Precomp NIFs` attaches the four archives
      → `TYREX_BUILD=true mix checksums.after_release` → commit
      `checksum-Elixir.Tyrex.Native.exs` → `mix hex.publish` behind its guard)
      and why the order cannot be permuted: step 2 downloads what step 1
      publishes, step 4 ships what step 2 writes, and publishing early makes
      `RustlerPrecompiled` raise before any network call for every precompiled
      user of that release.
      Review B4, consensus (release + requirements).
      `checksum-Elixir.Tyrex.Native.exs` holds only v0.3.0 entries while
      `mix.exs` is 0.4.0. `RustlerPrecompiled` resolves the artifact name,
      misses the local checksum map, and raises *before any network call* — so
      publishing breaks all four precompiled targets identically whether or not
      the tag exists. Nothing regenerates it and no runbook mentions it.
      Document the load-bearing order: GitHub release →
      `mix rustler_precompiled.download --all --print` → `mix hex.publish`.
      Prefer a CI step or a `mix` alias over prose.
- [x] **3.3 Assert the tag matches `mix.exs` in the publish guard** `[ci]` — `publish` now checks out the tree, scrapes `@version` with the same `sed`, and fails when `github.ref_name != v{version}`, before the archive-count guard
      Review W11. `PROJECT_VERSION` is scraped from `mix.exs` and is the sole
      source of the `v{version}` in every archive name; the tag ref is never
      compared to it. Tagging `v0.4.1` on a commit whose `mix.exs` says `0.4.0`
      produces four `v0.4.0` archives on the `v0.4.1` release, the `EXPECTED=4`
      count guard passes, and every user 404s — atomic and uniformly wrong,
      the exact failure class the job exists to prevent.
- [x] **3.4 Stop packaging `Cross.toml` without its Dockerfile** `[rust]` — `"native/tyrex/Cross.toml"` removed from `package.files`, and the file itself deleted since nothing in the repo invokes `cross`.
      **Correction (residue pass, task 1.6):** the rationale recorded here and in
      `f134c25`'s commit message — that `Cross.toml`'s stanza "referenced a
      Dockerfile that does not exist" — was **false**.
      `native/tyrex/Dockerfile.aarch64-unknown-linux-gnu` existed (332 bytes) and
      was tracked at `master`. The deletion was still correct, but for W12's
      actual reason: the Dockerfile was never *packaged*, so a consumer building
      from source got a `Cross.toml` pointing at a file they did not have. Having
      deleted `Cross.toml`, the Dockerfile became an orphan with no referent
      anywhere in the repo, and has now been deleted with it.
      Review W12. `package.files` ships `Cross.toml`, whose only live stanza
      references `Dockerfile.aarch64-unknown-linux-gnu` — which is not packaged.
      Same class of omission as the `.cargo/config.toml` bug v0.4.0 fixed.
      Dropping `Cross.toml` from `package.files` is cleaner than adding the
      Dockerfile: it is CI infrastructure, not something a consumer's
      `mix compile` reads.
- [x] **3.5 Strike the false deferral clause from the v0.4.0 plan** `[docs]` — struck the "touches none of the files the bump touches" clause; deferral now rests solely on the release-purpose reason
      Review S6. `.claude/plans/sandbox-integrity/plan.md` defers the deno bump
      partly because "the Phase 1-3 work touches none of the files the bump
      touches". True when written; `worker.rs` has since changed across 418
      lines, plus `Cargo.toml` and `Cargo.lock` — precisely the files a
      `deno_core`/`deno_runtime` bump touches. The deferral still stands on its
      other reason. Strike only the clause, so the bindings follow-up is not
      sized off a false premise.

**Verify:** `mix hex.build` and confirm the tarball contents; dry-run the release workflow.

*Done.* `mix hex.build` succeeds; the tarball carries 29 files with `native/tyrex/Cross.toml` gone and everything the documented source-build path needs still present (`native/tyrex/.cargo/config.toml`, `Cargo.toml`, `Cargo.lock`, `src/`, `extension/`). `cargo tree -p rustler -f "{p} {f}"` now reports `nif_version_2_16`, where before the `features` edit it stopped at `nif_version_2_15` — B3 closed and verified rather than asserted.

Not fully verifiable locally, as the plan anticipated: 3.2's and 3.3's guards only truly execute on a tag. Both were exercised standalone against the real tree instead — the tag guard passes for `v0.4.0` and exits 1 naming both values for `v0.4.1`, and the checksum guard exits 1 against the current v0.3.0-only `checksum-Elixir.Tyrex.Native.exs`. That residue is accepted.

## Phase 4 — Make the tests able to fail `[elixir]`

Every item here is a test that currently passes and would keep passing through
the regression it was written to catch.

- [x] **4.1 Pin `:heap_limit_error` instead of accepting `:timeout`** `[elixir]`
      Review W7. `assert name in [:heap_limit_error, :timeout]` accepts the
      exact output of the most plausible regression: drop
      `terminate_execution()` from the callback, keep the slack grant, and the
      guest allocates until the eval deadline returns `:timeout` — green test,
      BEAM-abort protection silently gone. Assert equality and add
      `refute Process.alive?(pid)`. If 30s ever proves tight, raise the timeout
      rather than widen the accepted name.
      *Done (LifecycleTests)* — `test/tyrex_lifecycle_test.exs` "a guest that
      exhausts the heap is terminated": `name: :heap_limit_error` by equality,
      plus a monitor asserting `{:DOWN, .., {:shutdown, :heap_limit_error}}` and
      `refute Process.alive?/1`. The DOWN wait is needed because the reply is
      sent from inside the clause that stops the runtime, so a bare
      `Process.alive?` would race the exit. 30s timeout kept, with the "raise
      the timeout, never widen the accepted name" rule written into the comment.
- [x] **4.2 Make the stale-timer test able to observe a stale timer** `[elixir]`
      Review W8. The comment names the bug — "a stale timer firing later would
      kill a healthy runtime" — then makes it unobservable: both evals use
      `timeout: 5_000` against a 200ms sleep, so an uncancelled timer fires
      ~4.8s after the test has finished. Deleting `cancel_timer/1` from the
      `:eval_reply` clause leaves it green. Use `timeout: 300` and
      `Process.sleep(600)`, then assert the runtime is still alive.
      *Done (LifecycleTests)* — `timeout: 300` on both fast evals and a 600ms
      wait, then alive plus still-serving. The wait is a
      `refute_receive {:trace, ^pid, :receive, {:deadline, _}}, 600` under
      `:erlang.trace(pid, true, [:receive])`: the `{:deadline, from}` clause
      drops a `from` it no longer holds as `:absent`, so a stale timer has no
      other outward effect and only the trace makes `cancel_timer/1`
      load-bearing. Mechanism verified out-of-band on a stand-in GenServer
      (cancelled: no trace; uncancelled: `{:deadline, _}` inside 600ms).
- [x] **4.3 Scale the CPU probe to the runner and fix `ps` resolution** `[elixir]`
      Review W9. Two independent hazards in the assertion the v0.4.0 plan said
      was most likely to be dropped and must survive. (a) Three runaways can
      accrue at most `min(3, vCPU)` cores/sec; on a 2-vCPU CI runner
      `running > baseline + 1.0` sits at the margin and on 1 vCPU it fails
      outright — scale to `System.schedulers_online()`. (b) `ps -o time=` has
      one-second resolution on Linux, making measurement error the same size as
      the one-leaked-thread signal — read `/proc/self/stat` utime+stime there,
      keep `ps` as the macOS path. With sub-second resolution restored, tighten
      the idle bound so a *single* leaked thread fails the probe.
      *Done (LifecycleTests)* — burn floor is
      `min(3, System.schedulers_online()) * 0.6` above baseline;
      `process_cpu_seconds/1` dispatches on `:os.type()`, reading
      `/proc/self/stat` fields 14+15 over `sysconf(_SC_CLK_TCK)` (100 on Linux)
      and keeping the `ps` parser for macOS/BSD. The idle bound is absolute
      rather than `baseline + 1.0`: 0.35 cores on Linux, 0.5 on Darwin where
      `ps`'s whole-second resolution costs ±0.25 over the now-4s window — both
      fail on a single leaked thread.
- [x] **4.4 Give the `kill/1` tests something that can fail** `[elixir]`
      Review S3. `kill/1` ends in `catch :exit, _ -> :ok`, so
      `assert :ok = Tyrex.kill(...)` is a tautology for every input. In
      "is safe to call on an already-dead runtime" it is the only assertion.
      Add `refute Process.alive?(pid)` and an elapsed bound — promptness is the
      property the catch-all is hiding.
      *Done (LifecycleTests)* — both `kill/1` tests: the dead-runtime case adds
      `refute Process.alive?/1` and `elapsed < 1_000` (a `:noproc` call exits at
      once, so anything near the 5s default means we waited on something); the
      wedged-guest case monitors first and bounds `kill/1` → `:DOWN` at 2_000ms.
- [x] **4.5 Tighten the bare `%Tyrex.Error{}` assertions** `[elixir]`
      Review S4. Several fail-closed permission tests assert only the struct and
      pass on any error, including a runtime that failed to start for an
      unrelated reason. Pin `:name` where the path is deterministic.
      *Done (PermTestTighten)* — all eight bare matches in
      `test/tyrex_permissions_test.exs` now pin `:name` by equality: five
      synchronous denials as `:execution_error` plus `message =~ "NotCapable"`
      and the `--allow-<perm>` flag naming the permission at issue, three async
      IIFE denials as `:promise_rejection`. `deny_net` additionally re-throws
      `e.message` as a string so the text reaches `:value` — otherwise it passes
      on an offline runner, where `fetch` rejects for unrelated reasons. Traced
      (`serde_v8-0.300.0/de.rs:468` + `rusty_v8` `GetPropertyNamesArgs::default`)
      that rejection payloads are collected with `ONLY_ENUMERABLE`, so a thrown
      `Error`'s non-enumerable `message` never reaches `:value`: that is why the
      other two async sites pin the name only, as does `import_message/2`.
- [x] **4.6 Cover the untested paths** `[elixir]` — all five sub-items covered and green. Pool half in `test/tyrex_pool_test.exs`; the other four in the new `test/tyrex_api_test.exs` (11 tests): `apply: []` collapses to a disabled bridge, the one-time `Logger.warning` (made deterministic by erasing `:persistent_term` `{Tyrex, :permissions_warned}` under `capture_log`, then asserting a second `start/1` is silent), `stop/1`'s escalation branch (wedged through the apply bridge with `apply: [{Process, :sleep, 1}]` — a non-blocking runaway leaves the GenServer *idle* and `blocking: true` parks it in a dirty NIF where `Process.exit(:kill)` is deferred, so neither reaches the escalation path), and `fail_inflight/2` with three concurrent callers.
      Review S5. `Pool` forwarding of `:apply` and `:max_heap_mb`, the one-time
      `Logger.warning`, `apply: []` collapsing to a disabled bridge, `stop/1`'s
      escalation branch, and `fail_inflight/2` with multiple concurrent callers
      — none are exercised. The `Pool` forwarding gap matters most: it is the
      only route by which a pooled runtime gets a heap cap.
      *Pool half done (PoolCoverage)* — `test/tyrex_pool_test.exs` "pool option
      forwarding": `:apply` reaching every child (allowlist proven by a
      `permission_denied` rejection), the no-`:apply` bridge-absent negative,
      and `:max_heap_mb: 64` pinned to `:heap_limit_error`. Forwarding itself
      was already correct in the working tree (HEAD dropped both keys);
      `pool.ex` still duplicates `Tyrex`'s `@runtime_opts` — residual, no task.
      Remaining: `Logger.warning`, `apply: []`, `stop/1` escalation,
      multi-caller `fail_inflight/2`.

**Verify:** `TYREX_BUILD=true mix test`. For 4.1, 4.2 and 4.3, confirm each new assertion **fails** when the corresponding production line is reverted — a test that has never been seen red is not evidence.

*Done.* Full suite: **160 passed**, `mix format --check-formatted` clean, `mix compile --warnings-as-errors` clean. Each of the three assertions was seen red, then the revert was restored from a byte-identical backup and re-run green (`diff -q` verified):

| Task | Revert applied | Observed red |
|---|---|---|
| 4.1 | `worker.rs`: dropped `handle.terminate_execution()` from the near-heap-limit closure **and** made the 8MB grant unconditional (the pre-2.6 ratchet) | `right: %Tyrex.Error{name: :timeout, message: "evaluation exceeded its deadline..."}` — exactly the value the old `assert name in [:heap_limit_error, :timeout]` accepted |
| 4.2 | `lib/tyrex.ex`: dropped `cancel_timer(timer)` from the `{:eval_reply, ...}` clause | `Unexpectedly received message {:trace, #PID<...>, :receive, {:deadline, ...}}` inside the 600ms window |
| 4.3 | `lib/tyrex.ex`: dropped `Native.terminate_runtime/1` from `terminate/2`, **and** `runtime.rs`: dropped `terminate_execution()` from `Runtime::drop` | `CPU did not return to baseline after stop/1 (baseline 0.005, running 3.02, after 3.0025, ceiling 0.5)` |

Two things the red runs established that reading could not:

- **4.3 needed *both* terminate paths disabled.** Removing `Native.terminate_runtime/1` from `terminate/2` alone left the test **green**: the `%Runtime{}` struct dies with the GenServer, the `ResourceArc` refcount hits zero promptly, and `Runtime::drop` terminates the isolate anyway. So the probe defends the *property*, not a line — and the two paths are genuine defence in depth rather than duplication. Worth knowing before anyone "simplifies" one of them away.
- **The measured leak is ~1.0 core per runtime** (3 runaways → 3.02). The old bound `after_stop < baseline + 1.0` therefore sat exactly on the single-leak signal; the new absolute ceiling of 0.5 fails on one leaked thread, which is what W9 asked for.

---

## Completeness check

All 23 review findings are mapped. None dropped.

| Review finding | Severity | Task |
|---|---|---|
| B1 `import()` bypasses read permissions | BLOCKER | 1.1 |
| B1 false-positive `deny_import` test | BLOCKER | 1.2 |
| B2 `Arc<HeapLimitState>` use-after-free | BLOCKER | 1.3 |
| B3 `RUSTLER_NIF_VERSION` inert, 2.15 as 2.16 | BLOCKER | 3.1 |
| B4 stale checksum file | BLOCKER | 3.2 |
| B5 guest-writable `_runtimeId` | BLOCKER | 1.4 |
| W1 `false` (deny all) inverted for `deny_*` | WARNING | 1.5 |
| W2 heap cap unprotected during bootstrap | WARNING | 1.6 |
| W3 `timeout: :infinity` disables the deadline | WARNING | 2.1 |
| W4 `timeout: -1` crashes runtime + siblings | WARNING | 2.2 |
| W5 `terminate/2` / `blocking_eval` skip drain | WARNING | 2.3 |
| W6 `:noproc` contradicts `@spec` | WARNING | 2.4 |
| W7 heap test accepts `:timeout` | WARNING | 4.1 |
| W8 stale-timer test unobservable | WARNING | 4.2 |
| W9 CPU probe scaling + `ps` resolution | WARNING | 4.3 |
| W10 `serde_v8` unwrap panics unguarded | WARNING | 1.7 |
| W11 tag vs `mix.exs` unasserted | WARNING | 3.3 |
| W12 `Cross.toml` without Dockerfile | WARNING | 3.4 |
| S1 non-boolean `allow_all` silently false | SUGGESTION | 2.5 |
| S2 heap slack ratchets | SUGGESTION | 2.6 |
| S3 `kill/1` tautological asserts | SUGGESTION | 4.4 |
| S4 bare `%Tyrex.Error{}` asserts | SUGGESTION | 4.5 |
| S5 untested paths | SUGGESTION | 4.6 |
| S6 false deno-deferral clause | SUGGESTION | 3.5 |

Still deferred from the original plan, unchanged: **perf** (global `Mutex<Slab>`,
apply-reply triple encode, no snapshot, unbounded mpsc, per-call atom interning),
**bindings** (the 19-minor deno lockstep bump), **arch** (pool strategy-state
lifecycle, `Tyrex` god module), **test-hygiene**, **CI** (clippy, Rust tests,
credo, dialyzer, unpinned actions).

## Risks

- **1.1 is the only task with real design risk.** The main-module exemption is
  the crux: too broad and the check is decorative, too narrow and
  `main_module_path` stops working under `permissions: :none`. Write the
  "main module still loads under `:none`" test before the enforcement test.
- **1.3 changes the heap-limit mechanism wholesale.** The current implementation
  demonstrably works (verified: `:heap_limit_error` with the BEAM alive); the
  replacement must be re-verified against the same probe, not assumed
  equivalent because it compiles.
- **1.4 touches the extension's JS.** `Tyrex._runtimeId` is currently set by a
  bootstrap `execute_script` that *also* deletes the global when the bridge is
  off. Removing the id half must not disturb the delete half — that delete is
  the whole of v0.4.0 task 1.1.
- **Phase 3 cannot be fully verified locally.** 3.1's effect on the built
  artifact is checkable; 3.2 and 3.3 only really prove themselves on a tag.
  Dry-run what can be dry-run and accept the residue.

### Self-check

- *What would make this plan wrong?* If Option B is chosen for B1, tasks 1.1 and
  1.2 change shape entirely — 1.1 becomes a deletion in `encode_permissions/1`
  plus a README rewrite, and 1.2 becomes deleting the test rather than fixing
  it. Make the decision before starting, not during.
- *What is most likely to be skipped under pressure?* 4.3, again — it was the
  v0.4.0 plan's answer to the same question, and the finding is that it shipped
  in a form that cannot fail on a 1-vCPU runner. Second most likely: the
  "confirm it fails when reverted" step in Phase 4's verify block, which is the
  only thing separating these tasks from the ones they are fixing.
- *What did the review not look at?* The `examples/` and `bench/` trees, still
  unexamined after two passes, and now stale: they call `Tyrex.start()` with no
  `:permissions` and several use `Tyrex.apply`, so they are broken by v0.4.0's
  defaults. No task covers them because no reviewer read them — worth a
  Phase 5 or a separate pass.
