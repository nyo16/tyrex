# Tyrex

[![Hex.pm](https://img.shields.io/hexpm/v/tyrex.svg)](https://hex.pm/packages/tyrex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/tyrex)

Embedded [Deno](https://deno.com) JavaScript runtime for Elixir via [Rustler](https://github.com/rusterlium/rustler) NIFs.

Execute JavaScript directly from Elixir — no external processes, no shelling out. Tyrex embeds the full Deno runtime as a native extension, giving you `fetch`, `Deno.*` APIs, Node.js compatibility, ES modules, and more.

## Features

- **Full Deno runtime** — `fetch`, `Deno.readTextFile`, `setTimeout`, Promises, etc.
- **Inline `~JS` sigil** — Write JavaScript directly in your Elixir code
- **Deny-by-default permissions** — Deno I/O is denied unless you grant it
- **Opt-in Elixir bridge** — Call Elixir from JavaScript via `Tyrex.apply()`, restricted to an explicit MFA allowlist
- **Real deadlines** — `:timeout` terminates the V8 isolate instead of abandoning the call
- **Module loading** — Import ES modules with `import`/`export`
- **Runtime pool** — Pool of Deno runtimes with pluggable dispatch strategies
- **Blocking & async modes** — Choose between NIF-blocking (fast, <1ms) or async eval
- **Node.js APIs** — `node:path`, `node:buffer`, `node:crypto`, etc.

## Installation

Add `tyrex` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tyrex, "~> 0.4.0"}
  ]
end
```

To build from source (instead of using precompiled binaries):

```bash
export TYREX_BUILD=true
mix deps.get && mix compile
```

### Upgrading from 0.3.x

v0.4.0 is a breaking release with three changes that need no code rewrite, only a
decision:

- `permissions:` now defaults to `:none` instead of `:allow_all`. If your JS
  needs file, network, or environment access, grant it explicitly — passing
  `permissions: :allow_all` restores the old behaviour verbatim.
- The `Tyrex.apply()` JS→Elixir bridge is now off by default. If your JS calls
  back into Elixir, pass an `:apply` allowlist (see
  [Calling Elixir from JavaScript](#bidirectional-calling-elixir-from-javascript)).
- Dynamic `import()` is now permission-checked: a `file:` specifier against read
  permissions, anything else against `allow_import`/`deny_import`. Guest code that
  imported files under a restrictive permission set was previously never checked
  and is now denied — grant `allow_read` for the paths it needs. The module named
  by `:main_module_path` and its static imports are unaffected.

All three are covered in detail below.

## Quick Start

```elixir
# Start a runtime — permissions default to :none, so Deno I/O is denied
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

## Error handling

The `Tyrex.eval/1,2` API returns `{:error, %Tyrex.Error{}}` on failure. The
error's `:name` field tags what went wrong; `:message` is human-readable and
`:value` carries any associated payload (e.g. the rejected promise value).

```elixir
case Tyrex.eval(code, pid: pid) do
  {:ok, result} ->
    result

  {:error, %Tyrex.Error{name: :execution_error, message: msg}} ->
    # JS/TS syntax error or thrown exception during synchronous code
    Logger.warning("JS execution failed: #{msg}")

  {:error, %Tyrex.Error{name: :promise_rejection, value: reason}} ->
    # A returned promise rejected; `reason` is the decoded rejection value
    {:error, {:js_rejected, reason}}

  {:error, %Tyrex.Error{name: :conversion_error, message: msg}} ->
    # A value could not round-trip between Elixir and JS
    {:error, {:bad_value, msg}}

  {:error, %Tyrex.Error{name: :timeout}} ->
    # The deadline expired; the isolate was terminated and this runtime is dead
    {:error, :js_timeout}

  {:error, %Tyrex.Error{name: :heap_limit_error}} ->
    # The guest exceeded `:max_heap_mb`; this runtime is dead
    {:error, :js_out_of_memory}

  {:error, %Tyrex.Error{name: :unsupported_option}} ->
    # e.g. `blocking: true` against a runtime with the apply bridge enabled
    {:error, :bad_options}

  {:error, %Tyrex.Error{name: :dead_runtime_error}} ->
    # The runtime is gone (crashed or stopped mid-call) — restart and retry
    {:error, :runtime_down}
end
```

For exception-style flow, the `Tyrex.eval!/1,2` (and `Tyrex.Pool.eval!/2,3`)
variants raise the `Tyrex.Error` directly on failure.

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

Tyrex runtimes are deny-by-default: unless you pass `:permissions`, the runtime
starts with no file, network, environment, subprocess, FFI, or system access.

> **Breaking change in v0.4.0.** The `:permissions` default changed from
> `:allow_all` to `:none`. The migration is one line:
>
> ```elixir
> Tyrex.start(permissions: :allow_all)
> ```
>
> Omitting `:permissions` logs a one-time warning, so the flip is not silent.

### Permission Presets

```elixir
# No Deno I/O at all — computation only (default)
Tyrex.start(permissions: :none)

# Full access — equivalent to deno run -A
Tyrex.start(permissions: :allow_all)
```

### Granular Permissions

Each permission accepts `true`, `false`, or a list of specific values. The same
literal means opposite things in the two directions, so read the key name before
the value:

- `allow_x: true` grants `x` without restriction. `allow_x: false` grants
  nothing. `allow_x: []` also grants nothing — an empty allowlist is zero paths
  or hosts, not all of them.
- `deny_x: true` denies `x` everywhere. `deny_x: false` denies nothing, and is
  not a denial: `deny_read: false` reads the file. `deny_x: []` likewise denies
  nothing.

In short, an empty list allows nothing but denies nothing, and `false` is the
absence of a rule in whichever direction the key names.

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
| `allow_read` | `deny_read` | File system reads (`Deno.readTextFile`, dynamic `import()` of a `file:` specifier, etc.) |
| `allow_write` | `deny_write` | File system writes (`Deno.writeTextFile`, etc.) |
| `allow_env` | `deny_env` | Environment variables (`Deno.env`) |
| `allow_run` | `deny_run` | Subprocess execution (`Deno.Command`) |
| `allow_ffi` | `deny_ffi` | Foreign function interface |
| `allow_sys` | `deny_sys` | System info (hostname, OS, memory, etc.) |
| `allow_import` | `deny_import` | Dynamic ES module imports of non-`file:` specifiers (`https:` and friends) |

### Dynamic `import()` vs. the main module

Module loading is permission-checked, but only for the loads guest code can
initiate:

- A dynamic `import()` of a `file:` specifier is checked against read
  permissions and reported as an `import()` read denial. Under
  `permissions: :none` it fails; under `permissions: [allow_read: ["/tmp/x"]]`
  the same import of `/tmp/x` succeeds.
- A dynamic `import()` of a non-`file:` specifier is checked against
  `allow_import` / `deny_import`, so `deny_import: true` blocks `https:` imports.
- The module named by `:main_module_path` and its static import graph are exempt.
  They are operator-supplied and loaded once at bootstrap, so
  `Tyrex.start(permissions: :none, main_module_path: "priv/js/app.js")` starts
  and that module's own `import` statements resolve. This is the same
  static-versus-dynamic specifier distinction Deno makes internally.

That exemption is the operator's boundary to hold. Pointing
`:main_module_path` at code a guest can write hands that code a read of its own
static imports — but it is the same trust the main module already has, since it
runs first in the same isolate with whatever `:apply` allowlist the runtime was
given.

Before this was enforced, `import()` read any file the BEAM user could read
under any permission set: `permissions: :none` denied
`Deno.readTextFileSync("/etc/passwd")` while
`import("file:///etc/passwd", {with: {type: "json"}})` returned the parsed file,
and `deny_import` was inert.

### Fail-Closed Parsing

Permission handling no longer guesses:

- A malformed or unexpectedly shaped permission payload makes the runtime refuse
  to start. It never degrades to allow-all.
- `allow_X: false` denies `X` even alongside `allow_all: true`.
- `allow_read: []` means "no paths", not "the whole filesystem".
- An unknown or misspelled permission key raises `ArgumentError` instead of being
  silently dropped.

Each of these behaved the opposite way in v0.3.x, so a typo like
`[deny_nett: true]` produced a fully permissive runtime that reported success.

### Pool with Permissions

Permissions apply to all runtimes in a pool:

```elixir
# SSR pool — only allow reading templates
{Tyrex.Pool,
  name: :ssr,
  size: 4,
  permissions: [allow_read: ["priv/templates"]],
  main_module_path: "priv/js/ssr.js"}
```

### What `permissions:` Covers

`permissions:` governs **Deno I/O only** — `fetch`, `Deno.readTextFile`,
`Deno.env`, `Deno.Command`, FFI and friends. It has never governed which Elixir
functions JavaScript can reach.

Under v0.3.x, with `permissions: :none`:

```javascript
Deno.readTextFileSync("mix.exs");                  // denied, as documented
await Tyrex.apply("File", "read!", ["mix.exs"]);   // succeeded — arbitrary read
await Tyrex.apply(":os", "cmd", [["id"]]);         // succeeded — shell execution
```

The `Tyrex.apply` bridge is a privileged capability and is unaffected by
`:permissions`. That is why it is now off by default and allowlisted when on —
see [Calling Elixir from JavaScript](#bidirectional-calling-elixir-from-javascript).

### Security Recommendations

- **Leave the bridge off.** If you need it, pass the narrowest `:apply`
  allowlist that works, and treat every entry as a capability handed to the guest
- **SSR / templating**: allow only `allow_read` for template directories
- **API proxying**: allow only `allow_net` with specific hosts
- **Always deny** `allow_run` and `allow_ffi` unless you specifically need
  subprocess or FFI access
- **Set `:max_heap_mb` and a `:timeout`** on any runtime evaluating code you did
  not write
- **Use a fresh runtime per unit of work** and discard it afterwards, rather than
  sharing one long-lived runtime across inputs

### Security Scope

Deny-by-default permissions, an off-by-default allowlisted bridge, a real kill,
and a heap cap close the holes described above. They do **not** constitute an
audited sandbox boundary, and none of them make Tyrex safe for untrusted or
model-authored JavaScript:

- JS runs in-process. A V8 or Deno vulnerability is a BEAM compromise, and Tyrex
  adds no layer between the two.
- Nothing here has been audited or fuzzed as a security boundary.
- `:max_heap_mb` bounds the V8 heap, not the OS process. CPU, sockets, and file
  descriptors are not quota'd, and a single allocation far exceeding the cap can
  still abort the node — see [`:max_heap_mb`](#max_heap_mb).
- `import()` is permission-checked only for the loads guest code initiates. The
  module named by `:main_module_path` and its static imports load regardless of
  `:permissions` — see [Dynamic `import()` vs. the main
  module](#dynamic-import-vs-the-main-module).
- **stdio is inherited from the host process and is not permissioned.** Deno's
  permission model does not govern file descriptors 0/1/2, so guest code under
  `permissions: :none` can write to the node's stdout — forging log lines — and
  read its stdin, which on an attached `iex` is the operator's keyboard.

If you need a hard security boundary for code you do not control, run Deno
out-of-process: a separate OS process you can confine with the operating system
and kill without taking the BEAM with it. An embedded NIF cannot offer the same
guarantee, and this README will not claim otherwise.

## Timeouts, Termination & Memory Limits

### `:timeout` is a real deadline

`:timeout` on `Tyrex.eval/1,2` and `Tyrex.Pool.eval/2,3` is a wall-clock
deadline, not just a `GenServer.call` timeout. On expiry Tyrex terminates the V8
isolate via `v8::IsolateHandle::terminate_execution()` and the call returns:

```elixir
{:error, %Tyrex.Error{name: :timeout}} =
  Tyrex.eval("for (;;) {}", pid: pid, timeout: 100)
```

In v0.3.x the caller gave up while the JavaScript kept running, burning a native
thread that outlived `Tyrex.stop/1`.

**Terminate means dead means restart.** V8 termination is uncatchable and leaves
the isolate unusable, so a terminated runtime is never reused:

```elixir
{:error, %Tyrex.Error{name: :dead_runtime_error}} = Tyrex.eval("1 + 1", pid: pid)
```

Start a fresh runtime. Under a supervision tree the runtime is replaced
automatically. Under a `Tyrex.Pool` it is replaced without disturbing its
siblings, but a caller whose runtime died mid-call still has to retry, and a
call that arrives during the restart window gets
`{:error, %Tyrex.Error{name: :dead_runtime_error}}`.

### `Tyrex.kill/0,1`

`Tyrex.kill/1` terminates a runtime immediately, without waiting for in-flight
JavaScript. It is not a pause or a reset — the same terminate-means-dead contract
applies, and there is no resume. `Tyrex.stop/1` remains the graceful shutdown.

```elixir
:ok = Tyrex.kill(pid: pid)
:ok = Tyrex.kill(name: MyApp.JS)
```

### `:max_heap_mb`

`:max_heap_mb` caps the V8 heap for a runtime:

```elixir
{:ok, pid} = Tyrex.start(max_heap_mb: 256)
```

Without it, a guest that exhausts the heap reaches V8's OOM handler, which calls
`abort()` and takes the entire BEAM node down. With it, a near-heap-limit
callback terminates the guest and gives V8 headroom to unwind, so the caller gets
`{:error, %Tyrex.Error{name: :heap_limit_error}}` instead. The runtime is dead
afterwards.

> #### `:max_heap_mb` does not cover every OOM {: .warning}
>
> It converts *incremental* heap growth into `:heap_limit_error` — an allocation
> loop, a growing accumulator, the usual shapes. It cannot save the node from a
> **single allocation far larger than the cap**: `new Array(1e9).fill(1)` still
> aborts the BEAM at caps of 32, 64 and 128 MB. V8 termination only takes effect
> at an interrupt check, and a builtin like `fill` never reaches one, so the
> guest is inside C++ when the heap runs out and V8 aborts before tyrex can act.
> Verified on arm64 macOS with V8 146.4.0. This is a V8 limitation, not a
> configuration mistake, and no `:max_heap_mb` value avoids it. Treat the cap as
> protection against gradual exhaustion, not as a guarantee that guest code
> cannot kill the node.

The minimum is 32 MB. The near-heap-limit callback cannot be armed until the
isolate exists, so Deno's bootstrap and snapshot deserialization — the heaviest
allocation phase in a runtime's life — always run under V8's default `abort()`.
Measured on arm64 macOS with V8 146.4.0, `max_heap_mb: 13` aborts the BEAM inside
bootstrap and 14 boots reliably; the floor sits well above the measured minimum
because the failure mode is loss of the whole node. Smaller values are rejected
at `Tyrex.start/1` rather than risked.

`Tyrex.Pool` forwards `:max_heap_mb`, `:permissions`, `:apply`,
`:startup_timeout` and `:main_module_path` to every runtime in the pool.

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

JavaScript can call Elixir functions through `Tyrex.apply()`, but the bridge is
**off by default** and, when enabled, restricted to an explicit allowlist of
`{Module, :function, arity}` tuples. There is no "call any Elixir function" mode.

```elixir
{:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}, {String, :upcase, 1}])

# Enum.sum([1, 2, 3])
{:ok, 6} = Tyrex.eval(~s"""
(async () => await Tyrex.apply("Enum", "sum", [[1, 2, 3]]))()
""", pid: pid)

# String.upcase("hello")
{:ok, "HELLO"} = Tyrex.eval(~s"""
(async () => await Tyrex.apply("String", "upcase", ["hello"]))()
""", pid: pid)
```

Erlang modules use a colon prefix from JavaScript and plain atoms in the
allowlist:

```elixir
{:ok, pid} = Tyrex.start(apply: [{:erlang, :length, 1}])

# :erlang.length([1, 2, 3])
{:ok, 3} = Tyrex.eval(~s"""
(async () => await Tyrex.apply(":erlang", "length", [[1, 2, 3]]))()
""", pid: pid)
```

### Denied calls

Any MFA outside the allowlist is rejected. The JS promise rejects with a string
beginning `permission_denied:`, which surfaces in Elixir as a
`:promise_rejection`:

```elixir
{:ok, pid} = Tyrex.start(apply: [{Enum, :sum, 1}])

{:error, %Tyrex.Error{name: :promise_rejection, value: reason}} =
  Tyrex.eval(~s"""
  (async () => await Tyrex.apply("File", "read!", ["mix.exs"]))()
  """, pid: pid)

true = String.starts_with?(reason, "permission_denied:")
```

JavaScript can catch it like any rejection:

```javascript
try {
  await Tyrex.apply("File", "read!", ["mix.exs"]);
} catch (e) {
  // e is a string starting with "permission_denied:"
}
```

The allowlist is enforced in Elixir, inside the runtime's GenServer — not in
JavaScript. A JS-side check would sit inside the blast radius of the code it is
meant to contain. Matching arity alone is not authorization: the module and
function must be in the list.

With `apply: false` (the default) the bridge is never installed and
`globalThis.Tyrex` is deleted after bootstrap, so guest JavaScript holds no
reference to it at all:

```elixir
{:ok, pid} = Tyrex.start()
{:ok, "undefined"} = Tyrex.eval("typeof globalThis.Tyrex", pid: pid)
```

### The bridge is not governed by `:permissions`

`:permissions` restricts Deno I/O and says nothing about Elixir reachability.
`permissions: :none` with `apply: [{File, :read!, 1}]` gives JavaScript file
reads with the BEAM's own OS privileges. The allowlist is the only control here.

### `blocking: true` is rejected when the bridge is enabled

`blocking: true` deadlocks against the bridge: the runtime parks inside the NIF
waiting for the eval to finish, while `op_apply` needs that same GenServer to
service the call. Rather than hang, Tyrex rejects the combination with
`{:error, %Tyrex.Error{name: :unsupported_option}}`. Use async eval (the default)
with the bridge, and keep `blocking: true` for bridge-free hot paths.

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

The main module and its static imports load regardless of `:permissions`; a
dynamic `import()` from guest code does not — see [Dynamic `import()` vs. the
main module](#dynamic-import-vs-the-main-module).

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

`Tyrex.Pool` cleans up its `:persistent_term` entry and any
strategy-owned ETS tables on supervisor shutdown, so it is safe to start and
stop pools dynamically (e.g. one pool per tenant) without leaking VM state.

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
| `examples/pool.exs` | Round-robin, hash strategy, concurrent runs |
| `examples/data_processing.exs` | CSV parsing, statistics, URL parsing, HTML sanitization |
| `examples/error_handling.exs` | Pattern-matching `Tyrex.Error` for execution, rejection, permission, and dead-runtime failures |
| `examples/least_loaded.exs` | Custom `Tyrex.Pool.Strategy` that routes to the runtime with the shortest mailbox |
| `examples/phoenix_ssr/ssr_example.exs` | SSR-like template rendering with a pool |
| `examples/ink_tui/tui_example.exs` | Terminal UI rendering with ANSI colors, tables, and progress bars |

## API Reference

### Core

| Function | Description |
|----------|-------------|
| `Tyrex.start/0,1` | Start an unlinked runtime |
| `Tyrex.start_link/1` | Start a linked/named runtime (for supervision trees) |
| `Tyrex.stop/0,1` | Stop a runtime |
| `Tyrex.kill/0,1` | Terminate the isolate immediately; the runtime is then dead |
| `Tyrex.eval/1,2` | Evaluate JS, returns `{:ok, result}` or `{:error, %Tyrex.Error{}}` |
| `Tyrex.eval!/1,2` | Same as `eval`, raises `Tyrex.Error` on error |

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
| `Tyrex.Pool.eval!/2,3` | Same as `eval`, raises `Tyrex.Error` on error |

### Runtime Options (`Tyrex.start/1`, `Tyrex.start_link/1`)

| Option | Default | Description |
|--------|---------|-------------|
| `:permissions` | `:none` | Deno I/O permissions — `:none`, `:allow_all`, or a granular keyword list |
| `:apply` | `false` | `false`, or a list of `{Module, :function, arity}` tuples callable from JS |
| `:max_heap_mb` | unset | Cap the V8 heap, in MB (minimum 32) |
| `:main_module_path` | unset | ES module loaded at startup |
| `:name` | unset | Register the runtime under a name |

`Tyrex.Pool` accepts `:permissions`, `:apply`, `:max_heap_mb`,
`:startup_timeout` and `:main_module_path` and forwards them to every runtime it
starts. It also takes `:max_restarts` / `:max_seconds` for the runtime children.

### Eval Options

| Option | `eval` | `Pool.eval` | Description |
|--------|:------:|:-----------:|-------------|
| `:pid` | x | | Target runtime PID |
| `:name` | x | | Target runtime name |
| `:blocking` | x | x | Use blocking NIF call (fast, <1ms only); rejected when `:apply` is enabled |
| `:timeout` | x | x | Wall-clock deadline (default: 5000ms); on expiry the isolate is terminated and the runtime is dead |
| `:key` | | x | Dispatch key (for hash strategy) |

## Precompiled Binaries

Tyrex ships precompiled NIFs for these platforms — no Rust toolchain needed:

| Platform | Target |
|----------|--------|
| macOS Apple Silicon | `aarch64-apple-darwin` |
| macOS Intel | `x86_64-apple-darwin` |
| Linux x86_64 (glibc) | `x86_64-unknown-linux-gnu` |
| Linux ARM64 (glibc) | `aarch64-unknown-linux-gnu` |

Precompiled binaries require **OTP 27+** (NIF version 2.16), which is what the
`nif-2.16` in each archive name refers to. The NIF level is selected by the
`nif_version_2_16` Cargo feature on the crate's `rustler` dependency — rustler
removed environment-variable selection in 0.30, so `RUSTLER_NIF_VERSION` has had
no effect since then and setting it changes nothing.

### Platforms requiring source build

If your platform is not listed above, you'll need to build from source:

- **Linux musl** (Alpine, NixOS)
- **Windows**
- **FreeBSD / OpenBSD**
- **Linux 32-bit, RISC-V, or other architectures**

## Building from Source

Requires Rust 1.92+ and LLVM 20:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
export TYREX_BUILD=true
mix deps.get
mix compile
```

> **Note:** The first build takes ~30-60 minutes because V8 is compiled from source.

On macOS, the system `libffi` is used automatically. On Linux, install build dependencies:

```bash
# Ubuntu/Debian
sudo apt-get install libffi-dev pkg-config libglib2.0-dev

# Fedora
sudo dnf install libffi-devel
```

## Releasing

The order of these four steps is load-bearing:

1. Tag the version already in `mix.exs` and push the tag. The `Precomp NIFs`
   workflow builds all four targets and attaches the archives to the GitHub
   release.
2. Regenerate the checksum file from the published archives, via the
   `checksums.after_release` alias:

   ```bash
   TYREX_BUILD=true mix checksums.after_release
   # runs: mix rustler_precompiled.download Tyrex.Native --all --print
   ```

   `TYREX_BUILD=true` is needed because the checksum map for the new version
   does not exist yet, so `Tyrex.Native` cannot load a precompiled artifact and
   has to build from source.
3. Commit the regenerated `checksum-Elixir.Tyrex.Native.exs`.
4. `mix hex.publish`. It is aliased to run a guard first, which aborts the
   publish if the checksum file has no entry for the current `@version` — step 2
   is not optional and will not be skipped silently.

The sequence cannot be permuted: step 2 downloads exactly what step 1 published,
and step 4 ships the checksum map step 2 writes. Publishing before regenerating
is the failure that matters. `RustlerPrecompiled` resolves the archive name for
the consumer's platform, finds no entry for it in the packaged checksum map, and
raises *before* it makes any network call — so every precompiled user of that
release fails identically at compile time whether or not the tag and its
artifacts exist, and the only remedy is another release.

## Acknowledgements

Tyrex is inspired by [deno_rider](https://github.com/aglundahl/deno_rider), which pioneered the approach of embedding the Deno runtime in Elixir via Rustler NIFs. Tyrex builds on the same proven architecture while adding a runtime pool with pluggable dispatch strategies, an inline `~JS` sigil, granular deny-by-default permissions, real execution deadlines, and an allowlisted bidirectional Elixir/JS bridge.

## License

Apache-2.0 — see [LICENSE](LICENSE) for details.
