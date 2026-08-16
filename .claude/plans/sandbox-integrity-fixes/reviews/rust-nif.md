# Rust / NIF Review — v0.4.0 sandbox integrity

**Verdict:** REQUIRES CHANGES

**Scope reviewed:** `native/tyrex/src/worker.rs`, `native/tyrex/src/lib.rs`,
`native/tyrex/src/runtime.rs`, `native/tyrex/src/atoms.rs`,
`native/tyrex/Cargo.toml`, `native/tyrex/Cargo.lock`,
`native/tyrex/extension/main.js`. Memory safety, concurrency, FFI, panic
behaviour, correctness under termination. Permission *model* left to
SandboxSecurity.

**How verified:**
- Read pinned crate sources, not docs: `deno_core-0.391.0`
  (`runtime/jsruntime.rs`, `extensions.rs`), `deno_permissions-0.97.0/lib.rs`,
  `v8-146.4.0` (`src/handle.rs`, `src/isolate.rs`, **and the vendored V8 C++ at
  `v8/src/heap/heap.cc`**), `rustler-0.38.0/Cargo.toml`.
- `cargo clippy --release` — clean (clippy 0.1.91, no warnings).
- `cargo tree -p rustler -f "{p} {f}"` → `default,nif_version_2_14,nif_version_2_15,nif_version_2_16`.
- Three live probes against the built NIF via `mix run` on throwaway scripts in
  `/tmp` (no repo file touched). One of them reproduces a whole-BEAM abort.

---

## Headline answers to the two questions the task asked explicitly

**Is B2 genuinely closed? Yes — proven, not plausible.**
`JsRuntime` is declared as
```
364 pub struct JsRuntime {
365   pub(crate) inner: InnerIsolateState,
366   pub(crate) allocations: IsolateAllocations,
```
(`deno_core-0.391.0/runtime/jsruntime.rs:364-366`). Rust drops struct fields in
declaration order, so `inner` — whose `Drop` (`jsruntime.rs:227-245`) is the
thing that calls `ManuallyDrop::drop(&mut self.v8_isolate)` — is destroyed
*before* `allocations`, which owns the `Box<RefCell<dyn Any>>` holding the
closure (`IsolateAllocations::near_heap_limit_callback_data`, `jsruntime.rs:105-110`).
The raw `*mut c_void` V8 holds is `boxed_cb.as_ptr()` (`jsruntime.rs:1855-1856`),
i.e. into that same box. So on **every** path that drops a `MainWorker` — both
`worker::new` error returns after installation (`worker.rs:487-504`: the
`delete globalThis.Tyrex` `execute_script` and `execute_main_module`), normal
exit of `run`, and unwind — the isolate dies first and the closure box second.
The old hand-rolled `Arc<HeapLimitState>` + `Arc::as_ptr` + `unsafe extern "C"`
is gone entirely; there is no `unsafe` block left in the crate. The
`Arc<AtomicBool>` cannot be freed early either: the closure owns a clone, and the
closure lives in `allocations`. **B2 closed.**

**Is the new mechanism behaviourally equivalent to the one it replaced? No.**
The plan claims the rewrite was "re-probed, not assumed", and the probe it
records (`max_heap_mb: 64` + `chunks.push(new Array(1_000_000).fill(7))`) does
still pass. But the same commit also changed the callback's *return value*
(task 2.6, review S2) from an unconditional `current + 8MB` to a one-shot grant.
That change is not behaviour-preserving, and it reintroduces the exact failure
the option exists to prevent. See BLOCKER-1. Everything else about the rewrite —
lifetime, stickiness, `termination_error` plumbing — is equivalent or better.

---

## Blockers

### One-shot heap slack turns a guest OOM back into a whole-BEAM `abort()`

- **Where:** `native/tyrex/src/worker.rs:455-476` (the `if granted { current_heap_limit }` arm)
- **What:** The near-heap-limit closure returns `current_heap_limit` unchanged on
  every invocation after the first. V8 treats "callback did not raise the limit"
  as "we are out of options" and calls `FatalProcessOutOfMemory`, which is
  `abort()` — the whole BEAM node, which is precisely what `:max_heap_mb` is
  documented to prevent.
