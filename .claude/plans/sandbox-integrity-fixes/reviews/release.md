# Release & Packaging Review — v0.4.0 sandbox integrity

**Verdict:** PASS WITH WARNINGS

**Scope reviewed:** `.github/workflows/release.yml`, `mix.exs` (`package/0`, `aliases/0`,
`assert_checksums_current!/1`), `scripts/docker-build.sh`, `native/tyrex/Cargo.toml`,
`native/tyrex/Cargo.lock`, `mix.lock`, `lib/tyrex/native.ex`, the deletion of
`native/tyrex/Cross.toml`, and the README sections that document the release/ABI story
(`README.md:688-693`, `:727-760`). Application-code correctness deliberately not reviewed.

**Prior findings in scope:** B3 **CLOSED**, B4 **CLOSED as a shipping defect**, W11 **CLOSED**,
W12 **CLOSED**. Details under *Persistent prior findings*.

**How verified (all local, on this arm64 macOS box, Elixir 1.20.2-otp-29):**

| What | Command / source | Result |
|---|---|---|
| Feature→ABI mechanism | `rustler-0.38.0/build.rs:854-864` (`get_nif_version_from_features`, reads `CARGO_FEATURE_NIF_VERSION_2_16`), `build.rs:169,175` (writes `NIF_MAJOR/MINOR_VERSION`), `src/codegen_runtime.rs:145-156` (`min_erts()`), `Cargo.toml:53-61` (`default = ["nif_version_2_15"]`) | feature genuinely selects `ERL_NIF_MINOR_VERSION` |
| Feature resolution | `cargo tree -p rustler -f "{p} {f}"` | `default,nif_version_2_14,nif_version_2_15,nif_version_2_16` |
| **Built artifact** | `strings -a native/tyrex/target/release/libtyrex.dylib \| grep -x 'OTP-2[0-9]\.0'` and the same on `_build/test/lib/tyrex/priv/native/tyrex.so` | `OTP-24.0` (= NIF 2.16). The v0.3.0 shipped artifact in `_build` has no such string at all |
| Label plumbing | repo-wide `grep RUSTLER_NIF_VERSION\|Cross.toml` excluding `_build/ deps/ target/` | only `CHANGELOG.md:155` (historical prose) and plan docs; no live reader |
| Build-step grep guard | `NIF_VERSION=2.16; grep -n "\"nif_version_${NIF_VERSION//./_}\"" native/tyrex/Cargo.toml` | matches **only** line 15, the dependency line — not the comment |
| `hex.publish` alias | `mix hex.publish --dry-run` | `** (Mix) checksum-Elixir.Tyrex.Native.exs has no entries for v0.4.0.` … exit **1** |
| Mix alias self-recursion + arg threading | throwaway project in `/tmp/aliasrec` with `"cmd": [&pre/1, "cmd"]`, ran `mix cmd echo TASKRAN` | `GUARD RAN args=[]` then `TASKRAN`; no loop. Guard gets `[]`, CLI args go to the last element |
| `checksums.after_release` alias | `mix checksums.after_release` (no `TYREX_BUILD`) | resolved the task, correct switches, requested exactly `…/releases/download/v0.4.0/libtyrex-v0.4.0-nif-2.16-<target>.so.tar.gz` for all four targets, 404 (no release yet), raised **before** `write_checksum!/2` — `git diff` on the checksum file stayed empty |
| Task/switch validity | `deps/rustler_precompiled/lib/mix/tasks/rustler_precompiled.download.ex:27-33,37-40` | `--all` and `--print` are both in `@switches`; `run([module_name \| flags])` matches the alias string |
| Packaging | `TYREX_BUILD=true mix hex.build`, then `tar -xOf tyrex-0.4.0.tar contents.tar.gz \| tar -tzf -` | 29 files; no `Cross.toml`; `.cargo/config.toml`, `Cargo.toml`, `Cargo.lock`, `src/*.rs` (8), `extension/main.js` all present. Tarball deleted (`rm -f tyrex-0.4.0.tar`, confirmed gone) |
| Cargo.lock currency | `grep -A4 'name = "rustler"' native/tyrex/Cargo.lock` | `0.38.0`, matching the `=0.38.0` pin — a source builder gets a consistent lock |
| `=` pin rationale | `grep -rn unsupported_rustler_version deps/rustler` | one definition (`compiler/messages.ex:27`), **zero call sites** — the Cargo.toml comment's claim is accurate |
| Tag-push trigger | GitHub Docs *Triggering a workflow*: "Path filters are not evaluated for pushes of tags" | the `paths:` filter does **not** suppress a doc-only release tag; no issue |

