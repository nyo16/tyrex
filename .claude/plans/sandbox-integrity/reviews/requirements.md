## Requirements Coverage

**MET 18 / PARTIAL 1 / UNMET 0 / UNCLEAR 0** across the plan's 19 numbered tasks. The single PARTIAL is **1.5** (docs): the README and moduledoc rewrite is real and thorough, but the exact sentence the task names — `false` documented as "deny all" — survives verbatim at `README.md:184` and `lib/tyrex.ex:141`, and is now wrong for the eight `deny_*` keys.

*Method: read every file the tasks name, plus the consuming side of each new value that crosses a boundary. No source or test file modified; no build, format, or test run (per constraint). Line numbers are working-copy lines.*

---

### Phase 1 — Close the escape

| # | Task | Verdict | Evidence |
|---|---|---|---|
| 1.1 | Make the apply bridge opt-in | **MET** | `:apply` in `@runtime_opts` `lib/tyrex.ex:77`, documented `:124-125`; `build_apply_allowlist(false) -> nil` `:720`; `apply: true` explicitly refused `:736-737`; allowlist keyed by the exact JS strings, never atoms `:762-766`; enforcement in the GenServer before any atom conversion `:638-655`; bridge-off path `:609-614`. Flag threaded to the NIF `:381-386` → `lib/tyrex/native.ex:32-34` → `native/tyrex/src/lib.rs:17,50` → `worker.rs:377-380`. |
| 1.2 | Permission parsing must fail closed | **MET** (3/3) | breakdown below |
| 1.3 | Reject unknown permission keys | **MET** | `@permission_keys` `lib/tyrex.ex:79-97`; `validate_permission_key!/1` raises `ArgumentError` `:794-811`; value shape validated `:813-834`. Independently enforced in Rust: `PERMISSION_KEYS` `native/tyrex/src/worker.rs:62-76`, unknown-key `Err` `:182-189`. |
| 1.4 | Flip the default to deny-by-default | **MET** | `resolve_permissions/1` falls through to `:none` `lib/tyrex.ex:683-692`; one-time `Logger.warning` gated by `:persistent_term` `:694-709`; documented `:120-121`; CHANGELOG leads **Changed** with it plus the one-line migration `CHANGELOG.md:11-20`; README breaking-change callout `README.md:163-171`. |
| 1.5 | Correct the documentation | **PARTIAL** | finding R1 |
| 1.6 | Tests for each of the above | **MET** | All six named reproductions present: bridge off by default `test/tyrex_permissions_test.exs:131`; `:none` no longer leaks Elixir (`File.read!` **and** `:os.cmd`) `:139`; allowlisted MFA permitted `:174`; non-allowlisted rejected as `permission_denied` `:186`; `[allow_all: true, allow_run: false]` denies run `:247`; `allow_read: []` is not the whole FS `:259`. Plus arity-is-not-authorization `:200`, raising callee does not kill the runtime `:214`, unexported MFA refused at start `:233`, no `apply: true` `:239`, and five native-parser tests that bypass Elixir validation entirely `:288,294,300,306,312`. |

**1.2 — the three fixes, verified independently**

1. *Malformed JSON / non-object shape must `Err`.* `serde_json::from_str(...).map_err(...)?` `native/tyrex/src/worker.rs:163-164`; unknown preset string `Err` `:168-173`; non-object shape `Err` `:176-180`. The old fallback is gone — `PermissionsContainer::allow_all` is now reachable **only** from the literal string `"allow_all"` `:166`. Tests `test/tyrex_permissions_test.exs:288,294,300`.
2. *`allow_X: false` denies under `allow_all: true`.* The `allow` closure consults `obj.get(key)` first and falls back to the `allow_all` baseline only when the key is **absent** `native/tyrex/src/worker.rs:200-206`; `PermValue::False -> None` `:130`. The `.or_else(allow_default)` swallow that caused the inversion no longer exists. Test `test/tyrex_permissions_test.exs:247-257`.
3. *"Empty allowlist" ≠ "unrestricted".* `allow_option` maps an empty `List` to `None` (grants nothing); only `PermValue::True` maps to `Some(vec![])` `native/tyrex/src/worker.rs:127-133`. The mirrored `deny_option` `:141-147` keeps the opposite polarity correct, so `deny_x: []` denies nothing rather than everything — the failure mode a naive shared helper would have introduced. Test `test/tyrex_permissions_test.exs:259-265`.

