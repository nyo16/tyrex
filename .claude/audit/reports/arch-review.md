# Architecture & Code-Structure Audit — tyrex

Scope: Elixir layer (`lib/**`, `mix.exs`) + the Elixir↔Rust NIF boundary (`native/tyrex/src/lib.rs` surface only). DB/schema/web/LiveView architecture criteria are **N/A** — tyrex is a NIF library with no Ecto, no repo, no web layer, and no application callback module.

## Score: 41/100

Start 100.

| Bucket (max) | Deductions | Left |
|---|---|---|
| Module boundaries respected (25, −5 each) | −5 strategy resources created inside `Supervisor.init/1`; −5 GenServer `from` tuple crosses the NIF into Rust; −5 `{Tyrex.Pool, name}` persistent_term key written by `Registry` / read by `Pool` with no owning accessor | 10/25 |
| Naming consistency (15, −3 each) | −3 `Tyrex.Runtime` names a struct, not the runtime process; −3 `Tyrex.Pool.Registry` is not a registry; −3 `function_exists?/3` returns `:ok \| {:error, binary}` | 6/15 |
| Over-coupled / god module (15, −5 each) | −5 `Tyrex` fuses facade + GenServer + apply-bridge + permissions DSL; −5 `Tyrex.Pool` fuses supervision + strategy lifecycle + dispatch + name derivation | 5/15 |
| Bloated / duplicated API surface (15, −5 per module) | −5 `Tyrex` (4 of 9 public functions are pure arity duplication; three parallel `eval` front doors with different resolution rules) | 10/15 |
| Missing `@spec`/`@doc` or inconsistent error contract (15, −3 each, cap −15) | 7 issues × −3 = −21, **capped at −15** | 0/15 |
| Folder/namespace + packaged native tree (15, −5 each) | −5 packaged native tree ≠ on-disk native tree (`.cargo/config.toml` omitted); module↔path layout itself is clean | 10/15 |

**Total: 41/100.**

No module exceeds ~30 public functions (largest is `Tyrex` with 9), so the ">30 public functions" trigger never fires. No name/arity drift was found at the NIF surface.

## Findings

### [HIGH] Pool strategy state is not re-initialized on Registry restart — a Registry crash permanently breaks dispatch

- Location: `lib/tyrex/pool.ex:62`, `lib/tyrex/pool.ex:66-74`, `lib/tyrex/pool/registry.ex:46`, `lib/tyrex/pool/strategy/round_robin.ex:11-19,31-34`
- Evidence:
  ```elixir
  # pool.ex:62 — runs ONCE, in the supervisor process
  strategy_state = strategy_mod.init(name, size)
  # pool.ex:66-72 — the state is frozen into the child spec args
  {Tyrex.Pool.Registry, %{name: name, size: size, strategy_mod: strategy_mod, strategy_state: strategy_state}}
  # registry.ex:46 — a child deletes the resource on every terminate
  strategy_mod.terminate(strategy_state)
  # round_robin.ex:31-33
  def terminate({table, _size}) do
    :ets.delete(table)
  ```
  and the stated intent, `pool.ex:86-87`:
  ```elixir
  # `:rest_for_one` ensures a Registry crash takes down the runtime children
  # so the supervisor rebuilds them with a fresh persistent_term entry.
  ```
- Impact: `strategy_mod.init/2` is only called from `Tyrex.Pool.init/1`, which runs only when the **supervisor** starts. If the Registry alone crashes, its `terminate/2` (reachable — `Process.flag(:trap_exit, true)` is set at `registry.ex:22`) deletes the RoundRobin ETS table, then `:rest_for_one` restarts the Registry **with the same frozen `strategy_state`** and re-publishes a handle to a table that no longer exists. Every subsequent `Tyrex.Pool.eval/3` then hits `:ets.update_counter/3` on a dead table id and raises `ArgumentError` for the lifetime of the supervisor. The persistent_term entry is refreshed; the strategy state it points at is not. Default pools use RoundRobin, so this is the default path.
- Fix: move `strategy_mod.init(name, size)` into `Tyrex.Pool.Registry.init/1` (it already receives `strategy_mod` and `size`), and store the returned state in the Registry's GenServer state. Restart then rebuilds the table, the owner of the resource is the same process that frees it, and `Tyrex.Pool.init/1` goes back to doing nothing but building child specs.

