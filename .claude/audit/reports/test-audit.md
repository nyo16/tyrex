# Test Health Audit — tyrex

Scope: `test/**` (108 tests, 0 failures, 26.2s wall — 0.1s async / 26.0s sync; suite NOT re-run for this audit),
`lib/**` read only to enumerate the public surface. Coverage figures below are **estimates** — no `mix test --cover`
was run.

Mox / `verify_on_exit!` / `set_mox_global` criteria are **N/A**: the project defines no mocks, no behaviours stubbed in
test, and no `Mox` dependency.

## Score: 44/100

```
start                                                              100
- public-API coverage: 4 untested public functions x -5             -20   (cap -30)
    Tyrex.eval/1, Tyrex.eval!/1, Tyrex.stop/0, Tyrex.Error.message/1
- flake patterns: 2 timing-dependent assertions x -5                -10   (cap -20)
    tyrex_test.exs:36 (startup_timeout: 1 race)
    tyrex_test.exs:439 (implicit 5s Task.await_many + 5s GenServer.call)
- async where possible: 3 files x -2                                 -6   (of 15)
    tyrex_test.exs, tyrex_permissions_test.exs, tyrex_sigil_test.exs
- isolation / shared-state hygiene: 2 x -5                          -10   (of 15)
    no on_exit cleanup on ~20 happy-path-only teardowns
    VM-global assertions (:persistent_term.info().count, :ets.all())
- suite duration: 26.0s of 26.2s is serial                           -5   (of 10)
- error paths: crash-recovery + eval-timeout + dead_runtime_error    -5   (of 10)
                                                                  -----
                                                                     44
```

Zero deduction taken for: absence of property-based round-trip tests (MEDIUM finding below, no bucket),
`Process.sleep`/`:timer.sleep` (**none exist** — genuinely clean), bare `receive`/`assert_receive` (none exist).

## Findings

### [HIGH] No worker-crash / pool-recovery test — the supervision contract is unverified
- Location: `test/tyrex_pool_test.exs:1-215` (whole file); nearest neighbour `test/tyrex_pool_test.exs:5-6`
- Evidence:
```elixir
    sup
    |> Supervisor.which_children()
```
  `which_children/1` is used only to *count* runtimes (`tyrex_pool_test.exs:22-25`, `29-32`). A repo-wide grep for
  `Process.exit`, `kill`, and `restart` in `test/` returns **no matches**.
- Impact: `Tyrex.Pool` is a `Supervisor` over N `Tyrex` GenServers, each owning a Deno worker thread behind a
  `ResourceArc`. Nothing proves that killing one runtime (a) gets restarted, (b) re-registers under
  `:"pool.Runtime.N"` so the strategy's index→name mapping still resolves, or (c) leaves the pool able to serve the
  next `eval`. The most likely production failure of an embedded-runtime library — a worker dying mid-flight — has
  zero coverage. `Tyrex.Error{name: :dead_runtime_error}`, which `lib/tyrex.ex:291` explicitly handles by stopping
  the GenServer, is never produced in any test.
- Fix: add `describe "pool recovery"` with a test that resolves a runtime pid via
  `Supervisor.which_children/1`, `Process.exit(pid, :kill)`, waits for the supervisor to replace it via
  `:sys.get_state(sup)` (or a monitor + `assert_receive {:DOWN, ...}, 5_000`), then asserts
  `{:ok, 3} = Tyrex.Pool.eval(pool, "1 + 2")` and that the child count is restored. Add a sibling single-runtime test
  asserting an in-flight `eval` against a killed runtime returns
  `{:error, %Tyrex.Error{name: :dead_runtime_error}}`.

### [HIGH] Eval timeout path is untested despite a 5s default
- Location: `lib/tyrex.ex:205-211` (behaviour under test), no covering test in `test/`
- Evidence:
```elixir
  def eval(code, opts) do
    GenServer.call(
      Keyword.get(opts, :pid) || Keyword.get(opts, :name, __MODULE__),
      {:eval, code, opts},
      Keyword.get(opts, :timeout, 5000)
    )
```
  No test in `test/` passes `timeout:` to `Tyrex.eval/2` (grep for `timeout:` in `test/` matches only
  `startup_timeout: 1` at `tyrex_test.exs:36`). No test evaluates long-running or non-terminating JS.
- Impact: the documented `:timeout` option has no coverage, and the consequences of exceeding it are unspecified by
  the suite: a `GenServer.call` timeout **exits the caller** while the JS keeps running and the runtime later sends
  `{:eval_reply, from, result}` to a stale `from` (`lib/tyrex.ex:331`). Whether that orphaned reply corrupts the next
  call, leaks, or crashes the runtime is exactly what a test should pin down. A `blocking: true` eval of a hot loop
  additionally occupies a dirty scheduler — also untested.