### Phase 2 — Make the kill real

| # | Task | Verdict | Evidence |
|---|---|---|---|
| 2.1 | `IsolateHandle` on the runtime resource | **MET** | Field + rationale `native/tyrex/src/runtime.rs:5-11`; captured inside `worker::new` `native/tyrex/src/worker.rs:355` and carried out on `Worker` `:262-266`; cloned into the `ResourceArc` **before** it is sent to Elixir `native/tyrex/src/lib.rs:56-68`. |
| 2.2 | `terminate_runtime/1` NIF | **MET** | Plain (non-dirty) NIF with the thread-safety and one-way-door rationale `native/tyrex/src/lib.rs:83-102`; it also sends `Stop` so the worker loop actually winds down `:96-100`. `@spec` on **all five** stubs: `lib/tyrex/native.ex:32,47,55,64,73`. |
| 2.3 | Recover-vs-teardown decided and pinned | **MET** | Decision made explicitly and documented in both languages: teardown, no `cancel_terminate_execution` `native/tyrex/src/worker.rs:428-438`, `native/tyrex/src/lib.rs:89-94`, `lib/tyrex.ex:53-57`, `CHANGELOG.md:42-44`. Enforced on every termination path — the loop breaks and drains pending promises `worker.rs:525-527,598-600,611-613,618-620`. **A test pins the contract rather than merely exercising it**: `test/tyrex_lifecycle_test.exs:30-39` traps exits and asserts `{:EXIT, ^pid, {:shutdown, :timeout}}` plus `refute Process.alive?(pid)`; a "recover and keep serving" implementation fails it. The sticky-flag caveat in the `_Done:_` note is real code, not narrative: `HeapLimitState.tripped` `worker.rs:250-255` is read before `is_execution_terminating` `:444-467`. |
| 2.4 | In-flight map + per-request deadline | **MET** | `inflight` on the state struct `lib/tyrex/runtime.ex:33,36`; armed per request, keyed by `from` `lib/tyrex.ex:419,535-542`; the timer carries that key `:540`, so `handle_info({:deadline, from}, ...)` **attributes** expiry to one caller, terminates the isolate, and replies to that caller only `:477-499`; the success path pops the same key and cancels the timer `:455-475`; `:absent` guards a stale/raced timer `:457,479`; remaining callers are failed with a distinct reason via `fail_inflight/2` `:551-563`. Server-wins-the-race grace `:72-75,532-533`. Tests: deadline attributed and beats the call timeout `test/tyrex_lifecycle_test.exs:16`; a stale timer does not kill a healthy runtime `:42`. |
| 2.5 | Fix `blocking: true` | **MET** | `tokio::time::timeout` replaces `blocking_recv` `native/tyrex/src/lib.rs:164-176`; on expiry it terminates the isolate **and** sends `Stop` so the thread is reclaimed `:186-199`; `schedule = "DirtyIo"` with rationale `:139-144`; refused when the bridge is on `lib/tyrex.ex:421-422,565-573` and when `:timeout` is `:infinity` `:424-425,575-582`. Tests `test/tyrex_lifecycle_test.exs:110,130,139,147` — including that the runtime is still usable after a refusal, which is what the old deadlock destroyed. |
| 2.6 | Bound `stop/1`'s default timeout | **MET** | `@default_stop_timeout 5_000` `lib/tyrex.ex:70`, applied `:212`; escalation on exit `:215-224`. `terminate_runtime` is reached on the graceful path through `terminate/2` `:502-510` and on the brutal path through the resource `Drop`, which terminates **before** sending `Stop` — the ordering that actually reclaims a runaway `native/tyrex/src/runtime.rs:23-31`. Test `test/tyrex_lifecycle_test.exs:93-107`. |
| 2.7 | V8 heap limit | **MET** | `:max_heap_mb` validated `lib/tyrex.ex:711-718`, documented `:126-127`, forwarded `:381-387`; `CreateParams::heap_limits` `native/tyrex/src/worker.rs:321-324,352`; near-heap-limit callback sets the sticky flag, terminates, and returns `+8MB` slack so V8 unwinds instead of `abort()`ing the BEAM `:271,281-297,361-371`; surfaced as `:heap_limit_error` `:447-452`, atom added `native/tyrex/src/atoms.rs`. Drop ordering documented **and** enforced explicitly `worker.rs:258-266,626-628`. Consuming side handled: `:heap_limit_error` is matched in `handle_info({:eval_reply, ...})` `lib/tyrex.ex:465-467` and in `blocking_eval/3` `:517-521`, and documented `lib/tyrex/error.ex`. Tests `test/tyrex_lifecycle_test.exs:156,170`. |
| 2.8 | Regression tests for the kill | **MET** (5/5) | (a) `for(;;){}` → `{:error, :timeout}` inside the deadline `test/tyrex_lifecycle_test.exs:16-28`; (b) deterministically dead afterwards `:30-39`; (c) **CPU returns to baseline after `stop/1`** — the audit's 3-runaway probe with `ps -o time=` sampling `:214-245,263-278`; (d) runtime death + pool recovery, asserting both children are rebuilt `:177-201`; (e) `:dead_runtime_error` delivered to an in-flight caller `:55-67`. |

