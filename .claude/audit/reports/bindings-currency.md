# Bindings Currency Audit — tyrex

Scope: Rust/NIF binding freshness for `native/tyrex` + the Elixir-side rustler stack.
Method: every version number below was fetched during this audit from the crates.io
sparse index (`https://index.crates.io/...`), the hex.pm API, or read out of the repo's
own `Cargo.toml` / `Cargo.lock` / `mix.lock`. The crates.io HTML/v1 API returned HTTP 403,
so the sparse index was used instead (same registry data). Crate sources for the pinned and
target versions were downloaded from `static.crates.io` and diffed locally to establish the
breaking-change surface — no `cargo` invocation, no file in the project was modified.

## Score: 5/100

```
start                                                             100
-10  deno_core      0.391.0 -> 0.410.0   (19 minor releases behind)  90
-10  deno_runtime   0.246.0 -> 0.265.0   (19 minor releases behind)  80
-10  serde_v8       0.300.0 -> 0.319.0   (19 minor releases behind)  70
-10  rustler (Rust) 0.36.0  -> 0.38.0    (2 minor releases behind)   60
 -5  deno_fs        0.148.0 -> 0.167.0                               55
 -5  deno_resolver  0.69.0  -> 0.88.0                                50
 -5  sys_traits     =0.1.24 -> 0.1.28 (exact pin, blocks resolution) 45
 -5  tokio          lock 1.50.0 -> 1.53.1                            40
 -5  libsqlite3-sys 0.35.0  -> 0.38.2                                35
 -5  libffi-sys     =4.1.0  -> 4.2.0                                 30
 -5  rustler_precompiled (hex) 0.8.4 -> 0.9.0                        25
-20  Elixir rustler 0.37.3 vs Rust rustler crate 0.36.0 — MISMATCH    5
```
Final: **5/100**. (`v8`/`deno_v8` is folded into the deno_core deduction rather than
double-counted, since it is the same lockstep group.)

## Version table

| Crate/Package | Pinned (Cargo.toml / mix.exs) | Resolved (lock) | Latest | Versions behind | Lockstep group | Breaking changes expected | Effort |
|---|---|---|---|---|---|---|---|
| `deno_core` | `0.391.0` | `0.391.0` | `0.410.0` | 19 minor | **deno** | None in the APIs tyrex uses (verified by source diff) | M |
| `deno_runtime` | `0.246.0` (`features=["transpile"]`) | `0.246.0` | `0.265.0` | 19 minor | **deno** | **Yes** — `WorkerServiceOptions.blob_store` type changed | M |
| `deno_fs` | `0.148.0` | `0.148.0` | `0.167.0` | 19 minor | **deno** | None for `deno_fs::RealFs` | S |
| `deno_resolver` | `0.69.0` | `0.69.0` | `0.88.0` | 19 minor | **deno** | None for `npm::{DenoInNpmPackageChecker, NpmResolver}` | S |
| `serde_v8` | `0.300.0` | `0.300.0` | `0.319.0` | 19 minor | **deno** | None for `from_v8` | S |
| `v8` (transitive) | — | `146.4.0` | `152.1.0` under old name; **renamed to `deno_v8` 0.2.0** | crate renamed + version reset | **deno** | None for tyrex (uses `deno_core::v8::*` re-export) | S |
| `sys_traits` | `=0.1.24` (exact) | `0.1.24` | `0.1.28` | 4 patch | **deno** (transitively) | Exact pin **conflicts** with target; must be relaxed | S |
| `rustler` (Rust crate) | `0.36.0` | `0.36.2` | `0.38.0` | 2 minor | rustler | **Yes** — dropped deprecated codegen (`resource!`, explicit `init!` list); MSRV 1.91 | S |
| `tokio` | `1.47.1` (floor) | `1.50.0` | `1.53.1` | 3 minor (lock) | — | None | S |
| `libsqlite3-sys` | `0.35.0` (`bundled`) | `0.35.0` | `0.38.2` | 3 minor | **deno** (via `deno_kv`→`rusqlite`) | Must move to `0.38` in lockstep with deno bump | S |
| `libffi-sys` | `=4.1.0` (macOS, `system`) | `4.1.0` | `4.2.0` | 1 minor | **deno** (via `deno_ffi`→`libffi`) | Upstream stopped depending on it directly | S |
| `rustler` (hex) | `~> 0.35` → `0.37.3` | `0.37.3` | `0.38.0` | 1 minor | rustler | None for tyrex's usage (`use RustlerPrecompiled` path) | S |
| `rustler_precompiled` (hex) | `~> 0.7` → `0.8.4` | `0.8.4` | `0.9.0` | 1 minor | rustler | **Yes** — drops `castore`, drops Elixir 1.13/1.14 | S |

