# Project Health Audit — tyrex

**Date:** 2026-08-14 · **Version:** 0.3.0 · **Commit:** e61bba8
**Scope:** full project (6 parallel audit tracks)

## Executive summary

**Overall health: 33/100 — Grade F. CRITICAL override in effect.**

tyrex is a well-built piece of engineering with a broken security model. The
craft is real: zero compile warnings, formatted, no dependency cycles, 108/108
tests green, no `unsafe` or `panic!` in the Rust layer, checksum-verified
precompiled artifacts with build provenance. The NIF concurrency design is
mostly *correct* — `eval` returns immediately and replies by message, which is
exactly right.

The problem is that the central promise of the library — "run untrusted
JavaScript safely" — does not hold, and I proved that rather than inferring it.
`permissions: :none` correctly denies `Deno.readTextFileSync`, then hands the
same script arbitrary filesystem access and shell execution through the
`Tyrex.apply` bridge, which consults no permission object at all. The README
tells users this mode is "safe for untrusted code".

Separately, `blocking: true` deadlocks by construction and leaks a V8 thread
that spins at 100% CPU forever, surviving `stop/1`.

This is not a "needs polish" audit. Three defects require a breaking release.

| Category | Score | Grade | Weight | Contribution |
|---|---|---|---|---|
| Architecture | 41/100 | F | 20% | 8.20 |
| Performance | 30/100 | F | 25% | 7.50 |
| Security | 5/100 | F | 25% | 1.25 |
| Test quality | 44/100 | F | 15% | 6.60 |
| Dependencies | 62/100 | D | 15% | 9.30 |
| **Overall** | **32.85/100** | **F** | | |
| Bindings currency | 5/100 | F | — | separate track |

Scores are only meaningful as a baseline for *this* project over time; they are
not comparable to other projects.

## Proven critical issues

Each item below was reproduced on this machine, not inferred from reading code.

### 1. Total sandbox escape via the `Tyrex.apply` bridge — CRITICAL

`native/tyrex/extension/main.js:25-41` · `native/tyrex/src/worker.rs:16-47` · `lib/tyrex.ex:304-328`

`globalThis.Tyrex.apply` is installed unconditionally by the extension's ESM
entry point. `op_apply` never touches the `PermissionsContainer`. On the Elixir
side there is no allowlist — `to_module/1` accepts any module and
`function_exists?/3` only checks that the function is exported.

Reproduction under `permissions: :none`:

```
Deno.readTextFileSync('mix.exs')            -> {:error, "NotCapable: Requires read access..."}   # correctly denied
Tyrex.apply('File','read!',['mix.exs'])     -> {:ok, 1962}   # full filesystem read
Tyrex.apply(':os','cmd',[[105,100]])        -> {:ok, 396}    # shell execution ("id"), allow_run denied
```

Deno's own sandbox works. The bridge routes straight around it. `Code.eval_string`
is reachable the same way, so this is arbitrary Elixir execution from guest JS.