### Phase 3 — Release integrity

| # | Task | Verdict | Evidence |
|---|---|---|---|
| 3.1 | Ship `native/tyrex/.cargo/config.toml` | **MET** | Listed in `package.files` with rationale `mix.exs:38-41`; the file exists and carries the musl rustflags (`native/tyrex/.cargo/config.toml:3-10`, `-C target-feature=-crt-static`) for both musl targets. Listed as an explicit path, so Hex's dotfile globbing is not relied on. |
| 3.2 | Set `RUSTLER_NIF_VERSION` in `release.yml` | **MET** | Workflow-level `env:` as the single source of truth `.github/workflows/release.yml:16-23`; derived into the cargo build `:243-250`, the archive name `:277`, and the cache key `:239`. The one remaining literal is the job `name:` `:129-132`, with a correct reason (GH Actions does not expose the `env` context in `name:`). The value `2.16` agrees with `scripts/docker-build.sh:123`, `native/tyrex/Cross.toml:3`, and `nif_versions: ["2.16"]` `lib/tyrex/native.ex:10`, so the three build paths no longer disagree. |
| 3.3 | Publishing all-or-nothing | **MET** | Per-leg publishing deleted; `build_nif` now has `contents: read` and no release step `.github/workflows/release.yml:141-146`. New `publish` job `needs: [build_nif]` with **no** `always()` `:324-327`, so any failed matrix leg skips it despite `fail-fast: false`. Second guard: an explicit 4-archive count check that exits non-zero `:344-351`. The residual `if: always()` on `build_nif` `:133-138` only lets the Linux legs reach a guard step that itself `exit 1`s `:158-165`, so the job still reports failure and `publish` is still skipped — the comment at `:134-137` states exactly this and matches the code. |
| 3.4 | Align the rustler pair | **MET** | `{:rustler, "~> 0.38.0", optional: true}` `mix.exs:83`, resolved to `0.38.0` in `mix.lock:12`; crate pinned `rustler = "=0.38.0"` `native/tyrex/Cargo.toml:8` with the anti-drift rationale inline. |
| 3.5 | CHANGELOG + version bump | **MET** | `@version "0.4.0"` `mix.exs:4`, crate `version = "0.4.0"` `native/tyrex/Cargo.toml:32`; `CHANGELOG.md:3-73` keeps the Added/Changed/Fixed structure and **Changed** leads with the two breaking items `:11-34`. See R2 for a release-readiness issue adjacent to this task. |

---

## Findings

### R1 — WARNING — 1.5 leaves the exact sentence it was written to fix, now inverted for `deny_*`

Task 1.5 names two artefacts. The first is fully done, and done well: `README.md:280-296` states plainly that this is not an audited sandbox boundary and points at out-of-process Deno; `README.md:249-266` reproduces the v0.3.x escape verbatim; the moduledoc carries an explicit `.warning` admonition that `:permissions` never governed Elixir reachability `lib/tyrex.ex:38-45`. The only surviving occurrence of "untrusted" in the README is inside its own negation `:284`.

The second is not done. `README.md:184` and `lib/tyrex.ex:141` both still read:

> Each permission key accepts `true` (allow all), `false` (deny all), or a list of specific allowed values

