# Consolidated Audit Digest — tyrex

Deduplication and cross-category correlation across 6 audit tracks.
Source reports: `.claude/audit/reports/{arch-review,perf-audit,security-audit,test-audit,deps-audit,bindings-currency}.md`

## Category scores

| Category | Score | Grade | Weight |
|---|---|---|---|
| Architecture | 41/100 | F | 20% |
| Performance | 30/100 | F | 25% |
| Security | 5/100 | F | 25% |
| Test quality | 44/100 | F | 15% |
| Dependencies | 62/100 | D | 15% |
| Bindings currency | 5/100 | F | (separate track) |

**Overall: 32.85/100 → F**, plus CRITICAL override (proven sandbox escape).

## Deduplicated findings — one root cause, many reports

Five clusters account for 11 of the 13 CRITICAL/HIGH findings. Fix the cluster, not the symptoms.

### Cluster A — `Tyrex.apply` bridge (3 tracks)
`native/tyrex/extension/main.js:25-41` + `worker.rs:16-47` + `lib/tyrex.ex:304-328`
- Security CRITICAL: installed unconditionally, consults no `PermissionsContainer` → total sandbox escape.
- Performance HIGH: triple JSON encode + full `execute_script` compile per callback.
- Architecture MEDIUM: `{:ok, {}} = Native.apply_reply` hard-matches a call that legitimately errors → MatchError.

### Cluster B — no execution timeout / no V8 termination (4 tracks)
`worker.rs:308-309`, `lib.rs:137-158`, `lib/tyrex.ex:206-210`
- Security HIGH + Performance HIGH: timeouts are Elixir-side only; `terminate_execution` is called nowhere in the crate.
- Performance CRITICAL: `eval_blocking`'s `blocking_recv()` has no timeout and deadlocks against the apply bridge.
- Test HIGH: eval timeout and `:dead_runtime_error` are both untested — which is why this shipped.

### Cluster C — permission-parsing trust bugs (2 tracks)
`worker.rs:59-121`
- Security CRITICAL ×2 + HIGH ×3: default `:allow_all`; `allow_X: false` inverts to allow-all under `allow_all: true`; `[]` means allow-all; malformed JSON fails **open**; unknown keys silently dropped.
- Architecture MEDIUM: unvalidated opts bag forwarded wholesale; docs at `lib/tyrex.ex:82` contradict the implementation.

### Cluster D — resource lifecycle / leaks (3 tracks)
- Performance HIGH: global `Mutex<Slab>` held across `enif_send` on every JS→Elixir call (`worker.rs:33-46`, `util.rs:7`).
- Architecture HIGH: strategy state built in `Supervisor.init/1` (`pool.ex:62`) but freed by `Registry.terminate/2` (`registry.ex:46`) → a Registry restart republishes a deleted ETS table id.
- Proven empirically: a runaway script leaks an OS thread spinning V8 at 100% CPU **after** `stop/1` returns `:ok`.

### Cluster E — packaging / release integrity (3 tracks)
- Architecture HIGH + Dependencies MEDIUM: `native/tyrex/.cargo/config.toml` (musl `-crt-static` rustflags) omitted from `mix.exs` `package.files`, while `README.md:407,418` sends Alpine/NixOS users to source builds → documented install path is broken from Hex.
- Dependencies HIGH: `release.yml:126` `if: always()` + per-leg publish can ship 3 of 4 archives against a checksum file claiming 4.
- Dependencies HIGH: `RUSTLER_NIF_VERSION` never set in `release.yml` while `nif-2.16` is hardcoded in artifact names.

## Cross-category correlations

1. **The test gap and the runtime defects are the same gap.** The three untested failure modes (eval timeout, worker crash/recovery, `:dead_runtime_error`) are precisely the three paths that are broken. No amount of added assertions on happy paths would have caught this; the suite has 108 passing tests and 0 coverage of the defects.
2. **Staleness compounds security.** The deno stack is 19 minor releases behind (Bindings 5/100). A sandbox library not tracking its sandbox upstream inherits every unpatched V8/deno issue on top of its own bypass.
3. **Documentation is a security surface here.** `README.md:140,199` markets `permissions: :none` as "safe for untrusted code". That claim is false and is the reason the apply-bridge escape is dangerous rather than merely surprising — users are told to rely on it.
4. **`blocking: true` is the intersection of all three worst clusters** (A+B+D): it deadlocks, pins a dirty-CPU scheduler, and leaks the isolate. It is documented and reachable via `Tyrex.eval/2` and the `~JS"..."b` sigil.
5. **Only Dependencies scored above F**, and its deductions are process gaps (version pinning, CI) rather than defects — the supply-chain hygiene (checksums, TLS verification, provenance attestation) is genuinely sound.

## Verified clean (do not re-litigate)

`mix compile --warnings-as-errors` exit 0 · `mix format --check-formatted` clean · no compile cycles · 108/108 tests pass · `mix hex.audit` clean · no hardcoded secrets · no `unsafe`/`panic!` in Rust (one `unwrap` at `tokio_runtime.rs:8`) · `String.to_existing_atom` guarded, no atom exhaustion · `~JS` sigil does not interpolate · precompiled-artifact checksums complete, enforced over verify_peer TLS, with build provenance attestation.
