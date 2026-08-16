# Review: tyrex v0.4.0 — Sandbox Integrity

**Date:** 2026-08-14
**Diff:** 19 files, +1671 / −289, uncommitted on `master`
**Panel:** 6 agents (rust-nif, security, elixir, testing, requirements, release)
**Verification status:** `mix format --check-formatted` clean, `mix compile --warnings-as-errors` clean (Elixir + Rust), **141 tests pass**. `verification-runner` skipped per the selection table — `/phx:work` had just passed all tiers.

## Verdict: REQUIRES CHANGES

5 BLOCKER · 12 WARNING · 6 SUGGESTION

The release does what it set out to do — every one of the audit's original escape vectors is closed and the CPU leak is genuinely reclaimed. But the panel found **a different, live sandbox escape that survives this release**, plus a memory-safety defect and two release-integrity faults that would break installation for every user.

Four findings were reproduced by me directly rather than accepted on the agents' word; those are marked **VERIFIED** with the command output.

---

## Requirements Coverage

**Source:** `plan .claude/plans/sandbox-integrity/plan.md`
**Summary:** 18 MET · 1 PARTIAL · 0 UNMET · 0 UNCLEAR

All 19 tasks implemented, including the ones easiest to fake: 1.2's three independent parser fixes, 2.3's teardown contract pinned by a test, 2.4's per-request in-flight map, 2.8's five regressions, 3.3's all-or-nothing publish.

**PARTIAL — 1.5 (docs).** Task 1.5 named two sentences to fix. The "safe for untrusted code" claim is gone; the second, `false` documented as "deny all", survives verbatim at `lib/tyrex.ex:141` and `README.md:184`. See BLOCKER-adjacent WARNING W1.

Deferred tracks confirmed genuinely untouched.

---

## BLOCKERS

### B1. `import()` bypasses all read permissions — `deny_import` is inert · **VERIFIED**
`native/tyrex/src/worker.rs:338` · flagged by security · PRE-EXISTING, but this release advertises the opposite

`module_loader` is `deno_core::FsModuleLoader`. Its `ModuleLoader::load` receives no `PermissionsContainer` and ends in a bare `std::fs::read`. `check_import`/`allow_import` appear nowhere in `deno_core-0.391.0` or `deno_runtime-0.246.0` — import enforcement lives only in Deno's CLI loader, which tyrex does not use.

I reproduced it. The agent's own repro used `type:"text"` and failed, which is why this looked clean; the real bypass is broader:

```
permissions: :none  import("file:///tmp/imp/secret.js")     -> "SECRET-FROM-DISK"
permissions: :none  import(".../secret.json", type:"json")  -> %{"secret" => "json-secret"}
permissions: :none  Deno.readTextFileSync(same file)        -> DENIED (correctly)
allow_all + deny_import: plain js import                    -> "SECRET-FROM-DISK"
```

Arbitrary file read under `permissions: :none`, and `deny_import: true` does not stop it. This is exactly the shape of the bug the release exists to fix — a documented control that silently does nothing — so shipping v0.4.0 with the permission table advertising `allow_import`/`deny_import` would re-commit the original sin in a new place.

Compounding: the new test `deny_import blocks dynamic ES module imports` (`test/tyrex_permissions_test.exs:109-128`) is a **false positive**. It uses an `https:` specifier that `FsModuleLoader` rejects as "not a file URL" regardless of permissions, and asserts only `err.name in [:promise_rejection, :execution_error]`.

Fix: wrap `FsModuleLoader` in a newtype that calls `PermissionsContainer::check_read` before delegating (the container is already in scope at `worker.rs:341`) — or remove `allow_import`/`deny_import` from the documented key set and say plainly that module loading is unrestricted. Either is defensible; silence is not.

### B2. Use-after-free: `Arc<HeapLimitState>` freed before the isolate on `worker::new`'s error paths
`native/tyrex/src/worker.rs:355-370` · flagged by rust-nif · **my bug, introduced by this change**

