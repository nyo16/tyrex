# Changelog

## v0.4.0 (2026-08-14)

Security and lifecycle release. Two independent reviews — an internal audit and
a downstream integrator reading the same commit — found the same two defects:
the `Tyrex.apply` bridge was an unrestricted Elixir gateway installed
unconditionally, and there was no way to stop a runaway program. Both are
closed here.

### Changed

**Breaking: `:permissions` now defaults to `:none` instead of `:allow_all`.**
Existing code loses Deno I/O with no compile error. Migration is one line:

```elixir
Tyrex.start(permissions: :allow_all)
```

A one-time `Logger.warning` is emitted when `:permissions` is omitted.

**Breaking: the `Tyrex.apply` JS→Elixir bridge is now opt-in and allowlisted.**
It was installed unconditionally and consulted no permissions at all, so under
`permissions: :none` Deno's own `readTextFileSync` was correctly denied while
the bridge still delivered `File.read!` and shell execution via `:os.cmd`. The
new `:apply` option takes `false` (the default) or an explicit MFA allowlist:

```elixir
Tyrex.start(apply: [{Enum, :sum, 1}, {String, :upcase, 1}])
```

With the bridge disabled, `globalThis.Tyrex` is deleted after bootstrap, so
guest code holds no reference to it. There is deliberately no `apply: true`.
Enforcement lives in the GenServer, not in JavaScript, and an unexported MFA is
rejected at start rather than at first call.

- `:timeout` on `eval/2` is now a real wall-clock deadline. It was previously
  only a `GenServer.call/3` timeout: the caller gave up and the JavaScript kept
  running. On expiry the V8 isolate is terminated and `{:error,
  %Tyrex.Error{name: :timeout}}` is returned. The `GenServer.call` timeout is the
  deadline plus a 1s grace, which covers scheduler jitter — but not GenServer
  *occupancy*: `arm_deadline/3` runs inside `handle_call`, so a caller queued
  behind a blocking eval has no deadline armed while its own call timeout runs
  out, and still exits `:timeout` rather than receiving an error tuple.
- Termination is a one-way door: a runtime that hits its deadline or heap cap
  is dead and is replaced, never reused. V8 termination is uncatchable and
  sticky, so a "recovered" isolate would be a silent brick.
- `stop/1`'s `:timeout` now defaults to `5_000` instead of `:infinity`, and
  escalates to a kill rather than hanging forever on a wedged runtime.
- `eval_blocking` moved from `DirtyCpu` to `DirtyIo` — it parks on a channel,
  which is I/O-shaped waiting, not compute.
- `blocking: true` is now refused with `:unsupported_option` when the `:apply`
  bridge is enabled, or when `:timeout` is `:infinity`.
- Aligned the rustler pair: Elixir `~> 0.38.0` and the Rust crate `=0.38.0`, the
  latter pinned with `=` and carrying the `nif_version_2_16` feature. Note only
  those are pinned: the `NIF_VERSION` label in the release workflow and the
  `nif_versions:` list in `lib/tyrex/native.ex` are kept in agreement by hand.

### Added

- `Tyrex.kill/0,1` — interrupt a runtime that is wedged inside a guest that
  never yields. `while (true) {}` cannot be stopped cooperatively, only
  terminated.
- `:max_heap_mb` option capping the V8 heap. Without it a guest that exhausts
  memory `abort()`s the entire BEAM; with it the guest is terminated and the
  caller gets `%Tyrex.Error{name: :heap_limit_error}`.
- New `Tyrex.Error` names: `:timeout`, `:heap_limit_error`,
  `:unsupported_option`.
- `Tyrex.Native.terminate_runtime/1`, and `@spec`s on all NIF stubs (there were
  none).
- `Tyrex.Pool` forwards `:apply` and `:max_heap_mb` to every runtime.

### Fixed

- **Dynamic `import()` bypassed every read permission, and `deny_import` was
  inert.** Under `permissions: :none`, `Deno.readTextFileSync("/etc/passwd")` was
  denied while `import("file:///etc/passwd", {with: {type: "json"}})` returned the
  parsed file — a documented control that did nothing. The module loader now
  checks a dynamic `file:` import against read permissions and a dynamic
  non-`file:` import against `allow_import`/`deny_import`. The module named by
  `:main_module_path` and its static import graph remain exempt: they are
  operator-supplied and loaded once at bootstrap, which is the same
  static-versus-dynamic specifier distinction Deno makes internally.
