# Release-integrity review — tyrex v0.4.0 (`sandbox-integrity`)

Scope: `.github/workflows/release.yml`, `mix.exs`, `native/tyrex/Cargo.toml`,
`mix.lock`, `native/tyrex/Cargo.lock`, `CHANGELOG.md`.
Read-only context: `scripts/docker-build.sh`, `native/tyrex/Cross.toml`,
`.github/workflows/ci.yml`, `lib/tyrex/native.ex`, `checksum-Elixir.Tyrex.Native.exs`.
No file was modified.

---

## Headline verdicts

**Is a partial publish now impossible?** **Yes, at run level — the mechanism is
sound.** But "all four archives shipped" is not the same as "the release is
installable", and two things outside the atomicity mechanism can still ship a
uniformly broken release. See BLOCKER-1 and BLOCKER-2.

**Checksum file:** `checksum-Elixir.Tyrex.Native.exs` still contains **only
v0.3.0 entries**. Nothing in the release process regenerates it, and the manual
step is documented nowhere. Publishing v0.4.0 to Hex in the current state ships
a package that **cannot compile without a 30–60 minute source build on all four
"precompiled" targets**. This is the single highest-risk item in the release.

---

## Atomicity trace (item 1) — PASSES

Each link verified against the file:

| Claim | Verdict | Evidence |
|---|---|---|
| `needs: [build_nif]` requires **all** matrix legs | ✅ | GitHub aggregates a matrix job into one job result; `needs` gates on that aggregate. `fail-fast: false` (`release.yml:150`) means the *other* legs keep running, but the aggregate is still `failure`. |
| `build_nif`'s `if: always()` (`release.yml:138`) cannot leak a partial publish | ✅ | `publish` (`release.yml:325`) has no `always()`, so its implicit `success()` requires `build_nif` to have *succeeded*, not merely completed. |
| A failed `build_v8` cannot reach `publish` | ✅ | `release.yml:157-161` fails both Linux legs (`needs.build_v8.result != 'success'` is the **aggregate** result, so one failed V8 target fails both Linux NIF legs) → `build_nif` fails → `publish` skipped. macOS legs succeed but are irrelevant. |
| A cancelled `build_v8` cannot reach `publish` | ✅ | `always()` runs `build_nif`, the guard step fails Linux, and `publish`'s `success()` is false for cancelled ancestors either way. |
| Download `pattern:` excludes `v8-archive-*` | ✅ | Artifact name is `steps.package-nif.outputs.file-name` = `libtyrex-v${VERSION}-nif-${RUSTLER_NIF_VERSION}-${TARGET}.so.tar.gz` (`release.yml:277-278`, `:294`, `:311-313`). `pattern: libtyrex-*.tar.gz` (`release.yml:335`) matches exactly those and never `v8-archive-<target>`. |
| `EXPECTED=4` cannot be fooled | ✅ (in practice) | Artifact names are unique per target within a run, so four files ⇒ four distinct targets. It is still a *count*, not an identity check — see WARNING-3. |

The old per-leg `softprops/action-gh-release@v2` step (previously
`release.yml:299-304`, confirmed via `git show HEAD:.github/workflows/release.yml`)
is gone. Good.

---

## BLOCKER-1 — `RUSTLER_NIF_VERSION` is inert; the shipped NIF is built against **2.15**, not 2.16

`.github/workflows/release.yml:18-23`, `:244-248`, `:277`
`native/tyrex/Cargo.toml:8`

The whole item-2 plumbing rests on a premise that has been false since
rustler 0.30. From the rustler CHANGELOG, `## 0.30.0 - 2023-10-11`:

> ### Removed
> - Support for `RUSTLER_NIF_VERSION`, NIF version requirements have to be set via features now

And `rustler/Cargo.toml` at tag `rustler-0.38.0`:

```toml
[features]
default = ["nif_version_2_15"]
nif_version_2_16 = ["nif_version_2_15"]
```

`native/tyrex/Cargo.toml:8` declares `rustler = "=0.38.0"` with **default
features and no `nif_version_2_16`**. Therefore:

- The workflow-level `env: RUSTLER_NIF_VERSION: "2.16"` (`release.yml:23`) has
  **zero effect on the compiled artifact**.
- The step-level re-export at `release.yml:244-248` — added by this patch with the
  comment *"so the rustler build script's NIF version selection is visible at the
  call site"* — is dead. rustler 0.38 has no such build-script selection; its
  `[build-dependencies]` is `regex-lite` only, and `rustler_sys` was folded into
  `rustler::sys` in 0.35.
- `native/tyrex/Cross.toml:2-4` (`passthrough = ["RUSTLER_NIF_VERSION"]`) and
  `scripts/docker-build.sh:123` (`-e RUSTLER_NIF_VERSION=2.16`) are likewise dead.
- The **only** live use of the variable is string interpolation into the archive
  filename at `release.yml:277`. The name asserts `nif-2.16`; the binary inside
  is `nif_version_2_15`.

**Impact.** This is *not* a load failure: a 2.15-entry NIF loads on any OTP ≥ 22,
and `RustlerPrecompiled` selects the archive by *filename* from
`nif_versions: ["2.16"]` (`lib/tyrex/native.ex:10`), which it will find. So
installs work. What breaks is the truth of the label and of the changelog:

1. `README.md:627` — *"Precompiled binaries require **OTP 27+** (NIF version 2.16)"* —
   is false in both halves. The binary is 2.15 (OTP 22+), and NIF 2.16 is OTP 24, not 27.
