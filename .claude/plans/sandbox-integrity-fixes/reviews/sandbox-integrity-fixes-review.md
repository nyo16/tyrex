# Review — v0.4.0 sandbox integrity (`f134c25`)

**Verdict: REQUIRES CHANGES** — 5 blockers, 8 warnings, 12 suggestions.

> **UPDATE — all 5 blockers fixed in `27bb9df`.** Each fix was verified against the
> probe that exposed it, and each new assertion was verified to go red without its
> fix. Suite 160 → 165. The 8 warnings and 12 suggestions below are NOT addressed
> and remain open. See "Blocker resolution" at the foot of this document.

Branch `v0.4.0-sandbox-integrity`, 24 files, +3109/−359, reviewed against `master`.
Panel of 8 specialists. Prior review: `.claude/plans/sandbox-integrity/reviews/sandbox-integrity-review.md` (23 findings).

**Requirements coverage:** 24/26 tasks MET, 2 PARTIAL (1.6, 2.2), 0 UNMET.
Of the 23 prior findings: 21 closed, **1 PERSISTENT (W4)**, 1 PARTIAL (W6).
Two blockers are *new*, introduced by the fixes themselves.

> ⚠️ `security.md` was EXTRACTED FROM AGENT ARTIFACT — the `security-reviewer` agent
> type has no write tool. Content is verbatim from `agent://SandboxSecurity`; see the
> WARN entry in `scratchpad.md`. Its four live probes were run by Main on its behalf.

The good news first, because it is load-bearing: **B1, B2, B3, B4, B5 and W1–W3, W5, W7–W12
are genuinely closed**, and two independent agents verified the closures against the pinned
crate sources rather than against the implementation notes. `SandboxSecurity` worked through
eleven distinct routes to a file read under `permissions: :none` and found none live.
`ReleaseMechanics2` confirmed the NIF 2.16 claim *on the built artifact* (`strings -a … | grep -x
'OTP-24.0'`), which is stronger evidence than the `cargo tree` check recorded in the plan.

---

## Blockers

### 1. Two lines of guest JavaScript abort the whole BEAM under `permissions: :none`

`native/tyrex/src/worker.rs:440-444` — `WorkerOptions { .. ..Default::default() }`

`WorkerOptions::default()` supplies `create_web_worker_cb: Arc::new(|_| unimplemented!())`
(`deno_runtime-0.246.0/worker.rs:264-269`). `Worker` is a live guest global; `op_create_worker`
performs **no permission check on the specifier**. The spawned thread hits `unimplemented!()`
before `handle_sender.send(...)`, and the op thread's `handle_receiver.recv().unwrap()`
(`ops/worker_host.rs:284`) then panics **inside a V8 `extern "C"` callback** → `panic_cannot_unwind`
→ unconditional `abort()`.

Reproduced by Main on the real build, `permissions: :none`, `apply: false`:

```
Tyrex.eval(~s|new Worker("file:///tmp/nope.js", {type: "module"}); 1|)
  → exit code 134 (SIGABRT), "thread caused non-unwinding panic. aborting."
```

This is deterministic, instant, needs the *most restrictive* permission set, and no permission
governs it. It is strictly worse than B1 (which only leaked reads) and it makes the `:max_heap_mb`
floor largely beside the point — that floor exists so a guest cannot `abort()` the BEAM. It also
defeats the release's central `terminate ⇒ dead ⇒ supervisor replaces the child` contract: there
is no child left, and no supervisor.

**`catch_unwind` cannot fix this** — the panic crosses the FFI boundary before any handler runs.
`grep catch_unwind` over all of `deno_core-0.391.0`: zero matches.

**Direction:** delete `globalThis.Worker` in the bootstrap script, **unconditionally**, mirroring
the existing `delete globalThis.Tyrex;`. Verified sufficient on this pin: `op_create_worker` is
absent from `Deno[Deno.internal].core.ops`, the only other holder is the `createWorker` closure
in `js/11_workers.js` reachable solely via the `Worker` class, and `node:worker_threads` is
unreachable because `FsModuleLoader` rejects non-`file:` URLs. `SandboxSecurity` grepped all of
`deno_runtime` for `unimplemented!`/`todo!`/`panic!`: 4 hits, and `Worker` is the only
guest-reachable one — so fixing it does not queue up a successor. Pin it with a test asserting
`typeof Worker === "undefined"` and treat that as a deno-bump gate.

### 2. The one-shot heap slack turns a guest OOM back into a whole-BEAM abort — introduced by task 2.6

`native/tyrex/src/worker.rs:468-476`

My own fix for S2. The closure returns `current_heap_limit` unchanged on every invocation after
the first. V8 treats a limit that is not **strictly greater** as callback failure and calls
`FatalProcessOutOfMemory` (`heap.cc:4224-4244`, `:1383-1403`, `:1797-1808`).