- Fix: add `describe "eval/2 - timeouts"`: (1) `catch :exit, Tyrex.eval("while(true){}", pid: pid, timeout: 100)`
  asserting the exit reason is `{:timeout, _}`, followed by an assertion that the runtime still answers a subsequent
  `Tyrex.eval("1 + 2")` (or is deliberately dead) — this documents the orphaned-reply semantics; (2) a positive test
  that `timeout: 10_000` lets a ~6s promise resolve, proving the option is actually threaded through.
  Tag both `@tag timeout: 30_000`.

### [MEDIUM] 3 of 5 test files are `async: false` without a shared-state justification
- Location: `test/tyrex_test.exs:2`, `test/tyrex_permissions_test.exs:2`, `test/tyrex_sigil_test.exs:2`
- Evidence:
```elixir
defmodule TyrexTest do
  use ExUnit.Case, async: false
```
  (identical line in all three; only `test/tyrex_strategy_test.exs:2` uses `async: true`.)
- Impact: 26.0s of the 26.2s wall clock is serial. Each of these files spins up its own Deno runtimes and the
  dominant per-test cost is runtime startup, which is exactly what module-level parallelism would overlap. Per-file
  verdict:
  - `tyrex_test.exs` — **can be async**. Every runtime is an anonymous pid from `Tyrex.start()` (line 42 etc.); the
    one global registration, `:test_named` (line 13), is unique across the suite; `Process.flag(:trap_exit, true)`
    (line 33) is process-local.
  - `tyrex_permissions_test.exs` — **can be async**. Per-test anonymous pids; the only global name, `:perm_pool`
    (line 133), is unique. `Deno.env.get('HOME')` is a read, never a write.
  - `tyrex_sigil_test.exs` — **can be async**. All runtime binding goes through the *process dictionary*
    (`Tyrex.Inline.set_runtime/1`), which ExUnit already isolates by running each test in its own process; the named
    runtime `:sigil_test_runtime` (line 137) is unique. `Code.compile_string/1` (line 149) serialises on the compiler
    lock but is correct concurrently.
  - `tyrex_pool_test.exs` — **must stay sync**. Genuine VM-global assertions: `:persistent_term.info().count`
    (lines 198, 211) and the full `:ets.all()` scan (lines 185, 193) observe state any concurrent pool would perturb.
  - `tyrex_strategy_test.exs` — already `async: true`; correct, its ETS table names are unique per test.
- Fix: flip the three files to `async: true`. If cross-file Deno worker pressure is a concern on small CI runners,
  bound it with `ExUnit.start(max_cases: System.schedulers_online())` in `test/test_helper.exs` rather than by
  serialising every file.

### [MEDIUM] Teardown only runs on the happy path — a single failure cascades
- Location: `test/tyrex_permissions_test.exs:9,22,29,38,50,59,74,81,94,106,124,144`; `test/tyrex_pool_test.exs:18,25,32,38,54,76,100,122,136,153,172`; `test/tyrex_test.exs:16,22,315,324,337,412,413,420,423,442`; `test/tyrex_sigil_test.exs:105,120,121,142,168`
- Evidence:
```elixir
    test "can read env" do
      {:ok, pid} = Tyrex.start()
      {:ok, home} = Tyrex.eval("Deno.env.get('HOME')", pid: pid)
      assert is_binary(home)
      Tyrex.stop(pid: pid)
    end
```
  (`test/tyrex_permissions_test.exs:25-30` — the whole file uses trailing `Tyrex.stop/1` / `Supervisor.stop/1` with
  **no `on_exit`**; `on_exit` appears only in the 10 `setup` blocks of `tyrex_test.exs` and `tyrex_sigil_test.exs`.)
- Impact: when an assertion raises, the trailing stop never executes. A leaked `Tyrex` GenServer keeps a Deno worker
  thread and its V8 isolate alive for the remainder of the run (memory + scheduler pressure that can convert one real
  failure into a cascade of timeouts). Worse for pools: `Tyrex.Pool.start_link(name: :basic_pool, ...)` registers
  `:"basic_pool.Supervisor"` globally and writes `:persistent_term`, so a leak makes the *next* test using that name
  fail with `{:error, {:already_started, _}}` and poisons the `:persistent_term` leak assertion at
  `tyrex_pool_test.exs:212`. Failures then no longer localise to the broken test.