**What only executes on a tag (read, not run):** everything in the `publish` job
(`release.yml:335-423`) — checkout, version scrape, tag guard, count guard,
`softprops/action-gh-release@v2`, checksum guard — and the `FEATURE` grep in
`build_nif` (`release.yml:252-263`). I read these; I did not execute them, and I make no
claim about their runtime behaviour beyond what the shell text and the referenced action
semantics establish. The scrape itself I did run locally: `sed -n 's/.*@version "\([^"]*\)".*/\1/p' mix.exs | head -n1` → `0.4.0`.

---

## Blockers

None.

---

## Warnings

### README states the wrong OTP floor and now attributes it to the NIF level

- **Where:** `README.md:689-693`
- **What:** "Precompiled binaries require **OTP 27+** (NIF version 2.16), which is what the
  `nif-2.16` in each archive name refers to." NIF 2.16 is **OTP 24**, not OTP 27. rustler's own
  table is unambiguous: `codegen_runtime.rs:145-156` maps `nif_version_2_16` → `b"OTP-24.0\0"`
  (2.17 → OTP-26.0, 2.18 → OTP-29.0), and that string is what lands in `ErlNifEntry.min_erts`,
  i.e. it is the floor the BEAM actually enforces at load time.
- **Why it matters:** this is the one sentence in the release whose job was to stop lying about
  the ABI. The `RUSTLER_NIF_VERSION` half of it was correctly rewritten; the same edit *added*
  the clause "which is what the `nif-2.16` in each archive name refers to", which explicitly
  ties the (wrong) OTP 27 number to the (now correct) NIF level. The number predates the patch;
  the endorsement does not. It also contradicts `mix.exs:11` (`elixir: "~> 1.18"`, which admits
  OTP 25) — a user on OTP 25/26 is told to upgrade or build from source for no reason, and there
  is nothing in the code that agrees with OTP 27.
- **Evidence:** `strings -a native/tyrex/target/release/libtyrex.dylib | grep -x 'OTP-24.0'` →
  one hit, on the artifact the tests actually load. `git diff master -- README.md` shows
  `-Precompiled binaries require **OTP 27+** (NIF version 2.16).` replaced by the four-line
  version, so the sentence was edited, not merely inherited.
- **Suggested direction:** say NIF 2.16 → OTP 24+, and state the *effective* floor separately
  (Elixir `~> 1.18` ⇒ OTP 25+). If OTP 27 is genuinely required for some other reason — CI matrix,
  a deno/V8 dependency — name that reason instead of blaming the NIF level.

### The CI checksum guard can never pass for the release it guards

- **Where:** `.github/workflows/release.yml:408-423` (with `:346-348`, `README.md:727-760`)
- **What:** the step greps `checksum-Elixir.Tyrex.Native.exs` **in the tree checked out at the
  tag** for `-v${PROJECT_VERSION}-nif-`. The checksums are, by construction, derived from the
  archives this same job has just uploaded, so the tagged commit cannot contain them. The README
  runbook (`:729-745`) ends at "commit the regenerated file … then `mix hex.publish`" with no
  step that re-points the tag, so the commit that finally carries the checksums is never the
  commit the `publish` job checks out. A re-run of the job re-checks out the same tag and fails
  identically.
- **Why it matters:** every successful release ends with a red `Precomp NIFs` run. That is a
  permanent false negative in the one workflow that gates releases: it trains the maintainer to
  ignore red, and it erases the signal for a *real* failure of the count guard, the tag guard, or
  a future step added after this one. The step's own comment argues the red is "exactly the
  forcing function", but the thing that actually blocks the irreversible action is the `mix.exs`
  alias (verified: `mix hex.publish --dry-run` exits 1), not this step. So what is implemented as
  a gate is in substance a notification, and it is paid for with a permanently failing workflow.
