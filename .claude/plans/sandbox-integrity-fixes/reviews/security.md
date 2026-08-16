# Sandbox Security Review — v0.4.0 sandbox integrity

> **Delivery note:** I have no write tool in this session (read/grep/glob/hub/yield only), so I could not create `.claude/plans/sandbox-integrity-fixes/reviews/security.md`. This document *is* the deliverable verbatim — please persist it at that path from `agent://SandboxSecurity`.

**Verdict:** REQUIRES CHANGES

**Scope reviewed:** `native/tyrex/src/worker.rs` (`PermissionedModuleLoader`, `op_apply`, `RuntimeId`, `build_permissions`/`parse_perm_value`/`allow_option`/`deny_option`, `worker::new`, `run`), `native/tyrex/extension/main.js`, `native/tyrex/src/lib.rs` (panic containment), `native/tyrex/src/runtimes.rs`, `native/tyrex/Cargo.toml`, the `:apply` authorization path in `lib/tyrex.ex` (`authorize_and_apply/4`, `authorize/4`, `invoke/3`, `decode_args/1`, `build_apply_allowlist/1`, `allowlist_entry!/1`, `js_module_name/1`, `encode_permissions/1`, `validate_permission_key!/1`, `validate_permission_value!/2`), plus the sandbox claims in `README.md` and `Tyrex`'s `@moduledoc`/`@doc`.

**How verified:** Read the pinned crate sources at `~/.asdf/installs/rust/1.57.0/registry/src/index.crates.io-1949cf8c6b5b557f/` — `deno_core-0.391.0` (`modules/map.rs`, `modules/recursive_load.rs`, `modules/loaders.rs`, `ops_builtin.rs`, `runtime/bindings.rs`, `runtime/jsrealm.rs`, `01_core.js`), `deno_runtime-0.246.0` (`worker.rs`, `ops/worker_host.rs`, `js/99_main.js`, `js/98_global_scope_shared.js`, `js/11_workers.js`), `deno_permissions-0.97.0/lib.rs`, `deno_napi-0.169.0/lib.rs`, `deno_node-0.176.0` (`ops/require.rs`, `polyfills/01_require.js`), `deno_io-0.148.0`. Four live probes were run against the real arm64 build by `Main` on my behalf (my own hub-launched BEAM is x86_64 and cannot dlopen the arm64 `.so`); their verbatim output is quoted inline. I ran no builds and modified no files.

---

## Blockers

### Two lines of guest JavaScript abort the whole BEAM under `permissions: :none`

- **Where:** `native/tyrex/src/worker.rs:440-444` (`WorkerOptions { extensions, create_params, ..Default::default() }`)
- **What:** `WorkerOptions::default()` supplies `create_web_worker_cb: Arc::new(|_| unimplemented!("web workers are not supported"))` (`deno_runtime-0.246.0/worker.rs:264-269`). The `Worker` constructor is a live guest global (`deno_runtime/js/98_global_scope_shared.js:109`, installed on `globalThis` at `js/99_main.js:477`). `op_create_worker` performs **no permission check on the specifier** — it clones the parent `PermissionsContainer` and spawns a thread (`ops/worker_host.rs:189-230`). Classic workers are refused early (`:176-180`), so `{type: "module"}` is required; with it, the spawned thread hits `unimplemented!()` before `handle_sender.send(...)`, the sender drops, and the *op* thread — tyrex's worker thread, inside a V8 callback — executes `handle_receiver.recv().unwrap()` (`ops/worker_host.rs:284`) and panics. The panic crosses an `extern "C"` boundary, so it is converted to `panic_cannot_unwind` and **aborts the process unconditionally**.
- **Why it matters:** This is a deterministic, instant, whole-OS-process kill from the *most restrictive* permission set tyrex offers, with `apply: false`. No permission governs it. It is strictly worse than B1, which only leaked reads, and it renders the `:max_heap_mb` floor (`lib/tyrex.ex:73-84`) largely beside the point — that floor exists precisely so a guest cannot `abort()` the BEAM, and this is a two-line path to the same outcome. It also defeats the release's central contract (`terminate means dead, the supervisor replaces the child`): there is no child left, and no supervisor.
- **Evidence:**
  - Source trace above, every hop read in the pinned crates.
  - `grep catch_unwind` over the whole of `deno_core-0.391.0`: **zero matches**. tyrex's own `catch_unwind` (`native/tyrex/src/lib.rs:66`) is on the right thread but the wrong side of the FFI boundary.
  - Live probe (`Main`, real arm64 build, `permissions: :none`, `apply: false`), `Tyrex.eval(~s|new Worker("file:///tmp/nope.js", {type: "module"}); 1|, timeout: 3000)`:
    ```
    thread 'worker-1' panicked at deno_runtime-0.246.0/worker.rs:268:9:
    thread '<unnamed>' panicked at deno_runtime-0.246.0/ops/worker_host.rs:276:46:
    thread '<unnamed>' panicked at library/core/src/panicking.rs:225:5:
    panic in a function that cannot unwind
      core::panicking::panic_nounwind
      core::panicking::panic_cannot_unwind
    thread caused non-unwinding panic. aborting.
    ```
    Exit code **134 (SIGABRT)**. The `SURVIVED` marker on the following line never printed.
  - The third frame forecloses the obvious fix: **no `catch_unwind` anywhere could have caught this.** "Wrap it" is not available.
