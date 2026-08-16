# Runtime Performance & Scalability Audit — tyrex

Scope: `native/tyrex/src/*.rs`, `native/tyrex/extension/main.js`, `lib/tyrex/native.ex`,
`lib/tyrex/runtime.ex`, `lib/tyrex/pool.ex`, `lib/tyrex/pool/strategy/*.ex`, `bench/*.exs`.

**N/A for this project:** N+1 query analysis, missing-index analysis, LiveView stream/assign
analysis, Ecto preload/query-composition review. There is no Ecto, no database, no LiveView and
no web layer in this repository — those criteria are not applicable and were not scored.

## Score: 20/100

| Category | Max | Deductions | Score |
|---|---|---|---|
| Scheduler safety | 30 | −15 (F1 `eval_blocking` unbounded block), −5 (F9 tokio runtime built + `unwrap` on a normal scheduler) | 10 |
| Runtime/isolate reuse | 20 | −10 (F7 per-call `execute_script` compile, `v8_code_cache: None`), −5 (F7 no startup snapshot → full JS bootstrap per runtime) | 5 |
| Serialization efficiency | 15 | −5 (F6 throwaway `serde_json::Value` on eval results), −5 (F3 triple-encode + script compile on apply-reply) | 5 |
| No single-process bottleneck | 15 | −10 (F5 global `Mutex<Slab>` held across `enif_send` on every JS→Elixir call), −5 (F10 per-call atom interpolation in pool dispatch) | 0 |
| Timeout / backpressure | 10 | −5 (F2 no V8 termination; Elixir-side timeout only), −5 (F8 unbounded queue, no backpressure) | 0 |
| Memory limits | 10 | −5 (no `create_params`/heap limit), −5 (no near-heap-limit callback → V8 OOM aborts the BEAM) | 0 |

Arithmetic: `100 − 20 − 15 − 10 − 15 − 10 − 10 = 20`. No category floored below 0.

### NIF scheduler inventory (all `#[rustler::nif]` in `native/tyrex/src/`)

| NIF | Attribute (lib.rs) | Blocking work | Verdict |
|---|---|---|---|
| `start_runtime` | `:12` `schedule = "DirtyCpu"` | slab insert + `std::thread::spawn` | over-scheduled (F13) |
| `stop_runtime` | `:67` plain | channel clone + `tokio::spawn` | OK, except F9 first-call init |
| `eval` | `:98` plain | `OwnedEnv::save` + `tokio::spawn` | OK, except F9 first-call init |
| `eval_blocking` | `:137` `schedule = "DirtyCpu"` | `response_receiver.blocking_recv()` — **no timeout** | **CRITICAL (F1)** |
| `apply_reply` | `:161` plain | unbounded channel `send` | OK |

## Findings

### [CRITICAL] `eval_blocking` blocks a dirty scheduler forever and deadlocks against `Tyrex.apply`
- Location: `native/tyrex/src/lib.rs:137-158`, `lib/tyrex.ex:286-296`, `native/tyrex/src/worker.rs:33-46`
- Evidence:
  ```rust
  // lib.rs:137
  #[rustler::nif(schedule = "DirtyCpu")]
  fn eval_blocking(
      resource: ResourceArc<runtime::Runtime>,
      code: String,
  ) -> Result<String, error::Error> {
      ...
      match response_receiver.blocking_recv() {   // lib.rs:151 — no timeout, no deadline
  ```
  ```elixir
  # lib/tyrex.ex:286
  if Keyword.get(opts, :blocking, false) do
    case Native.eval_blocking(state.reference, code) do
  ```
  ```rust
  // worker.rs:43 — op_apply delivers the JS callback to that same GenServer pid
  util::send_to_pid(pid, (atoms::apply(), application_id, module, function_name, args));
  ```
