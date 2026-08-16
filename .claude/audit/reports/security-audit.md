# Security Audit — tyrex

Threat model: **sandbox escape and host resource access from evaluated JS/TS**.
No web layer exists, so `sobelow` was not run (it only analyses Phoenix apps) and
CSRF/XSS/SQLi/session findings are out of scope by design.

## Score: 5/100

| Category | Max | Deductions | Left |
|---|---|---|---|
| Sandbox default-deny posture | 30 | default `:allow_all` grants net, fs-read, fs-write, env, run (subprocess) and ffi (-15 each, capped at category max) | **0** |
| Options enforced as documented | 20 | `allow_X: false` silently inverted to allow-all under `allow_all: true` (-10); unknown/typo'd permission keys accepted by the Elixir API and silently dropped in Rust (-10) | **0** |
| Panic/unsafe safety at NIF boundary | 15 | unconditional `unwrap()` on tokio builder in NIF-invoked path (-5); `Jason.decode!`/`Enum.count` on JS-supplied op payload (-5) | **5** |
| JS injection / atom exhaustion | 10 | `apply/3` driven entirely by JS-supplied module/function names (-10) | **0** |
| DoS: timeout + heap enforcement | 10 | no V8 isolate termination / execution timeout (-5); no heap limit (-5) | **0** |
| Secrets & CI/supply-chain integrity | 15 | three unpinned third-party actions in the release path (-5 each) | **0** |

Arithmetic: `100 − 30 − 20 − 10 − 10 − 10 − 15 = 5`.

No hardcoded secrets were found, `checksum-Elixir.Tyrex.Native.exs` exists, is
packaged, and `RustlerPrecompiled` enforces it — so the -15 checksum/secret
penalties do **not** apply.

---

## Findings

### [CRITICAL] `Tyrex.apply` is an unconditional arbitrary-MFA bridge that bypasses every Deno permission

- **Location**: `native/tyrex/extension/main.js:25-41`, `native/tyrex/src/worker.rs:206`, `lib/tyrex.ex:304-312`
- **Evidence**:

```js
// native/tyrex/extension/main.js:25-39 — always installed, no permission check
  apply: (module, functionName, args) => {
    ...
    op_apply(Tyrex._runtimeId, applicationId, module, functionName, JSON.stringify(args));
```

```elixir
# lib/tyrex.ex:304-312
def handle_info({:apply, application_id, module, function_name, args}, state) do
  decoded_args = Jason.decode!(args)
  with {:ok, decoded_module} <- to_module(module),
       {:ok, decoded_function_name} <- to_atom(function_name),
       :ok <- function_exists?(decoded_module, decoded_function_name, Enum.count(decoded_args)),
       result <- apply(decoded_module, decoded_function_name, decoded_args),
```

```rust
// native/tyrex/src/worker.rs:206 — extension registered for every worker,
// independent of the PermissionsContainer built above
extensions: vec![extension::init()],
```

