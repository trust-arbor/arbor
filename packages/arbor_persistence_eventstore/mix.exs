defmodule Arbor.Persistence.EventStore.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_persistence_eventstore,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [
        {:arbor_persistence, "~> 0.1.0-dev", path: "../arbor_persistence", env: Mix.env()},
        {:eventstore, "~> 1.4"},
        {:postgrex, "~> 0.19"},
        {:jason, "~> 1.4"}
      ],
      description: "EventStore adapter for Arbor Persistence's EventLog protocol",
      package: [licenses: ["MIT"], files: ~w(lib priv mix.exs README.md LICENSE)]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Arbor.Persistence.Ecto.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