- Impact: three compounding failures.
  1. **Deadlock.** `eval_blocking` runs *inside* `handle_call/3`, so the runtime GenServer cannot
     service its mailbox. Any JS evaluated in blocking mode that calls `Tyrex.apply(...)` makes
     `op_apply` post `{:apply, …}` to a process frozen in the NIF; `handle_info/2` never runs, no
     `apply_reply` is ever sent, the JS promise never settles, and `blocking_recv()` waits forever.
     This is reachable from documented public API: `~JS"…"b` (`lib/tyrex/sigil.ex:75`,
     `README.md:367`).
  2. **Unkillable process + stuck shutdown.** A process inside a dirty NIF cannot be killed, so
     `GenServer.stop`, supervisor shutdown and `Process.exit(pid, :kill)` all hang, and orderly VM
     shutdown blocks on the outstanding dirty NIF.
  3. **Dirty-CPU pool exhaustion.** `dirty_cpu_schedulers_online` defaults to
     `schedulers_online`, and `Tyrex.Pool` defaults to `size: System.schedulers_online()`
     (`lib/tyrex/pool.ex:58`). A pool doing blocking evals can occupy every dirty-CPU scheduler in
     the VM, starving all other dirty NIFs process-wide — none of the waiting is CPU work, it is
     pure waiting on a oneshot.
- Fix: (a) move the wait off the CPU pool — `schedule = "DirtyIo"`; (b) bound it —
  `tokio_runtime::get().block_on(tokio::time::timeout(deadline, response_receiver))` and return
  `{:error, :timeout}`; (c) pair it with V8 termination (F2) so the abandoned script actually
  stops; (d) reject or document-and-guard `Tyrex.apply` under `blocking: true` — the callback can
  never be serviced by the calling GenServer.

### [HIGH] Eval timeouts are Elixir-side only — a timed-out script keeps running and wedges the runtime
- Location: `lib/tyrex.ex:206-210`, `native/tyrex/src/worker.rs:308-364`; `terminate_execution`,
  `CancelHandle` and any deadline appear **nowhere** in `native/tyrex/src/`
- Evidence:
  ```elixir
  # lib/tyrex.ex:206
  GenServer.call(
    Keyword.get(opts, :pid) || Keyword.get(opts, :name, __MODULE__),
    {:eval, code, opts},
    Keyword.get(opts, :timeout, 5000)
  )
  ```
  ```rust
  // worker.rs:309 — no deadline is carried with the work
  Message::Eval(code, response_sender) => {
      match worker.execute_script("<anon>", code.into()) {
  ```
- Impact: after 5 s the caller exits, but the isolate is still executing. The worker owns a single
  V8 isolate on a single thread (`lib.rs:23-45`), so *every* subsequent eval on that runtime queues
  behind the runaway script — the runtime is permanently wedged while remaining "healthy" to the
  supervisor. `Tyrex.Pool` round-robin (`lib/tyrex/pool/strategy/round_robin.ex:27`) has no liveness
  signal and keeps routing `1/size` of all traffic into the wedged runtime. `while(true){}` in user
  JS is an unrecoverable, un-supervised outage.
- Fix: carry a deadline in `Message::Eval`; hold `worker.js_runtime.v8_isolate().thread_safe_handle()`
  and call `terminate_execution()` from a `tokio::time::sleep` watchdog (then
  `cancel_terminate_execution()` before the next script). Surface `:timeout` as a `Tyrex.Error`.

### [HIGH] Apply-reply transports data by compiling a JS source string per callback (triple encode)
- Location: `native/tyrex/src/worker.rs:284-305`, `lib/tyrex.ex:313-317`,
  `native/tyrex/extension/main.js:17`
- Evidence:
  ```rust
  // worker.rs:284
  let script = match (
      serde_json::to_string(&application_id),
      serde_json::to_string(kind),
      serde_json::to_string(&value),
  ) {
      (Ok(id_lit), Ok(kind_lit), Ok(value_lit)) => {
          format!("globalThis.Tyrex._applyReply({id_lit}, {kind_lit}, {value_lit})")
      }
  ...
  if let Err(err) = worker.execute_script("<anon>", script.into()) {
  ```
  ```javascript
  // extension/main.js:17
  const parsed = JSON.parse(value);
  ```
