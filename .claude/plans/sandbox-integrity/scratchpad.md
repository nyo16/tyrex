# Scratchpad — sandbox-integrity

Decisions, evidence, and dead ends. Working notes for whoever executes the plan.

## Evidence gathered before planning (all reproduced at e61bba8)

Escape, under `permissions: :none`:
```
Deno.readTextFileSync('mix.exs')        -> {:error, "NotCapable: Requires read access"}
Tyrex.apply('File','read!',['mix.exs']) -> {:ok, 1962}
Tyrex.apply(':os','cmd',[[105,100]])    -> {:ok, 396}    # shell exec, allow_run denied
```

Deadlock (`blocking: true` + bridge):
```
non-blocking apply          -> {:ok, 3}
blocking apply (4s timeout) -> {:caught, :exit, :timeout}
post-deadlock health check  -> ** (EXIT) time out   # runtime permanently unusable
```

Thread leak (3 runaways, all runtimes stopped, all Elixir procs dead):
```
schedulers_online / dirty_cpu_schedulers -> 10 / 10
cpu% after 3 stops                       -> 299.6
blocking:true on a fresh runtime         -> {:ok, 42}   # dirty schedulers NOT exhausted
run_queue                                -> 1
```

Op reachability probes (this is why the consumer's mitigation is sound):
```
typeof Deno?.core?.ops?.op_apply -> "undefined"   # Deno.core not exposed at all
delete globalThis.Tyrex          -> "undefined"   # plain writable prop, deletable
import("ext:core/ops")           -> TypeError: Importing ext: modules is only allowed from ext: and node: modules
import("ext:extension/main.js")  -> TypeError: (same)
```

## Decisions

- **One plan, not four.** The deno lockstep bump (19 minors) must not ride in a
  security release. Phases 1–3 touch none of the files the bump touches.
- **Deny-by-default over a deprecation cycle.** Pre-1.0, and v0.3.0 was itself a
  hardening release. A silent-behaviour-change warning for one release is the
  compromise (see plan risk note).
- **Bridge opt-in via allowlist, not a boolean.** A boolean `apply: true` just
  recreates the hole for anyone who flips it. `[{Module, :fun, arity}]` makes the
  privileged surface explicit and reviewable.
- **Allowlist enforced in Elixir, not JS.** JS-side checks are inside the blast
  radius. `handle_info({:apply, ...})` is the only trustworthy chokepoint.
- **`eval_blocking` → `DirtyIo`, not `DirtyCpu`.** It parks on a channel; that is
  I/O-shaped waiting. `DirtyCpu` is for compute.
- **Kill needs no dependency bump.** `thread_safe_handle()` is `Send + Sync` and
  present in the pinned deno_core. Confirmed against `worker.rs:182-209`.

## Corrected claim (worth preserving — it will resurface)

The consumer believes `eval` is `DirtyCpu` and that runaways are capped at one
lost dirty scheduler per core. Both wrong:

- `lib.rs:98` `eval` has no `schedule =`; `lib.rs:137` `eval_blocking` is the
  `DirtyCpu` one.
- Runaways burn the per-runtime OS thread from `lib.rs:23`, so the leak is
  **unbounded** — no core-count ceiling — and invisible to BEAM scheduler-utilization
  monitoring.
- `stop/1` returning `:ok` is not evidence of reclamation. It kills the Elixir
  process; the thread spins on.

## Dead ends / rejected

- **"Just document that `:none` isn't a sandbox."** Insufficient — the bridge is
  on by default, so the safe configuration is not reachable at all today.
- **Gating the bridge inside `main.js`.** Guest code runs in the same isolate; a
  JS-side guard is not a boundary. Rejected in favour of the Elixir chokepoint.
- **Relying on `deny_import` to block op re-acquisition.** Unnecessary — the
  `ext:` restriction is structural (probe above). Keep `deny_import` for network
  imports, not for this.
- **`GenServer.call` timeout as the deadline.** That is the current design and is
  exactly the defect: the caller gives up, the JS keeps running.

## RESOLVED — the Phase 2 open question

Does a `MainWorker` survive `terminate_execution()` mid-`execute_script` once
`cancel_terminate_execution()` is called, or is teardown the only safe recovery?

**Teardown won.** Contract shipped: terminate => the runtime is dead => the
caller (or its supervisor) starts a fresh one. No `cancel_terminate_execution`
anywhere in the tree. Reasoning, in order of weight:

1. A pooled runtime that silently became a brick after its first timeout is a
   far worse failure mode than one that was replaced. `:dead_runtime_error`
   already existed, so "terminate => dead" needed no new vocabulary.
2. Recovery is not observably testable — "sometimes survives" cannot be
   asserted. Teardown is deterministic and is now pinned by
   `test/tyrex_lifecycle_test.exs`.

A finding worth keeping, discovered while implementing 2.3: **`is_execution_terminating()`
is not a reliable post-hoc signal.** V8 clears the flag once the termination has
propagated out of the outermost script, so by the time `execute_script` returns
it frequently reads false. The heap-limit path therefore carries its own sticky
`AtomicBool` set inside the near-heap-limit callback; without it a guest OOM
reported `:execution_error` instead of `:heap_limit_error`. Anything else that
needs to know "was this torn down by us?" must carry its own flag too.

The pool did not need the deferred arch-plan strategy-state fix: `:rest_for_one`
already replaces a killed runtime. Note for whoever writes that plan — killing
child 0 tears down and rebuilds its siblings too, so calls during the restart
window exit with `:noproc` rather than returning an error tuple.

## Verified end to end (post-implementation, at v0.4.0)

```
Deno.readTextFileSync('mix.exs')        -> {:error, NotCapable}     # unchanged
typeof globalThis.Tyrex                 -> "undefined"              # was an object
Tyrex.apply('File','read!',['mix.exs']) -> {:error, ...}            # was {:ok, 1962}
Tyrex.apply(':os','cmd',[[105,100]])    -> {:error, ...}            # was {:ok, 396}
[allow_all: true, allow_run: false]     -> NotCapable: run          # was allowed
allow_read: []                          -> NotCapable: read         # was whole FS
[deny_nett: true]                       -> ArgumentError            # was permissive
blocking:true + bridge                  -> :unsupported_option      # was deadlock
3 runaways burning                      -> 2.99 cores
  after stop/1                          -> 0.00 cores               # was 2.996
64MB cap, unbounded allocation          -> :heap_limit_error, BEAM alive  # was abort()
```