After 1.2 that is true for the eight `allow_*` keys and **inverted for the eight `deny_*` keys**: `deny_run: true` denies all subprocesses (`deny_option(True) -> Some(vec![])`, `native/tyrex/src/worker.rs:143`) and `deny_run: false` denies nothing `:144`. The Rust side documents the distinction explicitly — "the same literal means opposite things for `allow_*` and `deny_*`" `worker.rs:90-92`, and again at `:139-140` — so the implementation knows the polarity and the user-facing docs assert the opposite of it. A reader following `README.md:184` writes `deny_run: false` expecting "deny all subprocesses" and gets a runtime that denies nothing; under `allow_all: true` that is a live permission hole reached purely by following the documentation. Both copies need the split: for `allow_*`, `true` grants everything and `false` grants nothing; for `deny_*`, `true` denies everything and `false` denies nothing. The key table `README.md:209-220` lists the pairs but does not state polarity either, and `lib/tyrex.ex:144-151` inherits the same ambiguity. Note the release ships a `Fail-Closed Parsing` section `README.md:222-235` that correctly describes three of the four polarity fixes but not this one.

### R2 — WARNING — `checksum-Elixir.Tyrex.Native.exs` is still a v0.3.0 file and is inside `package.files`

`mix.exs:4` is now `0.4.0`, but `checksum-Elixir.Tyrex.Native.exs:2-5` lists only `libtyrex-v0.3.0-nif-2.16-*.tar.gz`, and that file is shipped in the package `mix.exs:35`. `RustlerPrecompiled` resolves a downloaded artefact by its exact `v{version}` filename, so publishing 0.4.0 against this file makes every precompiled install fail — which is also why `TYREX_BUILD=true` is currently required locally. Nothing regenerates it: the new `publish` job only uploads archives `.github/workflows/release.yml:353-356`, and the Phase 3 verify step ("`mix hex.build` succeeds and the tarball contains `.cargo/config.toml`") does not exercise the checksum path. Not a defect inside any single task, but it sits on the 3.3/3.5 seam and is the thing that will actually break the 0.4.0 release; the manual `mix rustler_precompiled.download --all --print` step deserves to be written into the plan's Phase 3 verify block.

### R3 — SUGGESTION — the deno-bump deferral rationale is now false

`plan.md` §"Scope decision" justifies deferring the 19-minor deno bump with: *"the Phase 1–3 work touches none of the files the bump touches."* That was true when written and is not true now. `native/tyrex/src/worker.rs` changed across 418 lines — the permission parser, `worker::new`'s `WorkerServiceOptions`/`WorkerOptions` construction, `create_params`, `MainWorker` termination handling, and the `poll_event_loop` body — and `native/tyrex/Cargo.toml` and `Cargo.lock` were both edited. Those are precisely the files a `deno_core`/`deno_runtime` bump touches, so the bindings follow-up will now rebase onto a substantially rewritten `worker.rs` rather than the one it was scoped against. **I agree this should be flagged.** The deferral decision itself remains correct — the other reason given in the same paragraph, that a large dependency bump must not ride along in a trust-restoring release, stands on its own — so the fix is to strike the "touches none of the files" clause rather than to reopen the deferral.

### R4 — SUGGESTION — the CPU-baseline assertion is coarser than its own docstring

`test/tyrex_lifecycle_test.exs:241-244` asserts `after_stop < baseline + 1.0`, and the helper docstring at `:262` says "a leaked runaway shows up as ~1.0 per runaway". A **single** leaked thread therefore lands exactly on the boundary and may not fail the test; only a 2-or-3-thread leak is caught reliably. The setup assertion `:230-232` carries the same 1.0 slack against three runaways. The plan's own self-check names this assertion as the one most likely to be skipped under pressure — it was not skipped, which is the important part; only the margin is loose. Tightening `after_stop` to roughly `baseline + 0.5` would catch a partial regression while still tolerating GC noise. One related note: `test/tyrex_strategy_test.exs:2` is the only `async: true` file, so it can run concurrently with this measurement; it is pure strategy arithmetic, so the pollution is small, but it is the sole source of cross-file noise in the probe.

---

## Completeness-check table audit

Every row mapped to a task in this plan is genuinely implemented, including the four that are easiest to mark done and leave hollow:

- *`{:ok, {}} = apply_reply` MatchError → 1.1*: fixed at `lib/tyrex.ex:442-451`, which now matches `{:ok, _}` and handles `{:error, %Error{}}` by stopping with `{:shutdown, :dead_runtime_error}` and failing in-flight callers, instead of raising a `MatchError`.
- *No in-flight request map → 2.4*: implemented as tabled above, keyed by `from`, not global.
- *No `@spec` on NIF stubs → 2.2*: all five carry one, and the arities match the Rust signatures (`start_runtime/5` after the two new arguments).
- *Eval timeout / crash-recovery / `:dead_runtime_error` untested → 1.6, 2.8*: all three now covered.

Nothing mapped to a task in this plan was silently deferred.

The deferred rows are genuinely untouched, with **one exception**:

- **`:dead_runtime_error` contract (stop-without-reply) | MEDIUM | Deferred → arch plan** — this was in fact *fixed here*. `blocking_eval/3` now replies before stopping, with a comment naming the defect exactly: "Reply before stopping. Stopping without a reply left the caller blocked until its own call timeout, then exiting" `lib/tyrex.ex:519-521`. `fail_inflight/2` `:551-563` extends the same guarantee to every other in-flight caller, and `drain_pending_promises` `native/tyrex/src/worker.rs:414-424` does it on the Rust side. This is a table inaccuracy in the safe direction — work done, recorded as deferred — but the arch plan will be sized against a row that no longer exists, so the disposition should move to 2.4/2.8.

Spot-checked as genuinely untouched (deferral intact): `native/tyrex/src/runtimes.rs` global `Mutex<Slab>` is not in `git status` at all; the apply-reply triple `serde_json::to_string` + `execute_script` remains `worker.rs:493-521` (only panic-safety was added, not the perf shape); `v8_code_cache: Default::default()` `worker.rs:344` and still no snapshot; `unbounded_channel` `native/tyrex/src/lib.rs:24`; per-call atom interning in pool dispatch `lib/tyrex/pool.ex:110`; pool strategy state in `:persistent_term` `pool.ex:106-107`; `deno_core = "0.391.0"` and the rest of the deno stack unchanged `native/tyrex/Cargo.toml:2-5`; 4 of 6 test files still `async: false`; third-party actions still tag-pinned rather than SHA-pinned (`dtolnay/rust-toolchain@stable` `release.yml:64,173`, `Swatinem/rust-cache@v2` `:236`, `softprops/action-gh-release@v2` `:354`); no clippy/credo/dialyzer step added.

## Pre-existing (unchanged code, out of scope)

- `lib/tyrex.ex:50` — moduledoc refers to "the run/eval API"; there is no `Tyrex.run/1,2` anywhere under `lib/`. Cosmetic.
- `native/tyrex/src/worker.rs:191-194` — `allow_all: ["something"]` parses without error and is treated as `false`. It fails closed, so it is harmless, but it is silently ignored where an unknown *key* is rejected loudly.

## Verification sufficiency (challenged, as asked)

The escape script plus 141 passing tests cover every vector the plan enumerates, and the Phase 1 coverage is stronger than the plan asked for (the five native-parser tests exercise the Rust parser directly, so a future regression that only removes the Elixir guard is still caught). Three things the existing evidence does **not** establish:

1. **The packaged artefact was never installed.** `mix hex.build` containing `.cargo/config.toml` proves 3.1; it does not prove a consumer can `mix deps.get` v0.4.0 and load a NIF — which R2 says they currently cannot.
2. **The `publish` job has never executed.** Phase 3's own verify line says "dry-run the release workflow", but the `paths:` filter `release.yml:12-14` means a PR touching only `release.yml` runs `build_v8`/`build_nif` while `publish` is gated on `startsWith(github.ref, 'refs/tags/')` `:327` and cannot run on a PR at all. The 4-archive guard `:344-351` will first execute on the real v0.4.0 tag.
3. **The heap-cap test does not distinguish its own outcomes.** `test/tyrex_lifecycle_test.exs:167-168` accepts `name in [:heap_limit_error, :timeout]`, so it passes if the isolate merely times out and the sticky-flag path at `worker.rs:444-452` never runs. The escape-script evidence cited in the release notes ("64MB cap yielded `:heap_limit_error` with the BEAM alive") is the only thing pinning the `:heap_limit_error` attribution, and that is a one-off manual run rather than a regression test.
