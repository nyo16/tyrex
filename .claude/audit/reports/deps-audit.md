# Dependency & Release-Engineering Audit — tyrex

## Score: 62/100

```
Start                                                                100
Vulnerabilities (40 pts)          hex.audit clean, no advisories       -0
Version coupling (20 pts)
  Elixir rustler 0.37.3 vs Rust rustler 0.36.2, unpinned range        -10
  NIF version asserted as 2.16 but never pinned in the release build  -10
Outdated deps (20 pts, cap -20)
  rustler 0.37.3 -> 0.38.0 (1 minor behind)                            -5
  rustler_precompiled 0.8.4 -> 0.9.0 (1 minor behind)                  -5
  (benchee/ex_doc/jason bumps are patch-level -> no deduction)         -0
Unused / misdeclared deps (10 pts, -3 each)
  {:rustler, optional: true} missing runtime: false                    -3
Packaging & pinning (10 pts, -5 max)
  package.files incomplete AND 0.x ranges unsafe (single -5 cap)       -5
                                                                    -----
                                                                       62
```

Findings below the rubric line (missing credo/dialyzer/coverage, CI matrix
width, cargo clippy) carry no further deduction — the rubric has no slot for
them and the packaging/pinning category is already capped.

## Findings

### [HIGH] Released artifacts assert `nif-2.16` but the release build never pins `RUSTLER_NIF_VERSION`

- Location: `.github/workflows/release.yml:229-233`, `.github/workflows/release.yml:258`, `lib/tyrex/native.ex:10`, `scripts/docker-build.sh:123`, `native/tyrex/Cross.toml:1-4`
- Evidence:
  ```yaml
  # release.yml:229-233 — the only build step; no RUSTLER_NIF_VERSION anywhere in this file
        - name: Build the NIF
          shell: bash
          run: |
            cd native/tyrex
            cargo build --release --target ${{ matrix.target }}
  ```
  ```bash
  # release.yml:258 — the NIF version is asserted by string interpolation, never measured
  NIF_NAME="libtyrex-v${VERSION}-nif-2.16-${TARGET}.so"
  ```
  ```bash
  # scripts/docker-build.sh:123 — the project's own docker path DOES consider this necessary
    -e RUSTLER_NIF_VERSION=2.16 \
  ```
  ```toml
  # native/tyrex/Cross.toml:1-4 — and Cross.toml exists solely to pass it through
  [build.env]
  passthrough = [
    "RUSTLER_NIF_VERSION"
  ]
  ```
  ```elixir
  # lib/tyrex/native.ex:10
      nif_versions: ["2.16"],
  ```