Sources for the table:
- `native/tyrex/Cargo.toml:1-27` — declared requirements.
- `native/tyrex/Cargo.lock:1412,2233,1639,2189,6535,7340,6197,7555,4641,4583,7957` — resolved versions
  (`deno_core 0.391.0`, `deno_runtime 0.246.0`, `deno_fs 0.148.0`, `deno_resolver 0.69.0`,
  `serde_v8 0.300.0`, `sys_traits 0.1.24`, `rustler 0.36.2`, `tokio 1.50.0`,
  `libsqlite3-sys 0.35.0`, `libffi-sys 4.1.0`, `v8 146.4.0`).
- `mix.lock:12-13` — `rustler 0.37.3`, `rustler_precompiled 0.8.4`.
- `mix.exs:73-75` — `{:rustler, "~> 0.35", optional: true}`, `{:rustler_precompiled, "~> 0.7"}`.

---

## Findings

### [CRITICAL] Elixir `rustler` 0.37.3 is paired with Rust `rustler` crate 0.36.x

- Location: `mix.lock:12` and `native/tyrex/Cargo.toml:6`
- Evidence:
  ```
  # mix.lock:12
  "rustler": {:hex, :rustler, "0.37.3", ...}
  ```
  ```toml
  # native/tyrex/Cargo.toml:6
  rustler = "0.36.0"
  ```
  resolving to `native/tyrex/Cargo.lock:6197` → `name = "rustler" / version = "0.36.2"`.
- Correctly-paired versions: rustler ships the Elixir package and the Rust crate from a
  single repo/tag, and both sides publish the same version numbers (hex has
  `0.36.0 / 0.36.1 / 0.36.2 / 0.37.0 / 0.37.1 / 0.37.3 / 0.37.4 / 0.38.0`; crates.io has the
  same ladder — verified: `curl https://index.crates.io/ru/st/rustler` tail is
  `0.37.2, 0.37.3, 0.37.4, 0.38.0`). The intended pair is **same version on both sides**:
  today that is **hex `0.38.0` + crate `0.38.0`**; the minimal correction from the current
  state is **hex `0.37.3` + crate `0.37.3`** (or `0.37.4`).
- There is no hard runtime enforcement in the installed rustler: the error string exists but
  is orphaned — `deps/rustler/lib/rustler/compiler/messages.ex:27`
  `def message({:unsupported_rustler_version, crate, supported, version}) do` has **zero
  callers** (`grep -rn "unsupported_rustler_version" deps/rustler/lib/` returns only that
  definition). So the mismatch is silent today.
- Impact: the mismatch only bites on the `force_build` path (`TYREX_BUILD=true`,
  `lib/tyrex/native.ex:9`), where the Elixir-side mix compiler drives a crate built against a
  different codegen generation. Because it is silent, it will keep drifting until a genuinely
  incompatible generation lands and produces a confusing build failure or an ABI-level
  surprise rather than a clear version error.
- Fix: set both sides to the same version. Recommended: `mix.exs` `{:rustler, "~> 0.38"}`
  + `Cargo.toml` `rustler = "0.38.0"`, applied as one commit.

### [HIGH] `sys_traits = "=0.1.24"` exact pin will hard-block the deno bump

- Location: `native/tyrex/Cargo.toml:11`
- Evidence:
  ```toml
  sys_traits = "=0.1.24"
  ```
- Why it was pinned: there is **no comment** on this line (the only comment block in the file
  covers `libsqlite3-sys`, `Cargo.toml:14-16`). The pin mirrors upstream: `deno_runtime`
  `0.246.0` itself declares `sys_traits =0.1.24` (exact) — verified from the sparse index
  dependency list for `deno_runtime 0.246.0`. So the local `=` was tracking an upstream `=`.