- Impact: one JS→Elixir→JS round trip costs, per call — `Jason.encode!` (Elixir),
  a term→`String` copy across the NIF boundary, `serde_json::to_string` re-escaping the *already
  JSON* payload as a string literal (O(n) with ~2× growth on quote-dense payloads), a `format!`
  allocation, a **full V8 script compile** of freshly generated source (no code cache — see F7), and
  finally `JSON.parse` inside JS. That is 3 encodes and 3 parses of the same data, plus a compile,
  for every callback. `format!` is being used as a data-transport mechanism on the hottest
  bidirectional path.
- Fix: resolve `globalThis.Tyrex._applyReply` once at bootstrap into a
  `v8::Global<v8::Function>`; on reply build the arguments with `v8::String::new_from_utf8` (or
  `serde_v8::to_v8`) and `func.call(scope, …)`. No script compile, no escaping, and the
  `JSON.parse` in `main.js:17` disappears with it.

### [HIGH] No V8 heap limit and no OOM guard — runaway JS aborts the entire BEAM
- Location: `native/tyrex/src/worker.rs:205-209`; `create_params`, `heap_limits`,
  `add_near_heap_limit_callback` and `v8_flags` appear **nowhere** in `native/tyrex/`
- Evidence:
  ```rust
  // worker.rs:205
  deno_runtime::worker::WorkerOptions {
      extensions: vec![extension::init()],
      ..Default::default()
  },
  ```
- Impact: each isolate gets V8's default max-old-space (system-memory-derived, typically
  1.5–4 GB). With `Tyrex.Pool` defaulting to `System.schedulers_online()` runtimes
  (`lib/tyrex/pool.ex:58`), the aggregate ceiling is `size ×` that, unbounded from Elixir. Worse,
  V8's default near-heap-limit behaviour on exhaustion is a **fatal OOM that calls `abort()`** —
  in-process that takes down the whole BEAM node, not just the runtime. No supervisor can recover
  from it, and there is no per-runtime cap to prevent one tenant's script from doing it.
- Fix: pass `create_params: Some(v8::CreateParams::default().heap_limits(0, max_bytes))` in
  `WorkerOptions`, expose it as a `:max_heap_mb` start option, and register
  `add_near_heap_limit_callback` that raises the limit slightly and calls `terminate_execution()`
  so the runtime dies with a `Tyrex.Error` instead of aborting the VM.

### [HIGH] Global `Mutex<Slab>` is held across a BEAM message send on every JS→Elixir call
- Location: `native/tyrex/src/worker.rs:33-46`, `native/tyrex/src/runtimes.rs:4-20`,
  `native/tyrex/src/util.rs:3-8`
- Evidence:
  ```rust
  // worker.rs:33 — `pid` borrows from `slab`, so the guard lives to end of fn
  let slab = runtimes::lock_or_recover();
  let pid = match slab.get(parsed_id) { ... };
  util::send_to_pid(                       // worker.rs:43 — still holding the global lock
      pid,
      (atoms::apply(), application_id, module, function_name, args),
  );
  ```
  ```rust
  // util.rs:7 — allocates an env, encodes 5 terms, and does enif_send, under the lock
  let _ = OwnedEnv::new().send_and_clear(pid, |_env| data);
  ```