- **Evidence:** `actions/checkout@v6` at `:348` has no `ref:`, so it checks out `github.sha` —
  the tagged commit. The success branch (`:421-423`) is only reachable if the tag is deleted and
  re-created on the post-checksum commit, which no document in the repo instructs anyone to do.
  The trade-off the comment defends (release-then-verify, because `mix hex.publish` is the
  irreversible step and CI never runs it) is **correct** — `softprops/action-gh-release@v2`
  updates an existing release and replaces same-named assets, so re-running is harmless. The
  defect is not the ordering; it is that the step's pass condition is unreachable.
- **Suggested direction:** keep the check, drop the `exit 1` — emit `::notice` plus the same
  instructions into `$GITHUB_STEP_SUMMARY` so the runbook lands where the maintainer is already
  looking. If a hard failure is wanted, move it to a check that runs on pushes to `master` and
  fails when a tag exists whose version has no checksum entries; that check *can* go green.

---

## Suggestions

### Assert the ABI on the artifact, not on the manifest

- **Where:** `.github/workflows/release.yml:252-263`
- The grep is **load-bearing, not trivially satisfiable** — settled by running it: with
  `NIF_VERSION=2.16` the pattern `"nif_version_2_16"` (double quotes included) matches only
  `Cargo.toml:15`, the dependency line. The comment block uses backticks, so it does not satisfy
  the guard. Two residual gaps worth closing cheaply:
  1. `Cargo.toml:10` contains the literal `["nif_version_2_15"]` **inside the comment**. Set
     `NIF_VERSION: "2.15"` and the guard passes on prose alone. Anchoring the pattern to the
     dependency line (`grep -q "^rustler = .*\"$FEATURE\"" Cargo.toml`) removes that class.
  2. The guard proves what the manifest *requests*. `cargo tree` (the evidence recorded in the
     plan) proves what Cargo *resolves*. Neither proves what the `.so` being tarred was built
     with — the packaging step runs after a `Swatinem/rust-cache` restore. A one-line check in
     "Package NIF archive" closes it end to end, because rustler embeds `min_erts()` in the entry
     struct and the string is uniquely determined by the same feature:
     `strings -a "$SRC" | grep -qx 'OTP-24.0'`. That is the stronger check the task asked about,
     and it is the one I used to confirm B3 locally.

### Both checksum guards accept a single stale entry

