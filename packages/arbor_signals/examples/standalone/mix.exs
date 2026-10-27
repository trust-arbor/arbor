defmodule SignalsStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :signals_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [
        {:arbor_signals, path: System.get_env("SIGNALS_PACKAGE_PATH") || "../.."}
      ],
      releases: [signals_standalone_consumer: []]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {SignalsStandaloneConsumer.Application, []}]
  end
end