### [HIGH] `Supervisor.init/1` creates and owns non-supervision resources

- Location: `lib/tyrex/pool.ex:62`
- Evidence:
  ```elixir
  strategy_state = strategy_mod.init(name, size)
  ```
  with `round_robin.ex:12`: `table = :ets.new(:"#{pool_name}.RoundRobin", [:public, :set])`
- Impact: the ETS table (and anything a third-party strategy allocates — a table, a process, a port) is owned by the **pool supervisor process**, while `Tyrex.Pool.Registry` is documented as the thing "responsible for cleaning it up" (`registry.ex:2-4`). Ownership and release live in different processes, so the moduledoc guarantee at `pool.ex:27-31` ("cleaned up automatically … without leaking persistent_term or ETS resources") holds only by accident: on a clean pool stop the owning supervisor dies anyway, which is what actually reclaims the table. A supervisor callback that allocates side-effecting resources also breaks the "supervisors only supervise" rule and makes `init/1` non-idempotent.
- Fix: same as above — allocate in the Registry. Keep `Tyrex.Pool.init/1` pure.

### [HIGH] Hex package omits `native/tyrex/.cargo/config.toml`, breaking the documented musl/Alpine source build

- Location: `mix.exs:36-49`
- Evidence:
  ```elixir
  files: [
    "checksum-Elixir.Tyrex.Native.exs", "CHANGELOG.md", "LICENSE", "lib",
    "native/tyrex/Cargo.toml", "native/tyrex/Cargo.lock", "native/tyrex/Cross.toml",
    "native/tyrex/src", "native/tyrex/extension", "mix.exs", "priv/main.js", "README.md"
  ],
  ```
  On disk the native tree also contains `native/tyrex/.cargo/config.toml`:
  ```toml
  [target.x86_64-unknown-linux-musl]
  rustflags = ["-C", "target-feature=-crt-static"]
  [target.aarch64-unknown-linux-musl]
  rustflags = ["-C", "target-feature=-crt-static"]
  ```
  and `README.md:407,418` directs exactly those users to build from source:
  ```
  - **Linux musl** (Alpine, NixOS)
  export TYREX_BUILD=true
  ```
- Impact: `Tyrex.Native`'s `targets:` list (`native.ex:11-16`) publishes no musl artifact, so Alpine/NixOS users *must* take the `TYREX_BUILD=true` path — and from a Hex install the one file that carries the required `-crt-static` rustflags is absent, reproducing the linker failure the config exists to prevent. `Dockerfile.aarch64-unknown-linux-gnu` is likewise unpackaged (cosmetic — it is release tooling, not a build input).
- Fix: add `"native/tyrex/.cargo"` to `package.files`. Verify with `mix hex.build --unpack` that the unpacked native tree builds under `TYREX_BUILD=true`.

### [HIGH] `Tyrex.init/1` blocks for up to `startup_timeout + 1_000` ms; pool boot is serialized

- Location: `lib/tyrex.ex:242-282`
- Evidence:
  ```elixir
  task = Task.async(fn ->
    :ok = Native.start_runtime(pid, ..., encode_permissions(...))
    receive do
      {:ok, reference} -> {:ok, %Runtime{reference: reference}}
      error -> error
    after startup_timeout -> {:error, :nif_startup_timeout} end
  end)
  result = Task.await(task, startup_timeout + 1_000)
  ```
