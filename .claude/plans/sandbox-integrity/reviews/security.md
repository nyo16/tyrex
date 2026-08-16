# Security Review: tyrex v0.4.0 "sandbox integrity"

**Reviewer:** SecurityReview (read-only) · **Scope:** `git diff HEAD` for slug `sandbox-integrity`
**Threat model assumed:** the attacker fully controls the JavaScript passed to `Tyrex.eval/2`.
No source file was modified. No build or test was run (per constraints); all Rust/JS behaviour
below was verified by reading the pinned crate sources at
`~/.asdf/installs/rust/1.57.0/registry/src/index.crates.io-*/` (`deno_core-0.391.0`,
`deno_runtime-0.246.0`), located via `target/release/deps/*.d`.

## Executive summary

The core of the change is sound. I attacked the allowlist directly — string aliasing,
normalization, arity confusion, `decode_args/1` vs `apply/3` disagreement — and **found no
bypass**. The decision that guest strings are only ever a map *key* while the invoked
`{mod, fun}` comes from the allowlist *value* is the right one and holds up under pressure.
The decision to enforce in the GenServer rather than in JS is what contains Finding 1.
Bridge deletion is durable — I could not find a recovery path, though not for the reason the
code comments give (§3).

Two findings reopen holes:

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | **BLOCKER** | Guest-writable `Tyrex._runtimeId` lets a guest invoke **another runtime's** allowlist | Exploitable |
| 2 | **BLOCKER** | `import()` bypasses `allow_read` entirely; `allow_import`/`deny_import` are inert | Exploitable, confirmed in deno sources |
| 3 | WARNING | The test guarding op-unreachability is a false negative; the real protection is untested | Latent |
| 4 | WARNING | Bridge is unbounded message production; softens the deadline, evades `:max_heap_mb` | Exploitable (DoS) |
| 5 | WARNING | Argument injection is total and under-documented | Defence-in-depth / docs |
| 6 | WARNING | Elixir exception messages relayed verbatim into guest JS | Defence-in-depth |
| 7 | WARNING | README contradicts `pool.ex` on `:apply` forwarding | Docs |
| 8 | SUGGESTION | `allow_all: <list>`, boolean coercion in permission lists, unvalidated `:timeout`, dead JS | — |

Permission polarity (§9) is **clean** — I re-derived the full truth table and found no
combination that silently widens access.

---

## 1. BLOCKER — Guest-controlled `runtime_id` breaks the per-runtime allowlist boundary

**Location:** `native/tyrex/extension/main.js:24,39` · `native/tyrex/src/worker.rs:16-46,378` ·
`native/tyrex/src/lib.rs:24` · `native/tyrex/src/runtimes.rs:4-7`

The bridge's routing key is guest data.

```js
// extension/main.js:24,39
_runtimeId: null,
op_apply(Tyrex._runtimeId, applicationId, module, functionName, JSON.stringify(args));
```

```rust
// worker.rs:378 — installed as a plain, writable, configurable data property
format!("globalThis.Tyrex._runtimeId = \"{runtime_id}\";")

// worker.rs:26-46 — the guest's string indexes a *process-global* pid slab
let parsed_id = match runtime_id.parse::<usize>() { ... };
let slab = runtimes::lock_or_recover();
let pid = match slab.get(parsed_id) { ... };
util::send_to_pid(pid, (atoms::apply(), application_id, module, function_name, args));
```

`runtimes::get()` is one `OnceLock<Mutex<Slab<LocalPid>>>` shared by **every runtime in the
VM**, and `lib.rs:24` allocates ids with `Slab::insert` — small, dense integers from 0,
brute-forceable in a single loop. Freed slots are reused, so even a known-dead id can later
resolve to a fresh runtime.

A guest that assigns `globalThis.Tyrex._runtimeId` therefore chooses **which GenServer receives
the `{:apply, ...}` message**. That GenServer authorizes against *its own* `apply_allowlist`
(`lib/tyrex.ex` `authorize_and_apply/4`) and executes. The allowlist consulted is not the one
belonging to the isolate the code is running in.

This is the entire security control introduced by Phase 1, and the attacker selects it.

### Reproduction

