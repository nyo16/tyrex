# Requirements Coverage Review — v0.4.0 sandbox integrity

**Verdict:** PASS WITH WARNINGS
**Scope reviewed:** `.claude/plans/sandbox-integrity-fixes/plan.md` (all ticked checkboxes + 4 phase Verify blocks + Decision block + Risks + Self-check) cross-checked against `git diff master` (24 files, +3109/-359) at `f134c25`.
**How verified:** `git diff master --stat`, per-file `git diff master -- <path>`; direct reads of `native/tyrex/src/worker.rs`, `lib.rs`, `runtime.rs`, `extension/main.js`, `Cargo.toml`, `lib/tyrex.ex`, `lib/tyrex/{pool,native,error}.ex`, `mix.exs`, `.github/workflows/release.yml`, `README.md`, `CHANGELOG.md`, all five test files; crate sources `deno_permissions-0.97.0/lib.rs:3908-3948` (`check_specifier`) and `deno_core-0.391.0/modules/map.rs:1280-1305` (`load_dynamic_import`) + `modules/loaders.rs:69-148` (`ModuleLoader` trait surface); one standalone Elixir probe (`/tmp/exit_probe.exs`) to settle the exit-reason question in 2.4.

---

## Requirements Coverage

**Tasks: 23 MET, 1 PARTIAL, 0 UNMET, 0 UNCLEAR**
**Prior findings: 22 MET, 1 PARTIAL, 0 UNMET, 0 UNCLEAR**
**Phase Verify blocks: 4 MET (one with accepted residue)**

> **Count discrepancy.** The assignment says "26 tasks". `grep -c '^- \[x\] \*\*' plan.md` = **24**; `grep -c '^- \[ \]'` = 0. The plan has 24 task checkboxes across four phases (7/6/5/6). The tallies above are over those 24. The four phase **Verify** blocks and the **Decision required before task 1.1** block are assessed separately below; 24 + 4 verify blocks would be 28, 24 + the Decision + the Self-check would be 26 — either way the "26" in the brief does not match the file. No task is missing; the arithmetic is.

### Phase 1 — 7 MET