- At the target version this is inverted: `deno_runtime 0.265.0` declares
  `sys_traits ^0.1.28`, and `deno_core 0.410.0` likewise declares `sys_traits ^0.1.28`
  (docs.rs dependency listing for `deno_runtime 0.265.0`; sparse-index deps for
  `deno_core 0.410.0`). `=0.1.24` is unsatisfiable against `^0.1.28`.
- Impact: `cargo update` for the deno bump fails to resolve until this line changes. Silent
  time-bomb for whoever attempts the upgrade.
- Fix: change to `sys_traits = "=0.1.28"` (keeping the mirror-upstream discipline) or drop
  the exact pin to `"0.1.28"`. The pin is no longer *necessary* — upstream relaxed to a caret
  — but keeping it exact costs nothing and documents intent.

### [HIGH] `WorkerServiceOptions.blob_store` changes type — the one real code break in the deno bump

- Location: `native/tyrex/src/worker.rs` (the `WorkerServiceOptions` literal inside
  `worker::new`, the `blob_store: Default::default(),` field)
- Evidence — current call site:
  ```rust
  deno_runtime::worker::WorkerServiceOptions::<
      deno_resolver::npm::DenoInNpmPackageChecker,
      deno_resolver::npm::NpmResolver<sys_traits::impls::RealSys>,
      sys_traits::impls::RealSys,
  > {
      blob_store: Default::default(),
      ...
  ```
  Pinned definition (`deno_runtime-0.246.0/worker.rs`):
  ```rust
  pub blob_store: Arc<BlobStore>,
  ```
  Target definition (`deno_runtime-0.265.0/worker.rs:221`, with
  `deno_runtime-0.265.0/worker.rs:51` `use deno_web::BlobStoreTrait;`):
  ```rust
  pub blob_store: Arc<dyn BlobStoreTrait>,
  ```
  `deno_web-0.288.0/blob.rs:44` `pub trait BlobStoreTrait: Debug + Send + Sync {` — and
  grepping `deno_web-0.288.0/blob.rs` for `impl Default for` yields only
  `blob.rs:405: impl Default for CountingBlobStore` (a test helper), i.e. **no
  `impl Default for Arc<dyn BlobStoreTrait>`**.
- Impact: `blob_store: Default::default()` stops compiling. This is the single concrete
  source edit required by the deno bump.
- Fix: replace with an explicit concrete store, e.g.
  `blob_store: std::sync::Arc::new(deno_runtime::deno_web::BlobStore::default())`
  (confirm the exact re-export path when the bump is performed).

### [MEDIUM] `libsqlite3-sys = "0.35.0"` will silently stop applying `bundled` after the deno bump

- Location: `native/tyrex/Cargo.toml:13-17`
- Evidence:
  ```toml
  # Transitive dep via deno_kv → rusqlite. Enable bundled so it compiles
  # SQLite from source with pre-generated bindings (no libclang needed
  # for cross-compilation).
  libsqlite3-sys = { version = "0.35.0", features = ["bundled"] }
  ```
  Dependency chain, all fetched from the sparse index:
  - pinned: `deno_kv 0.146.0 -> rusqlite ^0.37.0`; `rusqlite 0.37.0 -> libsqlite3-sys ^0.35.0` ✅ unifies with the local `0.35.0`.
  - target: `deno_kv 0.165.0 -> rusqlite ^0.40.0`; `rusqlite 0.40.0 -> libsqlite3-sys ^0.38.0` ❌ does **not** unify with `0.35.0`.
- Impact: after the deno bump, two `libsqlite3-sys` majors coexist — the local `0.35` (with
  `bundled`) is dead weight, and the real `0.38` used by `rusqlite` is built **without**
  `bundled`, reintroducing the exact `libclang` / system-SQLite cross-compilation problem the
  comment says this line exists to prevent. Breaks CI release builds for the
  `*-unknown-linux-gnu` targets, and the failure mode is a linker/bindgen error far from the
  cause.
- Fix: bump to `libsqlite3-sys = { version = "0.38.0", features = ["bundled"] }` **in the
  same commit** as the deno bump, and verify via `cargo tree -i libsqlite3-sys` that exactly
  one version resolves.

### [MEDIUM] `rustler_precompiled` 0.8→0.9 drops `castore`, which is still in `mix.lock`