```elixir
{:ok, victim}   = Tyrex.start(apply: [{System, :cmd, 2}])   # a privileged runtime
{:ok, attacker} = Tyrex.start(apply: [{Enum, :sum, 1}])     # guest may only reach Enum.sum/1

Tyrex.eval(~s"""
(() => {
  for (let i = 0; i < 32; i++) {
    globalThis.Tyrex._runtimeId = String(i);
    try { Tyrex.apply("System", "cmd", ["touch", ["/tmp/tyrex-pwned"]]); } catch (_) {}
  }
  return "sent";
})()
""", pid: attacker)
```

**Expected today:** `File.exists?("/tmp/tyrex-pwned") == true`, though the attacker's allowlist
contains only `Enum.sum/1`.
**Expected after a fix:** file absent; every iteration rejects with `permission_denied:`.

### Scope and limits, stated honestly

- **Blind, not exfiltrating.** The victim worker runs `globalThis.Tyrex._applyReply(id, ...)`
  in *its* isolate (`worker.rs` `Message::ApplyReply`), whose `_applications` lacks the id, so
  `main.js:12-16` returns early and the value is dropped. The attacker gets side effects, not
  return values. That is still arbitrary invocation of any MFA any other runtime allowlisted.
- **Precondition:** the attacker's own runtime must have the bridge on, since `op_apply` is
  otherwise unreachable (§3 confirms this precondition genuinely holds). That is exactly the
  configuration this release supports, so the precondition is met in the intended threat model.
- **Good defence that bounds blast radius:** a victim with `apply: false` has
  `apply_allowlist == nil` and `authorize_and_apply(nil, ...)` rejects. Only bridged runtimes
  are usable victims. Keep that clause — it is doing real work here.
- **Also cross-tenant DoS:** repoint `_runtimeId` and flood an unrelated runtime's GenServer
  (compounds with Finding 4).
- `Tyrex.Pool` forwards `:apply` (`pool.ex:64`), so pool members are co-resident bridged
  runtimes. Within one pool the allowlists are identical so there is no privilege gain, but a
  deployment with a pool *plus* a separately-configured privileged runtime is fully exposed.

### Fix direction

The runtime id must not round-trip through JS. `deno_core::extension!` already takes a `state`
closure; put the id in `OpState` at extension init and have `op_apply` take
`state: &mut OpState` instead of `#[string] runtime_id`. `main.js` then drops `_runtimeId`
entirely and `worker.rs:377-381` loses the enabled branch's `format!`. That deletes the
attacker-controlled input rather than validating it.

The comment at `worker.rs:24` ("someone overwrote `Tyrex._runtimeId`") shows the mutability was
noticed, but treated as a robustness concern — don't panic — rather than an authorization one.

---

## 2. BLOCKER — `import()` is an unpermissioned file read; `allow_import`/`deny_import` are inert

**Location:** `native/tyrex/src/worker.rs:338` · `test/tyrex_permissions_test.exs:109-128` ·
`README.md` "Available Permission Keys"

```rust
module_loader: std::rc::Rc::new(deno_core::FsModuleLoader),
```

`deno_core::FsModuleLoader` is the basic embedder loader. Confirmed in
`deno_core-0.391.0/modules/loaders.rs:429-500`:

- `ModuleLoader::load` receives **no `PermissionsContainer`** (see the trait signature at
  `loaders.rs:89`), so it structurally cannot consult permissions.
- Its body ends in a bare `std::fs::read(path)` (`loaders.rs:484`).
- It honours import attributes: `.json` → `ModuleType::Json`, and for any other extension it
  maps `RequestedModuleType::Text` → `ModuleType::Text` and `Bytes` → `ModuleType::Bytes`
  (`loaders.rs:455-469`). `get_requested_module_type_from_attributes`
  (`modules/mod.rs:311-324`) accepts `"json"`, `"text"`, and `"bytes"`.
- `check_import` / `allow_import` appear **nowhere** in `deno_core-0.391.0` or
  `deno_runtime-0.246.0` (grepped both). Import permission enforcement lives only in Deno's
  CLI loader, which tyrex does not use.

So under `permissions: :none`, `Deno.readTextFileSync("mix.exs")` is denied — and tested at
`tyrex_permissions_test.exs:143` — while `import()` reads any file on disk.

### Reproduction