- Impact: `init/1` blocks the caller — i.e. the parent supervisor's start sequence — for up to 31 s per runtime by default. `Tyrex.Pool` starts `System.schedulers_online()` runtimes as ordinary sequential supervisor children (`pool.ex:76-82`), so a degraded NIF stalls application boot for `size × 31 s` with nothing observable in between. Secondary hazard: `:ok = Native.start_runtime(...)` at `tyrex.ex:248` is a hard match inside a linked `Task`, so a non-`:ok` return surfaces as a `MatchError` exit propagated from the Task rather than the documented `{:stop, :nif_startup_timeout}` shape (`tyrex.ex:70-72`).
- Fix: return `{:ok, %{reference: nil, pending: ...}, {:continue, :start_runtime}}` and handle the NIF's `{:ok, reference}` / `{:error, _}` in `handle_continue/handle_info`, with a `Process.send_after/3` deadline instead of `Task.await`. This also removes the `Task` (whose only job is to provide a clean mailbox for the `receive`) and lets a pool start its runtimes concurrently.

### [MEDIUM] `:dead_runtime_error` is documented as matchable but is never returned — callers get an `exit` instead

- Location: `lib/tyrex.ex:291-292`, `lib/tyrex.ex:337-338`, contract at `lib/tyrex/error.ex:12-13`
- Evidence:
  ```elixir
  # tyrex.ex:291
  {:error, %Error{name: :dead_runtime_error}} ->
    {:stop, {:shutdown, :dead_runtime_error}, state}
  # tyrex.ex:337 (async path) — same, and the pending `from` is never replied to
  ```
  vs `error.ex:12-13`:
  ```
  * `:dead_runtime_error` — The underlying runtime is no longer alive
    (e.g. crashed or was stopped while a call was in flight)
  ```
- Impact: the server stops **without replying**, so the in-flight `GenServer.call` in `Tyrex.eval/2` exits with `{{:shutdown, :dead_runtime_error}, {GenServer, :call, [...]}}` in the caller. The `@spec` at `tyrex.ex:204` promises `{:error, Error.t()}` and the docs promise a matchable `:name`; neither is deliverable for the one error a caller most wants to handle. `Tyrex.eval!/2`'s `case` (`tyrex.ex:235-238`) never sees it either, so `eval!` raises `exit`, not `Tyrex.Error`.
- Fix: reply before stopping — `{:stop, {:shutdown, :dead_runtime_error}, {:error, error}, state}` in `handle_call/3`, and `GenServer.reply(from, {:error, error})` before `{:stop, ...}` in `handle_info/2`. Restarting under the pool supervisor still self-heals.

### [MEDIUM] `Jason.decode!/encode!` inside GenServer callbacks converts data errors into runtime crashes; documented `:conversion_error` is unreachable

- Location: `lib/tyrex.ex:289`, `lib/tyrex.ex:305`, `lib/tyrex.ex:334`, `lib/tyrex.ex:354`, `lib/tyrex.ex:399,409,413`
- Evidence:
  ```elixir
  # tyrex.ex:305 — payload built by JS
  decoded_args = Jason.decode!(args)
  # tyrex.ex:354 — rejection value from JS
  {:error, %{e | value: Jason.decode!(e.value)}}
  ```
- Impact: any malformed or unexpected JSON on the wire raises inside the runtime GenServer, killing the runtime and every in-flight caller, instead of producing the `:conversion_error` that `error.ex:10-11` advertises. Grep shows the Elixir layer never constructs `:conversion_error` at all, so a documented member of the error union is dead.
- Fix: use `Jason.decode/1` at these boundaries and map failures to `%Tyrex.Error{name: :conversion_error, message: ...}`; keep `decode!` only for values the Rust side has already validated.

### [MEDIUM] `{:ok, {}} = Native.apply_reply(...)` hard match kills the runtime when the worker is gone

- Location: `lib/tyrex.ex:320-325`, NIF contract at `native/tyrex/src/lib.rs:161-175`
- Evidence:
  ```elixir
  {:ok, {}} =
    Native.apply_reply(state.reference, application_id, result)
  ```
  ```rust
  fn apply_reply(...) -> Result<(), error::Error> {
      resource.worker_sender.send(...).or(Err(error::Error { name: atoms::dead_runtime_error(), .. }))
  ```
