# Testing Review — v0.4.0 sandbox integrity

**Verdict:** REQUIRES CHANGES

**Scope reviewed:** `test/tyrex_api_test.exs` (new, 11 tests), `test/tyrex_lifecycle_test.exs` (new to git), `test/tyrex_permissions_test.exs` (+428), `test/tyrex_pool_test.exs` (+69), `test/tyrex_test.exs` (+13/-2). Production code read only as far as needed to decide whether an assertion can fail.

**How verified:**
- `git diff master -- test/` for every changed line; `lib/tyrex.ex` diff read in full for the paths the new tests claim to defend.
- `TYREX_BUILD=true mix test --seed 0` → **160 passed**; `--seed 999999` → **160 passed**. No order dependence observed across the two seeds.
- Four live probes against the real arm64 build (`mix run`, scripts in `/tmp`, repo untouched):
  1. `Deno[Deno.internal].core.ops` reachability under `permissions: :none` and under `apply: [...]`.
  2. A stub `GenServer` driven through the **real** `Tyrex.eval/2` to establish what an undrained in-flight caller observes.
  3. `:max_heap_mb` boundary sweep (0 / 1 / 31 / 32).
  4. Transitive static import under a guest `import()` with a partial `allow_read`.
- Crate/OTP sources read rather than guessed: `deno_permissions-0.97.0/src/lib.rs:3908-3960` (`check_specifier`), `stdlib-8.0/src/proc_lib.erl:1586-1618` (`stop/3` timeout semantics).

---

## Blockers

### The in-flight drain tests cannot fail — `dead_runtime_exit?/1` manufactures the exact value they assert
- **Where:** `test/tyrex_api_test.exs:97`, `test/tyrex_api_test.exs:113`, `test/tyrex_lifecycle_test.exs:81`
- **What:** All three assert only `{:error, %Tyrex.Error{name: :dead_runtime_error}}`. Task 2.3 (review W5) added `fail_inflight(state, :dead_runtime_error)` to `terminate/2` (`lib/tyrex.ex`, `terminate/2`) so pending callers are *replied to*. Task 2.4 (review W6) independently added `dead_runtime_exit?/1`, which maps `:noproc`, `:normal` and `{:shutdown, _}` exits to a struct with **the same `:name`**. A caller that is *not* drained therefore exits `:normal` (plain `stop/1`) or `{:shutdown, :killed}` (`kill/1`), gets laundered by `eval/2`'s `catch`, and produces a value indistinguishable from the drain at the granularity these tests assert.
- **Why it matters:** W5 was a WARNING in the prior review precisely because `kill/1`'s docs promise `dead_runtime_error` and two terminal paths did not deliver it. The fix is real; the tests written to defend it are tautologies. Delete `fail_inflight` from `terminate/2` and from `handle_call(:kill, ...)` and all three tests stay green — which is the Phase 4 failure class this whole phase exists to eliminate. The plan's Phase 2 verify block asserts "Covered by two new tests in `test/tyrex_api_test.exs`"; that claim is false.
- **Evidence (OBSERVED, `/tmp/probe2.exs`, `/tmp/probe3.exs`, run via `TYREX_BUILD=true mix run`):** a stub `GenServer` that accepts the call, never replies, and has **no drain logic whatsoever**, stopped with `:normal`:

  ```
  caller result when server stops :normal with NO drain: {:error,
   %Tyrex.Error{
     message: "the runtime was already gone when this call was made, or died before it could reply",
     name: :dead_runtime_error, value: nil}}
  ```

  and stopped with `{:shutdown, :killed}` (the `kill/1` reason):

  ```
  shutdown/killed exit, NO drain: {:error,
   %Tyrex.Error{
     message: "the runtime was already gone when this call was made, or died before it could reply",
     name: :dead_runtime_error, value: nil}}
  ```

  The two producers differ only in `:message` — `"…already gone…"` from the `catch` in `eval/2`, `"the runtime was terminated while this call was in flight"` from `fail_inflight/2`. The author already knows this: `test/tyrex_api_test.exs:135` asserts `message =~ "already gone"` to pin the *other* side of the same fork.
- **Suggested direction:** assert the drain-specific message (`message =~ "in flight"`) in all three tests, so the assertion selects the producer rather than the name. Optionally strengthen `test/tyrex_api_test.exs:101` by also asserting the elapsed time is far below the 30 000 ms call timeout, which distinguishes "replied" from "exited" independently of the message text.

---

