# Iron Laws Review — v0.4.0 sandbox integrity

**Verdict:** REQUIRES CHANGES
**Scope reviewed:** all 24 changed files, weighted to `lib/tyrex.ex`, `native/tyrex/src/worker.rs`, `native/tyrex/src/lib.rs`, `README.md`, `CHANGELOG.md`, `.github/workflows/release.yml`, `mix.exs`, `test/tyrex_permissions_test.exs`. Brief: inert controls, overclaiming docs, error swallowing.

## Which law list

**This project does not codify Iron Laws.** There is no `CLAUDE.md` at the repo root (`glob CLAUDE.md` → missing), and `.claude/` contains only plans and audit reports. The `Iron Law #5` / `#7` references in `.claude/plans/*/plan.md:6` point at the `oliver-kriska/elixir-phoenix` plugin, whose 26-law list lives outside the repo at `~/.claude/plugins/marketplaces/oliver-kriska/CLAUDE.md:581-643` (and its injectable template at `plugins/elixir-phoenix/skills/init/references/injectable-template.md:107-146`). That list is LiveView/Ecto/Oban-shaped; the only two laws with any surface here are **#10 (no `String.to_atom` on user input)** and **#14 (comments carry durable facts, not commit messages)**.

- **#10 — clean, and deliberately so.** `authorize/4` (`lib/tyrex.ex:741-754`) keys the allowlist map on the guest's *strings* and takes the module/function atoms from the allowlist value. Guest input never reaches `String.to_atom`. The comment at `lib/tyrex.ex:735-740` names exactly that.
- **#14 — clean.** Comments throughout cite the concrete defect they prevent (e.g. `worker.rs:66-85`, `lib/tyrex.ex:73-84`). Two of my findings below are that a comment *asserts a guarantee the code does not provide* — a #14-adjacent failure, not a #14 violation.

Everything else below is judged against the three hazards named in the brief.

---

## Blockers

### `Tyrex.kill/1` does not work on the case it is documented for, and returns `:ok` anyway

- **Where:** `lib/tyrex.ex:274-276` (doc), `lib/tyrex.ex:290-294` (the catch), `README.md:376-378`, `CHANGELOG.md:56-58`
- **What:** All three docs sell `kill/1` as the escape hatch `stop/1` cannot provide. `lib/tyrex.ex:274-276`: *"Unlike `stop/1` this works on a runtime that is wedged inside a guest that never yields — `while (true) {}` cannot be stopped cooperatively, only terminated."* `README.md:376-377`: *"`Tyrex.kill/1` terminates a runtime immediately, without waiting for in-flight JavaScript."* But `kill/1` is `GenServer.call(server, :kill)` — it needs the GenServer to be in its receive loop, exactly like `stop/1`. When the GenServer is parked inside `Native.eval_blocking/3` (a `blocking: true` eval on a non-yielding guest — the literal documented scenario), the call cannot be served, exits with `:timeout` after the 5s default, and `catch :exit, _reason -> :ok` at `lib/tyrex.ex:292-293` converts that into a reported success. The relationship the docs assert is in fact **inverted**: `stop/1` escalates to `Process.exit(pid, :kill)` and does tear the runtime down; `kill/1` has no escalation at all.
- **Why it matters:** This is the release's own bug class — a documented security/lifecycle control that silently does nothing while reporting success — reintroduced in a function this release **adds**. An operator who followed the docs and used `kill/1` on a wedged runtime is told the runtime is dead. It is not: it is still alive, still inside the NIF, still burning the OS thread the release exists to reclaim. Under `Tyrex.Pool` that slot stays occupied and the supervisor is never told anything is wrong.
- **Evidence:** OBSERVED on the real build (`TYREX_BUILD=true mix run`, arm64):

  ```
  # runtime wedged by:  Tyrex.eval("for(;;){}", pid: pid, blocking: true, timeout: 60_000)
  kill/elapsed/alive:  {:ok, 5001, true}
  alive after:         true
  cur:                 {:current_function, {Tyrex.Native, :eval_blocking, 3}}

  # same wedge, stop/1 instead of kill/1
  blocking stop:       {:ok, 5002, false}      # process actually gone

  # control: non-blocking runaway, where the GenServer is idle
  nonblocking kill:    {:ok, 0, false}         # kill/1 works here
  ```

  So the claim holds only for the non-blocking case, and fails for the blocking case that the wording ("wedged inside a guest that never yields") most directly describes. `.claude/plans/sandbox-integrity-fixes/plan.md` task 4.6 already records the mechanism — *"`blocking: true` parks it in a dirty NIF where `Process.exit(:kill)` is deferred, so neither reaches the escalation path"* — so the behaviour was known when the docs were written.