- Location: `mix.exs:75`, `mix.lock:3`, `mix.lock:13`
- Evidence:
  ```
  # mix.lock:13
  "rustler_precompiled": {:hex, :rustler_precompiled, "0.8.4", ..., [{:castore, "~> 0.1 or ~> 1.0", ... optional: false}, ...]}
  # mix.lock:3
  "castore": {:hex, :castore, "1.0.17", ...}
  ```
  rustler_precompiled CHANGELOG, `[0.9.0] - 2026-03-26`, *Changed*:
  > Rely on cert stores provided by Erlang/OTP +25. This change removes the dependency on
  > `castore` package in favour of loading the cert stores from OTP. In case an older OTP
  > version is in use, a warning is emitted.

  and:
  > Drop support for Elixir 1.13 and 1.14.
- Impact: `castore` becomes an orphan lock entry after the bump (harmless but noise);
  more importantly, download-time TLS trust now comes from OTP, so any CI runner on
  OTP < 25 starts emitting warnings and falls back. `mix.exs:11` declares
  `elixir: "~> 1.18"`, so the Elixir 1.13/1.14 drop is a non-issue here.
- Fix: `{:rustler_precompiled, "~> 0.9"}` and let `mix deps.unlock --unused` drop `castore`.

### [LOW] `libffi-sys = "=4.1.0"` macOS pin is now a workaround for a dependency that no longer exists

- Location: `native/tyrex/Cargo.toml:19-20`
- Evidence:
  ```toml
  [target.'cfg(target_os = "macos")'.dependencies]
  libffi-sys = { version = "=4.1.0", features = ["system"] }
  ```
  No comment explains it. Sparse-index deps show why the pin exists and why it is stale:
  - `deno_ffi 0.225.0 -> libffi =5.1.0` **and** `deno_ffi 0.225.0 -> libffi-sys =4.1.0`
    (upstream itself pinned `=4.1.0`; the local line is a feature-unification hack that turns
    on `system` for that already-present crate, so macOS links the system libffi instead of
    building it).
  - `deno_ffi 0.244.0 -> libffi =5.1.0` — and **no direct `libffi-sys` dependency at all**.
  - `libffi 5.1.0 -> libffi-sys ^4.1`; `libffi 5.1.1 -> libffi-sys ^4.2`.
- Impact: at the target versions the `=4.1.0` pin still *resolves* (satisfies `^4.1`) but it
  now pins a crate the graph reaches only indirectly, and it forecloses `libffi-sys 4.2.0` /
  `libffi 5.1.1`. Low risk, but it is undocumented magic that the next maintainer cannot
  explain from the file.
- Fix: keep the entry (the `system` feature is still the mechanism that avoids building
  libffi on macOS) but relax to `libffi-sys = { version = "4.1", features = ["system"] }`
  and **add a comment** stating the purpose, matching the style of the `libsqlite3-sys` block.

### [LOW] `tokio` lockfile is 3 minors behind with no constraint forcing it

- Location: `native/tyrex/Cargo.toml:12`, `native/tyrex/Cargo.lock:7555`
- Evidence: `tokio = "1.47.1"` (a floor, caret) resolving to `version = "1.50.0"`, while the
  registry's latest stable is `1.53.1`. `deno_runtime 0.265.0` requires only `tokio ^1.47.1`
  (docs.rs dependency listing), so nothing is holding it back.
- Impact: purely stale — missing upstream fixes for a crate that runs the entire worker event
  loop (`native/tyrex/src/tokio_runtime.rs`, `native/tyrex/src/worker.rs`).
- Fix: `cargo update -p tokio`. Zero code change.

---

## Breaking-change surface — API-by-API

Everything below was established by downloading the pinned and target crate sources from
`static.crates.io` and diffing them locally. Anything I could not read is marked
`[UNVERIFIED]`.