- **`:apply` authorization trusted a guest-writable runtime id.** `op_apply` read
  the id from `Tyrex._runtimeId` on the JS global, so guest code could name
  another runtime and have that runtime's allowlist authorize the call. The id
  now lives in per-runtime `OpState`, unreachable from JavaScript, and
  `Tyrex._runtimeId` is gone.
- **Runaway programs leaked a 100%-CPU OS thread for the life of the VM.**
  `stop/1` returning `:ok` was not evidence of reclamation: it killed the Elixir
  process while the per-runtime thread kept spinning. Measured at 299.6% CPU
  with three runaways after every runtime was stopped and every Elixir process
  was dead. Because this is not a dirty scheduler, the leak was uncapped by
  `dirty_cpu_schedulers` and invisible to BEAM scheduler-utilization
  monitoring. The runtime resource now terminates the isolate on drop, so the
  thread is reclaimed even on a brutal kill. Covered by a regression test that
  asserts CPU returns to baseline.
- **The near-heap-limit callback could outlive the state it pointed into.** The
  `Arc` holding the callback state was declared after the worker, so on
  `worker::new`'s error paths it was freed while the isolate still held a raw
  pointer into it. The hand-rolled callback is replaced by
  `JsRuntime::add_near_heap_limit_callback`, which owns the boxed closure in a
  field declared to outlive the isolate — no raw pointer, no `unsafe`, and no
  drop-order invariant for the next refactor to break silently.
- **A small `:max_heap_mb` aborted the entire BEAM at `Tyrex.start/1`** — exactly
  what the option exists to prevent. The callback cannot be armed before the
  isolate exists, so Deno's bootstrap and snapshot deserialization, the heaviest
  allocation phase in a runtime's life, always run under V8's default `abort()`.
  Measured on arm64 macOS with V8 146.4.0: 13 MB aborts inside bootstrap, 14 MB
  boots reliably. `:max_heap_mb` now has a floor of 32 MB — roughly 2.3x the
  measured minimum, because the failure mode is loss of the whole node — and
  smaller values are rejected with a message naming both numbers.
- Panics on the worker thread no longer leak a runtime slot and hang callers.
  The worker runs on a bare `std::thread::spawn`, outside rustler's
  `catch_unwind`, so a panic — `serde_v8` unwrapping an empty `MaybeLocal` under
  a pending termination, for instance — skipped both the slab removal and the
  drain of pending promises. The worker body is now wrapped in `catch_unwind` so
  that cleanup runs either way. This release made termination asynchronous and
  arbitrary, where it was previously observed only between operations.
- **`blocking: true` deadlocked permanently against the bridge.** `handle_call`
  parked in the NIF while `op_apply` needed that same GenServer; the call timed
  out and the runtime was then unusable forever. The blocking receive is now
  bounded and the combination is refused outright.
- **Permission parsing failed open.** Malformed JSON or an unexpected shape fell
  back to `PermissionsContainer::allow_all` while reporting success. It now
  returns an error and the runtime refuses to start.
- **`allow_x: false` was inverted under `allow_all: true`.** The explicit denial
  parsed to `None` and was then swallowed by the `allow_all` default, re-granting
  unrestricted access.
- **`allow_read: []` granted the whole filesystem.** An empty allowlist now
  grants nothing, matching what it reads like.
- **`false` was documented as "deny all" for all sixteen permission keys.** True
  for the eight `allow_*` keys, inverted for the eight `deny_*`, where
  `deny_read: false` denies nothing and the read succeeds. The docs now split by
  direction: `false` is the absence of a rule in whichever direction the key
  names, and an empty list allows nothing but denies nothing.
- Unknown permission keys were silently dropped, so `[deny_nett: true]` yielded
  a permissive runtime reporting success. They now raise `ArgumentError`, as do
  non-string list entries and malformed values.
- Non-string entries in a permission list were silently filtered out, quietly
  widening the grant.
