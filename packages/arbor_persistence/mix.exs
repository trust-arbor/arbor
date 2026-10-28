defmodule Arbor.Persistence.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_persistence,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [
        {:jason, "~> 1.4"},
        {:typed_struct, "~> 0.3", runtime: false},
        {:telemetry, "~> 1.0"}
      ],
      description: "Generic stores, acknowledged buffering and bounded event logs",
      package: [licenses: ["MIT"], files: ~w(lib mix.exs README.md LICENSE)]
    ]
  end

  # Resource lifetimes belong to the caller. Starting the library creates no stores.
  def application, do: [extra_applications: [:logger, :crypto, :telemetry]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