Proven by a decisive experiment rather than by reading — I made the callback *never* grow and
re-ran the allocation shape that survives with growth:

| Grant strategy | array-of-arrays shape | `new Array(1e9).fill(1)` |
|---|---|---|
| never grow | **BEAM DIED** | BEAM DIED |
| one-shot +8MB (shipped) | survives | **BEAM DIED** |
| unconditional +8MB | survives | **BEAM DIED** |
| `current * 2` (deno's own) | survives | **BEAM DIED** |

So any scenario reaching a second callback aborts under the shipped code. S2's ratchet concern was
real but the cure is worse: **V8 offers no "refuse" answer.**

**Direction:** always return strictly greater. The ratchet is bounded by the terminate-means-dead
contract — growth is bounded in wall-clock, not bytes.

### 3. `:max_heap_mb` cannot contain a single large allocation, and the README claims it can

`README.md:393-398`

Note row 3 and 4 of the table above: **even with a correct always-growing grant, `new Array(1e9).fill(1)`
aborts the BEAM at caps of 32, 64 and 128 MB.** `terminate_execution` cannot interrupt a V8 builtin
mid-allocation, so the guest never reaches an interrupt check. This is a genuine V8 limitation, not
a tyrex bug — but the README states the opposite outcome, and the shipped test uses an allocation
shape that terminates cleanly, so the suite stays green over it. Same class as W1 and B1: a
documented control described in terms that overstate it.

**Direction:** fixing #2 does not fix this. Document the boundary honestly — `:max_heap_mb` converts
*incremental* heap growth into `:heap_limit_error`; a single allocation far exceeding the cap can
still abort the process.

### 4. PERSISTENT W4 — `:timeout` is still unbounded above, and still kills the runtime

`lib/tyrex.ex:618-626` — `validate_timeout!/1` checks sign and integer-ness, not range.

Task 2.2 is ticked and the docstring claims a malformed value "cannot reach — and kill — the
runtime". Reproduced by Main:

```
timeout: 10_000_000_000_000  → caller raises ErlangError;  runtime alive? false   ← W4, verbatim
timeout: 5_000_000_000       → caller raises :timeout_value; runtime alive? true
```

Band A raises `:badarg` inside `Process.send_after/3` and kills the runtime — and under `Pool`'s
`:rest_for_one`, every sibling after it, which is exactly the blast radius W4 described. Band B
overflows `call_timeout/1` past `GenServer.call`'s `receive after` ceiling, so the caller raises
*after* the eval was dispatched, leaving a runaway guest with a decades-long deadline and a leaked
`inflight` entry — the condition `timeout: :infinity` was refused to prevent.

**Direction:** reject anything where `timeout + @deadline_grace_ms > 4_294_967_295`.

### 5. One guest deadline restarts every runtime in the pool; five kill the pool

`lib/tyrex/pool.ex:88-92` with `lib/tyrex.ex:564`

**Newly relevant because of this diff.** On `master` the non-blocking path armed no timer and never
stopped, so a timeout was caller-local. Making deadlines real converts a guest-triggered event into
a supervisor restart event — under `:rest_for_one` with default intensity. Reproduced by Main:

```
one deadline on storm.Runtime.0     → 4/4 runtimes have a new pid
five deadlines over ~2.5s           → POOL SUPERVISOR DIED: :shutdown
```

Runtime children are independent; `:rest_for_one` buys nothing here but collateral damage. Siblings
are *signalled*, not stopped, and `Tyrex` never traps exits, so their `terminate/2` — and the
`fail_inflight/2` that task 2.3 added — is skipped entirely. `{:shutdown, term}` terminations are
not logged, so the churn is silent. In a library whose premise is untrusted code, a guest that
simply does not finish is a DoS against the pool and the tree above it. `README.md:371-372`
("the runtime is replaced automatically, so callers only have to retry") is new in this diff and
false in both respects.

**Direction:** `:one_for_one` for the runtime children under a nested supervisor; expose
`:max_restarts`/`:max_seconds`, since the guest chooses the failure rate.

---

## Warnings

1. **`kill/1` is inert on the wedge it documents, and reports `:ok`.** `lib/tyrex.ex:288-294`.
   Documented in three places as working "unlike `stop/1`" on a guest that never yields, but it is
   a `GenServer.call` needing the same receive loop. Reproduced by Main against a `blocking: true`
   runaway: `kill → :ok after 5002ms, alive? true`; `stop → :ok after 5002ms, alive? false`. The
   documented relationship is **inverted**, and a 5s no-op is reported as success by
   `catch :exit, _ -> :ok`.
2. **stdio is reachable under `permissions: :none`.** `README.md:180-181`, `lib/tyrex.ex:153-154`.
   rids 0/1/2 are the host's stdin/stdout/stderr and no permission governs them. Probe wrote
   `TYREX-PROBE-FORGED-STDOUT` to the operator's real terminal and `typeof Deno.stdin.readSync`
   is `"function"`. Guest JS can forge host log lines and read an attached `iex`'s keyboard. The
   `:none` docs enumerate what is denied as if the list were exhaustive; it is not.
3. **PERSISTENT (prior per-agent security finding, never promoted into the 23): the op-reachability
   test is vacuous.** `test/tyrex_permissions_test.exs:317-318`. `typeof Deno?.core?.ops?.op_apply`
   short-circuits at `Deno.core`, which is `undefined` *always*; the assertion is satisfied by every
   op name. The real protection is deno's `removeImportedOps()`. Flagged independently by three
   agents. The test also starts with the bridge **on**, contradicting its own name.
4. **The in-flight drain tests cannot fail.** `test/tyrex_api_test.exs:96-99,113`,
   `test/tyrex_lifecycle_test.exs:81`. They assert only `name: :dead_runtime_error`, and task 2.4's
   `dead_runtime_exit?/1` manufactures that same value from an undrained exit. Delete both
   `fail_inflight` calls and all three stay green — demonstrated with a stub GenServer through the
   real `Tyrex.eval/2`. Fix: assert `message =~ "in flight"`.
5. **The whole of task 1.6 has no test that can see it.** `test/tyrex_lifecycle_test.exs:214-218`.
   Only `max_heap_mb: 0` is tested, against `~r/positive integer/` — which the *pre-fix* `mb > 0`
   guard also satisfied. Boundary sweep: 0, 1, 31 all raise; 32 starts. Neither discriminating row
   is asserted. Relax the guard back and `max_heap_mb: 8` aborts the BEAM again, green suite.
6. **Bare `:shutdown` and `:killed` bypass `dead_runtime_exit?/1`.** `lib/tyrex.ex:634-638`.
   Partially-persistent W6. `:shutdown` is what a *supervisor* sends, i.e. the dominant window
   under `:rest_for_one`; `:killed` is `:brutal_kill` and `stop/1`'s own escalation. The `@spec`
   still lies there. The tell survives: `test/tyrex_lifecycle_test.exs:241` still wraps a pool call
   in `catch :exit, _ -> false`.
7. **README states the OTP floor as 27+ and now attributes it to NIF 2.16.** `README.md:689-693`.
   NIF 2.16 is **OTP 24** (`rustler-0.38.0/src/codegen_runtime.rs:145-156` maps it to `b"OTP-24.0"`,
   confirmed on the artifact). Over-restriction, not a hole — but this patch edited that sentence
   and added the wrong attribution, and it contradicts `mix.exs:11`.
8. **The CI checksum guard can never pass.** `.github/workflows/release.yml:408-423`. It greps the
   tree checked out *at the tag* for checksums derived from archives the same job just uploaded, so
   the tagged commit cannot contain them and a re-run fails identically. Every successful release
   ends red, which erases the signal for a real failure of the tag or count guard. The
   release-then-verify ordering is right; implementing a notification as a permanent failure is not.

## Suggestions

1. Panic-path `try_remove` can unregister a *different, live* runtime — `run` already removes on all
   five exit paths and `slab` reuses keys (`lib.rs:102-107`). No live window found, but an RAII guard
   owning the slab entry would make removal exactly-once. `[INFERENCE]`
2. A heap trip during `worker::new` is reported as `:execution_error` — the two remaining fallible
   startup steps never consult `heap_limit_tripped` (`worker.rs:496-504`). Fails closed; misreports.
3. Document that `catch_unwind` does **not** cover panics inside V8 callbacks (`op_apply`, the loader
   hooks, the heap closure) — blocker #1 is the proof (`lib.rs:52-64`).
4. Make the `import()` exemption *positive* — a `Cell<bool>` set once `execute_main_module` returns —
   so it stops depending on deno's is-dynamic bookkeeping and on `removeImportedOps()` (`worker.rs:76-90`).
5. Anchor the workflow's NIF grep to the dependency line, and assert the ABI on the artifact
   (`strings -a "$SRC" | grep -qx 'OTP-24.0'`). With `NIF_VERSION=2.16` the current grep is *not*
   vacuous — but `Cargo.toml:10`'s comment contains `["nif_version_2_15"]`, so a 2.15 label would
   pass on prose alone.
6. Have the checksum guards require the full target set, not one matching line.
7. B5 shipped with **no** regression test — nothing asserts a guest cannot reach the runtime id.
8. `allow_all: [list]` rejection (task 2.5) and transitive static imports under a guest `import()`
   are both unpinned.
9. `Tyrex._handleApplicationResult` is a dead entry point on the privileged bridge object
   (`extension/main.js:7-10`); it also throws on an unknown id.
10. `encode_json/1` returns the un-encodable *value* to the guest, beyond the documented
    "exception message is preserved" rationale (`lib/tyrex.ex:708-716`).
11. `mix.exs`'s publish guard prints a remediation command that cannot run without `TYREX_BUILD=true`.
12. Cosmetic: `ascii_str!` instead of `String::from(...).into()`; the pool-recovery comment still
    blames `:noproc` after 2.4 removed that case; the README omits `:apply` from the forwarded pool
    options; the scratchpad still marks the Option A decision "pending user confirmation".

## What the panel verified clean

Worth recording, because it is the part that will not need re-reviewing:
`import()` enforcement across 11 routes (transitive graphs, `data:`/`blob:`, WASM, all
`RequestedModuleType`s, `ext:`, `import.meta.resolve`, `lazy_load_esm_module`, `op_import_sync`,
`node:` require, `op_napi_open`, and whether a guest can force a *static* load — it cannot,
`execute_script` compiles a classic script). B2's use-after-free (against `jsruntime.rs:364-366`
field order). Permission-parsing polarity against `deno_permissions`' own semantics, both layers,
including the direct-NIF bypass. `:apply` authorization (no atom minting, no existence oracle,
arity authorized not matched). B3 on the artifact. The three dead-code removals, the
no-double-reply invariant, `:erlang.raise/3` usage, mix alias mechanics. Cross-file test isolation
under seeds 0 and 999999. Clippy clean. No isolate or OS-thread leak constructible across nine
teardown scenarios.