- Impact: `apply_reply` legitimately returns `{:error, %Error{name: :dead_runtime_error}}` when the worker died while an Elixir callback was running. The match then raises `MatchError` in `handle_info/2`, so a normal, expected race becomes a crash with a misleading reason instead of a clean `{:stop, {:shutdown, :dead_runtime_error}, state}`.
- Fix: `case Native.apply_reply(...) do :ok-shape -> {:noreply, state}; {:error, %Error{name: :dead_runtime_error}} -> {:stop, {:shutdown, :dead_runtime_error}, state} end`.

### [MEDIUM] Bare `rescue _` + `catch _, _` swallows every strategy-cleanup failure

- Location: `lib/tyrex/pool/registry.ex:44-52`
- Evidence:
  ```elixir
  if function_exported?(strategy_mod, :terminate, 1) do
    try do
      strategy_mod.terminate(strategy_state)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
  ```
- Impact: this is the only place a leaked ETS table, port, or process would announce itself. A `KeyError`/`FunctionClauseError` from a custom strategy, or a double-delete of the RoundRobin table, is silently discarded — so the moduledoc's "no leaks" claim (`pool.ex:27-31`) cannot be falsified in production. `:logger` is declared in `mix.exs:25` yet grep shows **zero** `Logger.` calls in `lib/`; this is the site that most needs one.
- Fix: narrow to the expected failure (`rescue e in ArgumentError`), drop the bare `catch`, and `Logger.warning("Tyrex.Pool strategy cleanup failed: ...")` on the way out.

### [MEDIUM] `Tyrex.Inline.eval/2` raises an untyped `RuntimeError`, contradicting its own `@spec`

- Location: `lib/tyrex/inline.ex:77-81`
- Evidence:
  ```elixir
  @spec eval(binary(), Keyword.t()) :: {:ok, term()} | {:error, Tyrex.Error.t()}
  def eval(code, opts \\ []) do
    case Process.get(@runtime_key) do
      nil ->
        raise "No Tyrex runtime set for this process. Call Tyrex.Inline.set_runtime/1 first."
  ```
- Impact: the spec omits `no_return()`, so dialyzer is misled, and the `~JS` sigil (which expands to this function, `sigil.ex:76`) raises a bare `RuntimeError` that cannot be matched alongside every other Tyrex failure (`%Tyrex.Error{}`). Three error styles now coexist for the same operation: struct tuple (`Tyrex.eval/2`), raised `Tyrex.Error` (`eval!`), raised `RuntimeError` (`Inline.eval/2`).
- Fix: `raise Tyrex.Error, name: :no_runtime, message: "..."` (adding `:no_runtime` to the `error.ex` union) and correct the spec to include `no_return()`.

### [MEDIUM] `Tyrex.Pool.eval/3` raises `ArgumentError` for an unknown pool despite promising an error tuple

- Location: `lib/tyrex/pool.ex:100-103`
- Evidence:
  ```elixir
  @spec eval(atom(), binary(), Keyword.t()) :: {:ok, term()} | {:error, Tyrex.Error.t()}
  def eval(pool_name, code, opts \\ []) do
    %{strategy_mod: mod, strategy_state: state} =
      :persistent_term.get({__MODULE__, pool_name})
  ```
- Impact: a typo'd or not-yet-started pool name raises `ArgumentError` from `:persistent_term.get/1` — the single most likely user error in the pool API is the one case the declared contract does not cover. (Deduction capped; counted in the contract bucket.)
- Fix: `:persistent_term.get(key, :error)` and return `{:error, %Tyrex.Error{name: :no_such_pool, message: "..."}}`, or document the raise and add `no_return()`.

### [MEDIUM] Unvalidated opts bag: a stray `:pid` silently defeats pool dispatch