- `apply_reply` matched only `{:ok, {}}`, so a dead worker raised a `MatchError`
  and took the GenServer down with an unhelpful reason.
- An allowlisted Elixir function that raises now rejects the JavaScript promise
  instead of destroying the runtime.
- The blocking-eval path replied before stopping on a dead runtime; it
  previously stopped without replying, leaving the caller blocked until its own
  call timeout.
- The GenServer now tracks in-flight requests, so a timeout can be attributed to
  the request that caused it and every other in-flight caller is told the
  runtime died under it.
- `native/tyrex/.cargo/config.toml` is now packaged. It was missing from
  `mix.exs` `package.files` while the README sends Alpine/musl and NixOS users
  to a source build, so the documented install path was broken from Hex.
- The crate now enables rustler's `nif_version_2_16` feature, so the binaries
  match the `nif-2.16` label they have carried since v0.3.0. rustler removed
  env-var NIF selection in 0.30 — it is a Cargo feature now, and `rustler-0.38.0`
  defaults to `nif_version_2_15` — so `rustler = "=0.38.0"` with no `features`
  compiled against 2.15 while every artifact name said 2.16.
  `RUSTLER_NIF_VERSION` was inert everywhere it appeared, including in
  `release.yml`; that plumbing is deleted rather than kept and described as a fix.
- Releases are now all-or-nothing. Each matrix leg published its own archive
  with `if: always()` and `fail-fast: false`, so three of four targets could
  ship against a four-entry checksum file.

### Security scope

Bridge-off-by-default, a permission-checked module loader, a real kill, and a
heap cap close the known holes. The one deliberate exemption is the module named
by `:main_module_path` and its static imports, which load regardless of
`:permissions` because they are operator-supplied. None of this makes tyrex an
audited sandbox boundary: the runtime is in-process, so a V8 escape is a BEAM
compromise. For a hard boundary against untrusted code, run Deno out of process.

## v0.3.0 (2026-05-23)

### Added

- New `:startup_timeout` option for `Tyrex.start/1` and `Tyrex.start_link/1`
  (defaults to 30s); the GenServer init callback now returns
  `{:stop, :nif_startup_timeout}` if the NIF does not acknowledge in time.
- New `examples/error_handling.exs` demonstrating pattern-matching on
  `Tyrex.Error` (`:execution_error`, `:promise_rejection`,
  `:conversion_error`, `:dead_runtime_error`) and on `Tyrex.eval!` raising.
- New `examples/least_loaded.exs` implementing the LeastLoaded custom
  `Tyrex.Pool.Strategy` from the README as a real runnable script.
- New `examples/ink_tui/` example demonstrating terminal UI rendering.
- Documented the `deny_import` permission key (always supported by the Rust
  side; previously missing from Elixir docs and the README permission table).

### Changed

- `Tyrex.eval!/1,2` and `Tyrex.Pool.eval!/2,3` now raise `Tyrex.Error` on
  failure instead of crashing with `MatchError`.
- `Tyrex.Pool.Strategy.RoundRobin`'s first selection now returns index `0`
  (previously `1`). The counter is now seeded at `size - 1` so the first
  `update_counter/3` wraps to `0`.
- `Tyrex.Pool` is now supervised as `:rest_for_one` with a dedicated internal
  registry GenServer that owns the `:persistent_term` entry and the strategy
  state so they get cleaned up on supervisor shutdown.
- Tightened the `mix.exs` package description.

### Fixed

- ~16 panic sites in the Rust NIF and Deno worker event loop (BEAM crash
  risk) replaced with proper error propagation or best-effort logging.
- Pending promises now receive a `:dead_runtime_error` reply when the
  worker shuts down — callers no longer hang on `Tyrex.stop/1`.
- `Tyrex.Pool` now erases its `:persistent_term` entry and invokes the
  strategy's `terminate/1` callback (cleaning up ETS tables for
  `RoundRobin`) on supervisor shutdown, so create/destroy cycles no
  longer leak VM state.
- Recover from mutex poisoning in the Rust runtime registry rather than
  panicking on `lock().unwrap()`.
