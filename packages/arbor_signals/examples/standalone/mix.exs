defmodule SignalsStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :signals_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_kernel, "~> 2.0.0-dev",
         path: System.get_env("KERNEL_PACKAGE_PATH") || "../../../arbor_kernel", override: true},
        {:arbor_signals, "~> 0.2.0-dev",
         path: System.get_env("SIGNALS_PACKAGE_PATH") || "../..", override: true}
      ],
      releases: [signals_standalone_consumer: [include_erts: true]]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {SignalsStandaloneConsumer.Application, []}]
  end
end