- Location: `lib/tyrex/pool.ex:106` + `lib/tyrex.ex:207`
- Evidence:
  ```elixir
  # pool.ex:106 — merges the caller's opts, keeping any :pid they passed
  Tyrex.eval(code, Keyword.merge(opts, name: :"#{pool_name}.Runtime.#{index}"))
  # tyrex.ex:207 — :pid unconditionally wins over :name
  Keyword.get(opts, :pid) || Keyword.get(opts, :name, __MODULE__)
  ```
- Impact: `Tyrex.Pool.eval(:pool, code, pid: some_pid)` runs `mod.select/2`, computes an index, then throws the result away and dispatches to `some_pid`. The docs at `tyrex.ex:124-126` state `:name` and `:pid` "can't be provided" together, but nothing enforces it, and no option key is ever validated: the whole `opts` list is forwarded into the GenServer message (`tyrex.ex:208`) where only `:blocking` is read, so `blockign: true` or `timout: 1` are silently ignored. Related: `:size` is unvalidated at `pool.ex:58`, so `size: 0` yields the decreasing range `0..-1` at `pool.ex:77` and builds children named `…Runtime.0` / `…Runtime.-1` [INFERENCE — derived from Elixir range semantics, not executed], while `Tyrex.Pool.Strategy` declares `size :: pos_integer()`.
- Fix: validate at each entry point — reject `:pid` together with `:name`, require `is_integer(size) and size > 0`, and `Keyword.take/2` the server message down to the keys the server actually reads (`:blocking`).

### [MEDIUM] GenServer `from` tuple is passed through the NIF into Rust

- Location: `lib/tyrex.ex:298`, `lib/tyrex.ex:331`, `native/tyrex/src/lib.rs:101-137`
- Evidence:
  ```elixir
  :ok = Native.eval(from, state.reference, code)          # tyrex.ex:298
  def handle_info({:eval_reply, from, result}, state) do   # tyrex.ex:331
  ```
  ```rust
  fn eval(env: Env, from: rustler::Term, resource: ..., code: String) -> rustler::Atom {
      let mut from_env = rustler::OwnedEnv::new();
      let saved_from = from_env.save(from);
  ```
- Impact: an OTP implementation detail (`{pid, ref}` reply tag) becomes part of the Rust worker's ABI, and it is opaque to the Elixir side too: `Tyrex`'s state is only `%Runtime{reference: ref}` (`runtime.ex:23`), so the GenServer keeps **no record of in-flight evaluations**. Nothing can be introspected, cancelled, or failed on shutdown; when a caller's 5 s `GenServer.call` timeout (`tyrex.ex:209`) fires first, the late `GenServer.reply/2` is a silent no-op and the work is discarded with no accounting.
- Fix: pass an opaque monotonic request id across the NIF and keep a `%{id => from}` map in the GenServer state; reply by lookup. The Rust side then depends only on "an integer I hand back", and `terminate/2` can fail every pending caller with `:dead_runtime_error`.

### [MEDIUM] `Tyrex` is a god module: facade + GenServer + JS→Elixir apply bridge + permissions DSL

- Location: `lib/tyrex.ex:304-328`, `lib/tyrex.ex:361-394`, `lib/tyrex.ex:396-414`
- Evidence:
  ```elixir
  # apply bridge — reflection + arity checking + JSON, ~55 lines
  defp function_exists?(module, function_name, arity) do
  defp to_module(string) do
  defp to_atom(string) do
  # permissions DSL serialization, 4 clauses
  defp encode_permissions(:allow_all), do: ~s("allow_all")
  defp encode_permissions(opts) when is_list(opts) do
  ```
- Impact: three unrelated concerns share one module and one test surface. The permissions DSL is the module's largest documented feature (`tyrex.ex:74-102`) and has its own 147-line test file, yet has no module of its own; the apply bridge is a dynamic-dispatch mechanism (`String.to_existing_atom` → `apply/3`) that a reviewer must find buried under GenServer callbacks. Every change to either concern touches the file that also defines the public API.
- Fix: extract `Tyrex.Permissions.encode/1` (pure, directly testable) and `Tyrex.Bridge.apply/1` (takes the decoded request, returns `{:ok, json} | {:error, reason}`). `Tyrex` keeps the facade + the four GenServer callbacks.