| Task | Status | Evidence |
|---|---|---|
| 1.1 Module loading respects read permissions | **MET** | `native/tyrex/src/worker.rs:64-156` — `PermissionedModuleLoader{inner: FsModuleLoader, permissions}`; `check_dynamic` calls `PermissionsContainer::check_specifier(spec, CheckSpecifierKind::Dynamic)` (`worker.rs:92-102`), enforced in `resolve` (`:114-127`) and `load` (`:144-153`); wired at `worker.rs:413-416`. See divergence analysis below. |
| 1.2 Replace the false-positive `deny_import` test | **MET** | `test/tyrex_permissions_test.exs:159-273` — six tests: `file:` denial under `:none` with `"Requires read access"` + filename (`:169-188`), `type: "json"` denial (`:190-205`), same file allowed under `allow_read: [dir]` (`:207-219`), main module + static `dep.js` under `:none` returning 42 (`:221-242`), guest `import()` of the main module's own path denied (`:244-256`), `deny_import: true` blocking `https:` with `"Requires import access"` + `deno.land` (`:258-272`). Message read inside the isolate via `import_message/2` (`:519-534`). The old `https:`-only false positive is gone. |
| 1.3 Remove the unsafe heap-limit callback | **MET** | `grep` over `native/tyrex/src/` finds no `HeapLimitState`, no `Arc::as_ptr`, no `unsafe`. `Worker` now holds `heap_limit_tripped: Option<Arc<AtomicBool>>` (`worker.rs:378`). Closure via `add_near_heap_limit_callback` at `worker.rs:458-477`. **Both plan-mandated deletions confirmed:** no "field order is load-bearing" comment survives anywhere in the crate, and `run`'s destructure (`worker.rs:576-580`) ends with no explicit `drop(worker); drop(heap_limit_state);` — a repo-wide grep for `drop(` finds only `impl Drop for Runtime` in `runtime.rs:18`. |
| 1.4 Runtime id out of guest reach | **MET** | `RuntimeId(usize)` newtype `worker.rs:24`; `options = { runtime_id: usize }` + `state.put(RuntimeId(...))` `worker.rs:59-62`; `op_apply(state: &mut OpState, ...)` reads `state.borrow::<RuntimeId>().0` (`worker.rs:26-34`), no `#[string] runtime_id`. `grep parse::<usize>` → **no matches**. `extension/main.js`: `_runtimeId: null` field and the `op_apply` first argument both deleted. **`delete globalThis.Tyrex` survived** — `worker.rs:486-495`, guarded by `if !apply_enabled`, with the bridge-on `execute_script` gone. Pinned by `test/tyrex_permissions_test.exs:277-283` and `test/tyrex_pool_test.exs:188-199`. |
| 1.5 Fix the inverted `false` (deny all) docs | **MET** | `grep 'deny all'` over `README.md` + `lib/tyrex.ex` → **no matches**. `README.md:189-201` splits by direction and ends "an empty list allows nothing but denies nothing, and `false` is the absence of a rule in whichever direction the key names". `lib/tyrex.ex:158-169` spells out `allow_x`/`deny_x` × `true`/`false`/`[]`, naming `deny_read: false` as the reproduced case. CHANGELOG entry at `CHANGELOG.md:127-131`. |
| 1.6 Measured `:max_heap_mb` floor | **MET** (narrowed; see note) | `lib/tyrex.ex:87-88` `@min_heap_mb 32` / `@measured_min_heap_mb 14`, with the measurement in the comment `:77-86`. `validate_max_heap_mb!/1` at `:813-832` requires `is_integer(mb) and mb >= @min_heap_mb`. Message names **both** numbers ("at least 32 megabytes", "14 MB was the smallest cap that booted reliably", "the enforced floor is 32") and retains "positive integer" so `test/tyrex_lifecycle_test.exs:214-218`'s `~r/positive integer/` still matches. Documented at `README.md:399-405` and `lib/tyrex.ex:139-144` and `README.md:661`; CHANGELOG `:100-107`. |
| 1.7 Contain panics on the worker thread | **MET** | `native/tyrex/src/lib.rs:66-119` — `catch_unwind(AssertUnwindSafe(|| tokio_rt.block_on(...)))`, panic arm calls `runtimes::lock_or_recover().try_remove(runtime_id)` and, gated on the `Cell<bool>` `startup_reported` (`:50`), sends `{:error, _}` so `init/1` does not sit out its 30s `:startup_timeout`. `panic_reason/1` at `:122-130`. Both oneshot `RecvError` arms now report `dead_runtime_error` (`lib.rs:177-182` and the `eval_blocking` arm). `Cargo.toml` sets no `panic = "abort"` profile, so `catch_unwind` is live. |

**1.6 narrowing (not a defect, recorded for the ledger):** the task is tagged `[rust] [elixir] [docs]` and the inline note says "Elixir half only." No floor is enforced in Rust — `Tyrex.Native.start_runtime/5` accepts any `max_heap_mb`, and `test/tyrex_permissions_test.exs:453-486` calls it directly. `lib/tyrex/native.ex:1` is `@moduledoc false`, so there is no public route past `validate_max_heap_mb!/1`, and W2's stated ask ("enforce a floor with a message naming the measured minimum, and document it") is fully satisfied. Counted MET.

### Phase 2 — 5 MET, 1 PARTIAL