- Fix: replace every trailing stop with `on_exit(fn -> ... end)` registered immediately after start, e.g.
  `on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)`. Better: hoist a
  `ExUnit.CaseTemplate`-based `TyrexCase` exposing `start_runtime/1` and `start_pool/1` helpers that register cleanup
  automatically, and use it everywhere.

### [MEDIUM] VM-global state assertions couple tests to the whole BEAM
- Location: `test/tyrex_pool_test.exs:197-212`
- Evidence:
```elixir
      base = :persistent_term.info().count
      ...
      after_count = :persistent_term.info().count
      assert after_count - base <= 1
```
  and `test/tyrex_pool_test.exs:185-186`:
```elixir
      ets_names_before = :ets.all() |> Enum.map(&:ets.info(&1, :name))
      assert :"cleanup_pool.RoundRobin" in ets_names_before
```
- Impact: these assert over *all* `persistent_term` entries and *all* ETS tables in the node. They permanently forbid
  `async: true` for this file, they break the moment any library (or a future `Tyrex` feature) writes a
  `persistent_term` during the run, and the `<= 1` tolerance is an admitted fudge that would silently absorb a real
  one-entry leak. `:ets.all/0` is also O(all tables) and grows with the runtime count.
- Impact is a *test-design* problem, not an implementation one: the intent (pool cleanup erases its own keys) is
  checkable precisely.
- Fix: assert only on the pool's own keys — `assert :persistent_term.get({Tyrex.Pool, name}, :missing) == :missing`
  (already done at line 191, which is the good version) and replace the ETS scan with a direct
  `assert :ets.whereis(:"cleanup_pool.RoundRobin") == :undefined`. Drop the global count assertion entirely; keep the
  5-cycle loop but assert per-key erasure. That also unblocks `async: true` for the file.

### [MEDIUM] Timing-dependent test: `startup_timeout: 1` races the NIF, and the assertion can't tell the difference
- Location: `test/tyrex_test.exs:29-37`
- Evidence:
```elixir
    test "init returns error when startup times out" do
      ...
      assert {:error, _reason} =
               Tyrex.start(main_module_path: "/nonexistent/path.js", startup_timeout: 1)
```
- Impact: two defects in one. (1) It is a wall-clock race — the test intends the inner `receive ... after
  startup_timeout` at `lib/tyrex.ex:266` to fire, but a fast machine can deliver the real `{:error, ...}` from the NIF
  first. (2) The assertion is `{:error, _reason}`, so **either outcome passes** — including the outcome the test name
  denies. The test name says "times out"; the assertion verifies only "did not succeed", which the neighbouring test
  at line 25 already covers. Net coverage of the timeout branch: effectively zero, with a false sense of security.
- Fix: assert the actual reason — `assert {:error, :nif_startup_timeout} = Tyrex.start(main_module_path:
  "test/support/main_module.js", startup_timeout: 1)` (use a *valid* module so the only way to get an error is the
  timeout). If the race is still too tight, inject a deliberately slow main module.

### [MEDIUM] Implicit 5s timeouts in the concurrency test where the sibling test uses 10s
- Location: `test/tyrex_test.exs:439`
- Evidence:
```elixir
      results = Task.await_many(tasks)
```
  versus `test/tyrex_pool_test.exs:169`:
```elixir
      results = Task.await_many(tasks, 10_000)
```
- Impact: `Task.await_many/1` defaults to 5000ms, and each of the 10 tasks also carries the default 5000ms
  `GenServer.call` timeout from `lib/tyrex.ex:210` — all 10 serialising through a *single* runtime process. On a
  loaded CI box (or with the three files flipped to `async: true`) this is the first thing to flake, and it fails as
  an opaque `** (exit) exited in: Task.await_many/2`. The explicit `10_000` in the pool test is evidence the authors
  already hit the wall once and fixed it in only one place.
- Fix: `Task.await_many(tasks, 15_000)` and pass `timeout: 15_000` to the inner `Tyrex.eval/2`, or set a suite-wide
  floor in `test_helper.exs` (see next finding).

### [MEDIUM] `test/test_helper.exs` is bare — no timeout, no log capture, no `max_cases` policy
- Location: `test/test_helper.exs:1`
- Evidence:
```elixir
ExUnit.start()
```
  Repo-wide grep for `@tag`, `capture_log`, `ExUnit.configure` in `test/` → **no matches**.