`heap_limit_state` is declared *after* `worker`. Rust drops locals in reverse declaration order, so on either post-registration `?` early return (`execute_script` at :381, `execute_main_module` at :390) the Arc is freed first and the isolate — still holding `near_heap_limit_callback` registered against that exact address — is destroyed afterwards. Isolate teardown can re-enter `Heap::InvokeNearHeapLimitCallback`, which dereferences freed memory and calls `terminate_execution()` on an `IsolateHandle` read out of it.

The `Worker` struct's "field order is load-bearing" comment is vacuous: `run` destructures immediately, so no `Worker` is ever dropped whole, and panic unwind bypasses the explicit `drop`s at :627-628 too.

The clean fix removes the `unsafe` entirely, and I confirmed it exists in the pinned crate: **`JsRuntime::add_near_heap_limit_callback`** (`jsruntime.rs:1851`) takes a safe `FnMut(usize, usize) -> usize` closure and stores it in `self.allocations`, a field declared *after* `inner` precisely so it outlives the isolate. That is the invariant I hand-rolled and got backwards. Capture an `Arc<AtomicBool>` in the closure for the `tripped` flag.

### B3. `RUSTLER_NIF_VERSION` is inert — shipping 2.15 binaries labelled 2.16 · **VERIFIED**
`native/tyrex/Cargo.toml:6-8` · flagged by release

rustler removed env-var NIF selection in 0.30; it is a Cargo feature now. Confirmed in the vendored manifest:

```
[features]
default = ["nif_version_2_15"]
nif_version_2_16 = ["nif_version_2_15"]
```

`rustler = "=0.38.0"` requests no features, so the crate compiles against **2.15**. Task 3.2's entire plumbing — workflow `env:`, the step re-export, `Cross.toml`, `docker-build.sh:123` — has zero effect on what is built. The only live use is string interpolation into the archive filename, which now asserts `nif-2.16` over a 2.15 binary.

Not a load failure today (2.15 loads on OTP 22+), but `README.md:627` is false, the CHANGELOG claims a fix that does not exist, and rustler gates `ErlNifResourceTypeInit.members` on `nif_version_2_16` — latent breakage the day anyone adds `Resource::down`.

Fix: `rustler = { version = "=0.38.0", features = ["nif_version_2_16"] }`, or relabel everything 2.15 and delete the three dead plumbing sites.

### B4. Stale checksum file will break installation on all four targets · consensus (release + requirements)
`checksum-Elixir.Tyrex.Native.exs`

Contains only v0.3.0 entries while `mix.exs` is now 0.4.0. `RustlerPrecompiled` resolves the artifact name, misses the local checksum map, and raises **before any network call** — so the failure is identical before and after the tag is pushed. Publishing in this state is strictly worse than the 3-of-4 partial publish this release prevents.

Nothing in `release.yml` regenerates it, and no runbook documents it. The ordering is load-bearing and undocumented: GitHub release → `mix rustler_precompiled.download --all --print` → `mix hex.publish`.

I flagged this myself before the review; both agents independently reached the same conclusion.

### B5. Guest-writable `Tyrex._runtimeId` breaks the per-runtime allowlist · consensus (rust-nif + security) · **introduced by this change**
`native/tyrex/extension/main.js:39`, `native/tyrex/src/worker.rs:16-46,378`

`_runtimeId` is a plain writable global. `op_apply` takes it as a JS argument and indexes the process-global `Slab<LocalPid>` with no check that the id belongs to the calling isolate. Slab ids are dense integers from 0 — trivially enumerable.

Before this release, spoofing bought nothing: every runtime had an unrestricted bridge. **This patch creates the boundary it violates.** A guest in a runtime whose allowlist is `[{Enum, :sum, 1}]` can set `_runtimeId` to a sibling's id and make that runtime's GenServer invoke *its* allowlist with attacker-chosen arguments:

```js
for (let i = 0; i < 32; i++) {
  globalThis.Tyrex._runtimeId = String(i);
  try { Tyrex.apply("System", "cmd", ["touch", ["/tmp/pwned"]]); } catch (_) {}
}
```

Blind (the reply routes to the victim's isolate and is dropped) but the side effect lands. Requires the attacker's own runtime to have the bridge enabled — `apply: false` runtimes are not usable as attackers, and are not usable as victims either.

Fix: carry the id in per-runtime `OpState` via the `extension!` state closure and read it inside `op_apply`. Also deletes the `parse::<usize>()` failure branch and the `_runtimeId` bootstrap script.

---

## WARNINGS

**W1. `false` documented as "deny all" is inverted for the eight `deny_*` keys · VERIFIED · this is task 1.5's named target**
`lib/tyrex.ex:141`, `README.md:184`

```
allow_read: false                        -> denied
deny_read: true                          -> denied
deny_read: false  (docs say "deny all")  -> READ OK (2154 bytes)
```

A reader following the docs writes `deny_run: false` expecting "deny all subprocesses"; with `allow_all: true` that is a live permission grant reached purely by following documentation. The Rust side documents the split correctly (`worker.rs:90-92`), so the implementation knows the polarity while the user-facing docs assert its opposite.

**W2. Heap cap is unprotected during bootstrap; a small `:max_heap_mb` aborts the BEAM**
`worker.rs:321-324` — `create_params` applies the cap at isolate creation, but the callback that converts a fatal OOM into a guest termination is only installed *after* `bootstrap_from_options` has run deno's bootstrap, snapshot deserialization and extension init. `validate_max_heap_mb!/1` accepts any `mb > 0`; the only test uses 64. A plausible `max_heap_mb: 8` kills the whole BEAM at `Tyrex.start/1` — the exact outcome the option exists to prevent. Needs a measured, documented floor.

**W3. `timeout: :infinity` silently disables the deadline on the non-blocking path**
`lib/tyrex.ex:532-537` — the blocking path refuses `:infinity`; the default path accepts it and arms no timer. The consequence is worse than the refused case: an uncapped 100%-CPU OS thread, invisible to scheduler monitoring — v0.4.0's headline defect, reachable through a documented option. Via `Pool.eval/3` it permanently consumes a pool slot.

**W4. `timeout: -1` crashes the runtime and its pool siblings**
`lib/tyrex.ex:532-542` — `:timeout` is never validated. `call_timeout(-1) = 999` is a legal call timeout, so it reaches the server and `Process.send_after(..., -1)` raises inside the GenServer. Under `:rest_for_one`, one caller's bad argument restarts every runtime after the selected one.

**W5. `terminate/2` and `blocking_eval/3` skip `fail_inflight/2`**
`lib/tyrex.ex:512-526` — every other terminal path drains in-flight callers; these two leave them to exit. `kill/1`'s docs explicitly promise `dead_runtime_error` for this situation. One fix covers both: call `fail_inflight/2` at the top of `terminate/2`.

**W6. `:noproc` exits contradict the documented return type**
`lib/tyrex.ex:337-342` — `@spec` says `{:ok, term} | {:error, Error.t()}`, but the new terminate⇒dead contract makes every deadline, heap trip and `kill/1` produce a window where the next call exits instead. The patch's own test works around it (`tyrex_lifecycle_test.exs:189-195`).

**W7. Heap test accepts `:timeout`, defeating its own purpose**
`test/tyrex_lifecycle_test.exs:166` — `assert name in [:heap_limit_error, :timeout]`. If a refactor drops `terminate_execution()` from the callback and keeps only the slack grant, the guest allocates until the eval deadline and returns `:timeout` — test green, BEAM-abort protection silently gone. Assert `== :heap_limit_error`.

**W8. The stale-timer test cannot observe a stale timer**
`test/tyrex_lifecycle_test.exs:45-50` — both evals use `timeout: 5_000` with a 200ms sleep, so an uncancelled timer fires ~4.8s after the test has finished. Deleting `cancel_timer/1` from the `:eval_reply` clause leaves this green.

**W9. CPU probe is hard-coded to 3 runaways and depends on `ps` resolution**
`test/tyrex_lifecycle_test.exs:217-244` — on a 2-vCPU CI runner the process caps at 2.0 cores and `running > baseline + 1.0` sits at the margin; on 1 vCPU it fails outright. `ps -o time=` has one-second resolution on Linux, making measurement error the same size as the one-leaked-thread signal. Scale to `System.schedulers_online()` and read `/proc/self/stat` on Linux. *This is the assertion the plan says must survive — harden it, do not drop it.*

**W10. `serde_v8` unwrap panics reachable under async termination**
`worker.rs:544` — this release makes termination asynchronous and arbitrary where it was previously observed only between operations. Under a pending termination, V8 returns empty `MaybeLocal`s and `serde_v8` unwraps them (upstream marks these "fixme: this unwrap is not safe"). The worker runs on a bare `std::thread::spawn`, so a panic skips slab removal and promise drain, and hits B2's UAF. Contain with `catch_unwind`.

**W11. Publish guard does not assert the tag matches `mix.exs`**
`.github/workflows/release.yml:341-350` — tagging `v0.4.1` on a commit whose `mix.exs` says `0.4.0` produces four `v0.4.0` archives on the `v0.4.1` release. The count guard sees 4 and publishes: atomic and uniformly wrong.

**W12. `Cross.toml` is packaged but its Dockerfile is not**
`mix.exs:44` — same class of omission as the `.cargo/config.toml` bug this release fixes. Cleanest resolution is dropping `Cross.toml` from `package.files`; it is CI infrastructure.

---

## SUGGESTIONS

- **S1.** `allow_all: ["/tmp"]` parses to `PermValue::List`, `matches!(..., True)` quietly yields false. Fails closed, but contradicts the parser's own stated principle that a typo in a security control must never be silently ignored. (`worker.rs:191-194`)
- **S2.** Heap slack is a flat +8MB per invocation, so the ceiling ratchets. deno's own usage returns `current * 2`. (`worker.rs:296`)
- **S3.** `assert :ok = Tyrex.kill(...)` is a tautology — `kill/1` ends in `catch :exit, _ -> :ok`. In one test it is the *only* assertion. (`tyrex_lifecycle_test.exs:84-89`)
- **S4.** Several fail-closed permission tests assert bare `%Tyrex.Error{}` and would pass on any error.
- **S5.** Untested: `Pool` forwarding of `:apply`/`:max_heap_mb`, the one-time `Logger.warning`, `apply: []`, `stop/1`'s escalation branch, multi-caller `fail_inflight`.
- **S6.** Plan's deno-bump deferral rationale — "Phase 1–3 work touches none of the files the bump touches" — is now false; `worker.rs` changed across 418 lines. The deferral stands on its other reason; strike the clause so the follow-up is not sized off a false premise.

---

## What the release got right

Worth recording, because the panel confirmed it independently:

- Allowlist design is sound. No bypass found via string aliasing, unicode, arity confusion, or `decode_args`/`apply/3` disagreement. Resolving the module from the allowlist value rather than guest input holds up.
- Permission polarity in the rewritten parser verified correct against Deno's `PermissionsOptions` semantics.
- `terminate_runtime`'s non-dirty scheduling, `Runtime::drop`, `eval_blocking`'s `block_on`, the sticky termination flag, and NIF panic containment all verified correct against vendored sources.
- The in-flight state machine has no leaked entries, no double replies, no missing replies on any traced path.
- Atomic publish: no path to a 3-of-4 partial release could be constructed.
- All five original audit escape vectors are closed, and the 299.6% CPU leak genuinely returns to 0.00.