**Impact:** any user following `README.md:199` ("Untrusted code: use
`permissions: :none`") has a remote code execution hole.
**Fix:** default-deny the bridge. Gate it on an explicit
`allow_apply: [{Module, :fun, arity}, ...]` allowlist checked in
`handle_info({:apply, ...})`, and correct the README claims immediately —
the doc fix cannot wait for the code fix.

### 2. `blocking: true` deadlocks and permanently wedges the runtime — CRITICAL

`native/tyrex/src/lib.rs:137-158` · `lib/tyrex.ex:286-296` vs `:304`

`handle_call({:eval, ...})` with `blocking: true` parks the GenServer inside
`blocking_recv()` (no timeout). If the script calls back via the bridge,
`op_apply` sends `{:apply, ...}` to *that same blocked GenServer*, which cannot
reach `handle_info/2`. The JS promise never settles; `blocking_recv` waits
forever.

```
non-blocking apply          -> {:ok, 3}
blocking apply (4s timeout) -> {:caught, :exit, :timeout}
post-deadlock health check  -> ** (EXIT) time out      # runtime permanently unusable
```

A dirty-CPU scheduler is held for the lifetime of the VM; a default-size pool
(`System.schedulers_online()`) can exhaust the entire dirty-CPU pool.
Reachable via the documented `~JS"..."b` sigil.
**Fix:** replace `blocking_recv()` with `recv_timeout`, move the NIF to
`DirtyIo`, and reject `blocking: true` for code that can reach the bridge.

### 3. Runaway scripts leak a 100%-CPU thread that survives `stop/1` — HIGH

`native/tyrex/src/worker.rs:308-309` — `terminate_execution` appears nowhere in
the crate; timeouts are Elixir-side only.

```
healthy            -> {:ok, 2}
after "for(;;){}"  -> :call_timed_out
stop/1             -> :ok            # Elixir process dies cleanly...
cpu% 4s AFTER stop -> 100.0          # ...OS thread still spinning V8 forever
```

`stop/1` reports success because `Native.stop_runtime` is fire-and-forget; the
`Message::Stop` sits unread in a channel the worker will never poll again. The
slab entry leaks too. Note `stop/1` defaults to `timeout: :infinity`
(`lib/tyrex.ex:135`), so a caller who does not override it hangs indefinitely.
**Fix:** hold an `IsolateHandle`, call `terminate_execution` on timeout from a
watchdog, and set a V8 heap limit (`create_params` is never configured, so a
guest OOM `abort()`s the whole BEAM).

### 4. Permission parsing fails open — CRITICAL

`native/tyrex/src/worker.rs:59-121`

- Default is `:allow_all` (`lib/tyrex.ex:68,256`) = `deno run -A`.
- Malformed JSON or a non-object shape returns `PermissionsContainer::allow_all`
  (`worker.rs:83-88, 96-105`) — silently, with no error.
- `allow_X: false` → `None` → `Some(vec![])` when `allow_all: true` is set
  (`worker.rs:116-121`), i.e. **allow-all**. `lib/tyrex.ex:82` documents `false`
  as "deny all", so `[allow_all: true, allow_run: false, allow_ffi: false]`
  reads as hardened and grants both.
- `allow_read: []` grants the entire filesystem (`worker.rs:61,63-67`).
- Unknown/typo'd keys are accepted by `encode_permissions/1` and dropped in
  Rust, so `[deny_nett: true]` yields a permissive runtime reporting success.

**Fix:** deny on parse failure, treat `false` as an explicit deny that outranks
`allow_all`, reject unknown keys, and distinguish "empty allowlist" from
"unrestricted". Flip the default to deny-by-default in the next major.

## Other significant findings

**Performance** — global `Mutex<Slab>` held across `enif_send` on every JS→Elixir
call (`worker.rs:33-46`), serializing the callback path of every runtime in every
pool. Apply-replies transport data by compiling a JS source string per callback
(3 encodes + 3 parses + a full `execute_script`). No startup snapshot or
`v8_code_cache`. Unbounded mpsc channel with no backpressure. Pool dispatch
interpolates and interns an atom per call (`pool.ex:106`).

**Architecture** — `Tyrex` is a 415-line facade + GenServer + apply-bridge +
permissions DSL. Pool strategy state is built in `Supervisor.init/1`
(`pool.ex:62`) but freed by `Registry.terminate/2` (`registry.ex:46`), so a
Registry restart republishes a deleted ETS table id and every `eval` then raises
`ArgumentError` for the supervisor's lifetime. `:dead_runtime_error` is
documented as matchable but the implementation `{:stop, ...}`s without replying,
so callers get an exit instead. No `@spec` on any of the 5 NIF stubs.

**Tests** — 108 passing, but 26.0s of 26.2s is serial; 3 of 5 files could be
`async: true`. Zero `Process.sleep` (genuinely good). Untested: eval timeout,
worker crash + pool recovery, `:dead_runtime_error`, `:conversion_error`,
unicode and large-payload round-trips, and TypeScript module loading —
`test/support/greeter.ts`, `server.js`, and `async_module.js` are referenced by
no test at all. Several vacuous assertions (`tyrex_test.exs:86` matches any map;
`:323` asserts literal `true`; `pool.ex` test "selects randomly" asserts `1+1==2`).

**Dependencies** — `hex.audit` clean and supply-chain hygiene is sound.
Elixir `rustler 0.37.3` runs against Rust crate `rustler 0.36.2`; `mix.exs`'s
`~> 0.35` makes the drift unbounded and rustler's own version guard is dead code
(zero callers), so it is silent. `release.yml` never sets `RUSTLER_NIF_VERSION`
while hardcoding `nif-2.16`. `if: always()` + per-leg publish can ship 3 of 4
archives against a 4-entry checksum file. No clippy, no Rust tests, no
credo/dialyzer/coverage.

**Bindings currency (5/100)** — the whole deno stack is 19 minors behind:
`deno_core 0.391→0.410`, `deno_runtime 0.246→0.265`, `deno_fs 0.148→0.167`,
`deno_resolver 0.69→0.88`, `serde_v8 0.300→0.319`. The good news: a source diff
of pinned vs target found **exactly one** required code edit —
`blob_store: Default::default()` at `worker.rs:178-180`, because
`WorkerServiceOptions.blob_store` became `Arc<dyn BlobStoreTrait>`. Permissions
APIs, `op2`, `extension!`, `execute_script`, and snapshot options are unchanged.
Two constraints hard-block the bump: `sys_traits = "=0.1.24"` is unsatisfiable
against deno_runtime 0.265's `^0.1.28`, and `libsqlite3-sys 0.35` stops
unifying (deno_kv 0.165 → rusqlite ^0.40 → libsqlite3-sys ^0.38), which would
silently disable the `bundled` feature that exists to make cross-compilation
work. rustler 0.38's two removals were already migrated ahead of time.

## Action plan

### Immediate — before any further release
1. Correct `README.md:140,199` and `lib/tyrex.ex:79,82`. `:none` is not safe for
   untrusted code today; say so. Docs-only, ship now.
2. Gate `Tyrex.apply` behind an explicit MFA allowlist, default deny.
3. Make permission parsing fail **closed**; honour `allow_X: false` over
   `allow_all`; reject unknown keys; distinguish `[]` from unrestricted.
4. Add a timeout to `eval_blocking`'s `blocking_recv`, move it to `DirtyIo`, and
   document that `blocking: true` cannot be combined with the apply bridge.
5. Bound `stop/1`'s default timeout (currently `:infinity`).

### Short-term — next minor
6. V8 `terminate_execution` watchdog on eval timeout + `create_params` heap limit.
7. Release the slab lock before `enif_send`.
8. Align the rustler pair (Elixir 0.38.0 / crate 0.38.0) and pin the crate to a
   `=` version so drift cannot recur silently.
9. Add `native/tyrex/.cargo/config.toml` to `mix.exs` `package.files`; the
   documented Alpine/NixOS source-build path is broken from Hex without it.
10. Set `RUSTLER_NIF_VERSION` in `release.yml`; make publish all-or-nothing.
11. Tests for the four proven defects above, plus TypeScript loading and
    `:dead_runtime_error`. Turn on `async: true` for the 3 eligible files.

### Long-term
12. deno lockstep bump to the 0.410/0.265/0.167/0.88/0.319 tuple, relaxing
    `sys_traits` to `^0.1.28` and moving `libsqlite3-sys` to `0.38` with
    `bundled` retained.
13. Startup snapshot + `v8_code_cache`; replace the string-compiled apply-reply
    path with an op.
14. Rebuild strategy-state lifecycle so the owner allocates and frees it.
15. Add clippy, Rust unit tests, credo, dialyxir, and coverage to CI.

## Method

6 specialist tracks run in parallel; every CRITICAL was independently verified
by the orchestrator before inclusion. Two corrections were made to subagent
findings: the performance track's "-15 isolate reuse" deduction was reduced to
-5 (isolates *are* reused per runtime — the real gap is only the missing
snapshot/code cache), and the claim that `stop/1` cannot recover a wedged
runtime was corrected — it does kill the Elixir process; what leaks is the
native thread. Performance was rescored 20 → 30 accordingly.

Per-track detail: `.claude/audit/reports/`. Dedup and correlations:
`.claude/audit/summaries/consolidated.md`.