| API used by tyrex | Where | 0.391/0.246 → 0.410/0.265 | Verified how |
|---|---|---|---|
| `deno_core::op2` with `#[op2(fast)]` + `#[string] String` params | `src/worker.rs` (`op_apply`) | **Unchanged** | `deno_core 0.391.0` uses `deno_ops 0.267.0`, `0.410.0` uses `deno_ops 0.286.0`. Both keep `AttributeModifier::String(_) => "string"` (`signature.rs:827` / `:830`) and the `fast` flag (`config.rs:155` / `:158`, `InvalidAttributeCombination("fast", "nofast")`). |
| `deno_core::extension!` with `ops`, `esm_entry_point`, `esm = [dir …]`, `state = \|state\|` | `src/worker.rs` | **Unchanged / additive** | Diff of `extensions.rs` macro body: 0.410 only *adds* optional arms `lazy_loaded_js = [...]` and `synthetic_esm = [...]` plus `#[allow(..., reason = ...)]` lint annotations. All arms tyrex uses, and `pub fn init(...)`, are byte-identical. |
| `deno_runtime::ops::bootstrap::SnapshotOptions::default()` | `src/worker.rs` (`state =` closure) | **Unchanged** | `struct SnapshotOptions { ts_version: String, v8_version: &'static str, target: String }` identical in `deno_runtime-0.246.0/ops/bootstrap.rs` and `-0.265.0/ops/bootstrap.rs`. |
| `MainWorker::bootstrap_from_options` | `src/worker.rs` | **Unchanged** | Identical generic signature `(main_module: &ModuleSpecifier, services: WorkerServiceOptions<...>, options: WorkerOptions) -> Self` at `deno_runtime-0.246.0/worker.rs:340` and `-0.265.0/worker.rs:441`. |
| `WorkerServiceOptions { … }` field list | `src/worker.rs` | **BREAKING (one field)** | Full struct diff: only `blob_store: Arc<BlobStore>` → `Arc<dyn BlobStoreTrait>`. Every other field tyrex sets (`broadcast_channel`, `compiled_wasm_module_store`, `feature_checker`, `fetch_dns_resolver`, `fs`, `module_loader`, `node_services`, `npm_process_state_provider`, `permissions`, `root_cert_store_provider`, `shared_array_buffer_store`, `v8_code_cache`, `deno_rt_native_addon_loader`, `bundle_provider`) is present and unchanged. |
| `WorkerOptions { extensions, ..Default::default() }` | `src/worker.rs` | **No break** | `impl Default for WorkerOptions` still present at `deno_runtime-0.265.0/worker.rs:318`; `extensions` field retained. |
| `MainWorker.js_runtime` (public field) | `src/worker.rs` (`deno_core::scope!(scope, worker.js_runtime)`) | **Unchanged** | `pub js_runtime: JsRuntime` at `deno_runtime-0.246.0/worker.rs:149` and `-0.265.0/worker.rs:195`. |
| `JsRuntime::execute_script` | `src/worker.rs` (3 call sites) | **Unchanged** | Byte-identical signature `pub fn execute_script(&mut self, name: impl IntoModuleName, source_code: impl IntoModuleCodeString) -> Result<v8::Global<v8::Value>, Box<JsError>>` at `deno_core-0.391.0/runtime/jsruntime.rs:1695` and `-0.410.0/runtime/jsruntime.rs:2020`. |
| `JsRuntime::poll_event_loop` | `src/worker.rs` (`run_event_loop`) | **Unchanged** | `pub fn poll_event_loop(&mut self, cx: &mut Context, poll_options: PollEventLoopOptions) -> Poll<Result<(), CoreError>>` at `-0.391.0:2075` and `-0.410.0:2374`. |
| `deno_core::scope!` | `src/worker.rs` (3 call sites) | **Unchanged** | `macro_rules! scope` present in both (`-0.391.0/runtime/jsruntime.rs:607`, `-0.410.0/runtime/jsruntime.rs:702`, `#[macro_export]` at 701). |
| `deno_core::error::CoreError` | `src/worker.rs` (`run_event_loop` return) | **Unchanged shape** | `pub enum CoreErrorKind` at `error.rs:108` in **both** crates — same line number, no restructure. |
| `deno_core::FsModuleLoader`, `deno_core::ModuleSpecifier` | `src/worker.rs` | **Unchanged** | `pub struct FsModuleLoader;` in `modules/loaders.rs` of both (line 429 → 533, definition identical). |
| `deno_core::v8::{Global, Local, Value, Promise, PromiseState}` | `src/worker.rs` | **No source change needed** | The underlying crate was renamed: `deno_core 0.391.0` depends on `v8 ^146.3.0`; `deno_core 0.410.0` depends on `v8 ^0.2.0` **with `package = "deno_v8"`** (sparse-index dep records). `serde_v8 0.319.0` does the same. tyrex only ever reaches v8 through `deno_core::v8::*`, so the rename is invisible to `src/`. |
| `serde_v8::from_v8::<serde_json::Value>(scope, local)` | `src/worker.rs` (2 call sites) | `[UNVERIFIED]` — no signature diff performed on `serde_v8` itself; however `serde_v8` moves in lockstep with `deno_core` (`deno_core 0.410.0 -> serde_v8 ^0.319.0`) and no deno_core-side change touches it. Treat as low-risk but confirm at build time. |
| `deno_permissions::{PermissionsOptions, Permissions::from_options, PermissionsContainer::{new, allow_all}}` | `src/worker.rs` (`build_permissions`) | **Unchanged** | Full-struct diff of `PermissionsOptions` between `deno_permissions-0.97.0/lib.rs` (locked, `Cargo.lock:2128`) and `-0.116.0/lib.rs` (target): **all 19 fields identical**, including `ignore_env`, `ignore_read`, `prompt`. `Permissions::from_options(parser: &dyn PermissionDescriptorParser, opts: &PermissionsOptions) -> Result<Self, PermissionsFromOptionsError>` identical (`:3483` → `:3686`). `PermissionsContainer::new(Arc<dyn PermissionDescriptorParser>, Permissions)` and `::allow_all(Arc<dyn PermissionDescriptorParser>)` identical (`:3801/:3819` → `:4004/:4036`). |
| `deno_runtime::permissions::RuntimePermissionDescriptorParser::new(RealSys)` | `src/worker.rs` | **Unchanged** | Both `deno_runtime-0.246.0/permissions.rs:2` and `-0.265.0/permissions.rs:2` are the same one-liner: `pub use deno_permissions::RuntimePermissionDescriptorParser;`. |
| `deno_resolver::npm::{DenoInNpmPackageChecker, NpmResolver<TSys>}` | `src/worker.rs` (turbofish on `WorkerServiceOptions`) | **Unchanged** | `pub enum DenoInNpmPackageChecker` at `npm/mod.rs:64` in **both** `deno_resolver-0.69.0` and `-0.88.0`; `pub enum NpmResolver<TSys: NpmResolverSys>` at `:265` → `:291`, same generic bound. |
| `deno_fs::RealFs` | `src/worker.rs` | **Unchanged** | `deno_fs 0.167.0` remains the `deno_runtime 0.265.0` dependency; no signature change observed. `[UNVERIFIED]` at the `impl FileSystem` detail level. |
| `deno_runtime::deno_tls::rustls::crypto::aws_lc_rs` | `src/worker.rs` | **Path intact** | `pub use deno_tls;` at `deno_runtime-0.265.0/lib.rs:24`. `[UNVERIFIED]` for the `rustls` sub-path, which depends on the `deno_tls 0.244.0` rustls re-export. |
| `deno_runtime` feature `"transpile"` | `Cargo.toml:5` | **Still exists** | `deno_runtime-0.265.0/Cargo.toml:37` `transpile = ["deno_ast"]` (unchanged from `-0.246.0/Cargo.toml:42`). |
| `#[rustler::nif]`, `#[rustler::nif(schedule = "DirtyCpu")]` | `src/lib.rs` (5 NIFs) | **Unchanged** | rustler CHANGELOG 0.37.0–0.38.0 lists no change to the `nif` attribute. |
| `rustler::init!("Elixir.Tyrex.Native")` | `src/lib.rs` | **Already correct** | rustler `UPGRADE.md` §"0.37 -> 0.38": *"Explicit NIF function listing in `init!`, please remove the list"* — tyrex already uses the no-list form. |
| `#[rustler::resource_impl] impl rustler::Resource for Runtime` | `src/runtime.rs` | **Already correct** | Same `UPGRADE.md` entry drops the `resource!` macro in favour of `resource_impl` — tyrex already uses `resource_impl`. |
| `rustler::{Encoder, Env, Term, OwnedEnv, LocalPid, ResourceArc, Atom, atoms!, NifException}` | `src/util.rs`, `src/lib.rs`, `src/atoms.rs`, `src/error.rs` | **No breaking change; one deprecation** | rustler CHANGELOG 0.38.0 *Changed*: *"Along with UTF-8 support, introduce new signatures for atom creation and deprecate the old ones (#732)"* — `atoms!` keeps working, may emit deprecation warnings. 0.38.0 *Removed*: *"Drop deprecated codegen features (#701)"* — neither dropped feature is used (see two rows above). |
| MSRV | — | **1.91 required** | rustler CHANGELOG 0.37.2 *Changed*: *"Bump MSRV (Minimum Supported Rust Version) to 1.91 (#711)"*. Must be reflected in `.github/workflows/{ci,release}.yml` toolchain. |