### [MEDIUM] `Tyrex.Pool` mixes supervision, strategy lifecycle, dispatch, and name derivation

- Location: `lib/tyrex/pool.ex:56-89` vs `lib/tyrex/pool.ex:101-107`
- Evidence:
  ```elixir
  strategy_state = strategy_mod.init(name, size)                                   # lifecycle
  Supervisor.init([registry_child | runtime_children], strategy: :rest_for_one)    # supervision
  index = mod.select(state, opts)                                                  # dispatch
  Tyrex.eval(code, Keyword.merge(opts, name: :"#{pool_name}.Runtime.#{index}"))    # naming
  ```
- Impact: this is the most coupled file in the project (4 outgoing xref deps) because it is four things at once. The runtime-name convention `:"<pool>.Runtime.<i>"` is re-derived from string interpolation in three places — `pool.ex:79` (registration), `pool.ex:106` (lookup), and `strategy.ex:15-17` (the documented custom-strategy example) — with no single function owning the mapping, so any change to the scheme silently breaks lookup or user strategies.
- Fix: add `defp runtime_name(pool_name, index)`, expose it as a public `Tyrex.Pool.runtime_name/2` since custom strategies demonstrably need it, and move strategy `init`/`terminate` into the Registry so `Tyrex.Pool` is supervision + dispatch only.

### [MEDIUM] No `@spec` on any of the five NIF stubs — the least type-checked boundary is the least specified

- Location: `lib/tyrex/native.ex:27`, `:35`, `:42`, `:50`, `:57`
- Evidence:
  ```elixir
  def start_runtime(_pid, _main_module_path, _permissions_json),
    do: :erlang.nif_error(:nif_not_loaded)
  def eval_blocking(_reference, _code), do: :erlang.nif_error(:nif_not_loaded)
  ```
- Impact: every function here is documented in prose but has no machine-checked signature, so dialyzer cannot verify a single call site in `Tyrex` — including the `{:ok, {}}` match at `tyrex.ex:320` and the `%Runtime{reference: ref}` handle threading. At an FFI boundary where the callee is compiled by another toolchain, specs are the only contract the compiler can hold onto.
- Fix: add specs mirroring the Rust signatures, e.g. `@spec eval_blocking(reference(), binary()) :: {:ok, binary()} | {:error, Tyrex.Error.t()}` and `@spec apply_reply(reference(), binary(), {:ok, binary()} | {:error, binary()}) :: {:ok, {}} | {:error, Tyrex.Error.t()}`.

### [LOW] Pool metadata key `{Tyrex.Pool, name}` is written by one module and read by another with no accessor

- Location: `lib/tyrex/pool/registry.ex:24` vs `lib/tyrex/pool.ex:103`, erase at `registry.ex:40`
- Evidence:
  ```elixir
  :persistent_term.put({Tyrex.Pool, name}, %{...})   # registry.ex:24 — hardcoded literal
  :persistent_term.get({__MODULE__, pool_name})      # pool.ex:103 — different spelling
  ```
- Impact: mildest of the boundary issues, but the key shape and the map's keys (`:size`, `:strategy_mod`, `:strategy_state`) are duplicated across two modules with `:size` written and never read. Renaming the key or the struct requires a grep, not a compile error.
- Fix: one private module owning the key — `Tyrex.Pool.Meta.put/2`, `fetch/1`, `erase/1` — and drop the unused `:size` field or use it to validate `select/2`'s return.

### [LOW] Naming: `Tyrex.Runtime` is a struct, not the runtime; `Tyrex.Pool.Registry` is not a registry; `function_exists?/3` is not a predicate

- Location: `lib/tyrex/runtime.ex:1-25`, `lib/tyrex/pool/registry.ex:1-18`, `lib/tyrex.ex:371-377`
- Evidence:
  ```elixir
  defmodule Tyrex.Runtime do          # a 1-field struct; the runtime *process* is `Tyrex`
  defmodule Tyrex.Pool.Registry do    # no lookup/register/dispatch; owns one persistent_term key
  defp function_exists?(module, function_name, arity) do
    if function_exported?(module, function_name, arity) do
      :ok
    else
      {:error, "No such function: ..."}
  ```