- Impact: three separate gaps.
  (1) *Timeout*: the 60s ExUnit default is currently survivable (108 tests in 26.2s), but
  `tyrex_pool_test.exs:21-26` starts `System.schedulers_online()` Deno runtimes in one test — 10 on the audited M1
  Max, more on a big CI runner — each admitting a 30s `startup_timeout` (`lib/tyrex.ex:244`). One slow cold start
  under a cold V8 snapshot puts that single test within reach of 60s, and the failure mode is an unhelpful
  "test timed out after 60000ms". An explicit `ExUnit.configure(timeout: 120_000)` (or `@tag timeout:` on the pool
  and module-loading tests) makes the budget intentional.
  (2) *Log capture*: `tyrex_test.exs:25-27`, `tyrex_test.exs:29-37`, and `tyrex_test.exs:340-342` all deliberately
  fail `init/1`, which returns `{:stop, error}` and produces a `proc_lib` crash report on stdout. [INFERENCE — not
  observed, suite not re-run for this audit.] Those three tests, plus the pool teardown tests, are exactly where
  `@tag :capture_log` belongs so a genuine failure isn't buried in expected noise.
  (3) *Parallelism bound*: with the async flips recommended above, `max_cases` should be pinned so concurrent Deno
  workers don't oversubscribe small runners.
- Fix:
```elixir
ExUnit.start(capture_log: true, max_cases: System.schedulers_online())
ExUnit.configure(timeout: 120_000)
```
  and keep `@tag timeout:` overrides on the few genuinely long tests.

### [MEDIUM] Vacuous and over-broad assertions
- Location: `test/tyrex_test.exs:86`, `test/tyrex_test.exs:323`, `test/tyrex_test.exs:26`, `test/tyrex_test.exs:341`
- Evidence:
```elixir
      assert {:ok, %{}} = Tyrex.eval("({})", pid: pid)          # :86 — %{} matches ANY map
      assert {:ok, _} = Tyrex.eval("true", pid: pid)            # :323 — "chained imports" test
      assert {:error, _} = Tyrex.start(main_module_path: "nonexistent/file.js")   # :26
      assert {:error, _} = Tyrex.start(main_module_path: "test/support/syntax_error.js")  # :341
```
- Impact:
  - `:86` — in Elixir, `%{}` is a *subset* pattern: `{:ok, %{"a" => 1}}` matches it. The "empty object" case is
    therefore not tested at all; a regression returning `%{"__proto__" => ...}` or a non-empty map passes.
  - `:323` — the test is named "chained imports" (`import_b.js` → `import_a.js`) but evaluates the literal `true`,
    asserting nothing about either module. It verifies only that the runtime booted. Chained-import resolution is
    effectively untested.
  - `:26` / `:341` — `{:error, _}` cannot distinguish "file not found" from "syntax error" from "NIF crashed"; both
    tests pass on the same wrong behaviour. Note the JS syntax-error fixture *is* wired up here, so this is the one
    place the `syntax_error.js` fixture is used — and it verifies nothing about the error.
- Fix: `:86` → `assert {:ok, map} = ...; assert map == %{}`. `:323` → export a distinguishable symbol from
  `import_a.js`, re-export through `import_b.js`, and assert its value. `:26`/`:341` → assert the error shape, e.g.
  `assert {:error, %Tyrex.Error{name: :execution_error}} = ...` (or whatever the NIF actually returns — pin it).

### [MEDIUM] Disjunctive assertions accept either classification, so error-name regressions can't fail
- Location: `test/tyrex_test.exs:297`, `test/tyrex_permissions_test.exs:122`
- Evidence:
```elixir
      assert err.name == :promise_rejection or err.name == :execution_error     # tyrex_test.exs:297
      assert err.name in [:promise_rejection, :execution_error]                 # permissions:122
```
- Impact: `Tyrex.Error.:name` is the library's public error taxonomy (`lib/tyrex/error.ex:6-14`), and consumers
  pattern-match on it. These two tests declare the taxonomy unknowable for `throw new Error(...)` and for permission
  denials — precisely the two cases users hit most. A change that reclassifies every JS throw would leave the suite
  green. Contrast `tyrex_test.exs:306`, which correctly pins `err.name == :execution_error`.
- Fix: determine the actual current classification once and assert it exactly; if it is genuinely non-deterministic,
  that is an implementation bug to file, not an assertion to loosen.

