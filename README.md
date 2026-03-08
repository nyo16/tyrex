# Tyrex

[![Hex.pm](https://img.shields.io/hexpm/v/tyrex.svg)](https://hex.pm/packages/tyrex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/tyrex)

Embedded [Deno](https://deno.com) JavaScript/TypeScript runtime for Elixir via [Rustler](https://github.com/rusterlium/rustler) NIFs.

Execute JavaScript and TypeScript directly from Elixir — no external processes, no shelling out. Tyrex embeds the full Deno runtime as a native extension, giving you `fetch`, `Deno.*` APIs, Node.js compatibility, ES modules, and more.

## Features

- **Full Deno runtime** — `fetch`, `Deno.readTextFile`, `setTimeout`, Promises, etc.
- **Inline `~JS` sigil** — Write JavaScript directly in your Elixir code
- **TypeScript support** — Run `.ts` files as main modules
- **Bidirectional calls** — Call Elixir functions from JavaScript via `Tyrex.apply()`
- **Module loading** — Import ES modules with `import`/`export`
- **Runtime pool** — Pool of Deno runtimes with pluggable dispatch strategies
- **Blocking & async modes** — Choose between NIF-blocking (fast, <1ms) or async eval
- **Node.js APIs** — `node:path`, `node:buffer`, `node:crypto`, etc.

## Installation

Add `tyrex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tyrex, "~> 0.1.0"}
  ]
end
```

To build from source (instead of using precompiled binaries):

```bash
export TYREX_BUILD=true
mix deps.get && mix compile
```

## Quick Start

```elixir
# Start a runtime
{:ok, pid} = Tyrex.start()

# Evaluate JavaScript
{:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
{:ok, "HELLO"} = Tyrex.eval("'hello'.toUpperCase()", pid: pid)

# Promises are awaited automatically
{:ok, "done"} = Tyrex.eval("Promise.resolve('done')", pid: pid)

# Deno APIs
{:ok, version} = Tyrex.eval("Deno.version", pid: pid)

# Stop when done
Tyrex.stop(pid: pid)
```

## Inline `~JS` Sigil

Write JavaScript directly in Elixir with the `~JS` sigil. Since `~JS` is a raw sigil (no Elixir interpolation), JS template literals work naturally:

```elixir
import Tyrex.Sigil

{:ok, pid} = Tyrex.start()
Tyrex.Inline.set_runtime(pid)

{:ok, 3} = ~JS"1 + 2"
{:ok, "Value: 42"} = ~JS"`Value: ${40 + 2}`"

# Multi-line
{:ok, [2, 4, 6]} = ~JS"""
const arr = [1, 2, 3];
arr.map(n => n * 2)
"""
```

To pass Elixir values into JavaScript, use `Tyrex.Inline.eval/1` with standard string interpolation:

```elixir
x = 10
{:ok, 15} = Tyrex.Inline.eval("#{x} + 5")

name = "world"
{:ok, "Hello, world!"} = Tyrex.Inline.eval("'Hello, #{name}!'")
```

Use `with_runtime/2` for scoped runtime binding:

```elixir
Tyrex.Inline.with_runtime(pid, fn ->
  {:ok, 42} = ~JS"21 * 2"
end)
# runtime binding is restored after the block
```

## Permissions & Security

By default, Tyrex runtimes have full access to everything (like running `deno run -A`). You can restrict what JavaScript can do by passing a `:permissions` option.

### Permission Presets

```elixir
# Full access (default) — equivalent to deno run -A
Tyrex.start(permissions: :allow_all)

# No I/O at all — pure computation only (safe for untrusted code)
Tyrex.start(permissions: :none)
```

### Granular Permissions

Each permission accepts `true` (allow all), `false` (deny all), or a list of specific allowed values:

```elixir
# Allow network and file reads only
Tyrex.start(permissions: [
  allow_net: true,
  allow_read: true
])

# Restrict to specific hosts and paths
Tyrex.start(permissions: [
  allow_net: ["api.example.com:443", "cdn.example.com:443"],
  allow_read: ["/app/priv", "/tmp"],
  allow_write: ["/tmp"],
  allow_env: ["HOME", "PATH", "NODE_ENV"]
])

# Allow everything except subprocess execution and FFI
Tyrex.start(permissions: [
  allow_all: true,
  deny_run: true,
  deny_ffi: true
])
```

### Available Permission Keys

| Allow | Deny | Controls |
|-------|------|----------|
| `allow_net` | `deny_net` | Network access (`fetch`, `Deno.connect`, etc.) |
| `allow_read` | `deny_read` | File system reads (`Deno.readTextFile`, etc.) |
| `allow_write` | `deny_write` | File system writes (`Deno.writeTextFile`, etc.) |
| `allow_env` | `deny_env` | Environment variables (`Deno.env`) |
| `allow_run` | `deny_run` | Subprocess execution (`Deno.Command`) |
| `allow_ffi` | `deny_ffi` | Foreign function interface |
| `allow_sys` | `deny_sys` | System info (hostname, OS, memory, etc.) |
| `allow_import` | — | Dynamic ES module imports |

### Pool with Permissions

Permissions apply to all runtimes in a pool:

```elixir
# Sandboxed SSR pool — only allow reading templates
{Tyrex.Pool,
  name: :ssr,
  size: 4,
  permissions: [allow_read: ["priv/templates"]],
  main_module_path: "priv/js/ssr.js"}
```

### Security Recommendations

- **Untrusted code**: Use `permissions: :none` for user-submitted JavaScript
- **SSR / templating**: Allow only `allow_read` for template directories
- **API proxying**: Allow only `allow_net` with specific hosts
- **Always deny** `allow_run` and `allow_ffi` unless you specifically need subprocess or FFI access

## Named Runtimes

Add Tyrex to your supervision tree:

```elixir
# application.ex
children = [
  {Tyrex, name: MyApp.JS, main_module_path: "priv/js/app.js"}
]

# Anywhere in your app
{:ok, result} = Tyrex.eval("processData()", name: MyApp.JS)
```

## Bidirectional: Calling Elixir from JavaScript

JavaScript code can call any Elixir function via `Tyrex.apply()`:

```elixir
{:ok, pid} = Tyrex.start()

# Enum.sum([1, 2, 3])
{:ok, 6} = Tyrex.eval(~s"""
(async () => await Tyrex.apply("Enum", "sum", [[1, 2, 3]]))()
""", pid: pid)

# String.upcase("hello")
{:ok, "HELLO"} = Tyrex.eval(~s"""
(async () => await Tyrex.apply("String", "upcase", ["hello"]))()
""", pid: pid)

# Erlang modules use colon prefix — :erlang.length([1, 2, 3])
{:ok, 3} = Tyrex.eval(~s"""
(async () => await Tyrex.apply(":erlang", "length", [[1, 2, 3]]))()
""", pid: pid)
```

## Module Loading

```javascript
// priv/js/math.js
export function fibonacci(n) {
  if (n <= 1) return n;
  let a = 0, b = 1;
  for (let i = 2; i <= n; i++) [a, b] = [b, a + b];
  return b;
}
```

```javascript
// priv/js/app.js
import { fibonacci } from "./math.js";
globalThis.fib = fibonacci;
```

```elixir
{:ok, pid} = Tyrex.start(main_module_path: "priv/js/app.js")
{:ok, 55} = Tyrex.eval("fib(10)", pid: pid)
```

## Runtime Pool

`Tyrex.Pool` manages multiple isolated runtimes and distributes work across them with pluggable strategies.

```elixir
# In your supervision tree
children = [
  {Tyrex.Pool, name: :js_pool, size: 4}
]

# Evaluate — distributed via round-robin by default
{:ok, result} = Tyrex.Pool.eval(:js_pool, "1 + 1")
```

### Strategies

**Round-Robin** (default) — cycles sequentially, lock-free via ETS atomic counters:

```elixir
{Tyrex.Pool, name: :pool, size: 4}
```

**Random** — picks a random runtime, good for bursty workloads:

```elixir
{Tyrex.Pool, name: :pool, size: 4, strategy: Tyrex.Pool.Strategy.Random}
```

**Hash** — same key always hits the same runtime, for stateful JS sessions:

```elixir
{Tyrex.Pool, name: :pool, size: 4, strategy: Tyrex.Pool.Strategy.Hash}

# Same user always hits the same runtime
Tyrex.Pool.eval(:pool, "getCart()", key: user_id)
```

**Custom** — implement the `Tyrex.Pool.Strategy` behaviour:

```elixir
defmodule MyApp.LeastLoaded do
  @behaviour Tyrex.Pool.Strategy

  def init(pool_name, size), do: {pool_name, size}

  def select({pool_name, size}, _opts) do
    0..(size - 1)
    |> Enum.min_by(fn i ->
      :"#{pool_name}.Runtime.#{i}"
      |> Process.whereis()
      |> Process.info(:message_queue_len)
      |> elem(1)
    end)
  end
end
```

### Pool with Shared Module

All runtimes load the same main module:

```elixir
# SSR example
{Tyrex.Pool, name: :ssr, size: 4, main_module_path: "priv/js/ssr/server.js"}

{:ok, html} = Tyrex.Pool.eval(:ssr, "renderToString(#{Jason.encode!(props)})")
```

## Examples

Run any example with `TYREX_BUILD=true mix run examples/<file>`:

| Example | Description |
|---------|-------------|
| `examples/basic.exs` | Arithmetic, strings, Deno APIs, async, bidirectional calls |
| `examples/pool.exs` | Round-robin, hash strategy, concurrent eval |
| `examples/data_processing.exs` | CSV parsing, statistics, URL parsing, HTML sanitization |
| `examples/phoenix_ssr/ssr_example.exs` | SSR-like template rendering with a pool |

## API Reference

### Core

| Function | Description |
|----------|-------------|
| `Tyrex.start/0,1` | Start an unlinked runtime |
| `Tyrex.start_link/1` | Start a linked/named runtime (for supervision trees) |
| `Tyrex.stop/0,1` | Stop a runtime |
| `Tyrex.eval/1,2` | Evaluate JS, returns `{:ok, result}` or `{:error, %Tyrex.Error{}}` |
| `Tyrex.eval!/1,2` | Same as `eval`, raises on error |

### Inline

| Function | Description |
|----------|-------------|
| `~JS"code"` | Evaluate raw JS (no interpolation) on the process-local runtime |
| `~JS"code"b` | Same, but in blocking mode |
| `Tyrex.Inline.eval/1,2` | Evaluate JS string (supports interpolation) |
| `Tyrex.Inline.set_runtime/1` | Set runtime for current process |
| `Tyrex.Inline.with_runtime/2` | Scoped runtime binding |

### Pool

| Function | Description |
|----------|-------------|
| `Tyrex.Pool.start_link/1` | Start a pool supervisor |
| `Tyrex.Pool.eval/2,3` | Evaluate on a pool-selected runtime |
| `Tyrex.Pool.eval!/2,3` | Same as `eval`, raises on error |

### Options

| Option | `eval` | `Pool.eval` | Description |
|--------|:------:|:-----------:|-------------|
| `:pid` | x | | Target runtime PID |
| `:name` | x | | Target runtime name |
| `:blocking` | x | x | Use blocking NIF call (fast, <1ms only) |
| `:timeout` | x | x | GenServer call timeout (default: 5000ms) |
| `:key` | | x | Dispatch key (for hash strategy) |

## Building from Source

Requires Rust toolchain (1.70+):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
export TYREX_BUILD=true
mix deps.get
mix compile
```

On macOS, the system `libffi` is used automatically. On Linux, install `libffi-dev`:

```bash
sudo apt-get install libffi-dev   # Ubuntu/Debian
sudo dnf install libffi-devel     # Fedora
```

## License

MIT