## Warnings

### `"the underlying op is not reachable"` checks a path that is dead for an unrelated reason
- **Where:** `test/tyrex_permissions_test.exs:314-318`
- **What:** `assert {:ok, "undefined"} = Tyrex.eval("typeof Deno?.core?.ops?.op_apply", pid: pid)`. `Deno.core` is itself `undefined` in this build, so the optional-chain short-circuits at the *first* hop. The assertion is satisfied by every possible op name and says nothing about `op_apply`. The op table that actually exists is at `Deno[Deno.internal].core.ops`.
- **Why it matters:** this is the only test defending "guest code cannot re-acquire the bridge op", i.e. the last line of the v0.4.0 apply-bridge boundary. The plausible regression — the op becoming visible on the op table deno actually exposes, e.g. through an `extension!` change, a deno bump, or someone dropping `deno_core`'s internal-only marking — leaves the test green. Two independent things are being conflated: "the op table is unreachable" (false) and "`op_apply` is not in it" (true today).
- **Evidence (OBSERVED, `/tmp/probe_internal.exs`, `/tmp/probe2.exs`):** under both `permissions: :none` and `apply: [{Enum, :sum, 1}]`:
  ```
  typeof Deno?.core                    -> "undefined"
  typeof Deno.internal                 -> "symbol"
  typeof Deno[Deno.internal].core.ops  -> "object"
  Object.keys(Deno[Deno.internal].core.ops) -> ["op_base64_encode","op_napi_open","op_set_exit_code"]
  typeof Deno?.core?.ops?.op_apply     -> "undefined"
  typeof Deno?.core?.ops?.op_read_all  -> "undefined"   <-- an op that exists in deno_core; same answer
  ```
  The last line is the proof: the checked expression yields `"undefined"` for a name unrelated to this patch, so it is not measuring reachability of anything.
  Secondary: the test is titled *"even with the global deleted"* but starts the runtime with `apply: [{Enum, :sum, 1}]`, so `typeof globalThis.Tyrex` is `"object"` — the scenario in the title is never constructed.
- **Suggested direction:** assert against the live table — `typeof Deno[Deno.internal].core.ops.op_apply` — and additionally enumerate it (`Object.keys(...).filter(k => k.startsWith("op_apply"))` is empty). Run it on an `apply: false` runtime, after `delete globalThis.Tyrex`, so the title describes the test.

### The `:max_heap_mb` floor — the whole of task 1.6 — has no test that can see it
- **Where:** `test/tyrex_lifecycle_test.exs:214-218`
- **What:** the only cap-validation test is `max_heap_mb: 0` against `~r/positive integer/`. Task 1.6 replaced `mb > 0` with `is_integer(mb) and mb >= @min_heap_mb` (32) and deliberately kept the words "positive integer" in the new message so this assertion would keep matching. That decision means the assertion is satisfied by **both** guards.
- **Why it matters:** review W2's defect was that `max_heap_mb: 8` `abort()`s the entire BEAM inside `bootstrap_from_options`, before the near-heap-limit callback can exist. Relax the guard back to `mb > 0` — a one-token regression, and the kind a future reader might make because the message still says "positive integer" — and the suite is green while the release's stated protection is gone. Losing the whole VM is a strictly worse outcome than any other failure in this file.
- **Evidence (OBSERVED, `/tmp/probe3.exs`):**
  ```
  max_heap_mb: 0  -> {:raised, msg contains "positive integer"}
  max_heap_mb: 1  -> {:raised, msg contains "positive integer"}
  max_heap_mb: 31 -> {:raised, msg contains "positive integer"}
  max_heap_mb: 32 -> :started
  ```
  Rows 1 and 2 are also true of the pre-1.6 guard; only rows 3 and 4 discriminate, and neither is asserted anywhere in `test/`.
- **Suggested direction:** a boundary test — `max_heap_mb: 31` raises with a message naming `32`, `max_heap_mb: 32` starts and stops cleanly. That is the pair no weaker guard can satisfy.