- **Suggested direction:** `create_web_worker_cb` has no error channel (`CreateWebWorkerCb = dyn Fn(CreateWebWorkerArgs) -> WebWorker`), so a well-behaved callback is not on the table. Delete `globalThis.Worker` in the bootstrap script, exactly as `globalThis.Tyrex` is deleted at `worker.rs:488-489` — but **unconditionally**, not only on the `!apply_enabled` branch. I agree this removes a footgun rather than a feature: web workers were never supported here, the default callback is `unimplemented!()`, and the README's own feature list (inherited from deno_runtime) advertising `Worker` is simply wrong for tyrex.
  - **Is deleting the global sufficient?** On this pin, yes, and I checked the alternatives rather than assuming: `op_create_worker` is not in `Deno[Deno.internal].core.ops` — `Main`'s enumeration returned the entire table as `["op_base64_encode","op_napi_open","op_set_exit_code"]`; the only other holder of the op is the `createWorker` closure in `deno_runtime/js/11_workers.js:42-59`, reachable solely through the `Worker` class; and `node:worker_threads` is unreachable because `FsModuleLoader::load` rejects every non-`file:` URL (`deno_core/modules/loaders.rs:449-453`). Pin it with a test asserting `typeof Worker === "undefined"`, and treat that assertion as a deno-bump gate.
  - **Is `Worker` the only one?** I grepped all of `deno_runtime-0.246.0` for `unimplemented!`/`todo!`/`panic!`. Four hits: `worker.rs:268` (this bug), `worker.rs:756` (`Bootstrap exception` — only reachable if deno's own bootstrap throws), `web_worker.rs:1061` (inside a web worker, unreachable once `Worker` is gone), `transpile.rs:39` (build-time snapshotting). So **`Worker` is the only guest-reachable panicking default**, and fixing it does not queue up a successor.

---

## Warnings

### W-A. Guest JS can forge output on the host's stdout and read the host's stdin under `permissions: :none`, and the docs enumerate `:none` as if it were exhaustive

- **Where:** `README.md:180-181`, `lib/tyrex.ex:153-154`
- **What:** The `deno_io` extension registers rids 0/1/2 as stdin/stdout/stderr from `Stdio::default()` = inherit (`deno_io-0.148.0/12_io.js:112-114`). Nothing in Deno's permission model governs stdio — correct for a CLI, wrong assumption for a runtime embedded in a host OS process. `lib/tyrex.ex:153-154` says `:none` means "JavaScript can compute, but not read files, open sockets, read env, or spawn processes"; `README.md:180` says "No Deno I/O at all — computation only". Both read as exhaustive; neither is.
- **Why it matters:** On a release with an attached `iex` or a console, `Deno.stdin.readSync` consumes bytes from the operator's keyboard. `Deno.stdout.writeSync` injects arbitrary lines into the host's stdout — which for most Elixir deployments is the log pipeline, so a guest can forge log records. Neither is a filesystem or network escape, but both are capabilities a reader of the `:none` docs would swear were absent. That is the same defect class the release exists to eliminate: a control described in terms that overstate it.
- **Evidence:** Live probe (`Main`, `permissions: :none`):
  ```
  Deno[Deno.internal].core.resources()  -> {"0":"stdin","1":"stdout","2":"stderr"}
  Deno.stdout.writeSync(...)            -> "WROTE 26"  (TYREX-PROBE-FORGED-STDOUT appeared on the host terminal)
  typeof Deno.stdin.readSync            -> "function"
  ```
  Exactly three rids and no others, so the resource table is not otherwise populated under `:none` — the gap is stdio and only stdio.
- **Suggested direction:** Docs first: say plainly that `:none` denies *Deno's permissioned I/O* and that stdio is inherited from the host process and is not permissioned. If you want it closed rather than disclosed, `WorkerOptions.stdio` accepts piped/null handles — that is a one-field change at `worker.rs:440-444` and would make `:none` mean what it says.

### W-B. The `Deno.core` op-reacquisition defence is real but undocumented and untested; the code comment and the test both name the wrong mechanism (**PERSISTENT** — prior per-agent security Finding 3, `.claude/plans/sandbox-integrity/reviews/security.md:200-243`, never promoted into the consolidated 23)

- **Where:** `native/tyrex/src/worker.rs:481-486`, `test/tyrex_permissions_test.exs:317-318`
- **What:** The comment claims the op "cannot be re-acquired" because the global was deleted and `ext:` modules are unimportable. Both statements are true and neither is the operative protection for `Deno.core`. `Deno.core` is `undefined` only because `denoNs` has no `core` key; the whole of `core` is reachable at `Deno[Deno.internal].core` (`deno_runtime/js/99_main.js:558-565`), and every registered op *is* installed on `Deno.core.ops` unconditionally (`deno_core/runtime/bindings.rs:465-481`). What actually saves this is `removeImportedOps()` (`js/99_main.js:548-556`, called at `:720` and `:968`), which deletes every op not in `NOT_IMPORTED_OPS`. The test at `test/tyrex_permissions_test.exs:318` asserts `typeof Deno?.core?.ops?.op_apply == "undefined"` — a path that is `undefined` regardless, and would stay green if `removeImportedOps()` vanished in a deno bump. The prior review named this exact line and it survived verbatim.
- **Why it matters:** The invariant is upstream's, not tyrex's, and tyrex neither states nor pins it. If a deno bump re-populated `core.ops`, `op_apply` would become directly callable (still allowlist-checked in Elixir, so no escalation) **and so would `op_import_sync`, which is a genuine unchecked file read** — see the note under "What I verified clean" below. Same class as B1: a control whose failure would be silent.
- **Evidence:** Live probe (`Main`): `Object.keys(Deno[Deno.internal].core.ops)` -> `["op_base64_encode","op_napi_open","op_set_exit_code"]`; `typeof Deno[Deno.internal].core.ops.op_apply` -> `"undefined"` with the bridge both enabled and disabled; `typeof Deno[Deno.internal].core` -> `"object"` (reachable, as predicted). So the boundary holds today, for a reason neither the comment nor the test records.
- **Suggested direction:** Assert the reachable path, not the vacuous one — `typeof Deno[Deno.internal].core.ops.op_apply == "undefined"` — and additionally pin the shape (`typeof Deno[Deno.internal].core.ops == "object"`) plus the table itself, so a deno bump that re-exposes ops fails loudly instead of silently. Correct the comment at `worker.rs:481-486` to name `removeImportedOps()`.

### W-C. The static/dynamic exemption is a negative test, and it holds only because nothing guest-reachable creates a `LoadInit::Side` load

- **Where:** `native/tyrex/src/worker.rs:76-90` (the doc comment), `:105-124` (`resolve`), `:145-155` (`load`)
- **What:** The loader checks when `ResolutionKind::DynamicImport` or `options.is_dynamic_import`. The comment asserts that this "is exactly the operator/guest boundary". It is not a boundary, it is a proxy for one: `deno_core` has a third load shape, `LoadInit::Side`, which resolves with `ResolutionKind::Import` (`modules/recursive_load.rs:202-204`) and loads with `is_dynamic_import: false` (`:248`), and which is driven by the guest-facing `op_import_sync` (`ops_builtin.rs:72, 511-523, 639-645`). Neither of the loader's two hooks fires for it.
- **Why it matters:** Today `op_import_sync` is unreachable — I predicted it *was* reachable and was wrong; `Main`'s probe returned `typeof ... op_import_sync -> "undefined"` and the direct call `-> "ERR TypeError: ... is not a function"`, because `removeImportedOps()` stripped it. So there is no live escape. But the exemption is defined by what deno happens *not* to flag as dynamic, and it is guarded by an upstream detail (W-B) rather than by tyrex. Two upstream facts have to keep holding for `permissions: :none` to keep denying reads.
- **Evidence:** Source trace above; probe output quoted; `ops_builtin.rs:511-523` -> `RecursiveModuleLoad::side(..., SideModuleKind::Sync, code)` -> `LoadInit::Side`.
- **Suggested direction:** Make the exemption positive rather than negative. The operator's static graph is exactly "whatever loaded before `execute_main_module` returned" — a `Cell<bool>` on `PermissionedModuleLoader`, set at `worker.rs:497` once `execute_main_module` completes, turns the predicate into `if bootstrap_complete || options.is_dynamic_import { check }`. That is a handful of lines, it removes the dependence on deno's is-dynamic bookkeeping *and* on `removeImportedOps()`, and it makes the doc comment's claim structurally true instead of contingently true.

---

## Suggestions

- **S-A. Dead guest-facing surface in the rewritten bridge.** `native/tyrex/extension/main.js:7-10` defines `Tyrex._handleApplicationResult`, which nothing calls — the Rust side invokes `_applyReply` (`worker.rs:611-613`). Verified by grep: `_handleApplicationResult` appears only in `main.js`. It also throws on an unknown id (`Tyrex._applications[applicationId].resolve` on `undefined`). Delete it; a privileged bridge should carry no unreferenced entry points.
- **S-B. Slab ids have no generation counter.** `op_apply` resolves the pid with `slab.get(runtime_id)` (`worker.rs:33-46`) and `runtimes` reuses freed slots (`runtimes.rs:5-6`). If any future path let JS run after `try_remove(runtime_id)`, a reused slot would deliver `{:apply, ...}` to a *different* runtime's GenServer — B5, resurrected through the back door. I traced all seven removal sites (`worker.rs:594, 629, 702, 715, 722`; `lib.rs:43, 97, 106`) and every one is immediately followed by `break`/`return`, so **there is no window today**. Worth one line of comment at `worker.rs:33` recording that the absence of a generation counter rests on that invariant.
- **S-C. `invoke/3`'s encode-failure branch leaks more than the rescue branch does.** `lib/tyrex.ex:757-770` documents that an allowlisted function's *exception message* is deliberately returned to the guest. But `encode_json/1` (`:708-716`) additionally returns `"Could not convert to JSON: #{inspect(error.value)}"` — that is the un-encodable *return value* itself (a struct, a pid, a tuple), which the "nothing is hidden" rationale does not cover. Consider returning the type without the value.

---

## Persistent prior findings

**PERSISTENT (prior per-agent security review, Finding 3)** — `test/tyrex_permissions_test.exs:317-318` and its comment survive verbatim, still asserting `typeof Deno?.core?.ops?.op_apply`, a path that is `undefined` independent of any tyrex protection. See W-B. This finding was raised by the security agent in `.claude/plans/sandbox-integrity/reviews/security.md:200-243` and did not make the consolidated 23, which is why it was never assigned a fix task.

None of B1–B5 are persistent in my scope. Specifically:

### B1 — `import()` bypasses read permissions: **CLOSED.** What I checked

1. **Dynamic `import()` itself.** `resolve` checks on `ResolutionKind::DynamicImport` (`worker.rs:113-121`) and `load` checks on `options.is_dynamic_import` (`worker.rs:150-154`), both via `PermissionsContainer::check_specifier(.., Dynamic)` (`worker.rs:92-103`). The double check is load-bearing and the comment is accurate: `ModuleMap::load_dynamic_import` resolves at `map.rs:1290-1291` *before* the module-map cache lookup at `:1293-1301`, so a cache hit never reaches `load`.
2. **The whole transitive graph of a dynamic import.** `new_module_from_js_source` passes `ResolutionKind::DynamicImport` for *every* request in a module compiled with `is_dynamic_import` (`map.rs:862-867`), and `RecursiveModuleLoad` propagates `is_dynamic_import: self.is_dynamic_import()` into every `load` (`recursive_load.rs:248, 393-414, 515-519`). Both hooks fire for transitive deps, not just the entry specifier.
3. **`data:` / `blob:` smuggling.** `check_specifier` does return `Ok(())` for both (`deno_permissions/lib.rs:3946-3947`) — but `FsModuleLoader::load` rejects every non-`file:` URL with "is not a file URL" (`loaders.rs:449-453`), so no content can be introduced that way; and even if it could, its imports inherit `is_dynamic_import` per (2).
4. **WebAssembly.** `.wasm` is read through the same `load` (`loaders.rs:465-467`) and the synthetic JS shim is built with the same `is_dynamic_import` (`map.rs:960-981`). Checked.
5. **`RequestedModuleType::Bytes`/`Text`/`Json`.** These only select a `ModuleType` inside `FsModuleLoader::load` (`loaders.rs:455-484`) — same code path, same check. The B1 repro shape (`{with: {type: "json"}}`) is covered.
6. **`ext:` specifiers.** `ModuleMap::resolve` rejects them from non-`ext:`/`node:` referrers *before* the loader is consulted (`map.rs:1215-1231`), so `import("ext:core/ops")` cannot be used to re-acquire ops.
7. **`import.meta.resolve`.** Deliberately unchecked and genuinely harmless: `FsModuleLoader` does not override it, so it falls to the trait default -> `FsModuleLoader::resolve` -> `resolve_import`, pure URL arithmetic with no I/O (`loaders.rs:78-84, 432-439`). It is also unreachable from `eval` — see (9). Composing it into a read requires a subsequent `import()`, which is checked.
8. **`lazy_load_esm_module`.** Uses `LazyEsmModuleLoader` over build-time-registered sources only, never tyrex's loader and never the filesystem (`map.rs:2228-2262`).
9. **Can a guest cause a *static* load?** No. `eval` goes through `execute_script`, which compiles with `v8::Script::compile` (`deno_core/runtime/jsrealm.rs:415`) — a classic script, in which `import` statements and `import.meta` are syntax errors. Confirmed by source, not assumed.
10. **`op_import_sync`.** The one route that would bypass both hooks. Not reachable — probe confirmed `undefined`. Recorded as W-C because the reason is upstream's, not tyrex's.
11. **Anything loading outside `ModuleLoader` entirely.** `deno_node`'s `require` reads through `op_require_read_file`, which calls `ensure_read_permission` before touching the loader (`deno_node/ops/require.rs:499-512`), and `node:` specifiers are unreachable here anyway per (3). `op_napi_open` calls `permissions.check_ffi(path)` as the *first* statement of its body, before any `dlopen` (`deno_napi/lib.rs:586-590`) — confirmed live: `:none` -> `NotCapable: Requires ffi access`, `allow_ffi: true` -> `TypeError: Unable to find register Node-API module`, i.e. two different errors, so the gate is `allow_ffi` and it precedes the load. `deno_rt_native_addon_loader: None` is *not* what blocks it (`lib.rs:641-644` merely passes the path through), which is worth knowing.

### B5 — guest-writable `Tyrex._runtimeId`: **CLOSED.** What I checked

1. `RuntimeId` is placed in per-runtime `OpState` by the `extension!` state closure (`worker.rs:56-62`) from `extension::init(runtime_id)` (`worker.rs:441`). `OpState` is per-`JsRuntime`; `MainWorker` is single-realm; the `options` mechanism is a Rust-side constructor argument with no JS binding.
2. `op_apply` reads `state.borrow::<RuntimeId>().0` (`worker.rs:33`) and no longer takes an id from JS — `main.js:39` passes exactly four arguments, none of them an id.
3. No bootstrap script injects anything on the bridge-on path; the only `execute_script` at startup is the unconditional-on-`!apply_enabled` `delete globalThis.Tyrex;` (`worker.rs:488-489`). Nothing depended on the removed script: `_runtimeId` appears **nowhere in the repository** (grepped).
4. Direct op access does not resurrect it: `op_apply` is absent from `Deno[Deno.internal].core.ops` with the bridge both enabled and disabled (probe), and even if it were present the id would still come from `OpState`, so a guest could at most forge an `application_id` inside its *own* runtime.
5. Residual: slab-slot reuse, S-B. No live window.

### Permission parsing — clean

`allow_option`/`deny_option` (`worker.rs:220-241`) match `deno_permissions` semantics exactly: `Permissions::new_unary*` derives `granted_global`/`flag_denied_global` from `global_from_option`, so `Some(vec![])` is a *global* grant/denial and `None` is neither (`deno_permissions/lib.rs:3432-3462, 3483-3600`). `PermissionsOptions` has precisely the nineteen fields tyrex sets (`lib.rs:3393+`) — there is no `allow_all` field to forget, and the struct literal at `worker.rs:335-357` is exhaustive, so a future upstream field is a compile error rather than a silent default. `prompt: false`. The `allow_all` baseline is applied only to *absent* keys (`worker.rs:319-325`), so an explicit `allow_x: false` still denies, and explicit `deny_*` keys are honoured on top. `allow_all` as a list is now a hard error (`worker.rs:301-312`) rather than a silent `false`, closing S1. I could construct no shape among the sixteen keys that widens: booleans and string lists are the only accepted forms (`worker.rs:190-215`), a non-string list entry rejects the whole runtime, and an unknown key rejects the whole runtime (`worker.rs:288-295`). The two layers agree — `@permission_keys` at `lib/tyrex.ex:88-106` is the same set as `PERMISSION_KEYS` at `worker.rs:157-175`. Bypassing Elixir by calling `Tyrex.Native.start_runtime/5` directly cannot produce a permissive runtime: the Rust parser re-validates every key and shape and returns `Err` on anything it does not understand, and the only preset is the exact string `"allow_all"` (`worker.rs:271-280`). One narrowing-only quirk, not worth a finding: Elixir coerces atoms inside value lists to strings (`lib/tyrex.ex:938-939`), so `allow_read: [true]` becomes the path descriptor `"true"`.

### `:apply` authorization — clean

Guest strings reach only `Map.fetch(allowlist, {module, function_name, arity})` (`lib/tyrex.ex:735`); the MFA comes from the allowlist *value*, so there is no atom minting and no `String.to_atom` anywhere on the path. Arity is part of the key, so it is authorized rather than merely matched — `{Enum, :sum, 1}` does not authorize `Enum.sum/2`. There is no module-existence oracle: an allowlist miss always yields the same `permission_denied: ... is not in the :apply allowlist` message regardless of whether the module exists, and the `function_exported?` re-check (`:736-740`) is reachable only for entries already validated at `start/1` (`:891-901`). `js_module_name/1` (`:920-925`) cannot collide: Elixir modules lose the `Elixir.` prefix, Erlang modules gain a `:` prefix, so no two atoms map to one key. `decode_args/1` (`:721-727`) uses `Jason.decode`, which produces only maps with string keys, lists, numbers, strings, booleans and `nil` — no atoms, no structs. `invoke/3`'s `rescue`/`catch` (`:757-770`) rejects the JS promise instead of killing the runtime, which is the right call; the only leak beyond the documented exception message is S-C. `build_apply_allowlist([])` -> `nil` -> bridge not installed (`:875`), and `apply_enabled` is derived as `allowlist != nil` (`:446`), so the JS-side and Elixir-side notions of "bridge on" cannot diverge.

---

## Pre-existing (one line each)

- `native/tyrex/src/worker.rs:440-444` — the Blocker above is pre-existing in origin (`WorkerOptions::default()` predates v0.4.0); it is filed as a Blocker rather than a one-liner because it is a live, deterministic, whole-VM kill squarely inside this review's assigned target, and because v0.4.0 is the release that starts making sandbox promises.
- `README.md:180-181`, `lib/tyrex.ex:153-154` — W-A's stdio capability is likewise pre-existing and upstream; only the docs claim is tyrex's.
- `deno_napi-0.169.0/lib.rs:586-590` — `allow_ffi: true` grants arbitrary `dlopen`, i.e. native code execution. Correct per Deno's model and accurately described by `README.md:235`, noted only so the reader knows `allow_ffi` is a total-compromise grant, not a niche one.