- Impact: three names each point a reader at the wrong concept — the module named after the runtime is a handle, the module named after `Registry` has none of `Registry`'s API (a maintainer may reasonably try `Tyrex.Pool.Registry.lookup/2`), and a `?`-suffixed function violates the Elixir convention that `?` means boolean, so `if function_exists?(...)` would be a plausible and always-true bug.
- Fix: `Tyrex.Runtime` → `Tyrex.Runtime.Handle` (or rename the GenServer to `Tyrex.Runtime` and keep `Tyrex` as a pure facade); `Tyrex.Pool.Registry` → `Tyrex.Pool.Owner`; `function_exists?/3` → `check_function_exported/3`.

### [LOW] Duplicated entry points: 4 of `Tyrex`'s 9 public functions exist only as arity overloads

- Location: `lib/tyrex.ex:57-59`, `:114-116`, `:173-175`, `:220-225`
- Evidence:
  ```elixir
  def start do start([]) end
  def stop do stop([]) end
  def eval(code) do eval(code, name: __MODULE__) end   # eval/2 already defaults :name to __MODULE__
  def eval!(code) do case eval(code) do ... end
  ```
- Impact: `eval/1` is exactly `eval(code, [])`, so four extra `@doc`s, four extra `@spec`s and four extra public arities carry zero semantics. It is also internally inconsistent: `Tyrex.Pool.eval/3` (`pool.ex:101`) and `Tyrex.Inline.eval/2` (`inline.ex:78`) both use `opts \\ []`. Users now face three `eval` front doors — `Tyrex.eval/2` (explicit pid/name), `Tyrex.Pool.eval/3` (strategy-selected), `Tyrex.Inline.eval/2` (process dictionary) — with different arities, different runtime resolution and no shared behaviour or type tying them together.
- Fix: collapse to `eval(code, opts \\ [])`, `eval!(code, opts \\ [])`, `start(opts \\ [])`, `stop(opts \\ [])`. Consider a single `Tyrex.eval(target, code, opts)` where `target` is a pid, a name, or `{:pool, name}` so the three front doors become one.

### [LOW] `Tyrex.Pool` exposes no lifecycle or introspection API and hides its registered name

- Location: `lib/tyrex/pool.ex:50-53`, `lib/tyrex/pool.ex:1-31`
- Evidence:
  ```elixir
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: :"#{name}.Supervisor")
  ```
- Impact: `Tyrex.Pool` publishes only `eval/3` and `eval!/3`. `Tyrex` has `stop/1`, the pool has no `stop/1`, `size/1`, or `runtimes/1`, and the moduledoc — which does document the persistent_term and ETS lifecycle in detail (`pool.ex:25-31`) — never states that the supervisor is registered as `:"<name>.Supervisor"`. To stop the pool the moduledoc invites the reader to do, they must guess the name mangling.
- Fix: add `stop/1` and `size/1` delegating to the derived supervisor name, and document the `:"<name>.Supervisor"` / `:"<name>.Registry"` / `:"<name>.Runtime.<i>"` naming contract in the moduledoc.

### [LOW] `eval_blocking` is scheduled on `DirtyCpu` but blocks on a channel, not on CPU

- Location: `native/tyrex/src/lib.rs:139-158`
- Evidence:
  ```rust
  #[rustler::nif(schedule = "DirtyCpu")]
  fn eval_blocking(resource: ResourceArc<runtime::Runtime>, code: String) -> Result<String, error::Error> {
      ...
      match response_receiver.blocking_recv() {
  ```