- Impact: three build paths disagree. `scripts/docker-build.sh` and `Cross.toml` treat `RUSTLER_NIF_VERSION=2.16` as required; `release.yml` (the path that actually produces published artifacts) and `ci.yml` never set it, so the `rustler` 0.36.2 crate selects its default NIF version feature. The filename and `nif_versions: ["2.16"]` then *promise* NIF 2.16 to `RustlerPrecompiled`, which uses that promise to decide the artifact is loadable. If the default resolves above 2.16, `:erlang.load_nif/2` fails on every OTP release older than the one CI happens to use (CI is OTP 27 = NIF 2.17, so the mismatch is invisible in CI and only surfaces for a consumer on OTP 24–26). Nothing in the pipeline verifies the built `.so`'s declared NIF version against the name it is shipped under.
- Fix: set `RUSTLER_NIF_VERSION: "2.16"` in the `build_nif` job `env:` (and in `ci.yml`'s `mix_test` job env so CI exercises the same ABI), derive `NIF_NAME` from a single `NIF_VERSION` workflow variable instead of the literal `2.16`, and add a post-build assertion that the produced library declares that NIF version before packaging.

### [HIGH] A tagged release can publish a partial artifact set that the checksum file claims is complete

- Location: `.github/workflows/release.yml:123-141`, `.github/workflows/release.yml:299-304`, `checksum-Elixir.Tyrex.Native.exs:1-6`
- Evidence:
  ```yaml
  # release.yml:123-141
    build_nif:
      name: NIF 2.16 - ${{ matrix.target }} (${{ matrix.os }})
      needs: [build_v8]
      if: always()
      ...
      strategy:
        fail-fast: false
  ```
  ```yaml
  # release.yml:299-304 — publish happens per-matrix-leg, with no gate on the other legs
        - name: Publish archives and packages
          uses: softprops/action-gh-release@v2
          with:
            files: |
              ${{ steps.package-nif.outputs.file-path }}
          if: startsWith(github.ref, 'refs/tags/')
  ```
- Impact: `if: always()` + `fail-fast: false` + a per-leg publish step means each target uploads independently. If one leg fails (e.g. the aarch64 Linux V8 build, whose own build step is documented to tolerate failures via `|| true` at line 89), the tag still gets a GitHub release containing 3 of 4 archives — while `checksum-Elixir.Tyrex.Native.exs` lists all 4. Every consumer on the missing target gets a hard 404/compile failure at `mix deps.compile`, and the release looks green because no job aggregates the matrix.
- Fix: move publishing into a separate job that `needs: [build_nif]` without `if: always()`, downloads all four artifacts, asserts four files are present, and only then creates the release.

### [HIGH] The release workflow never regenerates or verifies the checksum file

- Location: `.github/workflows/release.yml:266-271`, `checksum-Elixir.Tyrex.Native.exs:1-6`
- Evidence:
  ```bash
  # release.yml:266-271 — checksum is computed, printed, and thrown away
  CHECKSUM=$(shasum -a 256 "$ARCHIVE_NAME" | cut -d ' ' -f 1)
  echo "file-name=$ARCHIVE_NAME" >> $GITHUB_OUTPUT
  echo "file-path=$ARCHIVE_NAME" >> $GITHUB_OUTPUT
  echo "file-sha256=$CHECKSUM" >> $GITHUB_OUTPUT
  ```
  No `mix rustler_precompiled.download` step exists in either workflow (grep for `rustler_precompiled` across `.github/workflows/` returns nothing).
- Impact: the checkedin checksum file is maintained entirely by hand. It currently *is* correct and complete — all four entries match `targets:` in `lib/tyrex/native.ex:12-17` and the `v0.3.0` prefix matches `@version` in `mix.exs:4` — but that is luck, not process. On the next version bump the archives change name (`libtyrex-v0.4.0-...`), and if the maintainer forgets `mix rustler_precompiled.download Tyrex.Native --all --print`, every consumer fails checksum verification. There is also no CI check that the file matches the tag being released.
- Fix: add a post-publish job that runs `mix rustler_precompiled.download Tyrex.Native --all --print`, and a tag-time check that fails if `checksum-Elixir.Tyrex.Native.exs` does not contain exactly one entry per `targets:` entry at the current `@version`.

### [HIGH] Elixir `rustler` 0.37.3 drifts from the Rust `rustler` 0.36.2 crate, with an unpinned range and no CI assertion

- Location: `mix.exs:83`, `mix.lock:12`, `native/tyrex/Cargo.toml:6`, `native/tyrex/Cargo.lock:6197-6212`
- Evidence:
  ```elixir
  # mix.exs:83
      {:rustler, "~> 0.35", optional: true},
  ```
  ```elixir
  # mix.lock:12
    "rustler": {:hex, :rustler, "0.37.3", ...},
  ```
  ```toml
  # native/tyrex/Cargo.toml:6
  rustler = "0.36.0"
  ```
  ```toml
  # native/tyrex/Cargo.lock:6197-6212
  name = "rustler"
  version = "0.36.2"
  ...
  name = "rustler_codegen"
  version = "0.36.2"
  ```
- Impact: two independent version axes for one toolchain, one full minor apart, with nothing enforcing agreement. `~> 0.35` means `>= 0.35.0 and < 1.0.0` — for a package whose 0.x minors are its breaking-change vehicle, that range lets a consumer's resolver pick *any* future rustler (0.38.0 is already out) while the Rust side stays frozen at 0.36. The Elixir side only matters on the force-build path (`deps/rustler_precompiled/lib/rustler_precompiled.ex:153` — `use Rustler, only_rustler_opts`), so the failure mode is exactly the one that is least tested: a consumer who sets `TYREX_BUILD=true`, or CI on a target with no artifact, gets an Elixir compiler/`Rustler.Compiler` version that was never validated against `rustler_codegen` 0.36.2.
  [INFERENCE] I did not find a hard version assertion inside the installed `rustler` 0.37.3 (`mix rustler.new` fetches the newest crate at scaffold time with `@fallback_version "0.36.1"` at `deps/rustler/lib/mix/tasks/rustler.new.ex:26`), so this is unenforced drift rather than a guaranteed compile break. That is the problem: it will fail silently and late, not loudly at `mix deps.get`.
- Fix: pin both sides to one pair and bump them together — `{:rustler, "~> 0.37.3", optional: true, runtime: false}` in `mix.exs` with `rustler = "0.37"` in `Cargo.toml` (or move to the documented `{:rustler, ">= 0.0.0", optional: true}` and instead add a CI step that asserts the two resolved versions share a minor).

### [MEDIUM] `native/tyrex/.cargo/config.toml` is load-bearing but excluded from the Hex package

- Location: `mix.exs:36-49`, `native/tyrex/.cargo/config.toml`, `scripts/docker-build.sh:126`
- Evidence:
  ```elixir
  # mix.exs:41-45 — native/tyrex/.cargo is not listed
        "native/tyrex/Cargo.toml",
        "native/tyrex/Cargo.lock",
        "native/tyrex/Cross.toml",
        "native/tyrex/src",
        "native/tyrex/extension",
  ```
  ```toml
  # native/tyrex/.cargo/config.toml
  [target.x86_64-unknown-linux-musl]
  rustflags = ["-C", "target-feature=-crt-static"]
  [target.aarch64-unknown-linux-musl]
  rustflags = ["-C", "target-feature=-crt-static"]
  ```
  ```bash
  # scripts/docker-build.sh:126 — the project itself copies this dir to make builds work
      cp -a /build/native/tyrex/.cargo /work/ 2>/dev/null || true
  ```
- Impact: `package.files` is an allowlist — an unlisted sibling directory is dropped from the tarball. A consumer force-building for a musl target inside the published package builds without `-crt-static`, i.e. produces a statically-linked-crt `cdylib` that cannot be `dlopen`'d as a NIF. The project's own docker script demonstrates this file is required for a correct build.
- Fix: add `"native/tyrex/.cargo"` to `package.files`.

### [MEDIUM] `Cross.toml` ships without the Dockerfile it references, and nothing in the repo invokes `cross`

- Location: `mix.exs:43`, `native/tyrex/Cross.toml:6-7`, `native/tyrex/Dockerfile.aarch64-unknown-linux-gnu`
- Evidence:
  ```toml
  # native/tyrex/Cross.toml:6-7
  [target.aarch64-unknown-linux-gnu]
  dockerfile = "Dockerfile.aarch64-unknown-linux-gnu"
  ```
  `mix.exs:43` ships `"native/tyrex/Cross.toml"`, but `native/tyrex/Dockerfile.aarch64-unknown-linux-gnu` is absent from `package.files`. Grepping `.github/workflows/` and `scripts/` for `cross build` / `Cross.toml` returns no invocation — `release.yml:233` and `scripts/docker-build.sh` both call `cargo build --release --target ...` directly.
- Impact: two defects in one. (1) A consumer who follows `Cross.toml` and runs `cross build --target aarch64-unknown-linux-gnu` inside the package hits a missing-Dockerfile error. (2) `Cross.toml` is dead configuration — no build path in this repo uses `cross`, so its `RUSTLER_NIF_VERSION` passthrough gives a false impression that the NIF version is pinned somewhere (see the first finding).
- Fix: either delete `Cross.toml` + `Dockerfile.aarch64-unknown-linux-gnu` and stop shipping `Cross.toml`, or add `"native/tyrex/Dockerfile.aarch64-unknown-linux-gnu"` to `package.files` and wire `cross` into the aarch64 leg. Do not ship half of it.

### [MEDIUM] `rustler_precompiled "~> 0.7"` allows a minor whose changelog announces a breaking target-list removal

- Location: `mix.exs:84`, `deps/rustler_precompiled/CHANGELOG.md` (0.8.3 entry)
- Evidence:
  ```elixir
  # mix.exs:84
      {:rustler_precompiled, "~> 0.7"},
  ```
  ```
  # deps/rustler_precompiled/CHANGELOG.md, 0.8.3
  - Update the list of supported targets ... We kept the legacy targets that would be
    removed, so we don't have a breaking change. We should remove those in v0.9.
  ```
- Impact: `~> 0.7` resolves to `>= 0.7.0 and < 1.0.0`, so a consumer's resolver may pick 0.9.0 — the release whose own changelog states legacy targets get removed. `lib/tyrex/native.ex:12-17` declares four targets that the library validates against `RustlerPrecompiled`'s supported-target list at compile time; a target-list change in a minor this range admits turns into a compile error in a *consumer* app that tyrex's own CI never sees. The same shape applies to `{:rustler, "~> 0.35"}` above.
- Fix: tighten to the minor actually validated — `{:rustler_precompiled, "~> 0.8"}` — and bump deliberately alongside a checksum regeneration.

### [MEDIUM] No `cargo clippy` and no Rust tests in CI for a NIF crate

- Location: `.github/workflows/ci.yml:52-56`, `.github/workflows/ci.yml:147-148`
- Evidence:
  ```yaml
  # ci.yml:52-56 — only rustfmt is installed; clippy is never added
        - name: Install Rust toolchain
          uses: dtolnay/rust-toolchain@stable
          with:
            toolchain: 1.92.0
            components: rustfmt
  ```
  ```yaml
  # ci.yml:147-148 — the only Rust check in the entire pipeline
        - name: Run rustfmt
          run: cargo fmt --manifest-path=native/tyrex/Cargo.toml --all -- --check
  ```
  `grep -E '#\[cfg\(test\)\]|#\[test\]|mod tests' native/tyrex/src` → no matches; `native/tyrex/tests/` does not exist.
- Impact: the Rust half of this library owns `unsafe`-adjacent territory — `ResourceArc` lifetimes, cross-thread `Mutex` handling, panic containment across the NIF boundary, `slab` index reuse. Clippy catches exactly this class (`clippy::unwrap_used`, `mem_forget`, `await_holding_lock`) and it is not run anywhere. There is likewise zero Rust-level test coverage and no `cargo test` step, so every Rust regression must be caught indirectly through Elixir integration tests. `cargo fmt` also runs *last* (line 148), after a ~30-minute V8/NIF build and `mix test`, so a one-character formatting failure costs a full pipeline.
- Fix: add `clippy` to `components:`, add a `cargo clippy --manifest-path=native/tyrex/Cargo.toml --all-targets -- -D warnings` step, add `cargo test`, and move both Rust lint steps ahead of `mix test`.

### [MEDIUM] CI tests exactly one Elixir/OTP pair while `mix.exs` promises `~> 1.18`

- Location: `.github/workflows/ci.yml:22-30`, `mix.exs:11`, `lib/tyrex/native.ex:10`
- Evidence:
  ```yaml
  # ci.yml:22-30
      strategy:
        fail-fast: false
        matrix:
          include:
            - pair:
                elixir: 1.18.3
                otp: "27"
              lint: lint
  ```
  ```elixir
  # mix.exs:11
        elixir: "~> 1.18",
  ```
- Evidence of the gap: `~> 1.18` admits 1.19+, and `nif_versions: ["2.16"]` implicitly claims OTP releases back to the 2.16 era; the matrix exercises neither. The `include:`/`lint:` scaffolding is shaped for a multi-entry matrix but has a single entry, so the `if: ${{ matrix.lint }}` guards on lines 135/138/143 are dead weight.
- Impact: the published compatibility contract is broader than what is verified. A 1.19 deprecation or an older-OTP NIF load failure ships to users undetected.
- Fix: add at least a newest-supported pair (Elixir 1.19 / OTP 28) and an oldest-supported pair matching the real `nif_versions` floor; keep the `lint: lint` flag on exactly one leg.

### [LOW] `{:rustler, optional: true}` is missing `runtime: false`

- Location: `mix.exs:83`
- Evidence:
  ```elixir
      {:rustler, "~> 0.35", optional: true},
  ```
- Impact: `rustler` is needed only at compile time (it is consumed via `use Rustler` on the force-build path, `deps/rustler_precompiled/lib/rustler_precompiled.ex:153`). Without `runtime: false`, any consumer who adds `rustler` to force a build also carries the `:rustler` application into their release's applications list. Harmless at runtime but incorrect declaration and extra release weight.
- Fix: `{:rustler, "~> 0.37.3", optional: true, runtime: false}`.

### [LOW] `force_build` accepts only the literal string `"true"` and is not enabled for the library's own dev/test

- Location: `lib/tyrex/native.ex:9`
- Evidence:
  ```elixir
      force_build: System.get_env("TYREX_BUILD") == "true",
  ```
- Impact: the conventional gate is `in ["1", "true"]`; `TYREX_BUILD=1` silently downloads the published v0.3.0 artifact instead of building. More significantly, a contributor editing `native/tyrex/src/*.rs` and running `mix test` without exporting `TYREX_BUILD` tests the *released binary*, not their change — the Rust edit appears to have no effect. CI is safe (`ci.yml:17` sets `TYREX_BUILD: "true"`), local development is not. `version:` is correctly derived from `Mix.Project.config()[:version]` (`lib/tyrex/native.ex:4,18`), so a release bump cannot serve a stale artifact — it fails to resolve instead.
- Fix: `force_build: System.get_env("TYREX_BUILD") in ["1", "true"] or Mix.env() == :test` (or document the export in the README contributing section).

### [LOW] `priv/main.js` is a 1-byte file (`"\n"`) shipped as the default JS entrypoint

- Location: `priv/main.js`, `lib/tyrex.ex:253-254`, `mix.exs:47`
- Evidence:
  ```
  $ od -c priv/main.js
  0000000   \n
  0000001
  ```
  ```elixir
  # lib/tyrex.ex:253-254 — this file is the runtime default main module
                :main_module_path,
                "#{Application.app_dir(:tyrex)}/priv/main.js"
  ```
- Impact: it is intentionally an empty ES module (the no-user-module default), and it is correctly listed in `package.files:47`, so this is not a broken package. But a 1-byte unexplained file is indistinguishable from a truncated artifact: nothing in the file or in `mix.exs` says "intentionally empty", so a future cleanup pass or an over-eager `.gitignore` deleting it turns every default `Tyrex.start/0` into an opaque module-load error. Note this is a *different* file from `native/tyrex/extension/main.js` (1258 bytes, embedded into the binary at `native/tyrex/src/worker.rs:52-53`), which invites confusion.
- Fix: put a one-line comment in `priv/main.js` (`// Intentionally empty: default main module when :main_module_path is not given.`) and reference it from the `main_module_path` docs.

### [LOW] No Elixir dependency/build cache in CI

- Location: `.github/workflows/ci.yml:120-132`
- Evidence:
  ```yaml
        - uses: Swatinem/rust-cache@v2
          with:
            prefix-key: v2-ci
            workspaces: |
              native/tyrex
        - uses: erlef/setup-beam@v1
          ...
        - name: Install dependencies
          run: mix deps.get
  ```
- Impact: Rust and the V8 archive are cached; `deps/` and `_build/` are not. Every run re-fetches and recompiles all Hex deps including `ex_doc`/`makeup`. Small next to the V8 build, but free to fix.
- Fix: add `actions/cache@v4` keyed on `mix.lock` + the Elixir/OTP pair for `deps` and `_build`.

### [LOW] `mix format --check-formatted` does not cover `bench/`, `examples/`, or `scripts/`

- Location: `.formatter.exs:3`, `.github/workflows/ci.yml:134-135`
- Evidence:
  ```elixir
  # .formatter.exs:3
    inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
  ```
  ```yaml
  # ci.yml:134-135
        - run: mix format --check-formatted
          if: ${{ matrix.lint }}
  ```
- Impact: `bench/*.exs` (3 files) and `examples/**/*.exs` (7 files) — all user-facing, all shown in docs — are outside the formatter's input glob, so CI's format gate cannot see them. They drift unformatted while CI stays green.
- Fix: extend inputs to `["{mix,.formatter}.exs", "{config,lib,test,bench,examples}/**/*.{ex,exs}"]`.

### [LOW] No credo, no dialyzer, no coverage tooling, no aliases, no `preferred_cli_env`

- Location: `mix.exs:7-21`, `mix.exs:80-88`
- Evidence: the whole dep list is
  ```elixir
      [
        {:jason, "~> 1.4"},
        {:rustler, "~> 0.35", optional: true},
        {:rustler_precompiled, "~> 0.7"},
        {:ex_doc, "~> 0.34", only: :dev, runtime: false},
        {:benchee, "~> 1.3", only: :dev, runtime: false}
      ]
  ```
  and `project/0` (`mix.exs:7-21`) contains no `aliases:`, no `dialyzer:`, no `test_coverage:`, and no `preferred_cli_env:` — confirmed against the full 89-line file.
- Impact: for a published library with a large `defp`-heavy Elixir surface plus a NIF boundary, Dialyzer is the tool that catches wrong specs on `Tyrex.Native` stubs and impossible return shapes — the exact bugs that only manifest in consumer code. Without `test_coverage`/excoveralls there is no signal on which of the 108 tests actually exercise the error paths. Without an `aliases: [check: [...]]` entry, the CI recipe (format, deps.unlock, compile, test, cargo fmt) exists only in `ci.yml` and cannot be run locally in one command. CHANGELOG discipline itself is fine — `CHANGELOG.md:3` reads `## v0.3.0` and matches `@version "0.3.0"` at `mix.exs:4`, and it is shipped (`mix.exs:38`) and in docs extras (`mix.exs:63`) — but nothing in CI enforces that a version bump touches it.
- Fix: add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` and `{:dialyxir, "~> 1.4", only: [:dev], runtime: false}` with a `dialyzer: [plt_add_apps: [:mix]]` entry, set `test_coverage: [tool: ExCoveralls]` or track `mix test --cover` thresholds, and add `aliases: [check: ["format --check-formatted", "deps.unlock --check-unused", "compile --warnings-as-errors", "credo", "test", "dialyzer"]]` so `ci.yml` calls `mix check`.

## Clean areas (one line each)

- No vulnerabilities: `mix hex.audit` reports no retired or advisory packages; all 13 locked entries resolve from `hexpm` with checksums.
- `mix.lock` is consistent with `mix.exs`: every locked version satisfies its declared range (jason 1.4.4/`~> 1.4`, rustler 0.37.3/`~> 0.35`, rustler_precompiled 0.8.4/`~> 0.7`, ex_doc 0.40.1/`~> 0.34`, benchee 1.5.0/`~> 1.3`) — no conflicts, and CI enforces `mix deps.unlock --check-unused` (`ci.yml:137`).
- Dep usage is honest: `jason` is genuinely a runtime dep (7 `Jason.encode!/decode!` call sites in `lib/tyrex.ex`), `benchee` is used only in `bench/` and `ex_doc` only for docs — both correctly `only: :dev, runtime: false`; nothing in `lib/` reaches a dev-only dep.
- Checksum file is currently complete and current: 4 entries in `checksum-Elixir.Tyrex.Native.exs` match all 4 `targets:` in `lib/tyrex/native.ex:12-17` at the correct `v0.3.0`/`nif-2.16` prefix (the gap is automation, not content).
- `version:` in `lib/tyrex/native.ex:18` derives from `Mix.Project.config()[:version]`, so a release bump cannot silently serve a stale artifact.
- Release workflow builds a job for every declared target (`release.yml:138-141` covers all four in `native.ex targets:`) — no declared-but-unbuilt target.
- CI runs the core Elixir gates: `mix format --check-formatted`, `mix deps.unlock --check-unused`, `mix compile --warnings-as-errors`, `mix test`, plus `cargo fmt --check`, with `TYREX_BUILD: "true"` so it genuinely builds the NIF from source.
- Expensive-artifact caching is well done: keyed V8 archive cache in both workflows and `Swatinem/rust-cache` scoped to the `native/tyrex` workspace.
- Supply-chain hygiene in release: `actions/attest-build-provenance@v3` on every artifact, and a hard `TPOFF32` relocation check on Linux `.so` output (`release.yml:274-286`) that would catch a wrong-TLS-model V8.
- No unnecessary root `config/` complexity — `config/config.exs` is a bare `import Config`, appropriate for a library.
- `.gitignore` correctly excludes `/native/tyrex/target/` and `/priv/native/` so build output cannot leak into the Hex tarball.
- `CHANGELOG.md` is current (v0.3.0 entry matches `@version`), detailed, and shipped in both `package.files` and docs extras.