| Task | Status | Evidence |
|---|---|---|
| 2.1 `timeout: :infinity` decision | **MET** | **Refused on both paths** (the plan's recommended branch). `lib/tyrex.ex:386-392` — `eval/2` returns `{:error, unsupported_option(:without_deadline)}` before any `GenServer.call`; the server-side guard is the **first** `cond` clause at `:481-485`. `unsupported_option(:without_deadline)` at `:674-683` is path-neutral, covering both the uncapped OS thread and the parked dirty-IO scheduler. Dead code confirmed gone: `call_timeout/1` (`:607`), `arm_deadline/3` (`:640-643`) and `cancel_timer/1` (`:645-648`) each have exactly one clause — no `:infinity` clause, no `cancel_timer(nil)`. Docs match: `lib/tyrex.ex:356-360`, `CHANGELOG.md:49-50`. `Tyrex.Pool.eval/3` routes through `Tyrex.eval/2` (`lib/tyrex/pool.ex:110`), so the pool path is covered too. |
| 2.2 Validate `:timeout` | **MET** | `lib/tyrex.ex:618-626` — `validate_timeout!/1` runs inside `eval/2` before the call; message is exactly `":timeout must be a positive integer number of milliseconds or :infinity, got: ..."`. Covered by `test/tyrex_api_test.exs:55-72` over `[-1, 0, 5.5, nil, "5"]`, and the load-bearing assertion is the runtime staying alive and serving after each rejection. |
| 2.3 Drain in-flight callers on every terminal path | **MET** | `lib/tyrex.ex:569-584` — `terminate/2` calls `fail_inflight(state, :dead_runtime_error)` **before** `Native.terminate_runtime/1`, with the no-double-reply reasoning in the comment. `blocking_eval/3`'s three `{:stop, ...}` returns (`:587-604`) are covered transitively because `{:stop, ...}` from a handler runs `terminate/2`. Tests: `test/tyrex_api_test.exs:85-100` (plain `stop/1`) and `:101-118` (three concurrent callers — this is also 4.6's multi-caller sub-item). |
| **2.4 Map `:noproc` exits to the documented error tuple** | **PARTIAL** | Landed: `lib/tyrex.ex:393-406` catches `:exit` and routes through `dead_runtime_exit?/1` (`:634-638`), which unwraps `{reason, {GenServer, :call, _}}` and answers true for `:noproc`, `:normal`, `{:shutdown, _}`; everything else is re-raised with the original stacktrace. Tests at `test/tyrex_api_test.exs:121-149` pin both directions. **Did not land:** the bare atom `:shutdown` — the reason an in-flight caller actually gets when a *supervisor* takes the runtime down. See the PARTIAL detail below. |
| 2.5 Reject a non-boolean `allow_all` | **MET** | `native/tyrex/src/worker.rs:292-309` — `matches!(..., PermValue::True)` replaced by an exhaustive `match` whose `List(_)` arm returns `permissions_error("permission allow_all must be true or false, not a list — it is a baseline for every other key…")`. Rationale comment at `:291-296` ties back to the `PERMISSION_KEYS` principle at `:161-163`. |
| 2.6 Bound the heap-limit slack | **MET** | `native/tyrex/src/worker.rs:459-476` — `let mut granted = false;` captured by the closure; first invocation returns `current_heap_limit + HEAP_LIMIT_SLACK_BYTES` (`:384` — 8 MiB), every later invocation returns `current_heap_limit`. Total growth bounded at +8 MB, no ratchet. Reasoning for choosing one-shot over deno's `current * 2` is in the comment. |

### Phase 3 — 5 MET

| Task | Status | Evidence |
|---|---|---|
| 3.1 Build against the NIF version we advertise | **MET** | Rust: `native/tyrex/Cargo.toml:15` `rustler = { version = "=0.38.0", features = ["nif_version_2_16"] }`, with the comment naming the two label sites that must stay in step. CI: workflow `env:` renamed to `NIF_VERSION` and documented as a **label** (`release.yml:17-28`); `shared-key` uses `${{ env.NIF_VERSION }}` (`:244`); archive name derives from it (`:288`); a new guard at `:252-261` computes `FEATURE="nif_version_${NIF_VERSION//./_}"` and fails the build if it is absent from `Cargo.toml`. `scripts/docker-build.sh` no longer passes `-e RUSTLER_NIF_VERSION=2.16`. Docs: `README.md:690-693` and the rewritten `CHANGELOG.md:150-156`. `grep RUSTLER_NIF_VERSION` across `mix.exs`/`release.yml`/`docker-build.sh`/`README.md` → only the README's "has had no effect since then" sentence. |
| 3.2 Checksum-regeneration in the runbook | **MET** (mechanism, not prose, as required) | `mix.exs:93-103` — `checksums.after_release` alias plus `"hex.publish": [&assert_checksums_current!/1, "hex.publish"]`; the guard at `:110-127` `Mix.raise`s when the file lacks `-v#{@version}-nif-`. CI re-check **after** the release step at `release.yml:408-423`, with the deadlock rationale written into the comment and a message stating the archives ARE published. README `## Releasing` at `:727-757` names all four steps and why the order cannot be permuted. |
| 3.3 Assert the tag matches `mix.exs` | **MET** | `release.yml:350-353` scrapes `@version` with the same `sed`; `:360-372` fails when `github.ref_name != v${PROJECT_VERSION}`, **before** the archive-count guard at `:379-388`. `env:` propagation via `$GITHUB_ENV` is correct across steps. |
| 3.4 Stop packaging `Cross.toml` | **MET** (and within intent) | `mix.exs` `package.files` no longer lists `"native/tyrex/Cross.toml"`; `native/tyrex/Cross.toml` deleted (7 lines). `grep 'Cross\.toml'` across `mix.exs`, `release.yml`, `scripts/docker-build.sh`, `README.md` → **no matches**, so the "no comment refers to it" claim holds. Deleting the file rather than only unpackaging it satisfies 3.1's "delete whichever plumbing is left inert" and is strictly more than 3.4 asked — the only stanza referenced a Dockerfile that does not exist, and nothing invokes `cross`. |
| 3.5 Strike the false deferral clause | **MET** | `.claude/plans/sandbox-integrity/plan.md:72-75` now reads "Rationale: a 19-minor dependency bump must not ride along in a release whose whole purpose is restoring trust in the sandbox." The "touches none of the files the bump touches" clause is absent (`grep` → no match) and **the deferral itself survives**, with the deferral table intact at `:224-227`. Note: `.claude/` is untracked (`git status --porcelain .claude` → `?? .claude/`), so this edit is not part of commit `f134c25`; it is verified against the working tree. |