- **Why it matters:** `Tyrex.start(permissions: :none, max_heap_mb: 64)` plus one
  line of guest JavaScript kills the node. `README.md:393-398` states the
  opposite in so many words ("Without it, a guest allocating `new Array(1e9)`
  reaches V8's OOM handler, which calls `abort()` … With it, a near-heap-limit
  callback terminates the guest … so the caller gets
  `{:error, %Tyrex.Error{name: :heap_limit_error}}` instead"). For a release
  whose premise is that tyrex stopped overclaiming, this is a documented control
  that does not hold.
- **Evidence — reproduced, three times, on the committed tree:**

  ```
  $ PROBE_MB=64 PROBE_CODE='const a = new Array(1e9); a.fill(1); a.length' \
      TYREX_BUILD=true MIX_ENV=test mix run /tmp/heap_probe2.exs

  <--- Last few GCs --->
  [83514:...] 387 ms: Mark-Compact (reduce) 54.6 (55.3) -> 54.6 (55.3) MB … last resort
  [83514:...] 391 ms: Mark-Compact (reduce) 54.6 (55.3) -> 54.6 (55.3) MB … last resort
  #
  # Fatal JavaScript out of memory: Ineffective mark-compacts near heap limit
  #
  ==== C stack trace ===============================
   2  v8::base::FatalOOM(v8::base::OOMType, char const*)
   3  v8::internal::V8::FatalProcessOutOfMemory(...)
   …
  15  v8::internal::Builtin_ArrayPrototypeFill(...)
  23  deno_core::runtime::jsrealm::JsRealm::execute_script
  25  tyrex … start_runtime …
  ```
  The BEAM does not survive; nothing after that line runs. Reproduced with
  `max_heap_mb` of **32, 64 and 128** (`const a = new Array(200_000_000).fill(1)`),
  and with the README's own `new Array(1e9)` example once `.fill(1)` forces the
  backing store to materialise. `new Array(1e9)` alone, the exponential
  string-doubling shape, and the array-of-arrays shape used by the shipped test
  all return `{:error, …}` and leave the BEAM alive — which is why the suite is
  green at 160.

  The abort site is `Heap::CheckIneffectiveMarkCompact`
  (`v8-146.4.0/v8/src/heap/heap.cc:1383-1403`):
  ```cpp
  if (++consecutive_ineffective_mark_compacts_ == kMaxConsecutiveIneffectiveMarkCompacts) {
    if (InvokeNearHeapLimitCallback()) {   // callback raised the limit
      consecutive_ineffective_mark_compacts_ = 0;
      return;                              // no abort
    }
    …
    FatalProcessOutOfMemory("Ineffective mark-compacts near heap limit");
  }
  ```
  and `Heap::InvokeNearHeapLimitCallback` (`heap.cc:4224-4244`) returns `true`
  **only** when `heap_limit > limits()->max_old_generation_size()`. The one-shot
  arm returns exactly `max_old_generation_size()`, so it returns `false`.
  `Heap::CheckHeapLimitReached` (`heap.cc:1797-1808`) has the identical shape
  with `FatalProcessOutOfMemory("Reached heap limit")`.

  Two consequences follow directly from that source, without speculation:
  1. The abort *proves* the callback fired at least twice and took the `granted`
     branch — the first invocation always returns `current + 8MB > current` and
     therefore always returns `true`.
  2. [INFERENCE, from the V8 source above] Under the pre-2.6 unconditional
     `current + HEAP_LIMIT_SLACK_BYTES`, `InvokeNearHeapLimitCallback()` returns
     `true` on every invocation, the ineffective-mark-compact counter is reset,
     and neither of the two abort sites can fire. The S2 fix traded an unbounded
     but survivable ratchet for a bounded but fatal ceiling.
- **Suggested direction:** the callback must never return a limit that is not
  strictly greater than the one it was handed — V8 offers no "fail this
  allocation" answer, only "raise the limit" or "die". Grow unconditionally
  (deno's own `current * 2`, `deno_core`'s test at
  `deno_core-0.391.0/runtime/tests/misc.rs:565-568`, or the original
  `current + 8MB`). S2's ratchet concern is answered by the terminate-means-dead
  contract, not by the return value: the isolate is already terminated on the
  first trip and the worker tears down within one loop turn, so growth is bounded
  in wall-clock rather than in bytes. If a hard byte bound is genuinely wanted,
  it has to be enforced by *not* returning to V8 at all — i.e. treat the second
  invocation as a tyrex-side fatal and log it — but there is no safe formulation
  that hands V8 an unchanged limit. Whichever way it goes, the shipped
  `max_heap_mb` test needs a second allocation shape (a dictionary-mode array via
  `.fill`) or it will keep passing over this.

---

## Warnings

### Panic-path `try_remove` can unregister a *different*, live runtime

- **Where:** `native/tyrex/src/lib.rs:102-106`
- **What:** The unwind handler calls `runtimes::lock_or_recover().try_remove(runtime_id)`
  unconditionally. `worker::run` already removes the same id on all four of its
  exit paths (`worker.rs:594`, `:629`, `:702`, `:715`, `:722`), and
  `slab::Slab::insert` reuses vacated keys. If the unwind happens *after* one of
  those removals — the remaining code in that window is `drain_pending_promises`
  and, at the end of `run`, the `MainWorker` drop, i.e. full V8 isolate teardown
  with arbitrary Rust `Drop` impls — then by the time the handler runs the id may
  already have been reissued to a runtime started meanwhile.
- **Why it matters:** the victim runtime's slab entry disappears while it is
  perfectly healthy. Its `op_apply` then takes the `None` arm
  (`worker.rs:39-47`), prints "could not find pid … dropping reply" to stderr,
  and every `Tyrex.apply` promise in that guest hangs forever. Silent, permanent,
  and attributed to the wrong runtime. Under `Tyrex.Pool` the odds of a
  concurrent start in that window are not small.
- **Evidence:** the removal is unconditional at `lib.rs:106`, whereas the
  adjacent `send_to_pid` *is* guarded by `startup_reported` (`lib.rs:107`) — the
  author reasoned about double-reporting the reply but not about double-removing
  the id. `slab`'s key reuse is documented behaviour and is what makes the ids
  dense and enumerable in the first place (the premise of prior finding B5).
  [INFERENCE] I did not construct a panic during teardown; the reachability
  argument rests on `run` removing before `worker` drops, which is visible in the
  code.
- **Suggested direction:** the same `Cell<bool>` trick already used for
  `startup_reported` — have `run` (or a small guard type) record that the id was
  surrendered, and make the unwind handler's removal conditional. Alternatively
  move ownership of the slab entry into an RAII guard whose `Drop` does the
  removal exactly once, which also makes the unwind path free.

### A heap trip during `worker::new` is reported as `:execution_error`

- **Where:** `native/tyrex/src/worker.rs:487-504`
- **What:** The callback is installed at `worker.rs:462` and the sticky flag is
  live from that instant, but `worker::new`'s two remaining fallible steps —
  the `delete globalThis.Tyrex` script and `execute_main_module` — map their
  errors straight to `atoms::execution_error()` without consulting
  `heap_limit_tripped`. `termination_error/2` is only reachable from `run`, and
  the `Worker` (and with it the flag) is dropped on the error return.
- **Why it matters:** an operator whose `:main_module_path` blows a tight
  `:max_heap_mb` gets V8's uninformative post-termination message and
  `:execution_error` at `Tyrex.start/1`, with no indication that the cap is what
  killed it. It is a misreport, not a hole — the runtime does fail closed.
- **Evidence:** read of `worker.rs:487-504`; `termination_error` is called only
  at `worker.rs:628`, `:680` and `:714`, all inside `run`.
- **Suggested direction:** consult the flag in those two `map_err`s the same way
  the `Eval` arm does, or state in a comment that startup heap trips are
  deliberately reported as generic execution errors.

---

## Suggestions

### `catch_unwind` does not cover panics raised inside V8 callbacks

`lib.rs:52-64`'s comment is accurate about what it claims, but the containment
boundary is narrower than a reader may assume. `catch_unwind` around
`tokio_rt.block_on` catches the `serde_v8` unwraps it was added for — those run
in pure Rust frames (`worker.rs:649`, `:774`) under `poll_fn`/`block_on`. It does
**not** catch a panic raised inside a Rust function that V8 calls through an
`extern "C"` trampoline: `op_apply` (`worker.rs:26-51`, reached via the op2 fast
callback), the `PermissionedModuleLoader` hooks (`worker.rs:105-157`, reached
from V8's dynamic-import host callback), and the near-heap-limit closure itself
(`jsruntime.rs:2619-2631`). A panic in any of those aborts the process at the
`extern "C"` boundary before any handler runs. One sentence in that comment
naming the boundary would stop a future reader from assuming ops are covered.

### `String::from(...).into()` for a `FastString` literal

`worker.rs:489` builds an owned `String`, then `impl From<String> for FastString`
boxes it (`deno_core-0.391.0/fast_string.rs:433-436`). The string is a
compile-time ASCII constant; `deno_core::ascii_str!` produces a
`FastStringInner::StaticAscii` with no allocation and no copy. One allocation per
bridge-disabled runtime — trivial in isolation, but this is the only place in the
crate that allocates a constant.

---

## Verified clean (recorded so it is not re-litigated)

- **Re-entrancy / aliasing on the `granted` flag.** `add_near_heap_limit_callback`
  wraps the closure in `RefCell` (`jsruntime.rs:1855`) but the trampoline forms
  `&mut *(data as *mut F)` from `RefCell::as_ptr` (`jsruntime.rs:2619-2631`) — no
  borrow tracking. A closure that re-entered V8 allocation would alias `&mut F`.
  Tyrex's closure only does an `AtomicBool::store` and
  `IsolateHandle::terminate_execution`, which takes a `Mutex<()>` and calls
  `v8__Isolate__TerminateExecution` (`v8-146.4.0/src/isolate.rs:1973-1981`) — no
  V8-heap allocation, so V8's `AllowGarbageCollection` scope inside
  `InvokeNearHeapLimitCallback` (`heap.cc:4226`) cannot re-enter. No hazard, but
  it is one `format!` away from being one.
- **Stale `IsolateHandle` after isolate death.** `terminate_execution` locks the
  annex mutex and null-checks (`isolate.rs:1973-1981`); `dispose_annex` nulls the
  pointer under that same mutex (`isolate.rs:994-1001`). So the closure's
  captured handle, `Runtime::drop`, `terminate_runtime` and `eval_blocking`'s
  timeout arm are all safe against a torn-down isolate, and the "plain
  (non-dirty) NIF on purpose" comment at `lib.rs:135-145` is accurate.
- **`AssertUnwindSafe` is justified, not papering.** The only `!UnwindSafe`
  captures are the `Cell<bool>` (single boolean store, no torn state) and the
  process-global `runtimes` mutex, whose poisoning is explicitly recovered by
  `runtimes::lock_or_recover` (`runtimes.rs:15-20`) with a rationale that holds:
  the slab's only invariant is `id -> LocalPid`, and a partial mutation is
  observable but harmless. Continuing to use the global after an unwind is sound.
- **"Unwinding drops the promise slab before `worker`" — true.** `run`'s
  `let Worker { mut worker, .. } = handle;` (`worker.rs:576-580`) precedes
  `let mut promises` (`worker.rs:581`), and locals drop in reverse declaration
  order, so `promises` goes first, with the isolate still alive. Dropping a
  `v8::Global` there is sound: `impl Drop for Global` null-checks the isolate and
  otherwise calls `v8__Global__Reset` (`v8-146.4.0/src/handle.rs:353-365`), and we
  are on the isolate's own thread. The consequent `RecvError` →
  `dead_runtime_error` mapping (`lib.rs:178-183`, `:233-237`) matches what
  `lib/tyrex.ex` documents.
- **`op2` / extension wiring.** `#[op2(fast)]` with a leading `state: &mut OpState`
  compiles and clippy-checks clean; `options = { runtime_id: usize }` generates
  `pub fn init(runtime_id: usize) -> Extension`
  (`deno_core-0.391.0/extensions.rs:533`), so `extension::init(runtime_id)` is the
  correct constructor. `RuntimeId` is a private newtype, so
  `state.borrow::<RuntimeId>()` cannot collide with the other occupant of the map
  (`SnapshotOptions`) or with a bare `usize`. `extension/main.js` no longer passes
  or stores the id.
- **One `PermissionsContainer`, one lock.** `#[derive(Clone)]` on
  `PermissionsContainer` clones two `Arc`s over a shared
  `inner: Arc<Mutex<Permissions>>` (`deno_permissions-0.97.0/lib.rs:3795-3799`);
  `deep_clone` (`:3812`) is a *separate* method and is not used. The loader at
  `worker.rs:413-416` and `WorkerServiceOptions.permissions` are therefore one
  view behind one lock, not two.
- **Cargo delta coherent.** `rustler` and `rustler_codegen` both 0.36.2 → 0.38.0
  with matching checksums, `libloading 0.9.0` added as 0.38.0's new dep (0.8.9
  retained for other crates), `libc` added, crate version 0.3.0 → 0.4.0.
  `rustler-0.38.0/Cargo.toml:54-58` confirms `default = ["nif_version_2_15"]` and
  `nif_version_2_16 = ["nif_version_2_15"]`, and `cargo tree` now reports
  `nif_version_2_16` enabled. Prior blocker **B3 closed and verified**, and
  the Elixir side agrees (`mix.exs:86` `~> 0.38.0`, `mix.lock` 0.38.0).
- **`cargo clippy --release`: no warnings.**

## Persistent prior findings

**None.** B2 and B5 are closed in the Rust (B5: the id now travels in per-runtime
`OpState`, `Tyrex._runtimeId` and the `parse::<usize>()` branch are gone). B3 is
closed and verified by `cargo tree`. W10's containment is present and correct for
the panics it was written for; S1 and S2 were both implemented — S2 is what
BLOCKER-1 is about, so it is a *new* defect rather than a persistent one.

## Pre-existing (one line each)

- `native/tyrex/src/lib.rs:12` — `start_runtime` is `schedule = "DirtyCpu"` but only inserts a slab entry and spawns a thread; it is not CPU work. PRE-EXISTING.
- `native/tyrex/src/lib.rs:22` — the slab entry is inserted before `std::thread::spawn`; if the spawn itself fails the entry leaks and `init/1` waits out its full `:startup_timeout`. PRE-EXISTING.
- `native/tyrex/src/worker.rs:524-531` — `let _ = sender.send(..).ok();` is doubly redundant. PRE-EXISTING.