- The Rust→JS apply-reply path now dispatches via a JS bridge function
  (`Tyrex._applyReply`) instead of `format!`-interpolating
  attacker-influenceable values into a `Tyrex._applications[...].fn(...)`
  expression.
- The `~JS` sigil now raises a `CompileError` for unknown modifiers
  (previously silently ignored).
- The `Tyrex` GenServer now has a configurable startup timeout (default 30s)
  instead of hanging forever on the inner `receive`.
- `[allow_all: true, deny_X: true]` now actually honors the deny overrides —
  the Rust permission parser used to short-circuit to `allow_all` and ignore
  any sibling `deny_*` keys, contradicting the README's documented pattern.
- Removed false "TypeScript main module" claim from the README and dropped
  the (broken) `examples/typescript/`. The default `FsModuleLoader` does not
  transpile `.ts` files; first-class TypeScript module loading is tracked
  for a future release. JavaScript (`.js`) main modules continue to work.

## v0.2.1 (2026-03-15)

### Fixed

- Fixed precompiled NIF archive packaging — files inside tar.gz are now named
  to match RustlerPrecompiled convention (`libtyrex-v{version}-nif-2.16-{target}.so`)
- Fixed CI: V8 source builds now work on all targets (tolerate bindgen failure,
  use pre-generated bindings from rusty_v8 releases)
- Replaced `philss/rustler-precompiled-action` with manual cargo build + tar
  (action installed cross even with `use-cross: false`)
- Fixed macOS runner: `macos-13` deprecated, switched to `macos-15`
- Fixed LLVM 19 → 20 in docker-build.sh Phase 2

### Changed

- NIF version 2.15 → 2.16 (requires OTP 27+)
- Removed Windows (`x86_64-pc-windows-msvc`) target (not building it)
- Upgraded Deno embedded runtime to v2.7.5 (see v0.2.0 for Deno changelog)

### Deno 2.7.5 highlights

- `deno compile` improvements with npm/jsr package support
- `deno init --npm vite` scaffolding
- `deno task` supports `dependencies` field for task ordering
- `Temporal` API support (behind `--unstable-temporal`)
- Node.js compatibility improvements (http2, worker_threads, async_hooks)
- V8 engine upgraded to 14.6

## v0.2.0 (2026-03-11)

### Changed

- Upgraded embedded Deno runtime to v2.7.5
  - deno_core 0.330.0 → 0.391.0
  - deno_runtime 0.194.0 → 0.246.0
  - deno_fs 0.96.0 → 0.148.0
  - deno_resolver 0.17.0 → 0.69.0
  - serde_v8 0.239.0 → 0.300.0
  - sys_traits 0.1.7 → 0.1.24
- Relaxed serde version pin

## v0.1.0 (2026-03-08)

Initial release.

### Features

- **Embedded Deno runtime** — Full Deno JS/TS runtime embedded in Elixir via Rustler NIFs
- **JavaScript & TypeScript evaluation** — `Tyrex.eval/1,2` with automatic promise awaiting
- **Blocking & async modes** — Choose NIF-blocking (fast, <1ms) or async eval
- **Bidirectional calls** — Call Elixir functions from JavaScript via `Tyrex.apply()`
- **Module loading** — Import ES modules with `import`/`export`, load main modules at startup
- **`~JS` sigil** — Write JavaScript inline in Elixir code with `Tyrex.Sigil`
- **`Tyrex.Inline`** — Process-local runtime binding with `set_runtime/1` and `with_runtime/2`
- **Granular permissions** — Control network, filesystem, env, subprocess, FFI, and system access per runtime
- **Runtime pool** — `Tyrex.Pool` supervisor with pluggable dispatch strategies:
  - `RoundRobin` (default) — Lock-free ETS atomic counter
  - `Random` — Random runtime selection
  - `Hash` — Key-based sticky sessions
- **Named runtimes** — Add Tyrex to supervision trees with `start_link/1`
- **Deno APIs** — `fetch`, `Deno.readTextFile`, `setTimeout`, Node.js compatibility, and more

### Precompiled binaries

- `aarch64-apple-darwin`
- `aarch64-unknown-linux-gnu`
- `x86_64-apple-darwin`
- `x86_64-pc-windows-msvc`
- `x86_64-unknown-linux-gnu`