- **Impact**: The permission model is decorative. Any evaluated JS — including a
  runtime started with `permissions: :none` — reaches **any exported function of
  any loaded module**. Concretely:
  - `Tyrex.apply("Code", "eval_string", ["System.cmd(\"sh\", [\"-c\", \"...\"])"])`
    → arbitrary Elixir evaluation → full host compromise.
  - `Tyrex.apply(":os", "cmd", [[108,115]])` → a JSON integer array decodes to an
    Erlang charlist → `:os.cmd(~c"ls")` → shell execution with **`allow_run`
    denied**.
  - `Tyrex.apply("File", "read!", ["/etc/passwd"])` → arbitrary read with
    `allow_read` denied; `File.write!/2` and `File.rm_rf!/1` likewise.

  `README.md:140` (`# No I/O at all — pure computation only (safe for untrusted
  code)`) and `README.md:199` (`**Untrusted code**: Use permissions: :none for
  user-submitted JavaScript`) are therefore actively dangerous advice;
  `README.md:220` documents the same bridge as a feature ("JavaScript code can
  call **any** Elixir function"). Two documented guarantees contradict each other.
- **Fix**: The bridge MUST be opt-in and allow-listed. Add an `:apply` option
  (default `false`) threaded through `Tyrex.start/1` into the JSON handed to
  `worker::new`, and gate `extension::init()` on it so the op is not even
  registered when disabled. When enabled, validate against a caller-supplied
  `{module, function, arity}` allow-list in `handle_info/2` before `apply/3` —
  never `function_exported?` alone. Until then, delete the "safe for untrusted
  code" claims from `README.md:140,199` and `lib/tyrex.ex:79`.

### [CRITICAL] Default posture is allow-everything (`deno run -A`)

- **Location**: `lib/tyrex.ex:256`, `lib/tyrex.ex:396`, `native/tyrex/src/worker.rs:90-94`
- **Evidence**:

```elixir
# lib/tyrex.ex:256
encode_permissions(Keyword.get(opts, :permissions, :allow_all))
# lib/tyrex.ex:396
defp encode_permissions(:allow_all), do: ~s("allow_all")
```

```rust
// native/tyrex/src/worker.rs:90-94
if parsed.is_string() && parsed.as_str() == Some("allow_all") {
    return Ok(
        deno_runtime::deno_permissions::PermissionsContainer::allow_all(descriptor_parser),
    );
}
```

- **Impact**: `Tyrex.start()` with no options grants net, fs-read, fs-write, env,
  **subprocess (`Deno.Command`)**, **FFI**, sys and dynamic import. `deno_process
  0.53.0`, `deno_ffi 0.225.0`, `deno_napi 0.169.0`, `deno_kv 0.146.0` and
  `rusqlite` / `libsqlite3-sys` are all linked in (`native/tyrex/Cargo.lock:1613,
  1769, 2074, 2158, 6106`), so the reachable surface under the default is the full
  Deno host API. `Deno.dlopen` and `Deno.openKv` additionally require unstable
  feature flags, which are not enabled (`WorkerOptions { ..Default::default() }`,
  `worker.rs:205-208`) — so KV/sqlite is not reachable from the `Deno` namespace
  and cannot write host paths today `[INFERENCE — inferred from deno_runtime's
  unstable-namespace gating; not executed here]`. `Deno.Command`, `fetch`,
  `Deno.readTextFile` and `Deno.writeTextFile` are stable and need no flag, so
  subprocess spawn and arbitrary filesystem writes are available by default with
  certainty. A library whose selling point is running application-supplied JS
  should fail closed; `test/tyrex_permissions_test.exs:4-30` instead encodes the
  unsafe default as expected behaviour ("permissions: :allow_all (default) … can
  read files … can read env").
- **Fix**: Flip the default in `lib/tyrex.ex:256` to `:none` and make `:allow_all`
  an explicit, loudly documented opt-in. Update the tests to assert the default
  denies fs/env/net.

### [CRITICAL] `allow_X: false` is silently inverted to *allow-all* when `allow_all: true` is set

- **Location**: `native/tyrex/src/worker.rs:60-70`, `native/tyrex/src/worker.rs:112-121`
- **Evidence**:

```rust
// 60-62
match value {
    serde_json::Value::Bool(true) => Some(vec![]),
    serde_json::Value::Bool(false) => None,
// 116-121
let allow_default = || if allow_all { Some(vec![]) } else { None };
let allow = |key: &str| {
    obj.get(key)
        .and_then(parse_string_list)   // `false` => None
        .or_else(allow_default)        // None    => Some(vec![]) == ALLOW ALL
};
```

- **Impact**: `lib/tyrex.ex:82` documents "`false` (deny all)". With
  `permissions: [allow_all: true, allow_run: false, allow_ffi: false]` the `false`
  collapses to `None` and is then replaced by `Some(vec![])`, which in Deno means
  *granted globally*. The operator believes subprocess and FFI are disabled; they
  are fully enabled. This is an accepted-but-inverted option — the worst class of
  trust bug, because the configuration reads as hardened. Only `deny_*` keys
  actually work in that combination, and nothing tells the caller so.
- **Fix**: Distinguish "key absent" from "key present and false". Parse into a
  tri-state (`Absent | Deny | Allow(Vec<String>)`) and let an explicit `Deny`
  short-circuit `allow_default`; alternatively reject the `allow_all: true` +
  `allow_x: false` combination in `encode_permissions/1` with an `ArgumentError`
  naming the conflicting keys.

### [HIGH] Empty permission list means *allow everything*, not *allow nothing*

- **Location**: `native/tyrex/src/worker.rs:63-68`, `lib/tyrex.ex:402-410`
- **Evidence**:

```rust
serde_json::Value::Array(arr) => Some(
    arr.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
),
```

- **Impact**: `Some(vec![])` is Deno's "granted, with no scoping restriction". So
  `permissions: [allow_read: []]` — the natural result of a computed list such as
  `allow_read: Enum.filter(paths, &File.exists?/1)` coming out empty — silently
  escalates from "no paths" to "the entire filesystem". The same `filter_map`
  drops non-string array entries instead of erroring, so a malformed entry narrows
  nothing and is never reported.
- **Fix**: Treat an empty array as deny (`None`) in `parse_string_list`, or reject
  it in `encode_permissions/1`. Return an error for non-string array elements
  rather than `filter_map`-ing them away.

### [HIGH] Permission parsing fails open — malformed or unexpected JSON grants everything

- **Location**: `native/tyrex/src/worker.rs:80-105`
- **Evidence**:

```rust
let parsed: serde_json::Value = match serde_json::from_str(permissions_json) {
    Ok(v) => v,
    Err(_) => {
        return Ok(PermissionsContainer::allow_all(descriptor_parser));
    }
};
...
    None => {
        // Same fallback behavior as before: unexpected JSON shape =>
        // allow_all (callers that want strict perms must pass an object).
        return Ok(PermissionsContainer::allow_all(descriptor_parser));
    }
```

- **Impact**: A security control that grants full access on parse failure. Today
  the only Elixir producer is `encode_permissions/1`, but
  `Tyrex.Native.start_runtime/3` is a public function taking a plain `String`
  permissions argument, and any future caller (or a truncated/mangled JSON string)
  gets an unsandboxed runtime with no error, no log line, and no observable
  difference from a correctly configured one.
- **Fix**: Return `Err(Error { name: execution_error, .. })` in both branches so
  startup fails loudly. `allow_all` must be reachable only via the explicit
  `"allow_all"` sentinel.

### [HIGH] Unknown permission keys are accepted by the Elixir API and silently ignored

- **Location**: `lib/tyrex.ex:402-410`, `native/tyrex/src/worker.rs:123-142`
- **Evidence**:

```elixir
defp encode_permissions(opts) when is_list(opts) do
  opts
  |> Map.new(fn
    {key, true} -> {key, true}
    {key, false} -> {key, false}
    {key, list} when is_list(list) -> {key, Enum.map(list, &to_string/1)}
  end)
  |> Jason.encode!()
end
```

  There is no key allow-list here, and `build_permissions` reads only the sixteen
  keys it knows (`worker.rs:123-142`).
- **Impact**: `permissions: [allow_all: true, deny_subprocess: true]` or
  `[deny_nett: true]` starts a fully permissive runtime and reports success. A
  single typo in a hardening config is invisible.
- **Fix**: Validate keys against the known set in `encode_permissions/1` and raise
  `ArgumentError` on anything else. Cheap, and it eliminates a whole class of
  silent misconfiguration.

### [HIGH] No execution timeout and no V8 heap limit — evaluated JS can wedge the worker and the BEAM

- **Location**: `native/tyrex/src/worker.rs:308-309`, `native/tyrex/src/lib.rs:137-140`
- **Evidence**:

```rust
// worker.rs:308-309 — synchronous, uninterruptible
Message::Eval(code, response_sender) => {
    match worker.execute_script("<anon>", code.into()) {
```

```rust
// lib.rs:137 — blocking eval occupies a dirty CPU scheduler for the whole run
#[rustler::nif(schedule = "DirtyCpu")]
fn eval_blocking(
```

  A grep of `native/tyrex/src` for `terminate_execution`, `create_params`,
  `heap_limit` and `max_old_space` returns no matches.
- **Impact**:
  1. `Tyrex.eval("while(true){}")` runs forever. The `GenServer.call` 5s timeout
     (`lib/tyrex.ex:205-210`) only abandons the *caller*; the worker thread and V8
     isolate spin at 100% CPU permanently. The `Message::Stop` branch lives in the
     same `tokio::select!` loop that is blocked, so `Tyrex.stop/1` cannot recover
     it — thread and isolate leak for the life of the node.
  2. With `blocking: true` the same code pins a **dirty CPU scheduler**. That pool
     is small and fixed; a handful of such calls (trivially reached through a
     runtime pool) starves all dirty-CPU work VM-wide.
  3. No `v8::CreateParams::heap_limits`, so `new Array(1e9).fill(0)` grows until
     the OS OOM-killer takes the whole BEAM node, not just the runtime.
- **Fix**: Give the isolate a heap limit via `CreateParams`, and hold an
  `IsolateHandle` (`worker.js_runtime.v8_isolate().thread_safe_handle()`) in the
  `Runtime` resource so a watchdog can call `terminate_execution()` when a per-eval
  deadline elapses or `Stop` arrives. Expose the deadline as a
  `:max_execution_time` start option with a finite default.

### [HIGH] Malformed op payload from JS crashes the owning GenServer, and can target *other* runtimes

- **Location**: `lib/tyrex.ex:305`, `lib/tyrex.ex:311`, `native/tyrex/src/worker.rs:16-45`
- **Evidence**:

```elixir
decoded_args = Jason.decode!(args)          # lib/tyrex.ex:305
... Enum.count(decoded_args) ...            # lib/tyrex.ex:311
```

  `op_apply` deliberately tolerates any input on the Rust side but forwards the raw
  `args` string unvalidated; the type guards live only in the `Tyrex.apply` JS
  wrapper (`native/tyrex/extension/main.js:26-34`), not in the op.
- **Impact**: JS calling the op directly (`Deno.core.ops.op_apply(...)` —
  `[INFERENCE]`, `Deno.core.ops` exposure is deno_core's default and was not
  executed here) with a non-JSON string raises `Jason.DecodeError` inside
  `handle_info/2`, killing the runtime GenServer; a JSON scalar such as `"5"`
  raises `Protocol.UndefinedError` from `Enum.count/1`. Because `runtime_id` is
  attacker-chosen and resolved against a process-global slab (`worker.rs:16-45`),
  one runtime can crash a **different** tenant's runtime by guessing its id — ids
  are dense slab indices starting at 0.
- **Fix**: Use `Jason.decode/1` and reply `{:error, ...}` on failure; require
  `is_list(decoded_args)`. Validate `runtime_id` against the id this worker was
  created with (already available — `worker::run` takes it) instead of trusting the
  JS-mutable `Tyrex._runtimeId`.

### [MEDIUM] `apply/3` result path crashes the GenServer on a dead runtime

- **Location**: `lib/tyrex.ex:320-325`
- **Evidence**:

```elixir
{:ok, {}} =
  Native.apply_reply(
    state.reference,
    application_id,
    result
```

- **Impact**: `apply_reply` returns `{:error, %Error{name: :dead_runtime_error}}`
  when the worker channel is closed (`native/tyrex/src/lib.rs:169-174`). The strict
  match turns an ordinary shutdown race into a `MatchError`, so a runtime torn down
  mid-callback dies with an exception and a crash report instead of the clean
  `{:stop, {:shutdown, :dead_runtime_error}, state}` used by the two sibling call
  sites (`lib/tyrex.ex:291-292`, `lib/tyrex.ex:337-338`).
- **Fix**: `case Native.apply_reply(...) do {:ok, {}} -> {:noreply, state}; {:error, %Error{name: :dead_runtime_error}} -> {:stop, {:shutdown, :dead_runtime_error}, state} end`.

### [MEDIUM] `unwrap()` on the shared tokio runtime builder inside a NIF path

- **Location**: `native/tyrex/src/tokio_runtime.rs:8`
- **Evidence**:

```rust
RUNTIME.get_or_init(|| Builder::new_multi_thread().enable_all().build().unwrap())
```

- **Impact**: Reached from the `stop_runtime` and async `eval` NIFs
  (`native/tyrex/src/lib.rs:71`, `:109`). `Builder::build` fails on thread-spawn
  failure or fd exhaustion — both reachable under the memory/fd pressure evaluated
  JS can create. A panic inside a NIF is not an Elixir exception: it unwinds across
  the FFI boundary and, absent a `catch_unwind` guard, takes down the emulator. The
  rest of the crate is clean — no `unsafe`, no slice indexing, no `as` casts, every
  other fallible path matched — so this is the single outlier.
- **Fix**: Store `OnceLock<Option<Runtime>>` and surface a `Tyrex.Error` with
  `name: :execution_error` instead of panicking.

### [MEDIUM] The `permissions: :none` test suite does not cover the dangerous surfaces

- **Location**: `test/tyrex_permissions_test.exs:33-60`
- **Evidence**: the `:none` block asserts only `Deno.readTextFile` and
  `Deno.env.get`. A grep of `test/` for `Deno.Command`, `Deno.run`, `Deno.dlopen`,
  `Deno.openKv`, `Deno.writeTextFile`, `core.ops`, `allow_run`, `allow_write` and
  `allow_ffi` returns **no matches**.
- **Impact**: The two permissions the README tells users to "always deny"
  (`allow_run`, `allow_ffi`) plus `allow_write` and the KV/sqlite surface have zero
  enforcement tests. Nothing would catch a regression that re-enables subprocess
  spawning, and nothing currently proves the sandbox holds for them — the
  `allow_all: true, allow_run: false` inversion above is exactly the bug such a
  test would have caught.
- **Fix**: Add negative tests under `permissions: :none` and under
  `[allow_all: true, deny_run: true, deny_ffi: true]` for `new Deno.Command(...)`,
  `Deno.writeTextFile`, `Deno.openKv`, and direct `Deno.core.ops.*` invocation.

### [MEDIUM] Three unpinned third-party actions in the artifact-publishing path

- **Location**: `.github/workflows/release.yml:159` (`dtolnay/rust-toolchain@stable`),
  `.github/workflows/release.yml:222` (`Swatinem/rust-cache@v2`),
  `.github/workflows/release.yml:300` (`softprops/action-gh-release@v2`); same
  pattern in `.github/workflows/ci.yml:53,120,126` (the last being
  `erlef/setup-beam@v1`, covered by the category cap)
- **Evidence**:

```yaml
      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@stable      # mutable *branch*, not even a tag
...
      - name: Publish archives and packages
        uses: softprops/action-gh-release@v2     # mutable tag, runs with contents: write
```

- **Impact**: The `build_nif` job holds `contents: write`, `id-token: write` and
  `attestations: write` (`release.yml:129-132`). Any of these mutable refs being
  repointed — `@stable` is a branch and moves by design — executes attacker code in
  the job that compiles and signs the NIF every downstream user downloads. The
  provenance attestation does not help; it would faithfully attest the compromised
  artifact. Related, folded into this finding by the category cap: `wget -qO
  /tmp/llvm.sh https://apt.llvm.org/llvm.sh && sudo /tmp/llvm.sh 20`
  (`release.yml:49-51`, `:204-206`, `ci.yml:44-46`) pipes a remote script into root
  with no checksum, and the `curl -L` of `src_binding_release_*.rs`
  (`release.yml:181-183`) pulls Rust source compiled into the published NIF with no
  integrity check beyond TLS.
- **Fix**: SHA-pin every third-party action (`uses: dtolnay/rust-toolchain@<40-hex>
  # 1.92.0`) and enable Dependabot for action updates. Pin the LLVM script and the
  V8 binding file by sha256 and verify before use.

### [LOW] Missing top-level least-privilege `permissions:` default

- **Location**: `.github/workflows/release.yml:1-18`, `.github/workflows/ci.yml:1-12`
- **Evidence**: only `build_nif` declares a `permissions:` block
  (`release.yml:129-132`); `build_v8` and CI's `mix_test` inherit the repository
  default token scope.
- **Impact**: The V8 job runs `git clone --recurse-submodules` of a third-party
  repo and a root-level install script with a token that may be read-write
  depending on repo settings. There is no `pull_request_target` and no secret
  exposure to fork PRs — that part is correct.
- **Fix**: Add `permissions: { contents: read }` at the top of both workflows; the
  job-level block in `build_nif` already grants what it needs.

### [LOW] Attacker-controlled strings written to stderr with `eprintln!`, bypassing Logger

- **Location**: `native/tyrex/src/worker.rs:29`, `native/tyrex/src/worker.rs:302-304`
- **Evidence**: `eprintln!("tyrex: op_apply got invalid runtime_id {runtime_id:?}: {err}");`
- **Impact**: JS controls `runtime_id`. `{:?}` escapes quotes and control
  characters, so this is not terminal-escape injection, but the output lands on raw
  stderr outside `Logger` — unfiltered, unstructured and unrate-limited. A loop
  calling the op with a bad id is a cheap log flood.
- **Fix**: Send diagnostics to the owning pid (the mechanism already exists in
  `util::send_to_pid`) and log them through `Logger` on the Elixir side.

### [LOW] `main_module_path` is joined to cwd with no validation

- **Location**: `native/tyrex/src/worker.rs:172`
- **Evidence**: `let path = cwd.join(main_module_path);`
- **Impact**: Absolute paths and `../` traversal both resolve — `Path::join` with an
  absolute argument discards the base entirely. Host-controlled rather than
  JS-controlled, so it only bites if an application derives the path from user
  input, but nothing in the docs warns against that.
- **Fix**: Document that `:main_module_path` must never be user-derived; optionally
  reject paths that escape the application directory.

---

## Clean areas (one line each)

- Atom handling is correct: `lib/tyrex.ex:389-394` uses `String.to_existing_atom/1` with an `ArgumentError` rescue, so JS-supplied module/function names cannot exhaust the atom table.
- No `String.to_atom/1`, `Code.eval_*`, or `:erlang.binary_to_term/1` anywhere in `lib/` — the only dynamic dispatch is the JS-driven `apply/3` reported above.
- `~JS` does not interpolate (`lib/tyrex/sigil.ex:65` receives the raw `{:<<>>, _, _}` AST), so the sigil is injection-free; note that `lib/tyrex/sigil.ex:35` *documents* raw `Tyrex.Inline.eval("#{x} + 5")` interpolation and should show `Jason.encode!/1` instead.
- Rust→JS reply construction is properly escaped through `serde_json::to_string` per argument rather than format-string interpolation (`native/tyrex/src/worker.rs:284-292`).
- `Tyrex._runtimeId` seeding interpolates a `usize`, not a string (`native/tyrex/src/worker.rs:213`) — not injectable.
- No `unsafe`, `panic!`, `expect(`, slice indexing, or `as` numeric casts anywhere in `native/tyrex/src` (the single `unwrap()` is reported above).
- Mutex poisoning is handled deliberately rather than unwrapped (`native/tyrex/src/runtimes.rs:15-20`), and pending promises are drained on shutdown so callers get `:dead_runtime_error` instead of hanging (`native/tyrex/src/worker.rs:241-252`).
- No hardcoded secrets, keys, or tokens in `lib/`, `native/`, `test/`, `priv/`, `mix.exs`, or `.github/`.
- `checksum-Elixir.Tyrex.Native.exs` holds sha256 entries for all four targets, is listed in `mix.exs:37` package files, and `RustlerPrecompiled` enforces it on download (`deps/rustler_precompiled/lib/rustler_precompiled.ex:780-825`) over TLS with `verify: :verify_peer` and hostname checking; checksum verification is **not** disabled anywhere in `lib/tyrex/native.ex`.
- No `pull_request_target` trigger and no secrets exposed to fork PRs in either workflow.
- `sobelow` was not run: it analyses Phoenix applications and this project has no web layer.