### [MEDIUM] Test names contradict their assertions
- Location: `test/tyrex_permissions_test.exs:5-10`, `test/tyrex_pool_test.exs:59-77`, `test/tyrex_pool_test.exs:103-123`
- Evidence:
```elixir
    test "can access network" do
      {:ok, pid} = Tyrex.start()
      {:ok, cwd} = Tyrex.eval("Deno.cwd()", pid: pid)     # permissions:5-7 — no network involved
```
```elixir
    test "selects randomly" do
      ...
      assert Enum.all?(results, &(&1 == 2))               # pool:59,74 — asserts 1+1==2, not selection
```
```elixir
    test "different keys may hit different runtimes" do
      ...
        assert val == i                                    # pool:103,119 — asserts stickiness, not spread
```
- Impact: the suite advertises coverage it does not have. `allow_all` + network is the highest-risk permission
  combination in a sandboxing library and is **not** exercised anywhere (the only `fetch` call,
  `permissions_test.exs:102`, is in the *deny* test and never leaves the process). A reader auditing permission
  coverage by test name is actively misled. The pool "random"/"different keys" names similarly hide that dispatch
  spread is only checked in the pure-strategy unit tests (`tyrex_strategy_test.exs:47-58`, `72-83`), never through
  `Tyrex.Pool.eval/3`.
- Fix: rename `"can access network"` → `"can call Deno.cwd"` and add a real network test behind
  `@tag :network` / `ExUnit.configure(exclude: [:network])` so CI can opt out; rename the pool tests to
  `"random strategy serves every request"` and `"hash strategy keeps keys sticky"`, and add a genuine spread
  assertion that collects `globalThis.id` across many dispatches.

### [MEDIUM] No property-based tests for the Elixir-term ↔ JS round-trip
- Location: `test/tyrex_test.exs:40-152` (the hand-rolled example table), no `stream_data`/`propcheck` in the project
- Evidence: coverage is a fixed list of literals —
```elixir
      assert {:ok, [1, 2, 3]} = Tyrex.eval("[1, 2, 3]", pid: pid)
      assert {:ok, %{"a" => 1, "b" => 2}} = Tyrex.eval("({a: 1, b: 2})", pid: pid)
```
- Impact: serialization is the core correctness surface of this library — every value crosses
  Elixir → JSON → V8 → JSON → Elixir (`lib/tyrex.ex:289`, `:334` both `Jason.decode!`). Hand-picked examples cover
  small ASCII strings, small ints, 2-key maps and 3-element lists, and miss the entire class of boundary inputs a
  generator finds in seconds: non-ASCII and astral-plane strings, lone surrogates, strings with embedded NUL/quotes,
  integers beyond IEEE-754 safe range (`2^53`), `-0.0`, deeply nested structures, empty-string keys, and large
  payloads. `Tyrex.Error{name: :conversion_error}` (`lib/tyrex/error.ex:10-11`) is a declared failure mode with **no
  test at all** — a generator is the natural way to find what triggers it.
- Fix: add `stream_data` as a test-only dep and one property module:
  `property "json-safe terms survive a round trip" do check all term <- json_term() do assert {:ok, ^term} =
  Tyrex.eval("(#{Jason.encode!(term)})", pid: pid) end end`, with `json_term/0` generating nested maps/lists of
  `string(:printable)`, `integer()`, `float()`, `boolean()`, `nil`. Pin the known-lossy cases (big integers, `-0.0`)
  as explicit examples documenting the contract.

### [LOW] Missing round-trip edge cases: unicode and large payloads
- Location: whole of `test/`
- Evidence: a grep of `test/` for non-ASCII characters matches only em-dashes inside comments (e.g.
  `test/tyrex_test.exs:31`, `test/tyrex_strategy_test.exs:8`); `String.duplicate` has no matches. Every string
  asserted is ASCII and under 12 bytes:
```elixir
      assert {:ok, "hello world"} = Tyrex.eval("'hello' + ' ' + 'world'", pid: pid)
```
  (`test/tyrex_test.exs:61`)
- Impact: the Elixir side is UTF-8 binaries, V8 is UTF-16, and the bridge is JSON over a NIF boundary — the classic
  place for mojibake, surrogate-pair truncation, and length mismatches. Nothing verifies that `"héllo"`, `"日本語"`,
  or `"👍"` survive, nor that a multi-megabyte string or a 100k-element array crosses without truncation or a
  scheduler stall (relevant given `eval_blocking` runs on a dirty scheduler, `lib/tyrex.ex:287`).
- Fix: add explicit cases — `assert {:ok, "héllo 日本語 👍"} = Tyrex.eval(~s|"héllo 日本語 👍"|, pid: pid)`,
  `assert {:ok, s} = Tyrex.eval("'x'.repeat(1_000_000)", pid: pid); assert byte_size(s) == 1_000_000`, and the same
  two in `blocking: true` mode.