- Impact: no name/arity drift and the dirty flag is present, which is the important part — but the thread parks on `blocking_recv()` while the Deno worker runs (potentially doing network I/O when `allow_net` is granted). Dirty-CPU schedulers are sized to core count, so a handful of concurrent blocking evals can occupy them all and stall unrelated CPU-bound NIFs. `DirtyIo` schedulers are sized far larger and are the documented home for "waiting" NIFs.
- Fix: switch to `schedule = "DirtyIo"`, or keep `DirtyCpu` and document a hard cap on concurrent blocking evals in `Tyrex.eval/2`'s `:blocking` docs (`tyrex.ex:183-185`).

### [LOW] `:logger` is declared but never used

- Location: `mix.exs:25`
- Evidence:
  ```elixir
  extra_applications: [:logger]
  ```
  Grep for `Logger\.` across `lib/` returns no matches.
- Impact: the dependency declaration implies the library logs; it never does. Combined with the swallowed rescue at `registry.ex:47-51` and the discarded late replies at `tyrex.ex:341`, several genuine failure paths are completely silent in production.
- Fix: either log at those three sites (and keep the declaration honest) or drop `extra_applications`.

## Clean areas (one line each)

- **NIF surface parity**: all five `Tyrex.Native` stubs match `lib.rs` exactly in name and Elixir-visible arity (`start_runtime/3`, `stop_runtime/1`, `eval/3`, `eval_blocking/2`, `apply_reply/3`) — no drift, and each `def` is a proper `:erlang.nif_error(:nif_not_loaded)` stub.
- **Dirty-scheduler coverage**: the two NIFs that can block (`start_runtime`, `eval_blocking`) carry `schedule = "DirtyCpu"`; `stop_runtime`, `eval`, and `apply_reply` only clone a sender / spawn onto tokio and correctly stay on normal schedulers.
- **`RustlerPrecompiled` configuration**: `crate`, `base_url`, `version`, `nif_versions`, `targets`, and `otp_app` are all pinned (`native.ex:6-19`), `force_build` via `TYREX_BUILD` gives a source fallback, and `{:rustler, "~> 0.35", optional: true}` (`mix.exs:83`) is the correct optional pairing.
- **`Tyrex.Pool.Strategy` behaviour**: three real `@callback`s with docs, `@optional_callbacks [terminate: 1]`, and all three strategies declare `@behaviour` plus `@impl true` on every callback they implement — RoundRobin implements all three, Random/Hash correctly omit the optional one.
- **Supervision ordering trick**: Registry-first + `:rest_for_one` (`pool.ex:84-88`) is a correct and well-commented way to make cleanup run after the runtimes stop — the flaw is the un-refreshed strategy state, not the ordering.
- **Folder ↔ namespace layout**: every file's path matches its module name (`lib/tyrex/pool/strategy/round_robin.ex` → `Tyrex.Pool.Strategy.RoundRobin`), and the crate directory `native/tyrex` matches `crate: "tyrex"` — zero deviations.
- **Docs grouping**: all ten modules in `mix.exs:67-76` `groups_for_modules` have real moduledocs; `@moduledoc false` is used only on the genuinely internal `Tyrex.Native` and `Tyrex.Pool.Registry`, neither of which is listed.
- **Compile-time coupling**: `Tyrex.Sigil`'s macro only injects a remote call to `Tyrex.Inline.eval/2` (`sigil.ex:76`), creating no compile-time dependency on `Inline`; no JS is embedded at compile time (`priv/main.js` is resolved at runtime via `Application.app_dir/1`, `tyrex.ex:254`) — consistent with the reported absence of compile cycles.
- **Library shape**: no `mod:` application callback and no library-owned supervision tree (`mix.exs:23-27`) — correct for a library; no `Process.sleep`, busy-wait, or unsupervised `spawn/spawn_link` anywhere in `lib/`, and `use GenServer` / `use Supervisor` provide `child_spec/1` so both `{Tyrex, ...}` and `{Tyrex.Pool, ...}` drop into a user's tree.
- **Narrow rescue done right**: `to_atom/1` (`tyrex.ex:389-394`) rescues only `ArgumentError` and converts it to a tagged error — the pattern `registry.ex:47-51` should have followed.