2. `CHANGELOG.md:110-112` claims a fix that does not exist (see WARNING-5).
3. **Latent:** rustler 0.37.4 gates `ErlNifResourceTypeInit.members` on
   `nif_version_2_16` (rustler CHANGELOG, #725). `native/tyrex/src/runtime.rs:14-15`
   registers `Runtime` via `#[rustler::resource_impl]` with no `down`/dyncall
   members today, so nothing misbehaves — but the day someone adds
   `Resource::down` for process monitoring, it will silently never fire on a
   build that does not enable `nif_version_2_16`. That failure mode is invisible.

**Fix (pick one and make everything agree):**

```toml
# native/tyrex/Cargo.toml
rustler = { version = "=0.38.0", features = ["nif_version_2_16"] }
```

…and keep the `2.16` labels; **or** drop the 2.16 claim to 2.15 in
`lib/tyrex/native.ex:10`, `release.yml:23`, `README.md:627`, and the archive names.
Either way, delete the three dead `RUSTLER_NIF_VERSION` plumbing sites
(`release.yml:244-248`, `Cross.toml:2-4`, `docker-build.sh:123`) and the comments
that assert rustler reads it — retaining inert configuration that *looks*
load-bearing is how this drifted in the first place.

Note also: `.github/workflows/ci.yml` never sets `RUSTLER_NIF_VERSION` at all and
builds with `TYREX_BUILD: "true"` (`ci.yml:14`). Under the *correct* model
(cargo features) that is fine and CI and release agree. Under the model the
comments describe, CI would be a fourth, silently-disagreeing build path. The
comments should stop describing a model that isn't real.

---

## BLOCKER-2 — the checksum file is stale and nothing regenerates it

`checksum-Elixir.Tyrex.Native.exs:1-6`, `mix.exs:4`, `.github/workflows/release.yml:315-357`

The file contains four `libtyrex-v0.3.0-nif-2.16-*.so.tar.gz` entries and no
v0.4.0 entries. `mix.exs:4` is now `@version "0.4.0"`, and
`lib/tyrex/native.ex:7,19` derives both `base_url` and `version:` from it.

**Exactly what happens, in three states:**

1. **Today (tag not pushed, nothing on Hex).**
   `mix deps.get && mix compile` in a fresh checkout **without** `TYREX_BUILD=true`:
   `RustlerPrecompiled` resolves the target artifact name
   `libtyrex-v0.4.0-nif-2.16-<target>.so.tar.gz`, looks it up in the checksum map,
   misses, and raises before it ever attempts a download —
   `deps/rustler_precompiled/lib/rustler_precompiled.ex:797-799`:
   *"the precompiled NIF file does not exist in the checksum file. Please consider
   run: `mix rustler_precompiled.download Tyrex.Native --only-local`…"*.
   This is precisely why `TYREX_BUILD=true` is currently mandatory, and matches
   `README.md:36-39`.

2. **After the tag is pushed and `publish` succeeds.**
   The four archives now exist at
   `https://github.com/nyo16/tyrex/releases/download/v0.4.0/…`. The checksum file
   in the repo is **unchanged**. A user gets the **identical error** — the miss
   happens against the local checksum map, before any network call. Publishing to
   Hex in this state ships a package whose advertised "precompiled, no Rust
   toolchain needed" (`README.md:619`) path is broken for **every user on all four
   targets**. That is a strictly worse outcome than the 3-of-4 partial publish this
   release set out to prevent.

3. **The step that is missing.** Nothing in `release.yml` regenerates it. There is
   no `mix rustler_precompiled.download` step in `publish`, no `mix hex.publish`,
   and no commit-back. That it is a manual step is only inferable from git history
   (`6278aa8 "Update precompiled NIF checksums for v0.3.0"` — a separate commit
   made *after* the v0.3.0 release). Grepping `README.md`, `CHANGELOG.md`, and
   `.claude/plans/sandbox-integrity/` for `checksum` / `rustler_precompiled.download`
   turns up **no release runbook**. **Flagged as undocumented, per the assignment.**

**Fix.** Add the step to `publish` (after the release is cut) or, at minimum, a
documented runbook. Minimal automated form:

```yaml
      - name: Refresh the precompiled checksum file
        run: |
          mix rustler_precompiled.download Tyrex.Native --all --print
```

…run against the just-published release, with the resulting
`checksum-Elixir.Tyrex.Native.exs` committed before `mix hex.publish`. Note the
ordering constraint is real and worth stating in the runbook: **GitHub release
first, checksum regeneration second, Hex publish third.** A `hex.publish` that
precedes step 2 is unrecoverable without a version bump.

Cheap interim mitigation: have `publish` print the four `file-sha256` values into
`$GITHUB_STEP_SUMMARY` so the maintainer has them without re-downloading.

---

## WARNING-3 — the count guard does not check the version, so a mistagged commit ships four uniformly-404ing archives

`.github/workflows/release.yml:168-171`, `:274-278`, `:340-350`

`PROJECT_VERSION` is scraped from `mix.exs` (`release.yml:168-171`) and is the
sole source of the `v{version}` component of every archive name (`release.yml:277`).
The tag ref is never compared against it.

Consequence: tag `v0.4.1` on a commit where `mix.exs` still says `0.4.0`, and the
workflow builds, attests, counts to exactly 4, and publishes four
`libtyrex-v0.4.0-…tar.gz` files onto the `v0.4.1` release. `lib/tyrex/native.ex:7`
then constructs `…/download/v0.4.1/libtyrex-v0.4.1-…` and every user 404s. The
publish is perfectly atomic and perfectly wrong — which is exactly the class of
failure this job exists to prevent, so the guard should cover it.

```suggestion
          ls -lh /tmp/nif-archives
          COUNT=$(find /tmp/nif-archives -name '*.tar.gz' -type f | wc -l | tr -d ' ')
          EXPECTED=4  # must match the build_nif matrix
          if [ "$COUNT" -ne "$EXPECTED" ]; then
            echo "::error::Expected $EXPECTED NIF archives, found $COUNT — refusing to publish a partial release"
            exit 1
          fi
          if ! ls /tmp/nif-archives | grep -q -- "-${GITHUB_REF_NAME#v}-nif-"; then
            echo "::error::Archive names do not carry tag version ${GITHUB_REF_NAME} — mix.exs @version is out of sync with the tag"
            exit 1
          fi
```

(Any equivalent assertion is fine; the point is that *something* must tie
`mix.exs @version` to `GITHUB_REF_NAME` before archives are attached.)

---

## WARNING-4 — `Cross.toml` is packaged but the Dockerfile it references is not

`mix.exs:44`, `native/tyrex/Cross.toml:6-7`

Item 5 asks whether anything *else* a source build needs is still missing.
`package.files` now ships `native/tyrex/Cross.toml`, whose entire non-dead content is:

```toml
[target.aarch64-unknown-linux-gnu]
dockerfile = "Dockerfile.aarch64-unknown-linux-gnu"
```

`native/tyrex/Dockerfile.aarch64-unknown-linux-gnu` exists in the repo (tracked,
332 B) but is **not** in `package.files` (`mix.exs:38-52`). A Hex source-build user
who reaches for `cross` on aarch64 glibc gets a `Cross.toml` pointing at a file
that isn't there. Same class of omission as the `.cargo/config.toml` bug this
release fixes.

Given BLOCKER-1, `Cross.toml`'s other stanza (`passthrough = ["RUSTLER_NIF_VERSION"]`)
is dead weight, so the cleaner resolution is to **drop `Cross.toml` from
`package.files`** — it is CI/maintainer infrastructure, not something a Hex
consumer's `mix compile` path reads — rather than adding the Dockerfile.

Everything else needed by the from-Hex source build **is** present: `Cargo.toml`,
`Cargo.lock`, `src`, `extension`, `priv/main.js`, and now `.cargo/config.toml`.
There is no `build.rs` to ship. Verified that Hex's path expansion handles the
dot-directory: `Path.wildcard("native/tyrex/.cargo/config.toml")` returns the
path with and without `match_dot: true`, because `.cargo` is a literal component,
not a wildcard. **The `.cargo/config.toml` addition is the right fix** — rustler's
mix compiler invokes cargo with cwd `native/tyrex`, so the `-crt-static` rustflags
for `*-unknown-linux-musl` are picked up exactly where the Alpine/NixOS path
(`README.md:629-634`) needs them.

---

## WARNING-5 — CHANGELOG claims a `RUSTLER_NIF_VERSION` fix that does not fix anything

`CHANGELOG.md:110-112`

> `RUSTLER_NIF_VERSION` is now set in `release.yml` from a single workflow-level
> source of truth. It was never set while `nif-2.16` was hardcoded in artifact
> names, so the three build paths disagreed about what was actually compiled.

Both sentences are wrong given rustler ≥ 0.30 (BLOCKER-1). The variable is now
set, but setting it changes nothing about what is compiled. And the three build
paths never disagreed *with each other* — release, `docker-build.sh`, and CI all
produce a `nif_version_2_15` binary. They disagree with the **label**, and this
change does not close that gap. A reader of the changelog will believe the NIF
version plumbing is now correct when it is inert.

Rewrite to state what actually shipped (a single source of truth for the archive
*filename* component), or land the `nif_version_2_16` cargo feature and then the
bullet becomes true.

---

## WARNING-6 — two behavioral breaks are documented as ordinary bullets, not under **Breaking**

`CHANGELOG.md:34-46`

The section is explicitly the migration surface. Two items in it are breaking but
are not labelled as such, unlike the two that are:

- `CHANGELOG.md:37-41` — `:timeout` on `eval/2` is now a hard deadline that
  **terminates the isolate and kills the runtime** (`lib/tyrex.ex:68`
  `@default_eval_timeout 5_000`; `lib/tyrex.ex:339,414`). Previously a slow eval
  timed out the `GenServer.call` and the runtime survived. Any caller that today
  retries after a timeout on the same named runtime now retries against a corpse.
  That needs a migration note, not a bullet.
- `CHANGELOG.md:45` — `stop/1`'s `:timeout` default moves `:infinity → 5_000`
  (`lib/tyrex.ex:70,212`). A caller relying on unbounded graceful shutdown now
  gets a brutal kill after 5 s.

Everything else in the entry cross-checks clean against the diff: `permissions:
:none` default plus a genuinely once-per-VM `Logger.warning`
(`lib/tyrex.ex:698-713`, `:persistent_term`-guarded, and the text itself says
"once per VM"); `:apply` opt-in with GenServer-side enforcement
(`lib/tyrex.ex:77, 376, 439, 648, 677`); `Tyrex.kill/0,1`
(`lib/tyrex.ex:233-236, 256-261`); `Tyrex.Pool` forwarding `:apply` and
`:max_heap_mb` (`lib/tyrex/pool.ex:64`); the rustler pair alignment; the
`.cargo/config.toml` packaging fix (`mix.exs:41-44`); and the all-or-nothing
release claim (`CHANGELOG.md:110-114`, matches `release.yml:315-357`).

One documentation gap worth closing while you are in here: `README.md:349-350`
and `README.md:603-604` both say `Tyrex.Pool` forwards `:max_heap_mb`,
`:permissions`, and `:main_module_path` — omitting `:apply` and
`:startup_timeout`, which `lib/tyrex/pool.ex:64` does forward. Since `:apply` is
the security-relevant one, the omission is the wrong way round.

---

## WARNING-7 (PRE-EXISTING) — the `paths:` filter can suppress the entire release workflow for a tag

`.github/workflows/release.yml:5-13` — unchanged by this patch.

```yaml
on:
  push:
    branches: [master]
    paths: ["native/**", ".github/workflows/release.yml"]
    tags: ["*"]
```

Ref filters and path filters are ANDed. A tag pushed onto a commit whose diff
touches neither `native/**` nor `release.yml` — i.e. any Elixir-only patch release
such as a future `v0.4.1` — can fail the path filter and the workflow never runs.
No archives, no `publish`, and a Hex release pointing at a `base_url` with nothing
behind it.

The v0.4.0 tag itself is safe (this diff touches `native/**` heavily), so this is
not blocking *today*. But `publish` is now the **sole** place archives are cut, so
the blast radius of a suppressed run is now the entire release. Recommend hoisting
tags into their own trigger with no `paths:`:

```yaml
on:
  push:
    branches: [master]
    paths: ["native/**", ".github/workflows/release.yml"]
  push:  # tags, unfiltered — a release must never be path-gated
    tags: ["*"]
```

(expressed as a single `on.push` with `tags` in a separate workflow, or by
dropping `paths` entirely and eating the extra CI minutes on master).

---

## Permissions review (item 3) — PASSES, exactly minimal

`build_nif` (`release.yml:141-147`):

| Scope | Needed by | Verdict |
|---|---|---|
| `contents: read` | `actions/checkout@v6` (`:163`); also **required** by `actions/attest-build-provenance` | ✅ |
| `id-token: write` | `attest-build-provenance@v3` (`:305-308`) — Sigstore OIDC | ✅ |
| `attestations: write` | `attest-build-provenance@v3` — writes the attestation to the attestations store | ✅ |

That is precisely the documented triple for `attest-build-provenance`. Dropping
`contents: write` does **not** break attestation: attestations are stored via the
attestations API under `attestations: write`, never as release assets or repo
commits. `upload-artifact@v5` / `download-artifact@v4` need no `contents` scope.

`publish` (`release.yml:329-330`): `contents: write` only, which is what
`softprops/action-gh-release@v2` needs to create the release and attach assets.
Correctly *not* granted `actions: read` — that is only required by
`download-artifact@v4` when downloading across workflow runs via `run-id`;
same-run downloads (`:333-339`) go through the artifact service with
`ACTIONS_RUNTIME_TOKEN`. Also correct that `publish` has no `actions/checkout`:
`action-gh-release`'s `files:` is an absolute path (`:357`) and the action needs
no working tree.

---

## Dependency alignment (item 6) — PASSES

| Manifest | Declared | Lockfile | Agrees |
|---|---|---|---|
| `mix.exs:85` | `{:rustler, "~> 0.38.0", optional: true}` | `mix.lock` → `rustler 0.38.0` | ✅ |
| `native/tyrex/Cargo.toml:8` | `rustler = "=0.38.0"` | `Cargo.lock` → `rustler 0.38.0` | ✅ |
| `mix.exs:4` | `@version "0.4.0"` | — | ✅ |
| `native/tyrex/Cargo.toml:32` | `version = "0.4.0"` | `Cargo.lock` → `tyrex 0.4.0` | ✅ |

`~> 0.38.0` is `>= 0.38.0, < 0.39.0`, so the Elixir side cannot drift past the
`=`-pinned crate within its allowed range. The `=` pin has **no transitive
counterparty**: nothing else in the Cargo graph depends on `rustler` (the deno
stack does not), so there is no requirement it can conflict with. Should one
appear, cargo fails at *resolve* time with an explicit conflict — loud, not
silent, which is the failure mode you want and the stated rationale in the
comment at `Cargo.toml:6-7`. The `=` pin is justified.

`mix.lock` also bumps `jason 1.4.4 → 1.4.5`, satisfying `mix.exs:84` `~> 1.4`;
`ci.yml:138` `mix deps.unlock --check-unused` will pass. `Cargo.lock` gains
`libloading 0.9.0` alongside the existing `0.8.9` — expected, rustler 0.38 moved
to `libloading 0.9` + `libc`.

**Noted, deliberately out of scope, not fixed:** `rustler_precompiled` is at
0.8.4 with 0.9.0 available (`mix.exs:86` `~> 0.7` would accept it); the deno
stack (`deno_core 0.391.0`, `deno_runtime 0.246.0`, `deno_fs 0.148.0`,
`deno_resolver 0.69.0`, `serde_v8 0.300.0`) is ~19 minors behind.

---

## SUGGESTION-8 — `EXPECTED=4` is a hand-maintained mirror of the matrix

`.github/workflows/release.yml:346`

The comment `# must match the build_nif matrix` is doing load-bearing work. It
fails **closed** (5 targets built ⇒ count 5 ≠ 4 ⇒ refuse), so this is genuinely
low severity — the failure mode is a loud false alarm, not a silent partial ship.
Worth one line of hardening only if you also touch `lib/tyrex/native.ex:12-17`,
which is the *third* independent copy of the target list (matrix at
`release.yml:152-156`, `targets:` in `native.ex`, `EXPECTED` in `publish`). Three
copies is where the next drift bug lives.

---

## Summary

| # | Sev | Item | Location |
|---|---|---|---|
| 1 | **BLOCKER** | `RUSTLER_NIF_VERSION` inert since rustler 0.30; NIF built as 2.15, labelled 2.16 | `release.yml:23,244-248,277`; `Cargo.toml:8` |
| 2 | **BLOCKER** | Checksum file stale at v0.3.0; nothing regenerates it; step undocumented | `checksum-Elixir.Tyrex.Native.exs:1-6`; `release.yml:315-357` |
| 3 | WARNING | Publish guard checks count but not tag-vs-`mix.exs` version | `release.yml:340-350` |
| 4 | WARNING | Packaged `Cross.toml` references an unpackaged Dockerfile | `mix.exs:44`; `Cross.toml:6-7` |
| 5 | WARNING | CHANGELOG claims a NIF-version fix that fixes nothing | `CHANGELOG.md:110-112` |
| 6 | WARNING | Two behavioral breaks not under the **Breaking** heading | `CHANGELOG.md:37-45` |
| 7 | WARNING (pre-existing) | `paths:` filter can suppress the release workflow for a tag | `release.yml:5-13` |
| 8 | SUGGESTION | `EXPECTED=4` is a third copy of the target list | `release.yml:346`; `native.ex:12-17` |

**Atomicity: the mechanism is correct and I could not construct a path to a
3-of-4 publish.** The remaining release risk is no longer *partial* — it is
*uniformly wrong*: a stale checksum file (BLOCKER-2), a mislabelled NIF version
(BLOCKER-1), or a mistagged version string (WARNING-3) each break all four
targets identically. Fix BLOCKER-2 before tagging; it is the one that breaks
installation for everyone.
