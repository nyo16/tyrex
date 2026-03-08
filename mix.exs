defmodule Tyrex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nyo16/tyrex"

  def project do
    [
      app: :tyrex,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
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
      "Execute JavaScript and TypeScript from Elixir with full Deno API support, " <>
      "bidirectional Elixir<->JS calls, and a pooled runtime system."
  end

  defp package do
    [
      files: [
        "checksum-Elixir.Tyrex.Native.exs",
        "LICENSE",
        "lib",
        "native/tyrex/Cargo.toml",
        "native/tyrex/Cargo.lock",
        "native/tyrex/Cross.toml",
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
      {:rustler, "~> 0.35", optional: true},
      {:rustler_precompiled, "~> 0.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
