defmodule Tyrex.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/nyo16/tyrex"

  def project do
    [
      app: :tyrex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Tyrex",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Embedded Deno JS/TS runtime for Elixir via Rustler NIFs. " <>
      "Bidirectional Elixir<->JS calls and a pooled runtime."
  end

  defp package do
    [
      files: [
        "checksum-Elixir.Tyrex.Native.exs",
        "CHANGELOG.md",
        "LICENSE",
        "lib",
        # Required by the documented Alpine/musl and NixOS source-build path:
        # it carries the `-crt-static` rustflags those targets need.
        "native/tyrex/.cargo/config.toml",
        "native/tyrex/Cargo.toml",
        "native/tyrex/Cargo.lock",
        "native/tyrex/src",
        "native/tyrex/extension",
        "mix.exs",
        "priv/main.js",
        "README.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Niko"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Tyrex, Tyrex.Error, Tyrex.Runtime],
        "Inline JS": [Tyrex.Sigil, Tyrex.Inline],
        Pool: [Tyrex.Pool, Tyrex.Pool.Strategy],
        Strategies: [
          Tyrex.Pool.Strategy.RoundRobin,
          Tyrex.Pool.Strategy.Random,
          Tyrex.Pool.Strategy.Hash
        ]
      ]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.38.0", optional: true},
      {:rustler_precompiled, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      # The checksums are of the archives attached to the GitHub release for the
      # current @version, so this can only run once that release exists — hence
      # the name. Commit the regenerated file, then publish.
      "checksums.after_release": ["rustler_precompiled.download Tyrex.Native --all --print"],
      # One function rather than [&guard/1, "hex.publish"]: Mix hands a function
      # element the CLI arguments only when it is the *last* element of the alias
      # list (`Mix.Task.join_args/3` discards them otherwise), and the guard has
      # to see them to tell `hex.publish` from `hex.publish docs`.
      "hex.publish": &hex_publish/1
    ]
  end

  # The `hex.publish` alias body: guard first, then the real task. The guard is a
  # guard, not a generator — it refuses to publish a package whose checksum file
  # predates the version being published, and never writes one.
  defp hex_publish(args) do
    # `mix hex.publish docs` uploads documentation only — no Hex tarball, so no
    # checksum file and no NIF archives. Gating it would block a docs fix behind
    # a GitHub release that need not exist yet.
    if "docs" not in args, do: assert_checksums_current!()

    Mix.Task.run("hex.publish", args)
  end

  # The four targets the release publishes: the `build_nif` matrix in
  # .github/workflows/release.yml, and `targets:` in lib/tyrex/native.ex.
  @precompiled_targets [
    "aarch64-apple-darwin",
    "aarch64-unknown-linux-gnu",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-gnu"
  ]

  # checksum-Elixir.Tyrex.Native.exs is packaged into the tarball, and
  # RustlerPrecompiled resolves the artifact name and raises on a missing entry
  # before it makes any network call — so a stale file breaks every precompiled
  # target identically, tag or no tag. v0.4.0 was cut with only v0.3.0 entries
  # because regenerating the file was prose in a runbook nobody executed.
  #
  # All four targets are required, not merely one matching line: RustlerPrecompiled
  # looks up the single entry for the consumer's own platform, so a file
  # regenerated for three of them reads as current here and breaks the fourth.
  defp assert_checksums_current! do
    file = "checksum-Elixir.Tyrex.Native.exs"
    contents = if File.exists?(file), do: File.read!(file), else: ""

    missing =
      Enum.reject(@precompiled_targets, fn target ->
        Regex.match?(
          ~r/-v#{Regex.escape(@version)}-nif-[\d.]+-#{Regex.escape(target)}\.so\.tar\.gz/,
          contents
        )
      end)

    if missing != [] do
      Mix.raise("""
      #{file} has no v#{@version} entries for:

          #{Enum.join(missing, "\n    ")}

      Cut the v#{@version} GitHub release first (the Precomp NIFs workflow attaches
      the four archives), then regenerate and commit the file:

          TYREX_BUILD=true mix checksums.after_release

      which runs: mix rustler_precompiled.download Tyrex.Native --all --print

      TYREX_BUILD=true is not optional: with no checksum entry for v#{@version},
      Tyrex.Native cannot load a precompiled artifact and must build from source.
      """)
    end
  end
end
