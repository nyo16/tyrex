# Changelog

## v0.3.0 (2026-05-23)

### Added

- New `:startup_timeout` option for `Tyrex.start/1` and `Tyrex.start_link/1`
  (defaults to 30s); `Tyrex.init/1` now returns
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
- `Tyrex.Pool` is now supervised as `:rest_for_one` with a dedicated
  `Tyrex.Pool.Registry` GenServer that owns the `:persistent_term` entry
  and the strategy state.
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