- Impact: `runtimes::get()` is one process-wide `Mutex<Slab<LocalPid>>` shared by *every* runtime in
  *every* pool. The critical section is not the `slab.get` (nanoseconds) — it spans `OwnedEnv::new`
  (`enif_alloc_env`), term encoding of five values including the whole JSON argument binary, and
  `enif_send` (a copy onto another process's heap). Every runtime's callback path serializes on a
  single lock, so JS→Elixir throughput does not scale with pool size at all. Every op also pays a
  fresh `OwnedEnv` alloc/free.
- Fix: dereference and drop first — `let pid = { let slab = runtimes::lock_or_recover(); *slab.get(parsed_id)? };`
  — then send outside the guard. Better: put the owner `LocalPid` in the extension's `OpState` at
  bootstrap so `op_apply` needs no global map, no lock and no `runtime_id` string parse
  (`worker.rs:26`) at all.

### [MEDIUM] Eval results are materialized into a throwaway `serde_json::Value`, then re-serialized
- Location: `native/tyrex/src/worker.rs:321-323`, `native/tyrex/src/worker.rs:423-426`,
  `lib/tyrex.ex:289`, `lib/tyrex.ex:334`
- Evidence:
  ```rust
  // worker.rs:321
  match serde_v8::from_v8::<serde_json::Value>(scope, local) {
      Ok(value) => {
          if response_sender.send(Ok(value.to_string())).is_err() {
  ```
  ```elixir
  # lib/tyrex.ex:334
  GenServer.reply(from, {:ok, Jason.decode!(json)})
  ```
- Impact: every result crosses as V8 value → **full `serde_json::Value` tree** (one allocation per
  node, immediately discarded) → `to_string()` re-serialization → BEAM binary → `Jason.decode!`.
  The intermediate tree is pure waste: three full traversals and a throwaway allocation graph where
  one traversal would do. Cost scales with result size, which is exactly why the benchmarks (all
  results ≤5 elements — F14) show none of it.
- Fix: minimum — `v8::json::stringify(scope, local)` produces the JSON string directly from V8, no
  Rust tree. Best — deserialize straight into a rustler `Term` via `OwnedEnv` and drop JSON from
  the result path entirely, removing `Jason.decode!` from `lib/tyrex.ex:289,334` too.

### [MEDIUM] No V8 startup snapshot and no code cache — full bootstrap per runtime, recompile per eval
- Location: `native/tyrex/Cargo.toml:5`, `native/tyrex/src/worker.rs:201`,
  `native/tyrex/src/worker.rs:205-208`, `native/tyrex/src/worker.rs:309`
- Evidence:
  ```toml
  # Cargo.toml:5 — no "snapshot" feature
  deno_runtime = { version = "0.246.0", features = ["transpile"] }
  ```
  ```rust
  // worker.rs:201
  v8_code_cache: Default::default(),   // == None
  // worker.rs:205 — WorkerOptions::default() ⇒ startup_snapshot: None
  deno_runtime::worker::WorkerOptions { extensions: vec![extension::init()], ..Default::default() },
  // worker.rs:309 — fresh compile of the same source on every call
  match worker.execute_script("<anon>", code.into()) {
  ```
- Impact: two distinct costs.
  * **Per runtime:** without `startup_snapshot`, the whole `deno_runtime` JS bootstrap plus
    `extension/main.js` is parsed and compiled from source at every `Tyrex.start`. `Tyrex.Pool`
    pays this `size` times at boot (`lib/tyrex/pool.ex:76-82`) — this is what `startup_bench.exs`
    is measuring without identifying the cause.
  * **Per call:** `execute_script` compiles a new `v8::Script` on every eval *and* every
    apply-reply (F3), with `v8_code_cache: None` so identical source is never amortized. The
    library's own pitch (pool + repeated evals) is exactly the workload a code cache exists for.
- Fix: enable the `deno_runtime` snapshot feature / produce a snapshot in `build.rs` and pass it as
  `startup_snapshot`; provide a `v8_code_cache` implementation; optionally memoize
  `v8::Global<v8::UnboundScript>` keyed by a hash of the source for repeated evals.

### [MEDIUM] Unbounded work queue and blind pool dispatch — no backpressure anywhere
- Location: `native/tyrex/src/lib.rs:21-22`, `lib/tyrex/pool.ex:100-107`,
  `native/tyrex/src/worker.rs:259`
- Evidence:
  ```rust
  // lib.rs:21
  let (worker_sender, worker_receiver) =
      tokio::sync::mpsc::unbounded_channel::<worker::Message>();
  ```
  ```elixir
  # lib/tyrex/pool.ex:105 — index chosen with zero knowledge of runtime load or liveness
  index = mod.select(state, opts)
  Tyrex.eval(code, Keyword.merge(opts, name: :"#{pool_name}.Runtime.#{index}"))
  ```
- Impact: `Tyrex.eval` never applies backpressure — the NIF always returns `:ok` and enqueues. Under
  overload the channel and the promise slab (`worker.rs:259`) grow without bound; callers give up at
  5 s but their work is still queued and still executes, so the system does strictly more work the
  more overloaded it gets. The "pool" is stateless dispatch, not checkout: there is no idle/busy
  tracking, so one slow script gives `1/size` of all requests head-of-line blocking, and a wedged
  runtime (F2) keeps receiving traffic.
- Fix: bounded `tokio::sync::mpsc::channel(n)` with `try_send` → `{:error, :overloaded}`; track
  in-flight count per runtime (an `:atomics` array in the pool's `persistent_term` entry) and add a
  least-busy strategy; drop queued `Eval` messages whose deadline has already passed.

### [MEDIUM] A whole multi-threaded tokio runtime exists to await two oneshots — built on a normal scheduler
- Location: `native/tyrex/src/tokio_runtime.rs:5-9`, `native/tyrex/src/lib.rs:71`,
  `native/tyrex/src/lib.rs:109`, `native/tyrex/src/lib.rs:23-27`
- Evidence:
  ```rust
  // tokio_runtime.rs:8
  RUNTIME.get_or_init(|| Builder::new_multi_thread().enable_all().build().unwrap())
  ```
  ```rust
  // lib.rs:109 — the entire workload of that runtime
  tokio_runtime::get().spawn(async move { ... response_receiver.await ... });
  ```
  ```rust
  // lib.rs:24 — plus a second, per-runtime tokio runtime on its own OS thread
  let tokio_rt = match tokio::runtime::Builder::new_current_thread().enable_all().build()
  ```
- Impact: the global runtime's only jobs are awaiting a oneshot and sending a message, yet
  `new_multi_thread()` eagerly spawns one worker thread per core (plus a lazily-grown blocking pool
  up to 512). Combined with one dedicated OS thread per JS runtime, a `schedulers_online`-sized pool
  on a 10-core box runs ~10 BEAM schedulers + ~10 dirty-CPU schedulers + ~10 tokio workers + 10 deno
  threads — heavy oversubscription and context-switch thrash against the BEAM's own scheduler
  binding. Additionally the construction is lazy and therefore happens **inside a normal-scheduler
  NIF** (`eval`/`stop_runtime`, the first one called), spawning N threads there, and `.unwrap()`
  panics in that same normal-scheduler NIF on failure (and poisons the `OnceLock` for every
  subsequent call).
- Fix: `Builder::new_current_thread()` (or `.worker_threads(1)`) for the waiter runtime — it is pure
  await; better still, let the worker thread send the reply itself and delete the global runtime.
  Construct it eagerly from a `rustler::init!(load = …)` callback and propagate the error instead of
  `unwrap`.

### [MEDIUM] Pool dispatch builds an atom from a binary on every call
- Location: `lib/tyrex/pool.ex:102-106`
- Evidence:
  ```elixir
  %{strategy_mod: mod, strategy_state: state} = :persistent_term.get({__MODULE__, pool_name})
  index = mod.select(state, opts)
  Tyrex.eval(code, Keyword.merge(opts, name: :"#{pool_name}.Runtime.#{index}"))
  ```
- Impact: per eval, on the hottest Elixir path, shared by every pool caller: two integer/atom
  `to_string` conversions, a binary concat, `binary_to_atom` (which takes the VM-global atom-table
  lock), a `Keyword.merge` allocation, and then a name→pid registry lookup in `GenServer.call`. The
  atom-table lock is a process-wide contention point that gets worse with concurrency — precisely
  the axis a pool is supposed to scale on.
- Fix: build the child names once in `Tyrex.Pool.Registry.init/1`
  (`lib/tyrex/pool/registry.ex:24-28`) as a tuple, store it in the `persistent_term` map, and do
  `elem(names, index)`. Cache pids where the supervisor restart story permits.

### [LOW] O(pending-promises) V8 scan on every event-loop poll
- Location: `native/tyrex/src/worker.rs:384-409`
- Evidence:
  ```rust
  std::future::poll_fn(|cx| {
      let poll = worker.js_runtime.poll_event_loop(cx, Default::default());
      deno_core::scope!(scope, worker.js_runtime);
      let resolved_promises: Vec<_> = promises
          .iter()
          .filter_map(|(key, (global, _))| {
  ```
- Impact: every single wake of the event loop enters a `HandleScope`, allocates a `Vec`, and walks
  every outstanding promise creating a `v8::Local` and reading `promise.state()` — polling work that
  is O(pending) per poll rather than O(resolved). A runtime holding many in-flight async evals (the
  advertised concurrency story) pays this repeatedly, and a chatty event loop multiplies it.
- Fix: make completion push-based — attach a `then`/`catch` handler (or use
  `JsRuntime::resolve(global)`) at insert time in `worker.rs:317` so a resolved promise reports
  itself; keep the slab keyed only for cleanup.

### [LOW] Two HandleScopes per non-promise eval, and a redundant `String::to_string()`
- Location: `native/tyrex/src/worker.rs:311-320`, `native/tyrex/src/worker.rs:213-214`
- Evidence:
  ```rust
  // worker.rs:311 — scope entered, dropped, then re-entered for the same value
  let is_promise = {
      deno_core::scope!(scope, worker.js_runtime);
      let local = deno_core::v8::Local::new(scope, &global);
      local.is_promise()
  };
  if is_promise { ... } else {
      deno_core::scope!(scope, worker.js_runtime);
      let local = deno_core::v8::Local::new(scope, &global);
  ```
  ```rust
  // worker.rs:213 — format! already returns String
  format!("Tyrex._runtimeId = \"{}\"", runtime_id).to_string().into(),
  ```
- Impact: an extra HandleScope enter/exit and `Local` creation on the common (non-promise) eval
  path; a redundant full string clone at bootstrap. Small but free to remove.
- Fix: open one scope, compute `is_promise` and convert inside it. Delete the `.to_string()`.

### [LOW] `start_runtime` consumes a scarce dirty-CPU slot for microseconds of work
- Location: `native/tyrex/src/lib.rs:12-23`
- Evidence:
  ```rust
  #[rustler::nif(schedule = "DirtyCpu")]
  fn start_runtime(...) -> rustler::Atom {
      let runtime_id = runtimes::lock_or_recover().insert(pid);
      let (worker_sender, worker_receiver) = tokio::sync::mpsc::unbounded_channel::<worker::Message>();
      std::thread::spawn(move || {
  ```
- Impact: the NIF body is a slab insert, a channel construction and a thread spawn — all
  sub-millisecond and safe on a normal scheduler. Marking it `DirtyCpu` adds a scheduler handoff to
  every runtime start and, worse, makes runtime startup queue behind any `eval_blocking` calls
  saturating the dirty-CPU pool (F1) — so recovery from a wedged pool is itself blocked.
- Fix: drop the `schedule` attribute (or use `DirtyIo` if the thread spawn is considered risky);
  the async bootstrap already happens off-scheduler on the spawned thread.

### [MEDIUM] Benchmarks miss every path identified above
- Location: `bench/eval_bench.exs:8-31`, `bench/concurrency_bench.exs:10-32`,
  `bench/startup_bench.exs:5-21`
- Evidence:
  ```elixir
  # eval_bench.exs:9 — every result is tiny, so serialization cost is invisible
  {:ok, _} = Tyrex.eval("1 + 2", pid: pid)
  # concurrency_bench.exs:8 — the only code under concurrency, and never blocking: true
  code = "[1,2,3,4,5].reduce((a, b) => a + b, 0)"
  ```
- Impact: the suite measures the cheapest possible workload, so it cannot detect any regression in
  the expensive paths. Uncovered hot paths:
  * **`Tyrex.apply` round trip** — zero coverage, yet F3, F5 and the `op_apply` JSON hop all live
    there; this is the single most expensive operation in the library.
  * **Payload size scaling** — all results are ≤5 elements, so F6's throwaway `serde_json::Value`
    and the JSON re-encode never appear. Needs a 1 KB / 100 KB / 1 MB result sweep.
  * **Many concurrent pending promises** — F11's O(pending) scan needs a bench holding e.g. 100
    unresolved `Promise`s while evaluating.
  * **`blocking: true` under concurrency** — `concurrency_bench.exs` never sets it, so dirty-CPU
    saturation (F1) is never exercised. A `blocking: true` × `size` concurrent bench would expose it
    immediately.
  * **Overload / backpressure** — no sustained-arrival-rate bench, so unbounded queue growth (F8)
    and head-of-line blocking behind a slow script are unmeasured.
  * **`Hash` and `Random` strategies** — only `RoundRobin` is benchmarked
    (`eval_bench.exs:30`); the `:key` dispatch path has no numbers.
  * **`memory_time`** is set in `eval_bench.exs:35` but omitted from `concurrency_bench.exs` and
    `startup_bench.exs`, where per-runtime memory is the interesting quantity.
- Fix: add the six benches above; they are what would turn F1/F3/F6/F8/F11 from review findings into
  regression-guarded numbers.

## Clean areas (one line each)

- Isolate reuse is correct: one `MainWorker` per `Tyrex` process lives for the process lifetime (`lib.rs:45-56`, `worker.rs:254-377`) — no per-call isolate creation.
- Atom safety is correct: all atoms are statically declared (`atoms.rs:1-10`) and the Elixir side uses `String.to_existing_atom` (`lib/tyrex.ex:389-394`) — no dynamic atom table growth from JS input.
- Panic safety in `op_apply` is handled: invalid `runtime_id` and missing slab entries are logged and dropped rather than unwrapped (`worker.rs:26-42`).
- Slab cleanup is covered on all three teardown routes — `Stop` (`worker.rs:272`), event-loop exit (`worker.rs:371`), and worker-bootstrap failure (`lib.rs:41,59`) — and `Runtime::drop` fires a best-effort `Stop` when the `ResourceArc` is GC'd (`runtime.rs:10-19`).
- Pending promises are drained with `dead_runtime_error` on shutdown instead of leaking waiting callers (`worker.rs:241-252`).
- Strategy `select/2` is O(1) in all three implementations: lock-free `:ets.update_counter` wrap (`round_robin.ex:27`), `:rand.uniform/1` (`random.ex:21`), `:erlang.phash2/2` (`hash.ex:29`) — `phash2` is the right choice here, cheap and adequately uniform for dispatch; crypto hashing would be strictly worse.
- Pool metadata lookup is `:persistent_term.get/1` (`pool.ex:103`) — no GenServer on the read path, no copy.
- Pool resource lifecycle is clean: the Registry erases the `persistent_term` entry and the strategy's ETS table last via `:rest_for_one` ordering (`registry.ex:39-54`, `pool.ex:84-88`).
- The default (non-blocking) `eval` NIF returns immediately and replies by message (`lib.rs:98-135`, `lib/tyrex.ex:298`, `lib/tyrex.ex:331`) — the correct shape for a NIF fronting long work.
- Mutex poisoning is recovered rather than propagated as a panic (`runtimes.rs:15-20`).
- Startup has an explicit timeout with a Task guard band (`lib/tyrex.ex:244-273`) — the one place in the codebase where a timeout is enforced end to end.

### Nitpicks (no deduction)
- `:ets.new(:"#{pool_name}.RoundRobin", [:public, :set])` (`round_robin.ex:12`) omits `write_concurrency` and every caller hammers the single `:counter` row; `:atomics.add_get/3` would remove the table-lock traffic entirely.
- `op_apply` is `#[op2(fast)]` with five `#[string]` parameters (`worker.rs:15-21`); non-Latin-1 payloads fall off the V8 fast path, so the `fast` annotation over-promises for UTF-8-heavy arguments.
