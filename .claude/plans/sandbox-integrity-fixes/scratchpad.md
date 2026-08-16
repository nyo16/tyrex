# Scratchpad — sandbox-integrity-fixes

Decisions, evidence, and dead ends. Working notes for whoever executes the plan.

## State of the tree when this plan was written

The v0.4.0 work is **uncommitted on `master`** — 19 files, +1671/−289, nothing
pushed. 141 tests green. A branch was requested and deliberately not created:
review came first and found five blockers.

Build note: `TYREX_BUILD=true` is required for every `mix compile` / `mix test`,
because `mix.exs` is now `0.4.0` and no precompiled v0.4.0 artifacts exist. See
task 3.2 — this is the same root cause as the stale checksum blocker.

## Evidence reproduced during review (all on this machine, at the v0.4.0 tree)

Module loader ignores permissions entirely (task 1.1):
```
permissions: :none  import("file:///tmp/imp/secret.js")     -> "SECRET-FROM-DISK"
permissions: :none  import(".../secret.json", type:"json")  -> %{"secret" => "json-secret"}
permissions: :none  import("file:///etc/passwd", type:"text") -> THREW: "text" is not a valid module type
permissions: :none  Deno.readTextFileSync(same file)        -> THREW: Requires read access
allow_all + deny_import: plain js import                    -> "SECRET-FROM-DISK"
```

The `type:"text"` line is the trap. The security agent's original repro used it,
it failed for an unrelated reason, and the bypass looked closed. **Probe with a
plain `.js` import or `type:"json"`.**

Deny polarity is inverted in the docs, not the code (task 1.5):
```
allow_read: false                        -> denied
deny_read: true                          -> denied
deny_read: false  (docs say "deny all")  -> READ OK (2154 bytes)
```

rustler ships 2.15, not 2.16 (task 3.1) — from the vendored manifest:
```
[features]
default = ["nif_version_2_15"]
nif_version_2_16 = ["nif_version_2_15"]
```
`native/tyrex/Cargo.toml` has `rustler = "=0.38.0"` with no `features`, so
`nif_version_2_16` is never enabled.

Safe replacement for the unsafe heap callback exists in the pinned crate
(task 1.3) — `deno_core-0.391.0/runtime/jsruntime.rs:1851`:
```rust
pub fn add_near_heap_limit_callback<C>(&mut self, cb: C)
where C: FnMut(usize, usize) -> usize + 'static
```
It boxes the closure into `self.allocations`, and `allocations` is declared
after `inner` in `struct JsRuntime` (jsruntime.rs:365-366) *precisely* so it
outlives the isolate. That is the invariant the v0.4.0 patch hand-rolled and got
backwards.

## Decisions

- **Phase 1 gates the PR; Phase 3 gates the tag.** Nothing in Phase 3 can hurt a
  user until `mix hex.publish` runs. Do not let Phase 3 block the branch.
- **Fix B1 rather than disclaim it — Option A, CONFIRMED and shipped.** The user
  chose Option A when asked, before task 1.1 began. `permissions: :none` cannot
  honestly describe itself while `import()` reads anything. Implemented as
  `PermissionedModuleLoader` over `PermissionsContainer::check_specifier`,
  enforcing in both `resolve` and `load`, with six tests. The decision is closed;
  do not treat it as open.
  *Caveat found later (residue plan task 1.1):* enforcing `import()` did not make
  `allow_import` a working grant. The loader only reads `file:` URLs, so a remote
  import fails under every permission set and `allow_import` is decorative. The
  docs written for Option A overstated it and are corrected in the residue pass.
- **Delete the unsafe, do not repair it.** Task 1.3 could be fixed by reordering
  two `let` bindings. Rejected: the safe deno_core API removes the raw pointer,
  the `Arc`, the `unsafe` block, the drop-order reasoning, and the two
  compensating comments. Reordering leaves a hand-rolled invariant that the next
  refactor breaks again silently.
- **Phase 4 tasks must be seen red.** The whole finding class is "test passes
  through the regression it exists to catch", so the verify step requires
  reverting the production line and watching the assertion fail. A test that has
  only ever been green is not evidence.

## Dead ends / rejected

- **"`import()` is pre-existing, so it is out of scope."** Tempting and wrong.
  It is pre-existing, but v0.4.0's entire premise is that tyrex stopped
  overclaiming about the sandbox, and it ships a permission table advertising
  `allow_import`/`deny_import`. Shipping it unchanged re-commits the original
  sin at a new address.
- **Reordering `let worker` / `let heap_limit_state` to fix the UAF.** See above.
- **`assert :ok = Tyrex.kill(...)` as a real assertion.** `kill/1` ends in
  `catch :exit, _ -> :ok`, so it returns `:ok` for a dead pid, an unregistered
  name, a wedged runtime, or a timeout. It cannot fail.
- **Trusting the v0.4.0 plan's completeness table.** It is accurate about task
  *coverage* (18/19 MET) and says nothing about task *correctness*. Three of the
  five blockers are inside tasks marked done.

## Open question for whoever does Phase 1

Task 1.1's main-module exemption: is matching on the resolved main-module
`ModuleSpecifier` captured at loader construction sufficient, or can a guest
cause a re-load of that same specifier to smuggle a read? The specifier is
operator-supplied and fixed at `worker::new`, so a guest cannot choose it — but
confirm a guest cannot `import()` the main module's *path* to prove the exemption
is not a general read primitive. Write that as a test either way.

## Not covered by any task

`examples/` and `bench/` have never been read by any reviewer across two audit
passes. They call `Tyrex.start()` with no `:permissions` and several use
`Tyrex.apply`, so v0.4.0's new defaults break them. No task covers them because
no one has looked. Flagged in the plan's self-check; needs a pass before release.

### [01:51] WARN: SandboxSecurity did not write .claude/plans/sandbox-integrity-fixes/reviews/security.md — extracted from agent artifact
The security-reviewer agent type has no write tool. Its full report was returned in the
`coverage_summary` field of `agent://SandboxSecurity` and was persisted verbatim by Main.
Content is the agent's, not paraphrased. Four live probes in it were run by Main on the
agent's behalf (its own BEAM was x86_64 and could not dlopen the arm64 NIF).
