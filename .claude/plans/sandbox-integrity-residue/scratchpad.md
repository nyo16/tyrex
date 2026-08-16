# Scratchpad — sandbox-integrity-residue

Decisions, evidence, and dead ends. Working notes for whoever executes the plan.

## State of the tree when this plan was written

Branch `v0.4.0-sandbox-integrity`, **two commits, nothing pushed**:

```
27bb9df  Fix five blockers found by the v0.4.0 review panel
f134c25  Tyrex 0.4.0: close the sandbox, make deadlines real
```

`TYREX_BUILD=true` is required for every `mix` command — there are no precompiled
v0.4.0 artifacts. Suite is **165 passing**, `mix format --check-formatted` clean,
`mix compile --warnings-as-errors` clean.

`.claude/` is untracked and has never been tracked in this repo, so the plans and
review reports do **not** travel with the branch. If that matters, it is a
deliberate change of convention, not an oversight.

## Evidence reproduced while writing this plan

`allow_import` cannot grant anything (task 1.1) — no permission set loads a remote
module:

```
allow_all                          -> "Provided module specifier "https://..." is not a file URL."
[allow_import: true,
 allow_net: true, allow_read: true] -> same
[allow_all: true, deny_import: true] -> "Requires import access to "deno.land:443""
```

So `deny_import` only changes the error *text*. `data:`/`blob:` are exempted by
`check_specifier` itself (`deno_permissions-0.97.0/lib.rs:3941-3942`) but also die
in `FsModuleLoader`, so no grant leaks either way.

The `Cross.toml` Dockerfile exists (task 1.6) — the recorded rationale is false:

```
$ ls -la native/tyrex/Dockerfile.aarch64-unknown-linux-gnu
-rw-r--r--  332 Mar 14 10:34
$ git ls-tree master --name-only native/tyrex/
  native/tyrex/Dockerfile.aarch64-unknown-linux-gnu     <-- tracked at master
```

Only `_build/*.beam` mention it now, i.e. stale build artifacts. It is an orphan.

`kill/1` is inert on its documented case (task 3.1), against a `blocking: true`
runaway wedging the GenServer inside `Tyrex.Native.eval_blocking/3`:

```
kill -> :ok after 5002ms; alive? true
stop -> :ok after 5002ms; alive? false
```

## Decisions

- **Phase 1 gates the tag.** It is docs-only and cheap, but it is the phase that
  makes the branch's claims true. Shipping v0.4.0 with `allow_import` described as
  a working grant re-commits the release's original sin for the third time.
- **`kill/1` is an open decision, not an oversight.** See the decision block in the
  plan. Option B recommended. Do not start 3.1 before choosing.
- **Do not delete `allow_import`/`deny_import`.** They are real
  `PermissionsOptions` fields and `deny_import` is live; the defect is the
  documentation presenting the pair as symmetric. Deleting them would break the
  one direction that works.
- **`[INFERENCE]` labels are load-bearing.** Task 4.2's slab-reuse finding has no
  reproduction. Keep the label in any commit message; do not promote it to
  "observed" because the fix is cheap.

## Dead ends / rejected

- **"`allow_import` is fail-closed, so it is fine."** It is fail-closed, which is
  why it is a warning and not a blocker. It is still a documented control that
  cannot be enabled, in the section written to close that exact class.
- **Wrapping the `Worker` panic in `catch_unwind`.** Foreclosed by the last pass:
  the panic crosses an `extern "C"` boundary as `panic_cannot_unwind` and aborts
  unconditionally. `deno_core` contains zero `catch_unwind`. Deleting the global
  was the only available fix and it is already done.
- **`Keyword.drop(opts, [:size, :strategy])` to de-duplicate `pool.ex`'s option
  list.** Rejected during the previous pass: it converts a fail-closed drop into a
  fail-open leak. The real fix is for `Tyrex` to own and export the list, which is
  an API change and out of scope.
- **Trusting a consolidated review list.** See the process note below. This is the
  second time it has cost a finding.

## Process note — how task 2.2 survived two audits

`assert {:ok, "undefined"} = Tyrex.eval("typeof Deno?.core?.ops?.op_apply", ...)`
was raised **by name, with the correct replacement assertion**, in the previous
review's per-agent security report
(`.claude/plans/sandbox-integrity/reviews/security.md:200-243`). It never made that
review's consolidated 23, so no task was ever assigned, so it shipped unchanged —
and three separate agents rediscovered it this pass.

The consolidation step loses findings, and nothing checks the per-agent files
against the consolidated list. The same thing happened to a lesser degree in *this*
pass: two priority-1 findings (the `:apply` MFA blocking the eval deadline, and the
CHANGELOG's false "always wins the race") were dropped from the consolidated
summary and only recovered because the extraction agents were told to expect it.

If there is a third review, diff the per-agent findings against the consolidated
list before acting on either.

## Open question for whoever does Phase 3

Task 3.2 may not have a good answer. The `:apply` MFA runs inside the GenServer
*on purpose* — the release's own rationale is that "a guard inside the isolate would
be inside the blast radius". Moving execution off the message loop to keep the
deadline serviceable moves it away from the process that holds the authorization
decision. Options are probably: spawn a task per apply and keep authorization in the
GenServer; or accept that bridge time is uncovered and document it. Decide on
evidence — measure a realistic allowlisted call — not on which reads tidier.

## Not covered by any task

`examples/` and `bench/` are broken by v0.4.0's defaults and have now been deferred
by three consecutive plans. `examples/basic.exs:49` calls `Tyrex.apply` with no
`apply:` option; six `Tyrex.start()` calls omit `:permissions`. They need a pass of
their own, and someone should actually run them.

`lib/tyrex/inline.ex`, `lib/tyrex/sigil.ex` and the pool strategy modules are
untouched by the diff and so have been out of scope for every review — which means
no reviewer has ever read them.