Net conclusion on the deno bump: **exactly one source edit is required** — the `blob_store`
field in `src/worker.rs`. Everything else in `src/` compiles unchanged. The real work is in
`Cargo.toml` constraint arithmetic (`sys_traits`, `libsqlite3-sys`) and in re-validating the
cross-compiled release builds.

---

## Ordered upgrade plan

### Step 1 — Low-risk independent bumps (Effort: **S**)
Nothing here touches `src/`.

1. `cargo update -p tokio` → `1.50.0` ⇒ `1.53.1`. Requirement `tokio = "1.47.1"` already allows it.
2. Hex housekeeping, independent of everything else: `benchee 1.5.0→1.5.1`,
   `ex_doc 0.40.1→0.40.3`, `jason 1.4.4→1.4.5` (dev/doc-only and a JSON patch).

**Risk if skipped:** low and slowly compounding — stale runtime/async fixes in the crate that
owns the entire worker event loop. No functional blocker.

### Step 2 — rustler Elixir/Rust alignment (Effort: **S**)
Do this **before** the deno bump so that if the deno bump misbehaves you are debugging one
variable, not two.

1. `mix.exs:74` → `{:rustler, "~> 0.38", optional: true}`; `mix deps.update rustler`.
2. `native/tyrex/Cargo.toml:6` → `rustler = "0.38.0"`.
3. Raise the Rust toolchain floor to **1.91** in `.github/workflows/ci.yml` and
   `.github/workflows/release.yml` (MSRV bump landed in rustler 0.37.2).
