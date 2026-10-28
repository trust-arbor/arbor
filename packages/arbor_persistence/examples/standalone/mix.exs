defmodule PersistenceStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :persistence_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_persistence, path: System.get_env("PERSISTENCE_PACKAGE_PATH") || "../.."}
      ],
      releases: [persistence_standalone_consumer: []]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
