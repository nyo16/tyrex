# Rust NIF review — `sandbox-integrity` (v0.4.0)

Scope: `native/tyrex/src/{worker,lib,runtime,atoms}.rs`, `native/tyrex/Cargo.toml`.
Read-only review. No source file modified. Nothing compiled or run.

Cross-referenced against the actual vendored sources:
`v8-146.4.0/src/isolate.rs`, `deno_core-0.391.0/runtime/jsruntime.rs`,
`deno_permissions-0.97.0/lib.rs`, `serde_v8-0.300.0/de.rs`,
`rustler_codegen-0.38.0/src/nif.rs`.

---

## Verdict on item 1 (load-bearing): the raw-pointer lifetime guarantee **does not hold**

The documented invariant — "`Worker` holds the `Arc` in a field declared after the
field owning the isolate, and `run` drops them in that order explicitly" — is
**sound in `run` and violated in `new`**, on two reachable error paths and on any
panic unwind.

* In `worker::run` the guarantee holds. Every exit from the `select!` loop is a
  `break`, there are no early `return`s, and control always reaches
  `drop(worker); drop(heap_limit_state);` (worker.rs:627-628). Correct.
* In `worker::new` the ordering is **inverted**. `worker` is declared at
  worker.rs:325, `heap_limit_state` at worker.rs:357. Rust drops locals in
  *reverse* declaration order, so on an early `?` return the `Arc` is freed
  first and the isolate — which still has `near_heap_limit_callback`
  registered against that exact address — is destroyed afterwards.
* The `Worker` struct's "field order is load-bearing" doc comment
  (worker.rs:254-266) is vacuous: `run` destructures the struct immediately
  (worker.rs:471-475), and no `Worker` value is ever dropped whole anywhere in
  the crate. The field order therefore guards nothing.

Details in BLOCKER-1.

---

## BLOCKER-1 — use-after-free: `Arc<HeapLimitState>` is freed before the isolate on `new`'s post-registration error paths

`native/tyrex/src/worker.rs:355-395`

The callback is registered at worker.rs:364-370 with
`Arc::as_ptr(state) as *mut c_void`. Two `?` operators run *after* that:

* worker.rs:381-388 — `execute_script("<anon>", bootstrap)` (`delete globalThis.Tyrex;`
  or the `_runtimeId` seed).
* worker.rs:390-396 — `execute_main_module(&main_module)`, which fails whenever the
  user's `:main_module_path` throws, fails to resolve an import, or blows the heap cap.

On either, locals unwind in reverse declaration order:
`heap_limit_state` (:357) → `isolate_handle` (:355) → `worker` (:325).
So the `Arc` allocation is released while the live isolate still holds a raw
pointer to it, and only then is `MainWorker`/`JsRuntime`/`v8::OwnedIsolate`
dropped.