## Per-agent reports

`security.md` · `rust-nif.md` · `elixir.md` · `testing.md` · `release.md` · `otp.md` ·
`requirements.md` · `iron-laws.md`

---

## Blocker resolution

All five fixed. Every fix was re-verified with the probe that exposed the defect,
and every new assertion was verified to go **red** without its fix — restored from
byte-identical backups afterwards (`diff -q` confirmed).

| # | Fix | Probe: before → after |
|---|---|---|
| 1 | `delete globalThis.Worker;` unconditionally at bootstrap (`worker.rs`), alongside the existing conditional `delete globalThis.Tyrex;` | `new Worker(...)`: **exit 134 SIGABRT** → `ReferenceError: Worker is not defined`, runtime alive, exit 0 |
| 2 | Heap grant always returns `current + 8MB`; the one-shot arm is gone | array-of-arrays at 64 MB: was already OK, but a second callback was fatal → now `:heap_limit_error`, BEAM alive |
| 3 | README `:max_heap_mb` warning block + Security Scope bullet + `lib/tyrex.ex` `@doc` | `new Array(1e9).fill(1)` still aborts — now **documented as a V8 limitation** instead of contradicted |
| 4 | `@max_timeout 4_294_967_295 - @deadline_grace_ms`, enforced in `validate_timeout!/1` | `timeout: 10_000_000_000_000`: runtime **dead** → `ArgumentError` in the caller, runtime alive |
| 5 | New `Tyrex.Pool.RuntimeSupervisor` (`:one_for_one`) nested under the pool's `:rest_for_one`; `:max_restarts`/`:max_seconds` exposed, default `max(size*4, 12)` in 5s | one deadline: **4/4** runtimes restarted → **1/4**; six deadlines: supervisor **DIED** → alive throughout |

