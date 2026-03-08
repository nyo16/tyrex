defmodule Tyrex.MixProject do
  use Mix.Project

  def project do
    [
      app: :tyrex,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Tyrex is an embedded Deno JS/TS runtime for Elixir via Rustler NIFs.",
      package: [
        files: [
          "checksum-Elixir.Tyrex.Native.exs",
          "LICENSE",
          "lib",
          "native",
          "mix.exs",
          "priv/main.js",
          "README.md"
        ],
        licenses: ["MIT"],
        links: %{}
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:rustler, "~> 0.35", optional: true},
      {:rustler_precompiled, "~> 0.7"}
    ]
  end
end
