# Changelog

## v0.2.1 (2026-03-14)

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
- Added `deny_import` permission option
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