### Blocker B5 (guest-writable `_runtimeId`) shipped with no regression test
- **Where:** `test/tyrex_permissions_test.exs:276-402` (the `"the apply bridge is a privileged capability"` block, where such a test belongs)
- **What:** `grep -rn "runtimeId" test/ lib/ native/tyrex/extension/` returns nothing. Task 1.4 moved the runtime id into per-runtime `OpState`, closing a cross-runtime confused-deputy escalation. The plan's Phase 1 verify table records a manual probe of the spoof; no test encodes it.
- **Why it matters:** B5 was a BLOCKER, it was *introduced by* the v0.4.0 patch, and its exploit is four lines of JavaScript. The regression is concrete: reintroduce `#[string] runtime_id` as an `op_apply` argument (or re-add the `_runtimeId` bootstrap script) and a guest in an `apply: [{Enum, :sum, 1}]` runtime again drives a sibling's allowlist. Nothing in 160 tests notices. Every other blocker in this release has a test; this one does not.
- **Evidence:** the grep above (empty), plus the plan's own verify table, which lists "cross-runtime `_runtimeId` spoof" among probes run by hand rather than among tests.
- **Suggested direction:** two runtimes with disjoint allowlists (`[{Enum, :sum, 1}]` and `[{String, :upcase, 1}]`); from the first, set `globalThis.Tyrex._runtimeId = "<n>"` for a small range of ids and call `Tyrex.apply("String","upcase",["x"])`; assert every attempt rejects with `permission_denied`. The current build also answers `typeof Tyrex._runtimeId === "undefined"`, which is a cheaper second assertion in the same test.

### Task 2.5 (`allow_all` given a list) is not covered by the native-parser test block
- **Where:** `test/tyrex_permissions_test.exs:453-501` (`describe "the native parser refuses malformed input"`)
- **What:** the block covers five malformed shapes — invalid JSON, non-object top level, unknown preset, unknown key, non-string list entry — and reaches the Rust parser directly via `Tyrex.Native.start_runtime/5`, which is exactly the right shape. `{"allow_all": ["/tmp"]}` is not among them.
- **Why it matters:** 2.5 replaced `matches!(perm, PermValue::True)` with an exhaustive `match` that rejects `List(_)` (`native/tyrex/src/worker.rs:297-309`). Revert that one expression and the parser silently reinterprets `allow_all: ["/tmp"]` as `allow_all: false` — the single behaviour the block's own header comment ("they used to answer every one of them with `PermissionsContainer::allow_all`") exists to forbid. Green suite.
- **Evidence:** `grep -n "allow_all" test/` shows no occurrence inside the native-parser block; the eight matches are all Elixir-side `permissions:` options.
- **Suggested direction:** one more case in the existing block: `~s({"allow_all": ["/tmp"]})` asserting the message mentions `allow_all` and "not a list" / "baseline".

### A guest `import()` of a permitted file that statically imports a forbidden one is untested
- **Where:** `test/tyrex_permissions_test.exs:207-219` (`"the same file imports fine once read is granted"`)
- **What:** the positive control imports a leaf module with no static dependencies. The enforcement's correctness rests on deno propagating `is_dynamic_import` through `RecursiveModuleLoad` to every transitive dependency — the exact property design decision 1 leans on, and the exact property that separates "a check" from "a whole-filesystem read primitive".
- **Why it matters:** narrow the check to the top-level dynamic specifier (a plausible "simplification" of the double `resolve`/`load` check, which already looks redundant to a reader) and a guest with `allow_read: ["/one/dir"]` regains arbitrary file read via a one-line trampoline module placed in that directory. Every existing import test still passes: they all import leaves.
- **Evidence (OBSERVED, `/tmp/probe4.exs`):** with `permissions: [allow_read: ["/tmp/tyrex_probe_a"]]`, a guest `import("file:///tmp/tyrex_probe_a/entry.js")` where `entry.js` statically imports `/tmp/tyrex_probe_b/secret.js` currently yields
  `"DENIED: Requires read access to \"/tmp/tyrex_probe_b/secret.js\", run again with the --allow-read flag"`.
  The behaviour is right; nothing pins it.
- **Suggested direction:** extend the existing `setup` fixture with a second directory and add one test asserting the transitive read is denied while the entry module itself is readable.