### [LOW] Three test fixtures are dead; one hardcodes a port
- Location: `test/support/server.js:2`, `test/support/greeter.ts`, `test/support/async_module.js`
- Evidence: no `.exs` file references them (grep for `support/*.{js,ts,txt}` across `test/` returns only
  `main_module.js`, `import_b.js`, `node_apis.js`, `syntax_error.js`, `read_file.txt`).
```javascript
const port = parseInt(Deno.args[0] || "8765");     // test/support/server.js:2
```
- Impact: `greeter.ts` means **TypeScript module loading is entirely untested** in a library whose README-level pitch
  is a "JS/TS runtime" — the fixture exists, the test does not. `async_module.js` (async resolve/reject/`fetchJson`)
  and `server.js` (`Deno.serve`) likewise represent intended-but-absent coverage. If `server.js` is ever wired up as
  written, port `8765` is hardcoded and will collide on shared CI runners.
- Fix: either write the missing tests — a TS test asserting `greet("x").message`, an async-module test asserting
  `asyncFail()` surfaces `%Tyrex.Error{name: :promise_rejection}` — or delete the fixtures. If `server.js` is used,
  bind port `0` and read the assigned port back from `Deno.serve`'s return value.

### [LOW] Host-environment coupling: `$HOME` and CWD-relative fixture paths
- Location: `test/tyrex_test.exs:222`, `test/tyrex_permissions_test.exs:27,79`, and all `read_file.txt` reads
- Evidence:
```elixir
      {:ok, home} = Tyrex.eval("Deno.env.get('HOME')", pid: pid)   # permissions:27
      "(async () => await Deno.readTextFile('test/support/read_file.txt'))()"   # permissions:17,46,69,89
```
- Impact: `HOME` is unset in some container and Windows CI images (`USERPROFILE` there), which turns
  `assert is_binary(home)` into a `MatchError` on `{:ok, nil}`. The `test/support/...` paths are relative to the
  *process* CWD, so the suite only works when run from the project root — `mix test` from an umbrella parent or with
  a changed `:cd` breaks four permission tests plus `tyrex_test.exs:213`. No deduction taken (the project ships no
  Windows target and `mix test` is normally root-relative), but both are one-line fixes.
- Fix: use a variable the test sets itself — `System.put_env("TYREX_TEST_VAR", "1")` in `setup` and read that; and
  build fixture paths with `Path.join(File.cwd!(), "test/support/read_file.txt")` or
  `Application.app_dir/2`-anchored paths.

### [LOW] Probabilistic and wall-clock assertions
- Location: `test/tyrex_strategy_test.exs:57`, `test/tyrex_test.exs:129`
- Evidence:
```elixir
      assert Enum.sort(Enum.uniq(results)) == [0, 1, 2, 3]     # strategy:57 — 100 draws, 4 buckets
      assert year >= 2024                                       # tyrex_test:129 — host clock
```
- Impact: `strategy:57` can fail by chance with probability ≈ 4·(3/4)^100 ≈ 1e-12 — negligible, but it is a
  statistical assertion presented as deterministic, and it would become material if the sample count were ever
  reduced. `tyrex_test:129` depends on the host clock; it silently degrades into a tautology over time and fails on a
  machine with a wrong RTC. Neither is deducted.
- Fix: `strategy:57` — assert `Enum.all?(results, &(&1 in 0..3))` (already line 55) and drop the coverage claim, or
  seed `:rand` for determinism. `tyrex_test:129` — compare against `Date.utc_today().year` instead of a literal.

### [LOW] Assertions on error *message strings* rather than structs
- Location: `test/tyrex_sigil_test.exs:129`, `test/tyrex_sigil_test.exs:148`, `test/tyrex_permissions_test.exs:21,73,93`, `test/tyrex_test.exs:218`
- Evidence:
```elixir
      assert_raise RuntimeError, ~r/No Tyrex runtime set/, fn ->     # sigil:129
      assert_raise CompileError, ~r/unknown ~JS modifier/, fn ->     # sigil:148
      assert content =~ "test file"                                   # permissions:21,73,93
```
- Impact: `sigil:129` is brittle by necessity — `lib/tyrex/inline.ex:81` raises a bare `RuntimeError` with a prose
  string, so the test can only match prose; rewording the message breaks the test, and consumers likewise cannot
  match on anything structured. `permissions:21` matches the substring `"test file"` where the fixture-based
  `tyrex_test.exs:218` uses the stronger `"test file for Deno.readTextFile"` — the weaker form would pass on a
  truncated or wrong read.
- Fix: give `Tyrex.Inline` a proper exception (`Tyrex.Error{name: :no_runtime}`) and assert the struct; the
  `CompileError` match is acceptable (compile-time diagnostics are inherently textual). Assert
  `content == File.read!("test/support/read_file.txt")` in the permission tests.

