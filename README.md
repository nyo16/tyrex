# Tyrex

Embedded [Deno](https://deno.com) JavaScript/TypeScript runtime for Elixir via [Rustler](https://github.com/rusterlium/rustler) NIFs.

Tyrex lets you execute JavaScript and TypeScript directly from Elixir without external processes. It embeds the full Deno runtime — including `fetch`, `Deno.*` APIs, Node.js compatibility, and ES module support — as a native extension.

## Features

- **Full Deno runtime** — `fetch`, `Deno.readTextFile`, `setTimeout`, Promises, etc.
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

To build from source (instead of using precompiled binaries), set the environment variable:

```bash
export TYREX_BUILD=true
```

## Quick Start

### Single Runtime

```elixir
# Start a runtime
{:ok, pid} = Tyrex.start()

# Evaluate JavaScript
{:ok, 3} = Tyrex.eval("1 + 2", pid: pid)
{:ok, "HELLO"} = Tyrex.eval("'hello'.toUpperCase()", pid: pid)

# Async/Promises work automatically
{:ok, result} = Tyrex.eval("""
  new Promise(resolve => setTimeout(() => resolve("done"), 100))
""", pid: pid)

# Access Deno APIs
{:ok, version} = Tyrex.eval("Deno.version", pid: pid)
{:ok, cwd} = Tyrex.eval("Deno.cwd()", pid: pid)

# Stop when done
Tyrex.stop(pid: pid)
```

### Named Runtime (for supervision trees)

```elixir
# In your application.ex
children = [
  {Tyrex, name: MyApp.JS, main_module_path: "priv/js/app.js"}
]

# Anywhere in your app
{:ok, result} = Tyrex.eval("processData()", name: MyApp.JS)
```

### Calling Elixir from JavaScript

```elixir
{:ok, pid} = Tyrex.start()

# Call any Elixir function from JS
{:ok, 6} = Tyrex.eval("""
  (async () => await Tyrex.apply("Enum", "sum", [[1, 2, 3]]))()
""", pid: pid)

{:ok, "HELLO"} = Tyrex.eval("""
  (async () => await Tyrex.apply("String", "upcase", ["hello"]))()
""", pid: pid)

# Erlang modules use colon prefix
{:ok, 3} = Tyrex.eval("""
  (async () => await Tyrex.apply(":erlang", "length", [[1, 2, 3]]))()
""", pid: pid)
```

### Module Loading

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

For concurrent workloads, use `Tyrex.Pool` to manage multiple isolated runtimes with pluggable dispatch strategies.

### Basic Pool

```elixir
# In your supervision tree
children = [
  {Tyrex.Pool, name: :js_pool, size: 4}
]

# Evaluate — requests are distributed via round-robin
{:ok, result} = Tyrex.Pool.eval(:js_pool, "computeExpensive()")
```

### Strategies

#### Round-Robin (default)

Cycles through runtimes sequentially. Lock-free via ETS atomic counters.

```elixir
{Tyrex.Pool, name: :pool, size: 4}
# equivalent to:
{Tyrex.Pool, name: :pool, size: 4, strategy: Tyrex.Pool.Strategy.RoundRobin}
```

#### Random

Selects a random runtime. Good for bursty workloads.

```elixir
{Tyrex.Pool, name: :pool, size: 4, strategy: Tyrex.Pool.Strategy.Random}
```

#### Hash

Routes requests by key — same key always hits the same runtime. Useful for stateful JS sessions.

```elixir
{Tyrex.Pool, name: :pool, size: 4, strategy: Tyrex.Pool.Strategy.Hash}

# Same user always hits the same runtime
Tyrex.Pool.eval(:pool, "getCart()", key: user_id)
```

#### Custom Strategy

Implement the `Tyrex.Pool.Strategy` behaviour:

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

{Tyrex.Pool, name: :pool, size: 4, strategy: MyApp.LeastLoaded}
```

### Pool with Shared Module

All runtimes in a pool can share the same main module:

```elixir
{Tyrex.Pool,
  name: :ssr,
  size: 4,
  main_module_path: "priv/js/ssr/server.js"}

{:ok, html} = Tyrex.Pool.eval(:ssr, "renderToString(#{Jason.encode!(props)})")
```

## Examples

See the `examples/` directory:

- **`examples/basic.exs`** — Single runtime: arithmetic, strings, Deno APIs, async, bidirectional calls
- **`examples/pool.exs`** — Pool usage: round-robin, hash strategy, concurrent eval
- **`examples/data_processing.exs`** — CSV parsing, statistics, URL parsing, HTML sanitization
- **`examples/phoenix_ssr/`** — SSR-like template rendering with a pool

Run any example:

```bash
TYREX_BUILD=true mix run examples/basic.exs
```

## API Reference

### Core

| Function | Description |
|----------|-------------|
| `Tyrex.start/0,1` | Start an unlinked runtime |
| `Tyrex.start_link/1` | Start a linked/named runtime |
| `Tyrex.stop/0,1` | Stop a runtime |
| `Tyrex.eval/1,2` | Evaluate JS code, returns `{:ok, result}` or `{:error, %Tyrex.Error{}}` |
| `Tyrex.eval!/1,2` | Same as `eval`, but raises on error |

### Pool

| Function | Description |
|----------|-------------|
| `Tyrex.Pool.start_link/1` | Start a pool supervisor |
| `Tyrex.Pool.eval/2,3` | Evaluate on a pool-selected runtime |
| `Tyrex.Pool.eval!/2,3` | Same as `eval`, but raises on error |

### Options

| Option | `eval` | `Pool.eval` | Description |
|--------|--------|-------------|-------------|
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

On macOS, the system `libffi` is used automatically. On Linux, you may need `libffi-dev`:

```bash
# Ubuntu/Debian
sudo apt-get install libffi-dev
```

## License

MIT