### The CPU probe leaks three runaway runtimes when its first assertion fails
- **Where:** `test/tyrex_lifecycle_test.exs:282-286`
- **What:** `assert running > baseline + burn_floor` sits *above* `Enum.each(pids, &Tyrex.stop(pid: &1))`, and there is no `on_exit`. If the burn assertion fails, three runtimes each spinning `for(;;){}` survive for the remainder of the VM.
- **Why it matters:** the leak is measured at ~1.0 core per runtime (the plan's own Phase 4 table: 3 runaways → 3.02 cores). The same file contains four wall-clock-bounded assertions whose order relative to this test is seed-dependent — `:16` (`elapsed < 3_000`), `:42` (`refute_receive … 600`), `:86` (`elapsed < 2_000`), `:126` (`elapsed < 10_000`) — plus `test/tyrex_api_test.exs`'s `Task.await(…, 10_000)`s. One honest red therefore turns into a cascade of unrelated reds on the next tests in the same VM, which is how a genuine regression gets misdiagnosed as "flaky CI" and the probe gets deleted. That is precisely the outcome the v0.4.0 plan flagged as most likely for this assertion.
- **Evidence:** read of `test/tyrex_lifecycle_test.exs:260-305`; no `on_exit` is registered in that test or in the enclosing `describe`. Same pattern (`Supervisor.stop/1` as the last statement rather than in `on_exit`) appears in `test/tyrex_pool_test.exs:185,198,222` and `test/tyrex_lifecycle_test.exs:249`, but those leak an idle pool rather than three burning cores.
- **Suggested direction:** register `on_exit(fn -> Enum.each(pids, &Tyrex.stop(pid: &1)) end)` immediately after the runtimes are started, and keep the explicit stop where it is (it is load-bearing for the measurement, not just for cleanup).

---

## Suggestions

### Arm the receive trace before the evals, not after
`test/tyrex_lifecycle_test.exs:45-59`. The construction is sound and the plan saw it red — but the two `timeout: 300` evals complete *before* `:erlang.trace(pid, true, [:receive])` is called. The whole 300 ms of timer life is spent unobserved; any stall longer than that between the second eval returning and the trace being armed (a GC pause, a loaded CI box, an unlucky scheduler) makes `refute_receive` vacuously true. That is fail-closed: the test silently stops testing rather than going red. Moving `:erlang.trace/3` above the two evals removes the race entirely; the `$gen_call` and `:eval_reply` trace messages it additionally collects do not match the refute pattern and are simply skipped by the selective receive.

### The JSON-import denial does not check *why* it was denied
`test/tyrex_permissions_test.exs:190-206` asserts only `%Tyrex.Error{name: :promise_rejection}`. Its `.js` sibling at `:169` uses `import_message/2` and asserts `"Requires read access"`; this one does not, so a future breakage of JSON module support (or any other loader-level failure) reads as a permission denial. The helper already exists two screens down — one extra `assert {:ok, message} = import_message(pid, specifier)` closes it.

### The server-side `timeout == :infinity` guard is unreachable from the tests
`lib/tyrex.ex`'s `handle_call({:eval, …})` puts `timeout == :infinity` first in its `cond` specifically "so it guards both paths for anyone calling this GenServer directly". `eval/2` refuses `:infinity` before the call, so no test reaches that clause. A direct `GenServer.call(pid, {:eval, "1", [timeout: :infinity]}, 5_000)` asserting `{:error, %Tyrex.Error{name: :unsupported_option}}` is one line and defends a guard whose failure mode is the uncapped 100 %-CPU worker thread this release exists to eliminate.

### Cross-file isolation is sound; recording it so nobody "fixes" it
Checked rather than assumed. `test/tyrex_api_test.exs:193` registers `on_exit(fn -> :persistent_term.put({Tyrex, :permissions_warned}, true) end)` **before** the `erase`, so the restore survives a mid-test failure; and because the test erases the flag itself rather than depending on being first, the one-shot `Logger.warning` is deterministic under any seed. Pool names (`:basic_pool`, `:rr_pool`, `:perm_pool`, `:apply_pool`, `:no_apply_pool`, `:heap_pool`, `:recovery_pool`, `:conc_pool`) and the one named runtime (`:deadline_dead`) are all distinct. `System.tmp_dir!` fixtures are `File.rm_rf!`'d in `on_exit`. `--seed 0` and `--seed 999999` both give 160 passed. The `on_exit`-before-`erase` ordering is load-bearing and non-obvious; it is worth a one-line comment saying so.

### Verified sound, recorded so it is not re-litigated
- **`stop/1` escalation (`test/tyrex_api_test.exs:152-173`) genuinely exercises the kill branch.** I checked `proc_lib:stop/3` (`stdlib-8.0/src/proc_lib.erl:1586-1618`): on timeout it `demonitor`s and `exit(timeout)`s the *caller*; it never signals the target. So the only producer of `:killed` is `stop/1`'s own `Process.exit(pid, :kill)`, and a graceful stop yields `:normal`. The DOWN reason does distinguish them, and wedging the GenServer through the apply bridge is the right lever — a non-blocking runaway leaves the GenServer idle.
- **The `/proc/self/stat` parsing is correct.** Splitting on `")"` and taking `List.last/1` survives a `comm` containing parentheses or spaces; after `trim`, index 0 is field 3 (`state`), so `utime` (field 14) is index 11 and `stime` (field 15) is index 12 — as coded. `USER_HZ` is 100 for the `/proc` ABI regardless of `CONFIG_HZ`, so the hardcoded constant is right; a wrong value would scale every reading uniformly and could only make the probe *more* likely to fail, not less.
- **The Darwin `ps` comment is accurate.** `ps -o time= -p <pid>` on this machine prints `00:51` — whole seconds, no fraction — which is what the 0.5-core ceiling and the 4 s window are sized for.
- **The panic-containment path (task 1.7) is not reachably testable from Elixir** and I am not asking for a test. Triggering it requires a `serde_v8` unwrap to fire under a pending termination, which has no deterministic trigger through the public API. The observable consequence — a leaked slab entry and hung callers — is already covered indirectly by the drain tests, once those are fixed per the blocker above.
- **`data:` and `blob:` import specifiers need no test.** `deno_permissions-0.97.0/src/lib.rs:3942-3943` returns `Ok(())` for both unconditionally, but `FsModuleLoader` then rejects them as non-`file:` URLs, so they are inert in this build. Confirmed by probe: `import("data:text/javascript,export default 7")` rejects with `ERR_MODULE_NOT_FOUND` under both `:none` and `allow_all: true, deny_import: true`.
- **`apply_reply` when the worker is gone** (the `{:error, %Error{}}` arm of `handle_info({:apply, …})`) has no test, and I could not construct a deterministic trigger: it needs the worker dead while an apply round-trip is in flight, and every Elixir-side route to killing the worker also stops the GenServer. Recording it as a known, accepted gap rather than asking for a flaky test.

---

## Persistent prior findings

None of the 23 survive as originally written. Checked directly:

- **W7** — `test/tyrex_lifecycle_test.exs:205-211` now asserts `name: :heap_limit_error` by equality plus `{:DOWN, …, {:shutdown, :heap_limit_error}}`; the `in [...]` form is gone from the tree (`grep -n "name in \[" test/` matches only a comment at `test/tyrex_permissions_test.exs:151` describing the old anti-pattern).
- **W8** — the window is now inside the test and observed by trace. Fixed; see the suggestion above for the residual arming race, which is a different defect.
- **W9** — scaled to `System.schedulers_online()` with an absolute idle ceiling; `/proc` path verified correct above.
- **S3** — `assert :ok = Tyrex.kill(...)` still appears at `test/tyrex_lifecycle_test.exs:95` and `:114`, but is no longer the only assertion in either test: both now bound elapsed time and one adds `refute Process.alive?/1`. The tautology is retained as a smoke check, which is fine.
- **S4** — one bare `%Tyrex.Error{}` remains, in an unchanged region (see below); all eight in `test/tyrex_permissions_test.exs` now pin `:name`, and five also pin the `--allow-<perm>` flag text.
- **S5** — four of five paths covered. The `:apply`/`:max_heap_mb` pool forwarding tests are real: `Tyrex.Pool.Strategy.RoundRobin.init/2` seeds its counter at `size - 1` so the first `select/2` returns index 0 (`lib/tyrex/pool/strategy/round_robin.ex:11-18`), which makes the "two calls exercise both children" claim at `test/tyrex_pool_test.exs:167-176` true on a fresh pool rather than merely likely. The `fail_inflight` multi-caller test is the one that regressed into a tautology — see the blocker.

---

## Pre-existing (one line each)

- `test/tyrex_test.exs:274` — `assert {:error, %Tyrex.Error{}}` on "throw string" passes on any error; PRE-EXISTING (unchanged region).
- `test/tyrex_test.exs:26` — `assert {:error, _} = Tyrex.start(main_module_path: "nonexistent/file.js")` does not distinguish a missing file from any other startup failure; PRE-EXISTING.
- `test/tyrex_test.exs:341` — same shape for `syntax_error.js`; PRE-EXISTING.
- `test/tyrex_pool_test.exs:185,198,222` and `test/tyrex_lifecycle_test.exs:249` — `Supervisor.stop/1` as the final statement rather than in `on_exit`, so a mid-test failure leaks a named pool; PRE-EXISTING pattern, low cost (idle runtimes).