### Phase 4 — 6 MET

| Task | Status | Evidence |
|---|---|---|
| 4.1 Pin `:heap_limit_error` | **MET** | `test/tyrex_lifecycle_test.exs:189-212` — `name: :heap_limit_error` by **equality**, plus `Process.monitor` asserting `{:DOWN, ^ref, :process, ^pid, {:shutdown, :heap_limit_error}}` and `refute Process.alive?(pid)`. 30s timeout kept; the "raise the timeout, never widen the accepted name" rule is in the comment at `:196-201`. The `in [...]` set is gone. |
| 4.2 Make the stale-timer test able to observe | **MET** | `test/tyrex_lifecycle_test.exs:42-67` — `timeout: 300` on both fast evals, then `:erlang.trace(pid, true, [:receive])` + `refute_receive {:trace, ^pid, :receive, {:deadline, _}}, 600`, then alive **and** still serving. The comment explains why the trace is the only observable: the `{:deadline, from}` clause drops an absent `from` silently (`lib/tyrex.ex:544-548`). |
| 4.3 Scale the CPU probe / fix `ps` resolution | **MET** | `test/tyrex_lifecycle_test.exs:279-280` — `burners = min(3, System.schedulers_online())`, `burn_floor = burners * 0.6`. `idle_cpu_ceiling/0` (`:336-341`) is **absolute** (0.35 Linux / 0.5 Darwin), not `baseline + 1.0`. `process_cpu_seconds/1` dispatches on `:os.type()` (`:353-366` Linux, `:370-380` macOS). **Field arithmetic verified:** splitting on `")"` and taking the last segment puts `/proc/self/stat` field 3 at index 0, so `utime` (field 14) is index 11 and `stime` (field 15) is index 12 — which is exactly what the code reads. |
| 4.4 Give the `kill/1` tests something that can fail | **MET** | `test/tyrex_lifecycle_test.exs:86-106` — wedged case monitors first and bounds `kill/1` → `:DOWN` at 2 000 ms; `:108-122` dead-runtime case adds `refute Process.alive?(pid)` and `elapsed < 1_000`. Both comments name the tautology being replaced. |
| 4.5 Tighten the bare `%Tyrex.Error{}` assertions | **MET** | `grep '%Tyrex\.Error\{\}'` across `test/` returns exactly **one** hit — `test/tyrex_test.exs:275` ("throw string"), which is not a fail-closed permission test and is outside S4's stated scope. Every assertion in `test/tyrex_permissions_test.exs` now pins `:name` (e.g. `:47`, `:66`, `:412`, `:429`, `:501`), with `--allow-<perm>` / `NotCapable` text where the path is synchronous, and `deny_net` re-throwing `e.message` as a string (`:114-125`) so an offline runner cannot pass it. |
| 4.6 Cover the untested paths | **MET** (5/5) | Pool `:apply` + `:max_heap_mb` forwarding — `test/tyrex_pool_test.exs:161-223` (allowlist proven by a `permission_denied` rejection, bridge-absent negative, `:heap_limit_error` by equality). One-time `Logger.warning` — `test/tyrex_api_test.exs:189-212`. `apply: []` — `:177-186`. `stop/1` escalation — `:152-174`, asserting `:killed` as the DOWN reason, which is the only evidence the branch ran. Multi-caller `fail_inflight/2` — `:101-118`. |