- **Suggested direction:** Two honest options, mirroring the B1 fork. (a) Make it true: `kill/1` needs a path that does not go through the GenServer mailbox — the isolate handle is reachable without it, so terminating from the caller (or having the caller drop the last `ResourceArc` reference) would work regardless of what the server is doing. (b) Say what it is: `kill/1` and `stop/1` have identical reachability; the difference is the exit reason and the escalation, and neither can preempt a `blocking: true` eval before that eval's own deadline. Either way, narrow the `catch` so a `:timeout` exit is *not* reported as `:ok` — returning `{:error, :not_stopped}` (or letting it propagate) is the minimum. `:ok` on a no-op is what makes this a blocker rather than a doc nit.

---

## Warnings

### The op-reachability test cannot fail — `Deno.core` is undefined in every runtime

- **Where:** `test/tyrex_permissions_test.exs:314-318`
- **What:** `assert {:ok, "undefined"} = Tyrex.eval("typeof Deno?.core?.ops?.op_apply", pid: pid)`, with the comment *"Deno.core is not exposed, so the op cannot be re-acquired directly."* That comment states the reason the assertion is **vacuous**, as if it were the property under test. `deno_runtime`'s bootstrap moves `core` to `Deno[Deno.internal].core`, so `Deno.core` is `undefined` in every tyrex runtime and the whole optional chain short-circuits before it ever looks for `op_apply`. The assertion would pass unchanged if `op_apply` were fully exposed on the surface guest code can actually reach. Two further problems in the same test: its name says *"even with the global deleted"* but it starts with `apply: [{Enum, :sum, 1}]`, i.e. the bridge **enabled** and `globalThis.Tyrex` **not** deleted (`worker.rs:486-489` only runs the delete when `!apply_enabled`); and the `ext:` half runs under the default `permissions: :none`, so it is refused by the new import permission check rather than by structural unimportability (the comment concedes this).
- **Why it matters:** This is the only automated guard on "the op cannot be re-acquired", which is the load-bearing half of the `apply: false` claim in `README.md:488-490`, `CHANGELOG.md:34-35`, `lib/tyrex.ex:34-36` and the comment at `worker.rs:480-484`. It is a guard that cannot fire. Same shape as prior B1's false-positive `deny_import` test, which task 1.2 fixed — the class recurred one file over.
- **Evidence:** OBSERVED, probing the real build under `permissions: :none` and under `apply: [...]`:

  ```
  Deno.core:                      "undefined"     <- why the assertion passes
  Deno.core.ops:                  "undefined"
  typeof Deno?.core?.ops?.op_apply: "undefined"   <- the asserted expression
  Deno[Deno.internal].core:       "object"        <- the reachable surface
  Deno[Deno.internal].core.ops:   "object"
  Object.keys(...core.ops):       "op_base64_encode,op_napi_open,op_set_exit_code"
  typeof ...core.ops.op_apply:    "undefined"     <- the property actually worth pinning
  ```

  The property is genuinely true today (`op_apply` is absent from the reachable ops table) — the defect is entirely in the test, which proves nothing about it.
- **Suggested direction:** Assert against `Deno[Deno.internal].core.ops`, not `Deno.core`. Pin both directions so the test can go red: `typeof Deno[Deno.internal].core.ops.op_apply === "undefined"` **and** a positive control asserting the same expression finds a known op (e.g. `op_base64_encode`), so a future rename of the internal accessor turns the test red instead of silently vacuous again. Also fix the test name/setup mismatch: run it with `apply: false` if it means to test the global-deleted case, or rename it.

### `CHANGELOG.md:41` — "so the server always wins the race" is false and observably so