### [LOW] `setup` duplication across eight describe blocks
- Location: `test/tyrex_test.exs:41-45, 100-104, 155-159, 201-205, 233-237, 253-257, 281-285, 346-350`; `test/tyrex_sigil_test.exs:7-12, 61-65`
- Evidence: the identical three lines, ten times:
```elixir
      {:ok, pid} = Tyrex.start()
      on_exit(fn -> Tyrex.stop(pid: pid) end)
      %{pid: pid}
```
- Impact: ten Deno runtimes are started and torn down where the tests within each block are mutually independent and
  most are pure computation. This is a meaningful share of the 26s wall clock. It is also the copy-paste template
  that the *un*-cleaned-up tests (previous finding) failed to follow — a single shared helper would have prevented
  that class of bug.
- Fix: extract an `ExUnit.CaseTemplate` (`test/support/tyrex_case.ex`) providing `setup :start_runtime` with
  `on_exit` registered once. Where tests genuinely need a pristine `globalThis` (e.g. `tyrex_test.exs:137-141`,
  `tyrex_sigil_test.exs:53-56`), keep a per-test runtime; otherwise a `setup_all` runtime shared by the read-only
  describe blocks (basic expressions, JS features, Deno APIs, blocking, error handling) would cut startups from ten
  to roughly three.

### [LOW] Untested public functions (coverage detail)
- Location: `lib/tyrex.ex:173`, `lib/tyrex.ex:220`, `lib/tyrex.ex:114`, `lib/tyrex/error.ex:54`
- Evidence:
```elixir
  def eval(code) do          # lib/tyrex.ex:173  — routes to the default-named runtime
    eval(code, name: __MODULE__)
  def eval!(code) do         # lib/tyrex.ex:220
  def stop do                # lib/tyrex.ex:114  — stop([]) -> name: Tyrex
  def message(error) do      # lib/tyrex/error.ex:54
    if error.message do
      "#{error.name}: #{error.message}"
```
  Every call in `test/` passes `pid:` or `name:` explicitly; no test starts a runtime registered as `Tyrex`.
  No test asserts on `Exception.message/1` output.
- Impact: the "one globally-named runtime" workflow — the shortest path in the docs
  (`lib/tyrex.ex:195-196`: `iex> Tyrex.eval("1 + 2")`) — has zero coverage, including the
  `Keyword.get(opts, :name, __MODULE__)` default resolution in `eval/2` and `stop/1`. `Tyrex.Error.message/1` has a
  real nil-branch that decides what users see in every stack trace and is unverified. Compounding this: there is **no
  `doctest Tyrex`** anywhere in `test/` (grep for `doctest` → no matches), so the four `iex>` examples in
  `lib/tyrex.ex:195-202` are unexecuted documentation that can rot silently.
- Fix: add a `describe "default named runtime"` block that does `Tyrex.start_link(name: Tyrex)` in `setup` and
  exercises `eval/1`, `eval!/1`, `stop/0`; add `doctest Tyrex` (the examples are already written to be runnable given
  a registered runtime); add a direct `Tyrex.Error` unit test covering both branches of `message/1`.

### [LOW] Untested internal-but-public surfaces
- Location: `lib/tyrex/native.ex:27,35,42,50,57`; `lib/tyrex/pool/registry.ex:44-52`
- Evidence:
```elixir
  def stop_runtime(_reference), do: :erlang.nif_error(:nif_not_loaded)   # native.ex:35
```
```elixir
      try do
        strategy_mod.terminate(strategy_state)
      rescue
        _ -> :ok                                                          # registry.ex:47-48
```
- Impact: no deduction taken (these are internal by convention, and the NIF-not-loaded clauses are unreachable once
  the NIF loads — testing them would require unloading it). Worth noting: the `rescue`/`catch` swallow in
  `registry.ex:47-52` is exercised only on its non-raising path (RoundRobin teardown, `tyrex_pool_test.exs:188`), so
  a custom strategy whose `terminate/1` raises would silently leak its resources with no test to catch it. The
  `function_exported?` false-branch *is* covered, via the Hash and Random pools' `Supervisor.stop` at
  `tyrex_pool_test.exs:76,100,122,136`.
- Fix: add a strategy unit test with a deliberately raising `terminate/1` asserting the pool still shuts down cleanly
  and `:persistent_term` is still erased.

## Error-path coverage matrix

