defmodule EventStoreStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :eventstore_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_persistence_eventstore,
         path: System.get_env("PERSISTENCE_PACKAGE_PATH") || "../.."}
      ],
      releases: [eventstore_standalone_consumer: []]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