4. No `src/` changes expected: `init!` already has no function list, resources already use
   `#[rustler::resource_impl]`. Watch for **deprecation warnings** from `rustler::atoms!`
   (`src/atoms.rs`) under the new UTF-8 atom-creation signatures — the project builds with
   `--warnings-as-errors` on the Elixir side only, but keep an eye on `cargo build` output.
5. Verify with `TYREX_BUILD=true mix compile` (the only path where the Elixir-side rustler
   compiler actually runs) plus the full `mix test`.

**Risk if skipped:** the Elixir/Rust rustler pair keeps drifting **silently** — the
`unsupported_rustler_version` guard is dead code (`deps/rustler/lib/rustler/compiler/messages.ex:27`,
no callers), so the first real incompatibility surfaces as an opaque build or ABI failure
rather than a version error. This is the single highest-value step in the plan.

### Step 3 — Deno lockstep bump (Effort: **M**)

**Target tuple** (derived from `deno_runtime 0.265.0`'s own dependency requirements, not from
per-crate maxima):

```toml
deno_core    = "0.410.0"
deno_fs      = "0.167.0"
deno_resolver= "0.88.0"
deno_runtime = { version = "0.265.0", features = ["transpile"] }
serde_v8     = "0.319.0"
sys_traits   = "=0.1.28"          # was =0.1.24 — MUST change or resolution fails
libsqlite3-sys = { version = "0.38.0", features = ["bundled"] }   # was 0.35.0
libffi-sys   = { version = "4.1", features = ["system"] }         # macOS; relax from =4.1.0
```

Transitively pulled and *not* to be declared directly: `deno_permissions 0.116.0`,
`deno_error =0.7.1`, `deno_features 0.54.0`, `deno_kv 0.165.0`, `deno_ast =0.53.3`,
`deno_v8 0.2.0` (formerly `v8`).

Per-file code changes required:

- **`native/tyrex/src/worker.rs`** — one edit. In the `WorkerServiceOptions` literal inside
  `worker::new`, replace `blob_store: Default::default(),` with an explicit
  `std::sync::Arc::new(...)` of a concrete `BlobStore`, because the field became
  `Arc<dyn BlobStoreTrait>` and `Arc<dyn Trait>` has no `Default`.
- **`native/tyrex/src/lib.rs`** — no change.
- **`native/tyrex/src/{runtime,runtimes,atoms,error,tokio_runtime,util}.rs`** — no change
  (none of these touch deno APIs).
- **`native/tyrex/extension/main.js`** — no change (the `extension!` `esm`/`esm_entry_point`
  arms are byte-identical).