- **Where:** `CHANGELOG.md:38-41`
- **What:** *"The `GenServer.call` timeout is now the deadline plus a 1s grace so the server always wins the race."* `call_timeout/1` (`lib/tyrex.ex:607`) adds a fixed 1000ms. That grace covers scheduler jitter, not GenServer occupancy: the `{:deadline, from}` message can only be processed when the server reaches its receive loop, and a `blocking: true` eval parks it inside the NIF for up to *its* timeout. A concurrent caller's own `GenServer.call` timeout is ticking the whole time — and the deadline for that caller has not even been armed yet, because `arm_deadline/3` runs inside `handle_call`.
- **Why it matters:** `lib/tyrex.ex:368-370` documents the exact opposite and is correct: *"a `:timeout` exit from `GenServer.call/3` itself means the server-side deadline lost its race, which is a bug and must not be swallowed."* The CHANGELOG tells users a failure mode cannot occur; `eval/2` deliberately re-raises it. The user-visible effect is an `:exit` escaping `eval/2`, which breaks the `@spec` that prior W6's fix (`dead_runtime_exit?/1`) was written to restore — so W6 is **PARTIAL**, not closed, for this path.
- **Evidence:** OBSERVED. Runtime wedged by a background `blocking: true` eval; second caller does `Tyrex.eval("1+1", pid: pid, timeout: 100)`:

  ```
  second caller with timeout: 100: {:EXITED, :timeout}
  ```
- **Suggested direction:** Replace "always wins the race" with the accurate statement — the grace is 1s of scheduling headroom, and the server can still lose it when it is occupied (blocking eval, a slow allowlisted `:apply` callback). Point at `lib/tyrex.ex:368-370`, which already says it properly.

### "pinned so the drift cannot silently recur" — nothing enforces the pin in the direction that drifts

- **Where:** `CHANGELOG.md:51-52`, `native/tyrex/Cargo.toml:5-14`
- **What:** `CHANGELOG.md:51`: *"Aligned the rustler pair: Elixir `~> 0.38.0` and the Rust crate `=0.38.0`, pinned so the drift cannot silently recur."* `Cargo.toml:5-6` makes the same claim: *"Pinned with `=` so it cannot drift from the Elixir-side `:rustler` dep again. rustler's own version guard has zero callers, so drift is otherwise silent."* But only one side is pinned. `mix.exs:86` is `{:rustler, "~> 0.38.0", optional: true}`, which admits every `0.38.x`. A `mix deps.update rustler` moves the Elixir side to `0.38.1` while Cargo stays hard-pinned at `0.38.0` — reproducing precisely the mismatch, and by the comment's own admission doing so silently, because the guard that would catch it has no callers.
- **Why it matters:** B3's whole lesson was that the NIF-version plumbing asserted something nothing checked. The new CI guard (`release.yml:251-260`) closes the *feature* half properly, but nothing anywhere compares the rustler crate version to `mix.lock`. The claim in the CHANGELOG is stronger than the mechanism.
- **Evidence:** `mix.exs:86` `{:rustler, "~> 0.38.0", optional: true}` vs `native/tyrex/Cargo.toml:14` `rustler = { version = "=0.38.0", features = ["nif_version_2_16"] }`. No grep hit for any check comparing the two: the only version assertion in `release.yml` is the `nif_version_2_16` feature grep at :256.
- **Suggested direction:** Either pin the Elixir side exactly (`"== 0.38.0"`), or extend the existing `release.yml` guard — it already reads `Cargo.toml`; having it also scrape `mix.lock`'s rustler version and compare is a three-line addition in a step that already exists. If neither, downgrade the sentence to "both currently sit at 0.38.0" and drop "cannot silently recur".

### `allow_import` grants nothing — the new import docs describe a capability that cannot be enabled

- **Where:** `README.md:237` (key table), `README.md:246-249`, `lib/tyrex.ex:180-183`
- **What:** The new docs present `allow_import`/`deny_import` as a two-way control over non-`file:` imports: `README.md:249` *"so `deny_import: true` blocks `https:` imports"*, table row *"Dynamic ES module imports of non-`file:` specifiers (`https:` and friends)"*. `deny_import` is now genuinely live (verified). `allow_import` is not, and cannot be: `PermissionedModuleLoader` delegates to `deno_core::FsModuleLoader` (`worker.rs:86-89`), which only loads `file:` URLs. Every non-`file:` specifier fails at `load` regardless of permissions. So the pair is a deny-only control, and the "allow" half is decorative.
- **Why it matters:** Fail-closed, so not a hole — but it is the documented-control-that-does-nothing shape, in the section written to close exactly that. A reader granting `allow_import: ["deno.land"]` for an SSR runtime gets `ERR_MODULE_NOT_FOUND` with a message about file URLs and no indication that remote imports are simply unsupported. Prior B1 explicitly offered Option B ("say plainly that module loading is unrestricted"); Option A was taken and made `deny_import` real, but nobody re-checked the allow direction.
- **Evidence:** OBSERVED on the real build:

  ```
  permissions: :allow_all              + import("https://deno.land/std@0.224.0/version.ts")
    -> ERR_MODULE_NOT_FOUND ~ Provided module specifier "https://..." is not a file URL.
  permissions: [allow_import: true, allow_net: true, allow_read: true] + same import
    -> ERR_MODULE_NOT_FOUND ~ ... is not a file URL.
  permissions: [allow_all: true, deny_import: true] + same import
    -> "Requires import access to \"deno.land:443\", run again with the --allow-import flag"
  ```

  (`data:` and `blob:` are additionally exempted by `check_specifier` itself — `deno_permissions-0.97.0/lib.rs:3941-3942` returns `Ok(())` for both unconditionally — but they too then die in `FsModuleLoader`, so no grant leaks.)
