defmodule Arbor.Signals.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_signals,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:boundary] ++ Mix.compilers(),
      boundary: [default: [type: :strict, check: [aliases: true]]],
      description: "Bounded signals, secure channels and provenance for Elixir applications",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs README.md LICENSE)],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Arbor.Signals.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:typed_struct, "~> 0.3", runtime: false},
      {:telemetry, "~> 1.0"},
      {:boundary, "~> 0.10", runtime: false},
      {:local_cluster, "~> 2.1", only: :test}
    ]
  end
end
