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
      # Guard, not a generator: refuse to publish a package whose checksum file
      # predates the version being published.
      "hex.publish": [&assert_checksums_current!/1, "hex.publish"]
    ]
  end

  # checksum-Elixir.Tyrex.Native.exs is packaged into the tarball, and
  # RustlerPrecompiled resolves the artifact name and raises on a missing entry
  # before it makes any network call — so a stale file breaks every precompiled
  # target identically, tag or no tag. v0.4.0 was cut with only v0.3.0 entries
  # because regenerating the file was prose in a runbook nobody executed.
  defp assert_checksums_current!(_args) do
    file = "checksum-Elixir.Tyrex.Native.exs"
    contents = if File.exists?(file), do: File.read!(file), else: ""

    if not String.contains?(contents, "-v#{@version}-nif-") do
      Mix.raise("""
      #{file} has no entries for v#{@version}.

      Cut the v#{@version} GitHub release first (the Precomp NIFs workflow attaches
      the four archives), then regenerate and commit the file:

          mix checksums.after_release

      which runs: mix rustler_precompiled.download Tyrex.Native --all --print
      """)
    end
  end
end