- **Suggested direction:** State it in the table row and in "Dynamic `import()` vs. the main module": non-`file:` module loading is not supported at all; `deny_import` moves the failure from "not a file URL" to an explicit permission denial, and `allow_import` cannot make a remote import succeed. One sentence, and it is the difference between a documented control and a decorative one.

### README lists three forwarded pool options; `Tyrex.Pool` forwards five, including `:apply`

- **Where:** `README.md:407-408`, `README.md:665-666`
- **What:** Both say the pool forwards `:permissions`, `:max_heap_mb` and `:main_module_path`. `lib/tyrex/pool.ex:64` takes `[:main_module_path, :permissions, :startup_timeout, :apply, :max_heap_mb]`, `pool.ex:48` documents `:apply`, `CHANGELOG.md:66` announces it, and `test/tyrex_pool_test.exs` covers it.
- **Why it matters:** The omitted option is the privileged bridge. `README.md:665` sits directly under the runtime-options table and reads as the authoritative enumeration, so a reader can reasonably conclude a pooled runtime never has the bridge. In a README whose new Security Scope section is otherwise careful, the one option a security reader most needs to see in that list is the one missing from it.
- **Evidence:** `README.md:665` vs `lib/tyrex/pool.ex:64` and `lib/tyrex/pool.ex:48`.
- **Suggested direction:** Add `:apply` (and `:startup_timeout`) to both sentences, or point them at `pool.ex`'s own list so the two cannot diverge again — the duplication is already a known residue.

---

## Suggestions

### `stop/1`'s catch-all `:exit` is wider than the two cases its comment names

