defmodule HistorianStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :historian_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_kernel, "~> 2.0.0-dev",
         path: System.fetch_env!("ARBOR_KERNEL_PATH"), override: true},
        {:arbor_support, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_SUPPORT_PATH"), override: true},
        {:arbor_persistence, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_PERSISTENCE_PATH"), override: true},
        {:arbor_historian, "~> 0.1.0",
         path: System.fetch_env!("ARBOR_HISTORIAN_PATH"), override: true}
      ],
      releases: [historian_standalone_consumer: [include_erts: true]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
