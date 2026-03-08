# Changelog

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