Fix 5 preserves the ordering `:rest_for_one` existed for: the Registry is still the
first child, so it terminates last, and a Registry crash still rebuilds every
runtime against a fresh `:persistent_term` entry. Only the runtime-to-runtime
coupling is removed.

**Red-test evidence for the new assertions:**

| Reverted | Test that went red |
|---|---|
| the `timeout <= @max_timeout` guard | `tyrex_api_test.exs` "each bad value raises ArgumentError and leaves the runtime alive" |
| `@min_heap_mb 32` → `1` | `tyrex_lifecycle_test.exs` "rejects a cap below the measured bootstrap floor" |
| pool flattened back to `:rest_for_one` | `tyrex_pool_test.exs` "a deadline on one runtime leaves its siblings untouched" — `blast_pool.Runtime.1 was restarted by an unrelated runtime's deadline` |

Blocker 1's test cannot go red gently: a regression aborts the test VM. That is the
strongest signal available and there is no gentler one, since the failure mode is
`abort()`. The pre-fix exit-134 capture is the red half of the pair.

Also folded in while touching the same lines (from warnings 6 and 12, not blockers):
`dead_runtime_exit?/1` now covers bare `:shutdown` and `:killed`, and the README's
pool-forwarding lists name `:apply` and `:startup_timeout`.

Final gate: `mix format --check-formatted` clean, `mix compile --warnings-as-errors`
clean, **165 passed**.