### Phase Verify blocks

| Block | Status | Assessment |
|---|---|---|
| Phase 1 Verify (+ escape-probe re-run) | **MET** | The 8-row before/after probe table is specific, names the exact error and message text per probe, and records one result that only running produces: the guest `import()` of the main module's own path was "denied — closed by the `resolve` check after the first round showed it resolving from the module map". That mid-course correction is visible in the code (`worker.rs:105-127`) and independently confirmed in the crate: `ModuleMap::load_dynamic_import` calls `resolve` at `map.rs:1291` *before* the module-map hit at `:1295`. |
| Phase 2 Verify | **MET** | `test/tyrex_api_test.exs` exists with 11 tests. The claim that 2.4's coverage pins the *non*-laundering direction is true (`:138-149`). |
| Phase 3 Verify | **MET, residue accepted** | `package.files` and the deleted `Cross.toml` are directly checkable and check out. The `mix hex.build` tarball count (29) and the `cargo tree` output are executor-recorded and not re-run here; the `Cargo.toml` feature they attest to is verified directly. 3.2/3.3 guards only truly execute on a tag — declared and accepted in the brief. |
| **Phase 4 Verify — "seen red"** | **MET, and credible** | The evidence table is present, per-task, and specific: it names the exact production line reverted, the exact failing output (`right: %Tyrex.Error{name: :timeout, ...}`; `Unexpectedly received message {:trace, ...}`; `baseline 0.005, running 3.02, after 3.0025, ceiling 0.5`), and records restoration from a byte-identical backup verified with `diff -q`. Two independent credibility markers: (a) the 4.3 numbers are internally consistent with the Darwin ceiling of 0.5 that the *code* selects on this arm64 mac, and with `min(3, schedulers)` burners; (b) the recorded surprise — reverting `Native.terminate_runtime/1` from `terminate/2` alone left 4.3 **green**, because `Runtime::drop` terminates the isolate anyway — is a counter-intuitive result that reading the diff does not produce and that is corroborated by `native/tyrex/src/runtime.rs:16-32`. I judge the evidence genuine. It rests on the executor's transcript (no log artifacts committed), which is the only reason this is not stronger than MET. |

### Decision required before task 1.1

**RESOLVED — Option A (enforce), and Option A is what shipped.** Recorded in `.claude/plans/sandbox-integrity-fixes/scratchpad.md` under *Decisions*: "**Fix B1 rather than disclaim it** (pending user confirmation — see the decision block in the plan)."

Two record-keeping residues, neither affecting the delivered behaviour:
- The "(pending user confirmation)" qualifier was never struck, so the scratchpad still reads as an open decision over an implementation that is complete and tested.
- The plan's own Decision block (`plan.md:88-107`) still reads "Two honest answers; pick one and record it in the scratchpad" and was never annotated with the outcome, so a reader of the plan alone cannot tell which branch was taken without reading the task note.

---

## Does 1.1's divergence satisfy the task's intent?

**Yes, and it is strictly stronger than the plan text.** Three deltas, judged individually:

1. **`is_dynamic_import` instead of "match on the resolved main-module specifier".** The plan's mechanism would have made the main module's *specifier* the exemption key. The implementation makes deno's own static/dynamic boundary the key. This is a superset in the right direction: a specifier match exempts that URL **forever, from any caller**, so a guest `import()` of `main_module_path` would have been a read primitive over that file; the `is_dynamic_import` boundary denies it, because the guest's load is dynamic no matter what it names. That is exactly the trap the plan's own Risks section and the scratchpad's "Open question" asked to be closed, and `test/tyrex_permissions_test.exs:244-256` pins it. The plan's stated trap — `main_module_path` must keep working under `permissions: :none` — is satisfied and pinned at `:221-242`.
2. **`check_specifier` instead of `check_read`; "`check_import` exists nowhere" was wrong.** The plan's assertion was about `check_import`, and it is true that no `check_import` exists in the pinned crates. `PermissionsContainer::check_specifier` does exist (`deno_permissions-0.97.0/lib.rs:3908`) and is better than the plan's `check_read`: I read the body, and for `"file"` it routes to `inner.read.check(..., Some("import()"))` (`:3927-3936`) — the same read permission the plan asked for, with an `import()` attribution in the message — while the `_ =>` arm routes to the import permission (`:3944-3948`), which is what makes `deny_import` non-inert. `check_read` alone would have left `deny_import` inert and B1 half-closed. **The plan text was narrower than the finding; the implementation matched the finding.**
3. **Checking in both `resolve` and `load`.** Necessary and load-bearing, and both directions are genuinely needed rather than belt-and-braces: for a dynamic import of an *already-loaded* specifier, `load` is never reached (`map.rs:1291` resolves before `:1295` consults the map), so only `resolve` sees it; conversely, the *static* imports of a dynamically imported module resolve with `ResolutionKind::Import` (unchecked) but load with `options.is_dynamic_import == true` (checked). Each hook covers a case the other misses.