- **Where:** `mix.exs:110-127`, `.github/workflows/release.yml:410-414`
- Both ask only "does the file contain `-v0.4.0-nif-`". One surviving line passes; a file with
  three of four targets, or entries carrying an outdated NIF label after a future `NIF_VERSION`
  bump, passes. `mix rustler_precompiled.download --all` writes all four or raises (verified: it
  raised before `write_checksum!/2` when the archives 404'd), so the realistic hole is a
  hand-edited or partially reverted file. Counting `-v#{@version}-nif-#{@nif_version}-` occurrences
  and requiring 4 costs one line and makes the guard say what it means.

### The raise text omits the `TYREX_BUILD=true` the command needs

- **Where:** `mix.exs:121`
- The guard tells the maintainer to run `mix checksums.after_release`. `README.md:738-744` and
  `release.yml:417-419` both say `TYREX_BUILD=true mix checksums.after_release`, and the README
  explains why: without it `Tyrex.Native` has no checksum entry for the new version and cannot
  compile at all. The one place the instruction is read under pressure — the abort message — is
  the one place it is wrong. Two words.

### `Cross.toml`'s Dockerfile is still in the tree, and the recorded rationale for the deletion is false

- **Where:** `native/tyrex/Dockerfile.aarch64-unknown-linux-gnu` (untouched),
  `.claude/plans/sandbox-integrity-fixes/plan.md:277-283`
- The deletion is right and W12 is closed, but the justification on record — that `Cross.toml`'s
  only stanza "referenced a Dockerfile that does not exist" — is wrong: the file exists at
  `native/tyrex/Dockerfile.aarch64-unknown-linux-gnu`. `git show master:native/tyrex/Cross.toml`
  shows `dockerfile = "Dockerfile.aarch64-unknown-linux-gnu"`. What was actually wrong is that
  it was never *packaged*, which is exactly what W12 said. Net effect: the Dockerfile is now an
  orphan with no referent anywhere in the repo (repo-wide grep finds no live mention). Delete it
  with its `Cross.toml`, or note in the plan that it was kept deliberately.

---

## Persistent prior findings

**None persist.** Status of the four in my scope:

- **B3 — CLOSED, verified on the artifact.** `native/tyrex/Cargo.toml:15` now reads
  `rustler = { version = "=0.38.0", features = ["nif_version_2_16"] }`. The mechanism is real:
  `build.rs:854-864` reads `CARGO_FEATURE_NIF_VERSION_2_16` and feeds `opts.nif_version` into the
  generated `ERL_NIF_MAJOR/MINOR_VERSION` (`:169,175`), and `min_erts()` flips to `OTP-24.0`.
  `cargo tree` reports the feature; more importantly the built `libtyrex.dylib` — the same 130 MB
  file the 160 passing tests load — contains `OTP-24.0`, which a 2.15 build cannot. `nif_versions:
  ["2.16"]` (`lib/tyrex/native.ex:11`), the archive label (`release.yml:288`) and the binary now
  agree. Declaring 2.16 raises the NIF floor to OTP 24, below the OTP 25 that `elixir: "~> 1.18"`
  already implies, so it constrains nothing new — see the README warning above for the doc side.
  All `RUSTLER_NIF_VERSION` plumbing is gone; nothing reads a variable that no longer exists
  (`shared-key` `:244` and `NIF_NAME` `:288` both use `env.NIF_VERSION`; the only remaining
  literal `2.16` is the job `name:` at `:139`, with a correct reason on `:135-137`).
- **B4 — CLOSED as a shipping defect.** The stale file remains v0.3.0-only, deliberately, but it
  is now unshippable: `mix hex.publish --dry-run` aborts with exit 1 before reaching Hex, and the
  alias threading is sound (verified empirically — guard first, CLI args to the real task, no
  recursion). `checksums.after_release` was verified to resolve the right task and to request
  archive names byte-identical to the workflow's `NIF_NAME`. It requires `TYREX_BUILD=true` on a
  clean tree, which the README documents and the raise text does not (suggestion above).
- **W11 — CLOSED.** `release.yml:360-369` compares `github.ref_name` to `v${PROJECT_VERSION}`
  before the count guard. No vacuous pass: `shell: bash` runs with `-eo pipefail`; an empty scrape
  compares `$TAG` against the literal `v` and fails; the guard's error message prints both values.
  It also closes a hole nobody filed: `on.push.tags: "*"` matches any tag, so before this a
  `nightly` tag would have cut a GitHub release carrying `v0.3.0`-named archives — now it dies at
  the tag guard, before `softprops` runs.
- **W12 — CLOSED.** `Cross.toml` is out of `package.files` and deleted. Inspected tarball: 29
  files, no `Cross.toml`, and everything the documented source-build path needs is present
  (`native/tyrex/.cargo/config.toml` — which really does carry only the two musl
  `-crt-static` stanzas the mix.exs comment claims — plus `Cargo.toml`, a `Cargo.lock` already
  updated to rustler 0.38.0, all eight `src/*.rs`, and `extension/main.js`).

`scripts/docker-build.sh` after the `-e RUSTLER_NIF_VERSION=2.16` deletion is coherent: nothing
inside either container read it, the NIF phase copies `native/tyrex/*` **and** `.cargo/` into
`/work` and runs a plain `cargo build --release --target $TARGET`, so it picks up the same
`nif_version_2_16` feature from the packaged manifest. It emits `/output/libtyrex_<target>.so`
with no NIF label at all, so there is nothing left to disagree with the workflow's label — the
workflow does its own packaging and naming (`release.yml:280-292`). It is a dev/debug helper, not
a release path.

---

## Pre-existing (one line each)

- `README.md:34-39` — consumer-facing "build from source" instructions never say to add `{:rustler, ">= 0.0.0", optional: true}` to the *consumer's* `mix.exs`; since tyrex declares rustler `optional: true` (`mix.exs:86`), a consumer following them verbatim hits `"Rustler dependency is needed to force the build."` (`deps/rustler_precompiled/lib/rustler_precompiled.ex:157`) — which matters more now that `README.md:695-702` lists musl/Windows/BSD as source-build-only. PRE-EXISTING.