| Failure mode | Covered | Where |
|---|---|---|
| JS syntax error (inline) | yes | `tyrex_test.exs:259-262`, `:300-307` |
| JS syntax error (module fixture) | weak | `tyrex_test.exs:341` — `{:error, _}` only |
| Thrown JS exception | weak | `tyrex_test.exs:291-298` — disjunctive `err.name` |
| Rejected promise | yes | `tyrex_test.exs:165-168` |
| Reference / type error | yes | `tyrex_test.exs:264-272` |
| Permission denial (read/env/net/import) | yes | `permissions_test.exs:41-125` |
| Bad `main_module_path` | weak | `tyrex_test.exs:26` — `{:error, _}` only |
| JS→Elixir apply, missing module/function | yes | `tyrex_test.exs:392-398` + describe `:345-399` |
| Concurrent eval on one runtime | yes | `tyrex_test.exs:428-443` |
| **Eval timeout** | **MISSING** | — |
| **Worker crash + pool recovery** | **MISSING** | — |
| **`:dead_runtime_error`** | **MISSING** | `lib/tyrex.ex:291` handler never reached |
| **`:conversion_error`** | **MISSING** | declared at `error.ex:10` |
| **Unicode round-trip** | **MISSING** | — |
| **Large-payload round-trip** | **MISSING** | — |
| **TypeScript module load** | **MISSING** | fixture `greeter.ts` unused |
| NIF-not-loaded | MISSING (accepted) | unreachable in a normal run |
| Pool exhaustion / checkout timeout | N/A | pool dispatches via `persistent_term` + strategy index; there is no checkout, so no exhaustion path exists |

## Estimated coverage by module (estimate — no `mix test --cover` was run)

| Module | Estimate | Basis |
|---|---|---|
| `Tyrex` (`lib/tyrex.ex`, 415 LOC) | ~75% | `eval/2`, `eval!/2`, `start/0,1`, `start_link/1`, `stop/1`, `handle_call`, both `handle_info` clauses and `terminate/1` all driven; untested: `eval/1`, `eval!/1`, `stop/0`, the `:dead_runtime_error` branch (`:290`), the `:timeout` option |
| `Tyrex.Pool` (119) | ~85% | all three public functions plus default/explicit sizing, all three strategies, main-module and permission propagation; no crash/restart path |
| `Tyrex.Pool.Registry` (56) | ~80% | init + terminate covered both with and without a strategy `terminate/1`; the `rescue`/`catch` arms uncovered |
| `Tyrex.Pool.Strategy.{RoundRobin,Random,Hash}` (35/23/35) | ~95% | direct unit tests in `tyrex_strategy_test.exs` **and** integration via pool tests; best-covered code in the repo |
| `Tyrex.Sigil` (81) | ~90% | happy path, `b` modifier, unknown-modifier `CompileError`, named runtime, error tuple |
| `Tyrex.Inline` (90) | ~90% | `set_runtime/1`, `get_runtime/0`, `with_runtime/2` incl. restore, `eval/2` incl. blocking and the no-runtime raise |
| `Tyrex.Error` (61) | ~40% | struct is pattern-matched constantly, but `exception/1` only indirectly and `message/1` never; 2 of 4 `:name` atoms never produced |
| `Tyrex.Native` (58) | n/a | thin NIF stubs; exercised transitively, `nif_error` clauses unreachable |
| `Tyrex.Runtime` (25) | n/a | struct definition only, no logic |

## Clean areas (one line each)

- Zero `Process.sleep/1` or `:timer.sleep/1` anywhere in `test/` — synchronisation uses `:sys.get_state/1` as a
  deterministic barrier (`tyrex_pool_test.exs:180,203`), which is the correct BEAM idiom.
- Zero bare `receive` blocks, zero `assert_receive`/`refute_receive` — no missing-timeout message-assertion hazards.
- No hardcoded ports bound by any running test; the only port literal lives in the unused `server.js` fixture.
- `test/tyrex_strategy_test.exs` is correctly `async: true` with per-test unique ETS table names — the model the
  other files should follow.
- Pool lifecycle hygiene is genuinely tested: `persistent_term` erasure and ETS table deletion on shutdown, plus a
  5-cycle start/stop loop (`tyrex_pool_test.exs:176-213`) — rare and valuable for a resource-owning library.
- Describe-block organisation is clear and consistent; every `setup` that exists correctly pairs `Tyrex.start/0` with
  `on_exit`-registered teardown.
- Permission coverage is broad for a sandboxing library: `:none`, `:allow_all`, granular `allow_read`/`allow_env`,
  `deny_net`, `deny_import`, and pool-wide propagation.
- Mox / `verify_on_exit!` / `set_mox_global` — N/A, the project uses no mocks and tests against the real NIF.