Failure mode, concretely: the interesting case is `execute_main_module` failing
*because* the heap cap tripped. At that moment the heap sits at
`max_heap_mb + 8MB` (the slack the callback just handed back), the callback is
still installed, and the guest's `Arc` is now freed memory. Isolate teardown
(`OwnedIsolate::drop` → `clear_scope_and_annex` → guaranteed finalizers →
`Isolate::Dispose`, plus V8's teardown GC) can re-enter
`Heap::InvokeNearHeapLimitCallback`. The callback then does
`&*(data as *const HeapLimitState)` on freed memory, `store`s into it, and calls
`terminate_execution()` on an `IsolateHandle` (i.e. an `Arc<IsolateAnnex>`) read
out of a freed allocation — an arbitrary pointer dereference and a refcount
decrement on reclaimed memory, inside the BEAM's address space. Not a caught
exception; a segfault or silent corruption.

The same inversion applies to **panic unwind**, in both `new` and `run`: in `run`
the destructured bindings are declared `worker` (:472) then `heap_limit_state`
(:474), so an unwind drops them in exactly the wrong order and bypasses the
explicit `drop`s at :627-628. The worker body runs on a bare
`std::thread::spawn` (lib.rs:25), so nothing catches that panic — see WARNING-3
for a reachable panic.

Three concrete fixes, cheapest last:

1. Remove the callback before the fallible steps can return:
   `worker.js_runtime.v8_isolate().remove_near_heap_limit_callback(near_heap_limit_callback, 0)`
   on each error path (verbose, easy to forget again).
2. Construct the `Worker` struct immediately after registration and run the
   bootstrap script and main module through `w.worker`. Then `?` drops a
   `Worker`, the declared field order actually applies, and the doc comment
   stops being aspirational.
3. Preferred: use deno_core's safe wrapper,
   `JsRuntime::add_near_heap_limit_callback(|current, initial| { … })`
   (jsruntime.rs:1851-1871). It boxes the closure into
   `JsRuntime::allocations`, and `JsRuntime` declares `inner` (the isolate)
   before `allocations` (jsruntime.rs:365-366) precisely so the data outlives
   the isolate — deno documents this at jsruntime.rs:2627-2628. That deletes
   the `unsafe` block, the `Arc`, the field-order comment, and this whole class
   of bug. The closure captures an `IsolateHandle` clone, which is all
   `HeapLimitState.handle` is; the sticky flag becomes a captured
   `Arc<AtomicBool>` shared with the loop.

---

## BLOCKER-2 — the heap cap does not cover bootstrap, so a small `:max_heap_mb` still `abort()`s the BEAM

`native/tyrex/src/worker.rs:321-370`, `lib/tyrex.ex:711-718`

`create_params` (worker.rs:321-324) hands `heap_limits(0, max_bytes)` to V8, so
the cap is enforced from isolate creation. But `near_heap_limit_callback` — the
thing that converts "V8 fatal OOM → `abort()`" into "terminate the guest" — is
only installed at worker.rs:364-370, i.e. **after**
`MainWorker::bootstrap_from_options` (worker.rs:325-353) has already run deno's
runtime bootstrap, extension ESM init and snapshot deserialization. That is the
single heaviest allocation phase in a runtime's life, and it runs under the cap
with V8's *default* OOM handler installed.

If the cap is below deno's bootstrap footprint, `Tyrex.start/1` kills the entire
BEAM with a V8 fatal OOM — the precise outcome `:max_heap_mb` exists to prevent,
triggered by a supported, validated option value. `validate_max_heap_mb!/1`
(lib/tyrex.ex:711-718) only requires `mb > 0`; the README (`:max_heap_mb`
section) and CHANGELOG document no floor; the only test uses 64
(test/tyrex_lifecycle_test.exs:157) and the only rejected value is `0`
(:171-173). `max_heap_mb: 8` is a perfectly plausible thing for a user to write
for a small sandbox.

Fix: measure deno's bootstrap high-water mark once and enforce a floor in
`validate_max_heap_mb!/1` (`mb >= @min_heap_mb`), with the reason in the error
message and in the README. Rejecting a too-small cap at `start/1` is the only
guard available — there is no hook between isolate creation and bootstrap in
`MainWorker::bootstrap_from_options` where the callback could be installed
earlier.

---

## WARNING-3 — termination can land inside result conversion and panic the worker thread

`native/tyrex/src/worker.rs:544` and `native/tyrex/src/worker.rs:674-675`

This release makes termination *asynchronous and arbitrary*: `terminate_runtime`
(lib.rs:95-107), `Runtime::drop` (runtime.rs:28-31), the `eval_blocking` timeout
arm (lib.rs:184-190) and the heap callback (worker.rs:281-298) can all set the
terminate flag at any instant, including while the worker thread is inside
`serde_v8::from_v8`. Before this patch the only teardown signal was a channel
`Stop`, which is observed strictly *between* operations.

Under a pending termination, V8 API calls return empty `MaybeLocal`s, and
serde_v8 unwraps them:

* `serde_v8-0.300.0/de.rs:539`, `:554`, `:631` — `obj.get_index(scope, pos).unwrap()`
  (array elements; `[1,2,3]` is an entirely ordinary eval result)
* `serde_v8-0.300.0/de.rs:494` — `obj.get(scope, key).unwrap()` (object values)
* `serde_v8-0.300.0/de.rs:203` — `to_string(scope).unwrap()`

The upstream `// fixme: this unwrap is not safe` comments are on those lines.

A panic there is **not** caught: rustler's `catch_unwind` only wraps NIF bodies
(rustler_codegen-0.38.0/src/nif.rs:81-85), and the worker runs on a plain
`std::thread::spawn` (lib.rs:25). The thread unwinds, and:

* `runtimes::lock_or_recover().try_remove(runtime_id)` never runs, so the
  `runtime_id → pid` slab entry leaks (and the id is not returned for reuse);
* `drain_pending_promises` never runs, so every in-flight `Tyrex.eval` caller
  hangs until its own GenServer deadline instead of getting `:dead_runtime_error`;
* the unwind drops `heap_limit_state` before `worker` — BLOCKER-1's UAF.

Window is small (microseconds per conversion) but it is a live race that scales
with eval throughput, and the failure is silent apart from a panic message on
stderr. Cheapest containment: wrap the worker body in
`std::panic::catch_unwind(AssertUnwindSafe(...))` inside the spawned thread so a
panic still runs the slab removal, the promise drain, and the ordered drops.

Note this same `unwrap` chain is reachable *today*, pre-existing, via a guest
throwing getter (see PRE-EXISTING list) — so the mechanism is not theoretical.

---

## WARNING-4 — `op_apply` trusts a guest-writable runtime id, which is now a privilege boundary

`native/tyrex/src/worker.rs:15-44`, `native/tyrex/extension/main.js:39`

`Tyrex._runtimeId` is an ordinary writable property on an ordinary global object;
`main.js:39` passes it straight into `op_apply`, and `op_apply` (worker.rs:24-43)
looks the target pid up in the process-global `runtimes` slab with no check that
the id belongs to the calling isolate.

Before this release that bought an attacker nothing: the bridge was installed
unconditionally on every runtime and accepted any MFA, so all bridge-enabled
runtimes were equally privileged. **This patch introduces the boundary** —
`:apply` is now opt-in and each runtime carries its own `{Module, :fun, arity}`
allowlist, enforced in that runtime's GenServer. So guest JS in a runtime whose
allowlist is harmless can execute
`globalThis.Tyrex._runtimeId = "<victim id>"` and cause a *different* runtime's
owner process to invoke *that* runtime's allowlisted MFA with attacker-chosen
args. The reply is routed back to the victim runtime, so the attack is blind,
but the side effect (a `System.cmd/2`, a DB write, a mailer) is real. Runtime ids
are small sequential slab indices, so enumeration is trivial.

Fix: stop taking the id from JS. The extension's `state` closure
(worker.rs:49-56) runs per `JsRuntime`, so the id can be put in `OpState` at
bootstrap and read inside the op:

* `state = |state| { state.put(deno_runtime::ops::bootstrap::SnapshotOptions::default()); }`
  gains a per-runtime id (the extension already needs to be built per runtime for
  this, which `extension::init()` per worker already is), and
* `op_apply` takes `state: &mut OpState` instead of `#[string] runtime_id: String`.

That also deletes the `parse::<usize>()` failure branch and the
`format!("globalThis.Tyrex._runtimeId = …")` bootstrap script entirely.

---

## SUGGESTION-5 — `allow_all` silently accepts a non-boolean and treats it as `false`

`native/tyrex/src/worker.rs:191-194`

```rust
let allow_all = match obj.get("allow_all") {
    Some(value) => matches!(parse_perm_value("allow_all", value)?, PermValue::True),
    None => false,
};
```

`parse_perm_value` happily returns `PermValue::List` for `allow_all: ["/tmp"]`,
and `matches!(…, PermValue::True)` then quietly evaluates to `false`. It fails
closed, so it is not a hole — but it is the one place in this parser that
silently reinterprets a shape it was given, and the stated rationale for the
rewrite is that a typo in a security control must never be silently ignored
(worker.rs:59-61). Reject anything that is not a bool for this key.

---

## SUGGESTION-6 — heap slack is a fixed 8MB and ratchets on repeat invocations

`native/tyrex/src/worker.rs:271`, `:295-296`

V8 may invoke the near-heap-limit callback more than once, and each invocation
returns `current_heap_limit + 8MB`, so the effective ceiling is
`max_heap_mb + 8MB × invocations` rather than a bounded overshoot. In practice
`terminate_execution()` on the first trip stops the guest quickly, so the
ratchet is short — but deno's own usage returns `current_limit * 2`
(deno_core-0.391.0/tests/misc.rs:565-568), and a proportional or one-shot
(`if already tripped, return current_heap_limit`) response is easier to reason
about. Non-blocking.

---

## Items interrogated and found correct

**Item 2 — is the callback allowed to call `terminate_execution()`?** Yes.
This is deno_core's own tested pattern: `deno_core-0.391.0/tests/misc.rs:565-568`
does exactly `cb_handle.terminate_execution(); current_limit * 2` inside a
near-heap-limit callback. No re-entrancy hazard:
`IsolateHandle::terminate_execution` (v8/src/isolate.rs:1973-1981) takes
`IsolateAnnex::isolate_mutex`, and the isolate's own thread never holds that
mutex while executing JS — it is a cross-thread guard for handle operations
only. Returning a raised limit is what lets V8 unwind rather than `abort()`;
the mechanism is sound, only the magnitude is worth bikeshedding (SUGGESTION-6).

**Item 3 — termination detection.** `SeqCst` (worker.rs:290, :447) is stronger
than required — a `Release` store / `Acquire` load would do — but it is correct
and costs nothing at this frequency. Cross-runtime misattribution is
**impossible**: `HeapLimitState` is constructed per `worker::new`
(worker.rs:357-362), one per runtime, and reached only through
`heap_limit_state` owned by that runtime's `run` loop. The flag is never reset,
which is correct under the stated contract (terminate ⇒ dead runtime; every
call site that observes it also `break`s: worker.rs:523-526, :596-599,
:609-612). One benign misattribution remains: a runtime that tripped the heap
cap and is then killed by `:timeout` reports `:heap_limit_error`; the runtime is
dead either way and the first cause is the true one. For the *timeout* path,
detection still leans on `is_execution_terminating()`, which by the code's own
(correct) documentation frequently reads false by the time `execute_script`
returns — so `terminated` stays false and the reply is `:execution_error`. That
is cosmetic: the caller's Elixir-side deadline has already replied `:timeout`,
and the `Stop` that `terminate_runtime` queued ends the loop on the next
iteration regardless.

**Item 4 — `terminate_runtime` as a plain NIF.** Justified.
`v8/src/isolate.rs:1973-1981` is: lock `isolate_mutex`, null-check, call
`v8__Isolate__TerminateExecution`, unlock. `isolate_mutex` is held for only a
handful of instructions everywhere in the v8 crate — including isolate teardown
(isolate.rs:997-1002), which takes it purely to null the pointer. V8's
`TerminateExecution` sets a flag and posts an interrupt request; it never waits
for the guest. The `worker_sender.send` that follows (lib.rs:104-107) is an
unbounded channel send, also non-blocking. Comfortably inside the ~1ms budget.
It is also race-free against teardown: the annex pointer is nulled under the
same mutex *before* `Isolate::Dispose`, and the `IsolateHandle`'s
`Arc<IsolateAnnex>` keeps the annex itself alive, so a `terminate_execution`
on an already-destroyed isolate returns `false` rather than touching freed
memory.

**Item 5 — `Runtime::drop`.** Safe. It can indeed run on a normal scheduler
thread during BEAM GC, but both operations are non-blocking (short mutex + an
unbounded send), so it cannot violate the scheduler budget. It cannot deadlock
against a worker mid-`execute_script`: the worker holds no V8 lock that
`terminate_execution` needs, and `terminate_execution` is explicitly documented
as callable from any thread without a `Locker` (v8/src/isolate.rs:1965-1972).
Terminate-then-`Stop` ordering (runtime.rs:29-31) is the correct one — a bare
`Stop` behind a runaway is exactly the 299.6%-CPU leak this release fixes.

**Item 6 — `eval_blocking` and `block_on`.** Correct, no panic risk.
`eval_blocking` is `schedule = "DirtyIo"` (lib.rs:149-150), so it runs on a BEAM
dirty-IO scheduler thread, which is never a tokio worker — `Runtime::block_on`
therefore cannot hit "cannot block the current thread from within a runtime".
The two runtimes stay distinct: each worker builds its own
`new_current_thread` runtime (lib.rs:26-29), while `tokio_runtime::get()`
(tokio_runtime.rs:5-9) is the shared multi-thread runtime used only by `eval`'s
`spawn` and by this `block_on`. `tokio::time::timeout` works because `block_on`
enters the runtime context, and the timer driver is shared correctly with the
worker threads.
The double-`Stop` is benign: the first `Stop` calls `worker_receiver.close()`
and `break`s (worker.rs:482-494), so every later send returns `Err` and is
discarded with `let _`. `try_remove(runtime_id)` runs at most once per worker,
because every path that calls it also `break`s — so no chance of a stale
`try_remove` evicting a *reused* slab id belonging to a newer runtime. The only
residue is an `eprintln!("lost reply for Eval …")` when the terminated eval's
sender fires after `eval_blocking` has dropped its receiver.
(Operational note, not a defect: each in-flight blocking eval occupies a
dirty-IO scheduler thread for up to `timeout_ms`; the default pool is small, so
`blocking: true` under concurrency queues. The refusal of `:infinity`
(lib/tyrex.ex:424-425) is the right guard.)

**Item 7 — permission polarity.** Verified against
`deno_permissions-0.97.0/lib.rs:4933`:

```rust
fn global_from_option<T>(flag: Option<&Vec<T>>) -> bool {
  matches!(flag, Some(v) if v.is_empty())
}
```

used for `granted_global` (lib.rs:3443) and `flag_denied_global` (lib.rs:3444).
So for both directions: `Some(vec![])` = global, `Some(non-empty)` = list,
`None` = neither. `allow_option` (worker.rs:127-136) and `deny_option`
(worker.rs:141-149) map onto that exactly, and the asymmetry the comments claim
is real and correctly implemented — `Some(vec![])` means "allow everything" for
allow and "deny everything" for deny; `None` means "not granted" and "no
denial".

`allow_read: []` → `PermValue::List(vec![])` → `None` → `granted_global = false`
with zero descriptors → `query_desc` returns `PermissionState::Prompt`
(lib.rs:1043-1046) → denied, because `prompt: false` (worker.rs:233). There is
no fallthrough to a default: the `None if allow_all => Some(vec![])` arm of the
`allow` closure (worker.rs:203) fires only when the key is **absent** from the
object, never when it is present-but-empty. The escape test's
`[allow_all: true, allow_run: false]` result follows from the same arm ordering.
`PermissionsOptions` is initialized field-by-field with no `..Default::default()`,
so a new permission axis in a future deno release breaks the build instead of
silently defaulting open. That is the right call and should stay that way.

**Item 8 — panics inside a NIF.** Contained.
`rustler_codegen-0.38.0/src/nif.rs:81-85` wraps every generated NIF body in
`std::panic::catch_unwind`, so a panic in `start_runtime`, `terminate_runtime`,
`eval`, `eval_blocking` or `apply_reply` becomes an Erlang error rather than
unwinding across the FFI boundary. That contains `tokio_runtime::get()`'s
`.unwrap()` (tokio_runtime.rs:8); `OnceLock` is not poisoned by a panicking
initializer, so a later call retries cleanly. New arithmetic is guarded:
`saturating_mul` at worker.rs:322 (and `mb as usize` is lossless on every
platform this ships for — the release workflow targets 64-bit only).
`promises.remove(key)` (worker.rs:663) uses keys collected from `promises.iter()`
inside the same closure with no interleaving mutation, so the slab cannot panic;
`promise.result(scope)` is guarded by the `Fulfilled | Rejected` filter
(worker.rs:653-655). Critically, `op_apply` — the one function actually invoked
*from* V8, where a panic would unwind through `extern "C"` frames into UB — is
panic-free by construction: `parse` and `slab.get` are both matched
(worker.rs:25-41), `lock_or_recover` absorbs mutex poisoning
(runtimes.rs:16-21), and `send_to_pid` discards send failures (util.rs:7).
The remaining uncaught-panic surface is the worker thread — WARNING-3.

---

## Pre-existing (not introduced by this patch; listed, not analyzed)

* `native/tyrex/src/worker.rs:544` — a guest-controlled throwing getter
  (`Tyrex.eval("({get a(){throw 1}})")`) makes `serde_v8` hit
  `de.rs:494`'s `obj.get(...).unwrap()` and panic the worker thread. Same
  mechanism as WARNING-3, reachable today. PRE-EXISTING.
* `native/tyrex/src/worker.rs:32` — `op_apply` holds the process-global
  `runtimes` mutex across `util::send_to_pid`, serializing every bridge call in
  the VM behind one lock. PRE-EXISTING.
* `native/tyrex/src/tokio_runtime.rs:8` — `Builder::build().unwrap()`;
  contained by rustler's `catch_unwind` for NIF callers, but it is a panic on a
  recoverable failure. PRE-EXISTING.

## Cargo.toml

No issues. `rustler = "=0.38.0"` pinned against the Elixir `{:rustler, "~> 0.38.0"}`
(mix.exs:86), crate `version = "0.4.0"` matches `@version "0.4.0"` (mix.exs:4) —
consistent, which is what `rustler_precompiled` checksum lookup needs.
`crate-type = ["cdylib"]` unchanged.