`lib/tyrex.ex:248-255`. The comment says *"The runtime did not shut down in time, or was already gone"*, but `catch :exit, _reason` also swallows a `terminate/2` that raises, an abnormal stop reason, and anything else `GenServer.stop/3` surfaces — after which `Process.exit(pid, :kill)` runs and `:ok` is returned regardless. The same patch introduced `dead_runtime_exit?/1` (`lib/tyrex.ex:634-638`) to do exactly this classification narrowly for `eval/2`, with a comment explaining why swallowing a `:timeout` there would hide a bug. Reusing that predicate here — escalate on `:timeout`/`:noproc`/`:normal`/`{:shutdown, _}`, re-raise otherwise — would make the two paths consistent and stop a crashing `terminate/2` from being invisible. (`kill/1`'s identical catch at `:292-293` is covered by the blocker above.)

### `README.md:689` — NIF 2.16 means OTP 24+, not OTP 27+

The sentence the patch extended still says *"Precompiled binaries require **OTP 27+** (NIF version 2.16)"*. `deps/rustler_precompiled/lib/rustler_precompiled.ex:74-76` and `PRECOMPILATION_GUIDE.md:165-167` both state `2.16` is for **OTP 24 and above** (`2.17` is OTP 26+). The parenthetical asserts an equivalence that is two major OTP releases off, in the one sentence this release rewrote to correct the NIF-version story. Conservative direction — it turns users away rather than breaking them — but the fix is one number.

### Worker diagnostics go to `eprintln!`, invisible to `Logger`

Eleven sites in `worker.rs` (`:42, :617, :624, :652, :667, :695, :745, :767, :778, :790, :804`) plus one in `lib.rs`'s panic handler write to process stderr. The one that costs most is `worker.rs:623-627`: an `_applyReply` `execute_script` failure means a guest promise will never settle, and Elixir sees nothing until that eval's deadline fires and reports `:timeout` — a correct-looking error with the wrong cause. Under a release running behind a `:logger` handler, none of these appear in application logs. Routing them through the owning pid (the runtime id is in scope at every site, and `util::send_to_pid` already exists) would put them where an operator looks. At minimum, say in `Tyrex.Native`'s docs that the worker writes to stderr.

### `assert_checksums_current!/1` proves one entry exists, not four

`mix.exs:110-125`. It correctly fails on a missing file (`contents` defaults to `""`) — I checked that specifically, it is not vacuous. But `String.contains?(contents, "-v#{@version}-nif-")` is satisfied by a single matching line, while the whole point of the surrounding machinery (`release.yml:379-386`, `EXPECTED=4`) is that a partial artifact set is the failure being prevented. Counting matches against the four `targets:` in `lib/tyrex/native.ex:12-17` would make the guard as strong as the CI check it mirrors. Low likelihood — `--all` writes all four — but the guard currently asserts less than its own docstring implies.

---

## Things I checked and did **not** find fault with

Recording these because each was a named candidate and reading settled it:

- **`release.yml:251-260`'s Cargo.toml grep is not vacuous.** It greps `"nif_version_2_16"` *with double quotes*; the explanatory comment block above the dependency writes it in backticks (`Cargo.toml:8`), so the only match is the live `features = [...]` line at `Cargo.toml:14`. It fires on the drift it was written for.
- **The publish job's guards fail closed with empty variables.** GitHub runs `run:` under `bash -e`. If the `sed` at `release.yml:353` misses, `PROJECT_VERSION` is empty: the tag guard compares against `"v"` and exits 1, and the checksum guard greps `-v-nif-` and exits 1. Neither is satisfiable vacuously.
- **The workflow does fire on tag pushes.** The `paths:` filter under `on.push` is not evaluated for tag pushes (GitHub documents this only in community discussions, e.g. community#165354, dorny/paths-filter#107), so the new tag-only `publish` job is reachable. Not inert.
- **The `import()` enforcement claims in `worker.rs:66-85` are accurate against the pinned crates.** `ModuleMap::load_dynamic_import` resolves with `ResolutionKind::DynamicImport` before consulting the cache (`deno_core-0.391.0/modules/map.rs:1290-1292`), which is why the `resolve` check is load-bearing; `RecursiveModuleLoad` propagates `is_dynamic_import` into every transitive `load` (`recursive_load.rs:393-413`). Both claims read as stated.
- **`op_apply` is genuinely unreachable from guest code.** Only `op_base64_encode`, `op_napi_open`, `op_set_exit_code` appear on `Deno[Deno.internal].core.ops`. The *claim* holds; only the test guarding it does not (see the warning above).
- **`invoke/3`'s `rescue`** (`lib/tyrex.ex:756-770`) is justified and its comment names the case: an allowlisted function raising must reject the promise, not destroy the runtime, and the exception type survives into the message. The adjacent `catch kind, reason` has no comment, but it is the same argument one level out and I could not construct a bug it hides.
- **`catch_unwind` in `start_runtime`** (`lib.rs:47-105`) does what the CHANGELOG says: `try_remove(runtime_id)` runs on unwind, and the `startup_reported` `Cell` prevents both a double reply and a 30s wait on the panic-at-startup path.

---

## Persistent prior findings

**None of the 23 survive verbatim.** I spot-checked the ones in my lane: W1's inverted `false` is fixed and split by direction in both places (`lib/tyrex.ex:157-171`, `README.md:238-247`); B3's inert `RUSTLER_NIF_VERSION` is gone with the feature enabled and a CI guard behind it; B1's `deny_import` is live (probe above); B1's false-positive test is replaced with six that read the message inside the isolate.

Two qualifications:

- **W6 is PARTIAL, not closed.** `dead_runtime_exit?/1` restores `eval/2`'s `@spec` across the terminate-means-dead window, but a `GenServer.call` `:timeout` still escapes as an exit and is reachable whenever the server is occupied — observed above. That is deliberate (`lib/tyrex.ex:368-370` says so), but `CHANGELOG.md:41` tells users it cannot happen.
- **B1's *class* recurred.** The prior review's own lesson was that a guard can pass against a completely unguarded implementation. `test/tyrex_permissions_test.exs:318` is a new instance of that, in the file task 1.2 was written to fix.

## Pre-existing (one line each)

- `native/tyrex/src/worker.rs:459` — `let _ = ...install_default();` swallows the rustls provider result with no comment; benign (it errors only when already installed) but unexplained. PRE-EXISTING.
- `native/tyrex/src/worker.rs:524-528` — `let _ = response_sender.send(...).ok();` double-discards; `.ok()` is redundant after `let _ =`. PRE-EXISTING.