**Leaving `import_meta_resolve` unchecked is correct** — I confirmed against `deno_core-0.391.0/modules/loaders.rs:69-148` that the `ModuleLoader` trait's only read-performing hook is `load`, and `import_meta_resolve` returns a URL. The remaining trait methods (`prepare_load`, `finish_load`, `code_cache_ready`, `purge_and_prevent_code_cache`, `get_source_map`) take `FsModuleLoader`'s defaults and none reach the filesystem on a guest-chosen path.

---

## PARTIAL detail

### 2.4 / W6 — `dead_runtime_exit?/1` misses the bare `:shutdown` a supervisor produces

- **Where:** `lib/tyrex.ex:634-638`
- **What landed:** `:noproc`, `:normal`, `{:shutdown, _reason}` (2-tuple) are converted to `{:error, %Error{name: :dead_runtime_error}}`.
- **What did not:** the bare atom `:shutdown`. `dead_runtime_exit?({:shutdown, _reason})` matches a 2-tuple only; `:shutdown` as an atom falls to the `_reason -> false` clause and is re-raised.
- **Why it matters:** that is the reason a caller actually receives when a **supervisor** takes the runtime down, which is the dominant case under `Tyrex.Pool`'s `:rest_for_one` — the scenario W6 was written about ("every deadline, heap trip and `kill/1` opens a window where the next call exits instead of returning"). `Tyrex.Pool.eval/3` funnels through `Tyrex.eval/2` (`lib/tyrex/pool.ex:110`), so `@spec eval(...) :: {:ok, term()} | {:error, Error.t()}` (`lib/tyrex.ex:384`) still lies in exactly that window.
- **Evidence (OBSERVED, not inferred):** standalone probe, no NIF involved — a `GenServer.call` in flight when its callee is stopped by its supervisor exits with `{:shutdown, {GenServer, :call, [...]}}`, which `dead_runtime_exit?/1` unwraps to the atom `:shutdown` and rejects:

  ```
  $ elixir /tmp/exit_probe.exs
  exit reason from supervisor shutdown: {:shutdown, {GenServer, :call, [:slowsrv, :wait, 10000]}}
  ```

  The same class covers `:killed` (brutal kill / `stop/1`'s escalation branch), also unmatched.
- **Corroborating tell — the review's own tell survives.** `test/tyrex_lifecycle_test.exs:237-243` still wraps a pool call in `catch :exit, _ -> false`. The review named this workaround (at the v0.4.0 line numbers) as the signal that W6 was live. It is still there, and its comment at `:234-236` — "calls during that window exit with `:noproc` rather than returning an error tuple" — is now **factually wrong**: after 2.4, `:noproc` returns an error tuple. The `catch` is still load-bearing, but for `:shutdown`, not `:noproc`.
- **Judgement.** This is a narrowing, not a relitigation of design decision #4. That decision's stated exclusion is `GenServer.call`'s own `:timeout` — "swallowing that would hide a server-side deadline that lost its race" — and that reasoning does not extend to `:shutdown`, which carries no diagnostic value the 2-tuple form does not. Covering `{:shutdown, _}` but not `:shutdown` reads as an oversight in the clause list rather than a boundary anyone drew.
- **Direction:** add a `dead_runtime_exit?(:shutdown)` clause (and consider `:killed`), and correct the stale comment at `test/tyrex_lifecycle_test.exs:234-236`; if the `catch :exit` there can then be dropped, dropping it is the proof.

---

## Prior findings — 22 MET, 1 PARTIAL, 0 UNMET, 0 UNCLEAR

Assessed independently of task status: a task can be done while its finding survives.

| Finding | Task | Status | Evidence |
|---|---|---|---|
| B1 `import()` bypasses read permissions | 1.1 | **MET** | `worker.rs:64-156`; `deno_permissions-0.97.0/lib.rs:3908-3948` confirms `file:`→read and other schemes→import. Six tests at `test/tyrex_permissions_test.exs:159-273`. Caveat below. |
| B1 false-positive `deny_import` test | 1.2 | **MET** | Old `https:`-only assertion replaced; `:258-272` now asserts the *message* text. |
| B2 `Arc<HeapLimitState>` UAF | 1.3 | **MET** | No `unsafe`/`Arc::as_ptr`/`HeapLimitState` in the crate; `worker.rs:458-477` uses the safe API. Both compensating artefacts (comment, explicit drops) deleted. |
| B3 `RUSTLER_NIF_VERSION` inert | 3.1 | **MET** | `Cargo.toml:15` feature; CI guard `release.yml:252-261`; docs corrected `README.md:690-693`; CHANGELOG rewritten, not deleted, `:150-156`. |
| B4 stale checksum file | 3.2 | **MET** | Guard + alias `mix.exs:93-127`, CI re-check `release.yml:408-423`, runbook `README.md:727-757`. The file itself is still v0.3.0-only — accepted by design; the guards fail loudly rather than shipping it stale. |
| B5 guest-writable `_runtimeId` | 1.4 | **MET** | `OpState` `RuntimeId`; `_runtimeId` gone from JS and Rust; `parse::<usize>` gone. |
| W1 `false` (deny all) inverted | 1.5 | **MET** | No `deny all` anywhere in `README.md`/`lib/tyrex.ex`. |
| W2 heap cap unprotected in bootstrap | 1.6 | **MET** | Floor 32, measured minimum 14 named in the message, documented in three places. |
| W3 `timeout: :infinity` disables the deadline | 2.1 | **MET** | Refused at `lib/tyrex.ex:386-392` and `:481-485`; covered on the pool path via `pool.ex:110`. |
| W4 `timeout: -1` crashes runtime + siblings | 2.2 | **MET** | `validate_timeout!/1` `:618-626`; test asserts the *runtime survives*, which is the defect. |
| W5 `terminate/2` / `blocking_eval` skip drain | 2.3 | **MET** | `lib/tyrex.ex:576`; two tests including three concurrent callers. |
| **W6 `:noproc` contradicts `@spec`** | 2.4 | **PARTIAL** | `:noproc`/`:normal`/`{:shutdown, _}` closed; bare `:shutdown` (supervisor teardown — the pool case W6 was about) and `:killed` still propagate. `test/tyrex_lifecycle_test.exs:241`'s `catch :exit, _ -> false` — the review's named tell — survives. See PARTIAL detail. |
| W7 heap test accepts `:timeout` | 4.1 | **MET** | Equality + DOWN + `refute Process.alive?`. |
| W8 stale-timer test unobservable | 4.2 | **MET** | `timeout: 300` / 600 ms trace window. |
| W9 CPU probe scaling + `ps` resolution | 4.3 | **MET** | Scheduler-scaled floor, absolute ceiling, `/proc/self/stat` on Linux with correct field indices. |
| W10 `serde_v8` unwrap panics unguarded | 1.7 | **MET** | `catch_unwind` at `lib.rs:66`, slab removal + startup reply on the panic arm. The unwraps themselves remain (upstream's), which is what W10 asked for — containment, not removal. |
| W11 tag vs `mix.exs` unasserted | 3.3 | **MET** | `release.yml:360-372`, ordered before the count guard. |
| W12 `Cross.toml` without Dockerfile | 3.4 | **MET** | Unpackaged **and** deleted; no dangling references. |
| S1 non-boolean `allow_all` silently false | 2.5 | **MET** | `worker.rs:297-306` exhaustive match with an explanatory error. |
| S2 heap slack ratchets | 2.6 | **MET** | One-shot `granted` flag, `worker.rs:469-476`. |
| S3 `kill/1` tautological asserts | 4.4 | **MET** | Liveness + elapsed bounds on both tests. |
| S4 bare `%Tyrex.Error{}` asserts | 4.5 | **MET** | One bare match left repo-wide, outside S4's scope. |
| S5 untested paths | 4.6 | **MET** | All five sub-items have a named test. |
| S6 false deno-deferral clause | 3.5 | **MET** | Clause struck, deferral retained. |

**B1 caveat (not a coverage failure, flagged for the panel):** B1 as scoped — "`import()` bypasses read permissions, `deny_import` is inert" — is closed on every route I could construct through the `ModuleLoader` trait. A sibling agent is separately probing whether `op_apply` is reachable via `Deno[Deno.internal].core.ops`; that is orthogonal to B1's module-loader question (the runtime id now comes from `OpState`, so reachability alone no longer buys a cross-runtime spoof), but it does mean `test/tyrex_permissions_test.exs:314-330` ("the underlying op is not reachable even with the global deleted") checks only `Deno?.core?.ops?.op_apply` and not the `Deno[Deno.internal]` path. That test is not a deliverable of any of the 24 tasks, so it does not change a tally — but if the sibling's probe lands, the test is where the gap will show.

---

## Risks and Self-check delivery

| Promise | Status |
|---|---|
| Risk: "1.1 is the only task with real design risk… write the 'main module still loads under `:none`' test **before** the enforcement test" | **Delivered in substance.** Both tests exist (`test/tyrex_permissions_test.exs:221-242` exemption, `:169-205` enforcement). Authoring order is not recoverable from a squashed commit and is immaterial to the outcome; the exemption is pinned in both directions, including the "not a general read primitive" case the scratchpad's open question demanded. |
| Risk: "1.3 must be re-verified against the same probe, not assumed equivalent" | **Delivered.** Phase 1's probe table records `max_heap_mb: 64` + allocation loop → `:heap_limit_error`, runtime dead, BEAM alive, explicitly "unchanged after the callback rewrite"; `test/tyrex_lifecycle_test.exs:189-212` encodes it. |
| Risk: "1.4 — removing the id half must not disturb the `delete globalThis.Tyrex` half" | **Delivered.** `worker.rs:486-495` retains it; asserted by `test/tyrex_permissions_test.exs:277-283` and `test/tyrex_pool_test.exs:188-199`. |
| Risk: "Phase 3 cannot be fully verified locally" | **Accepted residue**, as declared. |
| Self-check: "make the decision before starting" | **Partially delivered** — decision made and recorded, but never de-qualified. See Decision section. |
| Self-check: "4.3 is most likely to be skipped" | **Delivered**, and it is the one with the strongest red-run evidence. |
| Self-check: "`examples/` and `bench/` are stale, worth a Phase 5" | **Not delivered** — explicitly out of scope per the review brief's accepted-residues list. Recorded, not counted. |

---

## Minor coverage gaps (no tally impact)

- `README.md:407` and `README.md:665` both say `Tyrex.Pool` forwards `:permissions`, `:max_heap_mb`, and `:main_module_path` — omitting `:apply` (and `:startup_timeout`), which `lib/tyrex/pool.ex:62-63` now forwards, `lib/tyrex/pool.ex:48` documents, `CHANGELOG.md:66` announces, and `test/tyrex_pool_test.exs:162-186` tests. Both README sentences were written in this diff, so the inconsistency is new. Task 4.6 is still MET (it required tests, not docs).
- `test/tyrex_lifecycle_test.exs:234-236` — comment now misdescribes the behaviour it explains (see PARTIAL detail).

## Pre-existing (one line each)

- `.github/workflows/release.yml:3-11` — `on.push` combines `branches`/`paths` with `tags: "*"`; a `paths` filter on a push event also gates tag pushes, so a tag touching nothing under `native/**` may not trigger the release build. Unchanged by this diff (`git show master:.github/workflows/release.yml` is byte-identical here). PRE-EXISTING.
- `scripts/docker-build.sh:69-72` — overwrites `native/tyrex/.cargo/config.toml` for the arm64 cross build, which is the same file `mix.exs:40-42` now packages for the musl `-crt-static` rustflags. PRE-EXISTING.
- `lib/tyrex/pool.ex:62-63` — hand-lists `Tyrex`'s `@runtime_opts` a second time. PRE-EXISTING and already acknowledged as an accepted residue.