- **`native/tyrex/Cargo.lock`** — regenerate.

Verification order: `cargo tree -i libsqlite3-sys` (must show exactly one version) →
`cargo tree -i sys_traits` → `cargo build` → `TYREX_BUILD=true mix test` →
cross-build the four release targets in CI, because the sqlite/ffi constraints only break on
the cross-compiled Linux targets.

**Risk if skipped:** 19 minor releases of accumulated V8, TLS, `deno_fetch`/`deno_net`, and
permission-system fixes go unshipped in a component that **executes untrusted JavaScript**.
`Tyrex`'s whole permission story (`build_permissions` in `src/worker.rs`) is delegated to
`deno_permissions`; running five months behind on the sandbox layer is the most
security-relevant staleness in the project. Additionally, the `v8` → `deno_v8` rename means
every extra month makes the jump wider and the ecosystem support thinner.

### Step 4 — `rustler_precompiled` 0.8 → 0.9 (Effort: **S**)

1. `mix.exs:75` → `{:rustler_precompiled, "~> 0.9"}`; then `mix deps.unlock --unused` to drop
   the now-orphaned `castore 1.0.17` (`mix.lock:3`).
2. **NIF version:** no change needed. `lib/tyrex/native.ex:9` declares `nif_versions: ["2.16"]`.
   NIF `2.18` support (OTP 29) is in rustler_precompiled's *Unreleased* section, **not** in
   0.9.0 — so 0.9.0 brings no new NIF version to opt into. Leave `["2.16"]` as-is unless you
   deliberately want to add `2.17`/`2.18` targets, which is a separate decision.
3. **Targets:** no change needed. The four entries in `lib/tyrex/native.ex:11-16`
   (`aarch64-apple-darwin`, `aarch64-unknown-linux-gnu`, `x86_64-apple-darwin`,
   `x86_64-unknown-linux-gnu`) are unaffected by 0.9.0.
4. **Checksum file:** `checksum-Elixir.Tyrex.Native.exs` does **not** need regeneration for
   this step alone. Artifact names are built by
   `lib_name(basename, version, nif_version, target_triple)`
   (`deps/rustler_precompiled/lib/rustler_precompiled.ex:398`), i.e. keyed on the *crate/app*
   version, NIF version, and target triple — none of which the rustler_precompiled bump
   changes. It **must** be regenerated (`mix rustler_precompiled.download Tyrex.Native --all`)
   as part of cutting the next tyrex release after Steps 2–3, because the `0.3.0` → next
   version bump changes every artifact name and every binary's bytes.
5. Confirm CI runners are on **OTP ≥ 25** — 0.9.0 now sources CA certs from OTP and only warns
   on older releases.

**Risk if skipped:** low functionally. You forgo the `NO_PROXY` and IPv6
(`RUSTLER_PRECOMPILED_IPFAMILY`) support, and you keep a `castore` dependency that upstream has
already shed — a supply-chain surface you no longer need. The step is cheap; skipping it is
mostly a hygiene loss.

### Sequencing note
Steps 1, 2, and 4 are mutually independent and each is a self-contained commit. **Step 3 must
come after Step 2** (isolate variables) and **before the checksum regeneration in Step 4.5**
(the release cut), since Step 3 changes the compiled artifact bytes.

## Clean areas
- Permission plumbing (`PermissionsOptions`, `Permissions::from_options`, `PermissionsContainer`, `RuntimePermissionDescriptorParser`) is byte-for-byte source-compatible across `deno_permissions` 0.97.0 → 0.116.0 — the highest-risk-looking surface in the project needs zero edits.
- `deno_core` APIs used by tyrex (`op2`, `extension!`, `scope!`, `execute_script`, `poll_event_loop`, `CoreError`, `FsModuleLoader`, `ModuleSpecifier`) are unchanged across 0.391.0 → 0.410.0.
- The `v8` → `deno_v8` crate rename is invisible to `native/tyrex/src` because all v8 access goes through the `deno_core::v8` re-export.
- rustler's two 0.38.0 removals (`resource!`, explicit `init!` listing) were already migrated ahead of time in `src/runtime.rs` and `src/lib.rs`.
- `mix.exs` requirement ranges (`rustler ~> 0.35`, `rustler_precompiled ~> 0.7`) are permissive enough that Steps 2 and 4 are lockfile-and-one-line changes, not constraint surgery.
