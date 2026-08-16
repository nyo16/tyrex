# Plan: tyrex v0.4.0 — Sandbox Integrity

**Slug:** `sandbox-integrity`
**Created:** 2026-08-14
**Input:** `.claude/audit/summaries/project-health-2026-08-14.md` (audit at e61bba8) + downstream consumer feedback (Nous "Code Mode")
**Research:** none spawned — the audit findings are the research (Iron Law #7). Every CRITICAL was reproduced on this machine before planning.

## Problem

tyrex advertises a sandbox. Two independent reviews — my audit and a downstream
integrator reading the same commit — landed on the same two defects:

1. **`Tyrex.apply` is an unrestricted Elixir gateway.** Installed
   unconditionally, consults no `PermissionsContainer`, no module allowlist.
   Proven: under `permissions: :none`, Deno's own `readTextFileSync` is correctly
   denied, while the bridge delivers `File.read!` and shell execution via
   `:os.cmd`.
2. **There is no way to kill a runaway program.** `terminate_execution` appears
   nowhere in `native/`. `:timeout` is only a `GenServer.call` timeout — the
   caller gives up, the JS keeps running.

For tyrex's documented SSR/templating uses, (1) is a feature. For any
untrusted-code consumer it is a full escape, and `README.md:199` actively
recommends `permissions: :none` for "untrusted code".

### Consumer requirement (drives Phase 1 priority)

A downstream integration is blocked on these two items, with the standard stated
as: *"a BEAM process deadline for wall clock. The kill is real — no
`worker.terminate()` race to lose."* Their comparison table scores tyrex
`real kill: no` — that cell is the deliverable of Phase 2.

Their proposed consumer-side mitigation for (1) — delete `globalThis.Tyrex`
before evaluating model code, plus `deny_import` — **does work**, and I verified
why: `ext:` modules are structurally unimportable from user code by deno_core's
module loader, independently of `deny_import`.

```
delete globalThis.Tyrex                     -> "undefined"
import("ext:core/ops")                      -> TypeError: Importing ext: modules is only allowed from ext: and node: modules
import("ext:extension/main.js")             -> TypeError: (same)
typeof Deno?.core?.ops?.op_apply            -> "undefined"   # Deno.core is not exposed at all
```

So the hole is closable from outside today. But it is **opt-out, undocumented,
and load-bearing on an implementation detail**. Task 1.1 makes it opt-in and
supported so consumers stop depending on deleting a global.

### One correction to the consumer's analysis

They wrote that `eval` is `schedule = "DirtyCpu"` and that a runaway
"permanently consumes a dirty-CPU scheduler thread, which defaults to one per
core... N runaway programs = N lost cores."

The conclusion is right; the mechanism is wrong, and the real bound is worse:

- `eval` (`lib.rs:98`) has **no** `schedule =` attribute. It returns immediately
  after spawning onto tokio. `eval_blocking` (`lib.rs:137`) is the `DirtyCpu` one.
- The runaway therefore burns the **per-runtime OS thread** spawned at
  `lib.rs:23` (`std::thread::spawn` + its own current-thread tokio runtime).
- That is **not capped at `dirty_cpu_schedulers`**. Measured: 3 runaways →
  `299.6%` CPU *after* all three runtimes were stopped and their Elixir
  processes were dead, while `blocking: true` still returned `{:ok, 42}` on a
  fresh runtime and `run_queue` was `1`.

Consequences for the consumer: there is no core-count ceiling on the leak, and
because it is not a dirty scheduler, BEAM scheduler-utilization monitoring will
not show it. `stop/1` returning `:ok` is not evidence of reclamation.

## Scope decision

**One plan, v0.4.0, security + lifecycle only.** The audit's remaining tracks are
explicitly deferred below rather than dropped. Rationale: a 19-minor dependency
bump must not ride along in a release whose whole purpose is restoring trust in
the sandbox.

v0.4.0 is a **breaking** release. The project is pre-1.0 and v0.3.0 was itself a
hardening release, so this is consistent with its trajectory.

---

## Phase 1 — Close the escape `[rust] [elixir] [docs]`

- [x] **1.1 Make the apply bridge opt-in**  `[elixir] [rust]`
      _Done: `:apply` option, `false` default; allowlist keyed by the exact JS strings so guest input never mints atoms; bridge-off deletes `globalThis.Tyrex`_
      Add `:apply` to `Tyrex.start/1` opts: `false` (default) | `[{Module, :fun, arity}, ...]`.
      - Rust: pass the flag through `permissions_json` (or a new arg) so
        `worker::new` only runs the `Tyrex._runtimeId` seed and installs the
        bridge when enabled; when disabled, `delete globalThis.Tyrex` after
        bootstrap so no reference survives.
      - Elixir: enforce the allowlist in `handle_info({:apply, ...})`
        (`lib/tyrex.ex:304`) **before** `to_module/1`. Reject with a
        `:permission_denied` `Tyrex.Error`, never a crash.
      - Keep `function_exists?/3`, but check the allowlist first — arity match
        alone is not authorization.
- [x] **1.2 Permission parsing must fail closed**  `[rust]`
      _Done: tri-state `PermValue` parser; malformed/unknown-shape/unknown-key/non-string-entry all return Err; empty list = grants nothing_
      `native/tyrex/src/worker.rs:59-121`:
      - Malformed JSON / non-object shape → return `Err`, not
        `PermissionsContainer::allow_all` (`worker.rs:83-88, 96-105`).
      - `allow_X: false` must deny even under `allow_all: true`. Today
        `parse_string_list(Bool(false))` → `None` → `or_else(allow_default)` →
        `Some(vec![])` = allow-all (`worker.rs:116-121`).
      - Distinguish "empty allowlist" from "unrestricted": `allow_read: []`
        currently grants the whole filesystem (`worker.rs:61`).
- [x] **1.3 Reject unknown permission keys**  `[elixir]`
      _Done: `@permission_keys` validated in `encode_permissions/1`, raises ArgumentError_
      `encode_permissions/1` (`lib/tyrex.ex:402`) silently accepts typos;
      `[deny_nett: true]` yields a permissive runtime reporting success. Validate
      against the known key set and raise `ArgumentError`.
- [x] **1.4 Flip the default to deny-by-default**  `[elixir] [docs]`
      _Done: default `:none`; one-time `Logger.warning` via `:persistent_term` when `:permissions` omitted_
      `permissions:` default `:allow_all` → `:none` (`lib/tyrex.ex:68,256`).
      Breaking; headline the CHANGELOG entry with the one-line migration
      (`permissions: :allow_all` restores old behaviour).
- [x] **1.5 Correct the documentation**  `[docs]`
      _Done: README rewritten (no 'safe for untrusted code'); moduledoc warns `:permissions` never governed Elixir reachability_
      `README.md:140,199` ("safe for untrusted code") and `lib/tyrex.ex:79,82`
      (`false` documented as "deny all"). Document the bridge as a privileged
      capability, and that `permissions:` governs Deno I/O only — not Elixir
      reachability. **Ship this even if the rest slips**; it is docs-only.
- [x] **1.6 Tests for each of the above**  `[elixir]`
      _Done: 17 tests incl. all 4 audit reproductions + 5 native-parser tests that bypass Elixir validation_
      Port the four reproductions from the audit into `test/tyrex_permissions_test.exs`:
      bridge denied by default; allowlisted MFA permitted; non-allowlisted MFA
      rejected; `[allow_all: true, allow_run: false]` denies run; malformed
      permission JSON refuses to start; `allow_read: []` is not the whole filesystem.

**Verify:** `mix compile --warnings-as-errors && mix format --check-formatted && mix test`
plus the audit's escape script must now fail on every vector.

## Phase 2 — Make the kill real `[rust] [elixir]`

The API exists in the pinned deno_core; no dependency bump required.
`worker.js_runtime.v8_isolate().thread_safe_handle()` yields a `Send + Sync`
`v8::IsolateHandle` with `terminate_execution()` / `cancel_terminate_execution()`.

- [x] **2.1 Carry an `IsolateHandle` on the runtime resource**  `[rust]`
      _Done: `isolate_handle` on `runtime::Runtime`, captured in `worker::new` before the ResourceArc ships_
      Add `isolate_handle: deno_core::v8::IsolateHandle` to
      `runtime::Runtime` (`native/tyrex/src/runtime.rs:3`). Capture it in
      `lib.rs:46-55` after `worker::new()` succeeds and before the `ResourceArc`
      is sent to Elixir, so the handle ships with the resource.
- [x] **2.2 Add a `terminate_runtime/1` NIF**  `[rust]`
      _Done: plain NIF (terminate_execution is thread-safe/non-blocking); `@spec` added to all 5 stubs_
      Plain (non-dirty) NIF — `terminate_execution()` is thread-safe and
      non-blocking by design. Declare the stub in `lib/tyrex/native.ex` with a
      `@spec` (the audit found no `@spec` on any of the 5 stubs).
- [x] **2.3 Recover the isolate after termination**  `[rust]`
      _Done: RESOLVED: terminate => dead, no cancel_terminate_execution. `is_execution_terminating()` alone is unreliable (V8 clears it once the termination propagates out), so the heap cap carries a sticky flag_
      In `worker::run` (`worker.rs:308`), a terminated `execute_script` returns
      an uncatchable error. Reply `{:error, :timeout}` to that request's sender,
      call `cancel_terminate_execution()`, and keep serving — or tear the runtime
      down deterministically. Pick one and encode it in a test; do not leave it
      implementation-defined.
- [x] **2.4 Track in-flight requests and arm a per-request deadline**  `[elixir]`
      _Done: `inflight` map keyed by `from`; `Process.send_after` deadline; call timeout = deadline + 1s grace so the server wins the race_
      The GenServer keeps no in-flight map, so it cannot attribute a timeout to a
      request (audit: arch MEDIUM). Store `from` by request id, arm
      `Process.send_after(self(), {:deadline, id}, timeout)`, and on fire call
      `Native.terminate_runtime/1` and reply `{:error, %Tyrex.Error{name: :timeout}}`.
      This makes `:timeout` a real deadline instead of a caller-side giveaway.
- [x] **2.5 Fix `blocking: true` — deadlock and dirty-scheduler pinning**  `[rust] [elixir]`
      _Done: `recv_timeout` via tokio `timeout`, moved to `DirtyIo`, `blocking: true` refused with the bridge on and with `timeout: :infinity`_
      `blocking_recv()` (`lib.rs:151`) has no timeout and deadlocks against the
      bridge: `handle_call` parks while `op_apply` needs that same GenServer.
      Proven — the call times out and the runtime is then permanently unusable.
      Use `recv_timeout`, move the NIF to `DirtyIo` (it parks on I/O, not CPU),
      and reject `blocking: true` when the bridge is enabled.
- [x] **2.6 Bound `stop/1`'s default timeout**  `[elixir]`
      _Done: default 5_000, escalates to `Process.exit(pid, :kill)`; resource Drop terminates the isolate so a brutal kill still reclaims the thread_
      `lib/tyrex.ex:135` defaults to `:infinity`; a caller who does not override
      it hangs forever on a wedged runtime. Default to something finite and
      escalate to `terminate_runtime` + brutal kill.
- [x] **2.7 Set a V8 heap limit**  `[rust]`
      _Done: `:max_heap_mb` -> `CreateParams.heap_limits`; near-heap-limit callback terminates + grants 8MB slack so V8 unwinds instead of abort()ing the BEAM_
      `create_params` is never configured, so a guest OOM `abort()`s the whole
      BEAM. Add a `:max_heap_mb` option and a near-heap-limit callback.
- [x] **2.8 Regression tests for the kill**  `[elixir]`
      _Done: 15 lifecycle tests; the 3-runaway probe measured 2.99 cores -> 0.0 after stop/1_
      `for(;;){}` must return `{:error, :timeout}` within the deadline; the
      runtime must be usable (or deterministically dead) afterwards; **and CPU
      must return to idle after `stop/1`** — the audit's 3-runaway/299.6% probe
      becomes the regression test. Also cover worker crash + pool recovery and
      `:dead_runtime_error`, all three of which are currently untested.

**Verify:** `mix test`, plus the audit's leak probe (`3 runaways → stop → ps %cpu`)
must show CPU returning to baseline.

## Phase 3 — Release integrity `[ci] [rust]`

- [x] **3.1 Ship `native/tyrex/.cargo/config.toml`**  `[rust]`
      _Done: added to `package.files`; verified present in the built tarball_
      Missing from `mix.exs` `package.files` (musl `-crt-static` rustflags), while
      `README.md:407,418` sends Alpine/NixOS users to source builds — so the
      documented install path is broken from Hex.
- [x] **3.2 Set `RUSTLER_NIF_VERSION` in `release.yml`**  `[ci]`
      _Done: single workflow-level `env:` source of truth, derived into cargo build, archive name and cache key_
      Never set, while `nif-2.16` is hardcoded in artifact names;
      `scripts/docker-build.sh:123` and `Cross.toml` treat it as required, so the
      three build paths disagree.
- [x] **3.3 Make publishing all-or-nothing**  `[ci]`
      _Done: per-leg publish deleted; new `publish` job `needs: [build_nif]` with a 4-artifact count guard_
      `release.yml:126` `if: always()` + `fail-fast: false` + per-leg publish can
      ship 3 of 4 archives against a 4-entry checksum file.
- [x] **3.4 Align the rustler pair**  `[rust]`
      _Done: Elixir `~> 0.38.0` + crate `=0.38.0`; both build clean_
      Elixir `rustler 0.37.3` vs Rust crate `0.36.2`. Move both to `0.38.0` and
      pin the crate with `=` so drift cannot recur — rustler's own version guard
      is dead code (zero callers), so the drift is silent. The 0.38 removals
      (`resource!`, explicit `init!` listing) are already migrated.
- [x] **3.5 CHANGELOG + version bump to 0.4.0**  `[docs]`
      _Done: v0.4.0 entry; Changed leads with the two breaking items_
      Follow the existing Added/Changed/Fixed structure. Lead **Changed** with
      the two breaking items (default permissions, bridge opt-in).

**Verify:** `mix hex.build` succeeds and the packaged tarball contains
`.cargo/config.toml`; dry-run the release workflow.

---

## Completeness check

Every audit finding is either a task above or explicitly deferred. No finding is dropped.

| Audit finding | Severity | Disposition |
|---|---|---|
| apply bridge = sandbox escape | CRITICAL | 1.1, 1.5 |
| `blocking: true` deadlock | CRITICAL | 2.5 |
| Permission parse fails open | CRITICAL | 1.2 |
| `allow_X: false` inversion | CRITICAL | 1.2 |
| Default `:allow_all` | CRITICAL | 1.4 |
| `allow_read: []` = whole FS | HIGH | 1.2 |
| Unknown permission keys dropped | HIGH | 1.3 |
| No terminate_execution / real kill | HIGH | 2.1–2.4, 2.8 |
| Runaway leaks 100%-CPU thread | HIGH | 2.3, 2.8 |
| No V8 heap limit | HIGH | 2.7 |
| `stop/1` timeout `:infinity` | MEDIUM | 2.6 |
| `{:ok, {}} = apply_reply` MatchError | MEDIUM | 1.1 |
| No in-flight request map | MEDIUM | 2.4 |
| No `@spec` on NIF stubs | MEDIUM | 2.2 |
| Eval timeout / crash-recovery / `:dead_runtime_error` untested | HIGH | 1.6, 2.8 |
| `.cargo/config.toml` unpackaged | HIGH | 3.1 |
| `RUSTLER_NIF_VERSION` unset | HIGH | 3.2 |
| Partial-publish risk | HIGH | 3.3 |
| rustler pair mismatch | HIGH | 3.4 |
| Global `Mutex<Slab>` across `enif_send` | HIGH | **Deferred → perf plan** |
| Apply-reply triple encode + `execute_script` | HIGH | **Deferred → perf plan** |
| No snapshot / `v8_code_cache` | MEDIUM | **Deferred → perf plan** |
| Unbounded mpsc, no backpressure | MEDIUM | **Deferred → perf plan** |
| Per-call atom interning in pool dispatch | MEDIUM | **Deferred → perf plan** |
| Pool strategy state freed by non-owner | HIGH | **Deferred → arch plan** |
| `:dead_runtime_error` contract (stop-without-reply) | MEDIUM | **Deferred → arch plan** |
| `Tyrex` god module / API duplication | LOW | **Deferred → arch plan** |
| deno stack 19 minors behind | — | **Deferred → bindings plan** |
| 3 of 5 test files could be async | LOW | **Deferred → test-hygiene plan** |
| Vacuous assertions, dead fixtures, no TS test | MEDIUM | **Deferred → test-hygiene plan** |
| No clippy / Rust tests / credo / dialyzer | MEDIUM | **Deferred → CI plan** |
| Unpinned third-party GitHub Actions | MEDIUM | **Deferred → CI plan** |

Deferred follow-up plans, in recommended order: **perf** (lock + serialization),
**bindings** (deno lockstep — one code edit, two constraint fixes), **arch**,
**test-hygiene**, **CI**.

## Risks

- **2.3 is the one genuinely uncertain task.** V8 termination is uncatchable and
  leaves the isolate in a poisoned state until `cancel_terminate_execution()`.
  Whether a `MainWorker` reliably survives termination mid-`execute_script`
  needs a spike before committing to "recover" over "tear down". Budget for
  discovering that teardown is the only safe answer.
- **1.4 breaks every existing user silently** — their JS loses I/O with no
  compile error. Mitigation: the CHANGELOG one-liner, and consider emitting a
  one-time `Logger.warning` when `permissions:` is omitted, for one release.
- **1.1 changes a documented feature.** The README advertises "call any Elixir
  function". Anyone using the bridge must now pass an allowlist.
- **Phase 2 does not make tyrex safe for model-authored code on its own.**
  Bridge + kill + heap limit close the known holes; they do not constitute an
  audited sandbox boundary. Say so plainly in the README rather than
  re-inheriting the `:none` overclaim in a new form.

### Self-check

- *What would make this plan wrong?* If the downstream consumer's real
  requirement is process-level isolation, no amount of in-process hardening
  reaches their bar and the honest answer is out-of-process deno (their own
  table already scores that `real kill: yes`). Phase 2 buys a real deadline, not
  a security boundary.
- *What is most likely to be skipped under pressure?* 2.8 — the CPU-returns-to-idle
  assertion. Without it, a future refactor silently reintroduces the thread leak.
- *What did the audit not look at?* The `examples/` and `bench/` trees, and
  `native/tyrex/extension/` beyond `main.js`.