```elixir
{:ok, pid} = Tyrex.start(permissions: :none)

Tyrex.eval(
  ~s|(async () => (await import("file:///etc/passwd", {with:{type:"text"}})).default)()|,
  pid: pid
)
# expected: {:ok, "##\n# User Database\n..."} — arbitrary file read under :none
```

The `type: "text"` attribute needs no particular file extension, so this reads **any** file the
BEAM's OS user can read. `type: "json"` gives structured reads of `.json` files;
`type: "bytes"` gives raw bytes; and `import("file:///abs/x.js")` executes attacker-planted
on-disk JavaScript.

Control, proving `deny_import` is inert rather than merely bypassed:

```elixir
{:ok, p2} = Tyrex.start(permissions: [allow_all: true, deny_read: true, deny_import: true])
Tyrex.eval(same_code, pid: p2)   # expected: still succeeds
```

### Why the existing test does not catch it

`tyrex_permissions_test.exs:109-128` uses an **`https:`** specifier. `FsModuleLoader::load`
rejects any non-`file:` URL with `"Provided module specifier ... is not a file URL."`
(`loaders.rs:449-453`) regardless of permissions, so the test passes whether or not
`deny_import` does anything — and it asserts only
`err.name in [:promise_rejection, :execution_error]`, which cannot distinguish a permission
denial from an unsupported-scheme error. The inline comment ("Deno checks the import permission
*before* any network call") describes the CLI's behaviour, not this embedding's.

### Fix direction

Either wrap `FsModuleLoader` in a loader that calls `PermissionsContainer::check_read` before
delegating (a ~20-line newtype; it has the container already at `worker.rs:341`), or — if that
is out of scope for this release — remove `allow_import`/`deny_import` from the documented key
set, state plainly that ES module loading sits outside the permission system, and rewrite the
test against a `file:` specifier asserting the real behaviour. Advertising an inert key in the
permission table is the exact failure mode task 1.3 set out to eliminate, one level up.

---

## 3. WARNING — The test guarding op-unreachability is a false negative

**Location:** `test/tyrex_permissions_test.exs:161-172`

```elixir
# Deno.core is not exposed, so the op cannot be re-acquired directly.
assert {:ok, "undefined"} = Tyrex.eval("typeof Deno?.core?.ops?.op_apply", pid: pid)
```

The assertion passes, but **the stated reason is false and the test does not cover the property
it claims to.** From `deno_runtime-0.246.0/js/99_main.js`:

```js
// 99_main.js:558-566
// FIXME(bartlomieju): temporarily add whole `Deno.core` to `Deno[Deno.internal]` namespace.
ObjectAssign(internals, { core, nodeGlobals: { ...nodeGlobals } });
const internalSymbol = Symbol("Deno.internal");
const finalDenoNs = { internal: internalSymbol, [internalSymbol]: internals, ...denoNs, ... };
// 99_main.js:804 — unconditional, no unstable flag
ObjectDefineProperty(globalThis, "Deno", core.propReadOnly(finalDenoNs));
```

`Deno.core` is undefined only because `denoNs` has no `core` key. The whole of `core` **is**
reachable from guest JS at `Deno[Deno.internal].core`. The test probes a path that would remain
`undefined` even if the real protection were removed tomorrow.

**The real protection is `removeImportedOps()`** (`99_main.js:548-556`, called at `:720` and
`:968`), which deletes every op from `core.ops` except a small `NOT_IMPORTED_OPS` allowlist that
does not include `op_apply`. Both call sites run during `JsRuntime` construction inside
`MainWorker::bootstrap_from_options`, i.e. before `worker::new` issues any `execute_script` and
long before guest code. tyrex's `main.js:3` static `import {op_apply} from "ext:core/ops"`
captures the function into a module-scope binding, which survives the property deletion — which
is precisely why the bridge still works while the guest cannot name the op.

So the invariant holds today, but it rests entirely on an upstream implementation detail that
tyrex neither tests nor documents, and the one test that looks like it covers this is blind to
it. A deno bump that changes `removeImportedOps` or `NOT_IMPORTED_OPS` reopens the escape with
a green suite.

**Fix:** assert the load-bearing path.

```elixir
assert {:ok, "undefined"} =
         Tyrex.eval("typeof Deno[Deno.internal].core.ops.op_apply", pid: pid)
# and pin the shape, so the test fails loudly rather than vacuously if the path moves:
assert {:ok, "object"} = Tyrex.eval("typeof Deno[Deno.internal].core.ops", pid: pid)
```

Correct the comment while you are there, and treat this assertion as a deps-upgrade gate for
the deferred bindings plan.

---

## 4. WARNING — Bridge is an unbounded message-production primitive; the deadline degrades

**Location:** `worker.rs:43-46` · `lib.rs:196-208` (`apply_reply`) · `lib/tyrex.ex`
`arm_deadline/3`, `handle_info({:apply, ...})`

`op_apply` performs one `enif_send` per call with no counter and no cap, and `apply_reply`
pushes into an `unbounded_channel`. A guest with the bridge on drives both queues:

```elixir
{:ok, p} = Tyrex.start(apply: [{Enum, :sum, 1}], max_heap_mb: 64)
Tyrex.eval(~s|for(;;){ Tyrex.apply("Enum","sum",[[1]]); }|, pid: p, timeout: 1_000)
```

The `for(;;)` never yields, so the worker thread stays inside `execute_script` and never drains
the `ApplyReply` mpsc, while the GenServer mailbox fills from the other side.

1. **`:max_heap_mb` does not bound this.** The V8 heap stays small (each iteration's promise is
   collectable); growth is BEAM mailbox plus native mpsc. The README correctly says the cap
   bounds the V8 heap and not the OS process, but never mentions that a bridged guest holds a
   direct handle on BEAM memory.
2. **The deadline becomes soft.** `arm_deadline/3` uses
   `Process.send_after(self(), {:deadline, from}, timeout)`, so `{:deadline, from}` lands at the
   *tail* of the same mailbox, behind every `{:apply, ...}` that arrived before it. Firing is
   delayed by `backlog / drain_rate`. "Real deadlines" (README:16) holds with the bridge off and
   softens exactly where guests are most privileged.

Measure both: watch RSS, and compare wall-clock time-to-`{:error, %Tyrex.Error{name: :timeout}}`
against the requested 1000 ms.

The plan defers "unbounded mpsc, no backpressure" to a perf plan, which was reasonable when it
was a throughput concern. Now that the bridge ships as a supported security feature, the same
code is a guest-reachable resource-exhaustion primitive and a weakening of the headline
deadline guarantee. Re-triage it as security, not throughput.

**Fix direction:** an in-flight counter in `OpState`; `op_apply` throws a JS error above a cap.
`op_apply` is synchronous, so throwing *is* natural backpressure — the guest's own loop stalls.

---

## 5. WARNING — Argument injection is total, and the docs do not say so

The allowlist authorizes the *function*; it never constrains the *arguments*. `decode_args/1`
`Jason.decode`s guest JSON, so an allowlisted `{M, :f, n}` is callable with any
JSON-representable term. That is a defensible design — but each allowlist entry is a far larger
capability than "one function", and nothing says which entries are catastrophic.

Two nuances worth writing down, because they are easy to get wrong in *both* directions:

- **JSON cannot mint atoms**, so `{Kernel, :apply, 3}` is *not* directly exploitable — a binary
  module name raises `ArgumentError` inside `invoke/3` and is caught. Pleasant surprise.
- **JSON absolutely can mint charlists.** `[105, 100]` decodes to `~c"id"`, so `{:os, :cmd, 1}`
  is fully exploitable. The project's own test at `tyrex_permissions_test.exs:154` uses exactly
  this encoding. "Guests can't build Erlang terms" is not a safety property to lean on.

Entries a reasonable user might plausibly add that hand over the machine:
`{Code, :eval_string, 1}` (RCE), `{System, :cmd, 2}` (RCE), `{File, :read!, 1}` /
`{File, :write!, 2}` (arbitrary FS — README:442 does call this one out),
`{String, :to_atom, 1}` (atom-table exhaustion, kills the VM),
`{:erlang, :binary_to_term, 1}` (unsafe deserialization).

README:270 ("treat every entry as a capability handed to the guest") is the right instinct.
**Ask:** a short "what not to allowlist" subsection stating that the guest chooses every
argument, plus the list above. Docs-only; no code change.

---

## 6. WARNING — Exception messages are relayed verbatim into guest JS

**Location:** `lib/tyrex.ex` `invoke/3`

```elixir
rescue
  exception -> reject("#{inspect(exception.__struct__)}: #{Exception.message(exception)}")
catch
  kind, reason -> reject("#{kind}: #{inspect(reason)}")
end
```

The comment ("the exception type is preserved in the message so nothing is hidden") frames this
as transparency, and for the common case it is. But Elixir exception messages routinely carry
data the guest never supplied:

- `File.Error` → the **resolved absolute path**, leaking directory layout and deployment root.
- `Ecto.NoResultsError` → the generated SQL, leaking schema.
- `KeyError` / `MatchError` → `inspect/1` of the whole term; for a config map or struct that can
  include credentials.
- The `catch` clause is widest: an `:exit` from a `GenServer.call` inside an allowlisted
  function yields `{:timeout, {GenServer, :call, [pid, <entire request term>]}}` — the full
  request, verbatim, into guest JS.

**Not** a finding: the `permission_denied:` strings. They echo only guest-supplied names plus
the computed arity, and `authorize/4` does `Map.fetch` *before* any `Code.ensure_loaded?`, so
they are not a module-existence oracle. That ordering is correct — keep it.

**Fix direction:** keep the default (debuggability matters), document the leak, and consider an
opt-in `apply_error: :opaque` returning only `inspect(exception.__struct__)`.

---

## 7. WARNING — README contradicts `pool.ex` about `:apply`

`README.md:349` and `README.md:603-604` both say `Tyrex.Pool` forwards `:permissions`,
`:max_heap_mb`, and `:main_module_path`. `lib/tyrex/pool.ex:64` forwards `:apply` as well —
and pool.ex's own `@doc` at :48 documents it correctly.

A reader trusting the README cannot tell that `Tyrex.Pool.start_link(apply: [...])` enables the
privileged bridge on *every* member of the pool. For a security-relevant option that
undercounts the blast radius, and it interacts directly with Finding 1. Fix the README.

---

## 8. Attacks that did NOT work — no bypass found

Recorded so nobody re-litigates them.

**Allowlist key aliasing (no bypass).** `js_module_name/1` maps Elixir `Foo` → `"Foo"` and
Erlang `:foo` → `":foo"`; the leading `":"` makes the two namespaces disjoint. The only
colliding construction is a module atom like `:"Elixir.:os"` (→ key `":os"`), and
`allowlist_entry!/1`'s `Code.ensure_loaded?` + `function_exported?` reject it at start time.
Even granting a collision it is structurally harmless: `Map.fetch` returns the allowlist
**value** and `invoke/3` applies *that*, so a guest string can select a table row but can never
name the code that runs. This is the load-bearing design decision of the change and it is
correct.

**Unicode / normalization (no bypass).** `Map.fetch/2` on binary keys is byte equality — no NFC
normalization, no case folding. `"Ｅnum"`, `"enum"`, `"Enum\u0000"`, `"Enum "` all miss.
deno_core's `#[string]` lossy UTF-8 conversion can only introduce `U+FFFD`, which appears in no
legitimate key, so it can merge two guest strings but never map one onto an allowlisted entry.

**Arity confusion (no bypass).** `arity = length(decoded_args)` and
`apply(mod, fun, decoded_args)` consume the *same* list, so authorized and invoked arity cannot
disagree; JSON cannot produce an improper list. `function_exported?/3` re-checks with the same
value. `decode_args/1` rejects non-list JSON, so a map cannot be smuggled into the length
computation. `main.js:33` also checks `Array.isArray`, but the Elixir side re-checks
independently — the JS guard is not load-bearing, which is the correct layering.

**Bridge deletion durability (no recovery path found).** Against every enumerated vector:

- *`Deno.core` / direct op access:* `core` **is** reachable at `Deno[Deno.internal].core`
  (99_main.js:561-565, 804) — but `removeImportedOps()` (99_main.js:548-556, called at :720 and
  :968, both during `JsRuntime` construction) deletes `op_apply` from `core.ops`. Holds, for a
  different reason than the code comment claims. See Finding 3.
- *Closures from ESM evaluation:* `op_apply` is bound in the `ext:extension/main.js` module
  scope; the only value closing over it was `Tyrex.apply`, unreachable once the object is gone.
  Module scopes are not reflectable from user code.
- *`globalThis.__proto__` / `Object.prototype`:* `Tyrex` was an **own** configurable data
  property of the global, not inherited, so `delete` removes it outright — no prototype-chain
  copy survives.
- *`structuredClone`:* throws `DataCloneError` on functions, and any clone is taken *after* the
  deletion regardless.
- *Realms / `new Worker`:* extensions are per-`WorkerOptions`; a child context does not receive
  `extension::init()`, so it is not a bridge-recovery path.
- *`import("ext:...")`:* verified structural in deno_core, independent of `deny_import` —
  `modules/map.rs:1214-1231` rejects `ext:` specifiers from any referrer that is not `ext:`,
  `node:`, or `checkin:`. The plan's claim is correct.
- *Ordering:* the delete runs at `worker.rs:380`, **before** `execute_main_module`, so even a
  hostile main module cannot capture the global first. If that `execute_script` fails,
  `worker::new` returns `Err` and the runtime refuses to start — fail-closed. Correct.

**JS-injection via `execute_script` (correctly defended).** `Message::ApplyReply` is the one
place guest-influenced data is concatenated into a script, and each of the three arguments goes
through `serde_json::to_string` before `format!`, so a `permission_denied:` message containing
quotes or newlines cannot break out of the literal. Worth calling out because it is exactly the
kind of thing someone later "simplifies" into a bare `format!` — keep the comment.

**Bridge-off runtimes as victims (correctly defended).** `authorize_and_apply(nil, ...)` rejects
rather than crashing, and `handle_info({:apply, ...})` returns `{:noreply, state}` on a
successful reply, so a bridge-off runtime cannot be driven or wedged through Finding 1.

---

## 9. Permission polarity — re-derived truth table, no widening found

From `parse_perm_value` / `allow_option` / `deny_option` and the `allow`/`deny` closures in
`build_permissions` (`worker.rs:96-200`):

| Config | Passed to Deno | Effect |
|---|---|---|
| `allow_x` absent, no `allow_all` | `None` | **deny** |
| `allow_x` absent, `allow_all: true` | `Some([])` | allow (unrestricted) |
| `allow_x: true` | `Some([])` | allow |
| `allow_x: false` (with or without `allow_all: true`) | `None` | **deny** ✅ the 1.2 fix |
| `allow_x: []` | `None` | **deny** ✅ the 1.2 fix |
| `allow_x: ["a"]` | `Some(["a"])` | scoped allow |
| `deny_x: true` | `Some([])` | deny everything |
| `deny_x: false` | `None` | deny nothing |
| `deny_x: []` | `None` | deny nothing |
| `allow_all: false` | baseline off | deny |
| `allow_all: []` / `allow_all: ["x"]` | `matches!(_, True)` false → baseline off | deny (fails closed) |

**No combination silently widens access.** `allow_all` is a baseline that explicit keys override
in both directions, and every surprising input lands on the deny side. Unknown keys are rejected
twice (Elixir `validate_permission_key!`, Rust `PERMISSION_KEYS`), non-string list entries
reject the whole runtime, malformed JSON refuses to start, and `:allow_all` is a distinct string
branch unreachable by accident. This part of the change is clean.

Caveat: the table describes what tyrex *passes* to Deno. Finding 2 is that one row
(`allow_import`/`deny_import`) is never consulted by anything downstream.

---

## 10. Judgement on the README's security claims (item 7)

**The `### Security Scope` section (README:280-296) is well calibrated — if anything it
underclaims, which is the right direction.** "JS runs in-process", "a V8 or Deno vulnerability
is a BEAM compromise", "nothing here has been audited or fuzzed as a security boundary", and the
closing "run Deno out-of-process… this README will not claim otherwise" are honest and far
better than v0.3.x. It does not re-inherit the old `:none` overclaim in a new form, which was
the stated risk in the plan. Keep it as written.

The overclaims are elsewhere — in surrounding *factual* claims the Security Scope caveats do not
cover, because those caveats are about V8 bugs and quotas rather than about tyrex's own controls:

1. **README:14 "Deno I/O is denied unless you grant it", plus the `allow_import`/`deny_import`
   row in the permission-keys table.** Finding 2 is confirmed: module loading sits outside the
   permission system and `permissions: :none` does not deny file reads. This claim must not ship
   unmodified.
2. **README:16 "Real deadlines — `:timeout` terminates the V8 isolate instead of abandoning the
   call."** True with the bridge off; Finding 4 makes it soft with the bridge on. One qualifying
   sentence in the bridge section.
3. **README:290 "`:max_heap_mb` bounds the V8 heap, not the OS process."** Accurate and well put,
   but the more reachable version — a bridged guest growing *BEAM* memory without bound — is
   unmentioned.
4. **README:430-437 "the bridge is never installed and `globalThis.Tyrex` is deleted… so guest
   JavaScript holds no reference to it at all."** True, but load-bearing on upstream behaviour
   tyrex does not test (Finding 3). Worth a sentence naming `removeImportedOps` as the reason,
   so the next deno bump knows what to re-verify.
5. **README:443 "The allowlist is the only control here."** Accurate, and with :270 the right
   framing. It needs the Finding 5 caveat that the guest also chooses every argument.

Underclaim worth noting: the docs undersell how well the *allowlist itself* is built. The
"guest strings are keys, never code" property (§8) is the strongest thing in this release and is
not called out anywhere.

---

## 11. SUGGESTIONS

- **Two vacuous security tests.** `tyrex_permissions_test.exs:109-128` (`deny_import`, Finding 2)
  and `:168-169` (`ext:` import) assert only that *some* error occurred. The `ext:` one would
  pass if the import failed for an unrelated reason, e.g. `FsModuleLoader` rejecting the scheme —
  which for `ext:extension/main.js` is a real possibility. Assert against the message
  (`"only allowed from ext: and node: modules"`) so it tests the property it names.
- **No test pins `_runtimeId`.** Add one with Finding 1's fix: two runtimes, different
  allowlists, attacker repoints the id, assert the victim's function did not run.
- **`allow_all: <list>` is silently accepted** and means "not allow_all"
  (`matches!(parse_perm_value(...)?, PermValue::True)`). Fails closed, so not a vulnerability,
  but a user writing `allow_all: ["/tmp"]` believes they granted something. Reject non-booleans.
- **Booleans coerced to path strings.** `validate_permission_value!/2`'s list clause matches
  `is_atom` after `is_binary`, and `true`/`false`/`nil` are atoms — so `allow_read: [true]`
  becomes the relative path `"true"` instead of raising. Fails closed, but it is precisely the
  silent-coercion class task 1.3 set out to remove. Restrict list entries to binaries.
- **`:timeout` is unvalidated** on a security-relevant knob. `Tyrex.eval(code, timeout: -1)`
  reaches `Process.send_after(self(), _, -1)` (ArgumentError, GenServer crash) or, with
  `blocking: true`, `Native.eval_blocking(_, _, -1)` against a `u64` (rustler decode error). Not
  guest-reachable — the host supplies it — so robustness rather than sandbox. Reject it the way
  the other two bad combinations are, with `:unsupported_option`.
- **`timeout: :infinity` on non-blocking eval arms no deadline** (`arm_deadline/3`'s `:infinity`
  clause stores `nil`), reinstating pre-0.4.0 runaway behaviour. It is an explicit opt-in and
  `blocking: true` correctly refuses it, so this is fine — but the `:timeout` docs should say
  what the caller gives up.
- **Dead code on the privileged global.** `main.js:7-10` `_handleApplicationResult` is never
  called from Rust (`Message::ApplyReply` calls `_applyReply`). Delete it; unused surface on the
  one object that *is* the bridge costs review attention and earns nothing.

---

## Verification notes

No build, test, or JavaScript execution — the assignment forbids builds and I have no shell.
Elixir/Rust findings are derived from the sources in this repository. Findings 2 and 3, and the
`ext:` and `Deno.core` conclusions in §8, are derived from reading the pinned upstream crates at
`~/.asdf/installs/rust/1.57.0/registry/src/index.crates.io-1949cf8c6b5b557f/` — specific files
and line numbers are cited inline so each is independently checkable.

Recommended manual follow-up, in priority order:

1. Run Finding 2's reproduction (`import(..., {with:{type:"text"}})` under `permissions: :none`).
   I expect a successful arbitrary read; it is the most severe finding and takes a minute.
2. Run Finding 1's reproduction. I expect `/tmp/tyrex-pwned` to appear.
3. Add Finding 3's corrected assertion and confirm it passes *today* — it should — so it can
   serve as the deps-upgrade gate afterwards.
4. `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit` (no Bash access here).
