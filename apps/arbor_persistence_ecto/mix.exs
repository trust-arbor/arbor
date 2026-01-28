defmodule Arbor.Persistence.Ecto.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_persistence_ecto,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Arbor.Persistence.Ecto.Application, []}
    ]
  end

  defp deps do
    [
      # Umbrella deps
      {:arbor_contracts, in_umbrella: true},
      {:arbor_persistence, in_umbrella: true},

      # EventStore - battle-tested Postgres event store (Commanded's backend)
      {:eventstore, "~> 1.4"},

      # Postgres adapter
      {:postgrex, "~> 0.19"},

      # JSON serialization
      {:jason, "~> 1.4"},

      # Documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "event_store.setup"],
      "event_store.setup": ["event_store.create", "event_store.init"],
      "event_store.reset": ["event_store.drop", "event_store.setup"]
    ]
  end
end
