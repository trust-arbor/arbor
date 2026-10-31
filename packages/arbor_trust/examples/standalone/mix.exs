defmodule TrustStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :trust_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_kernel, "~> 2.0.0-dev",
         path: System.fetch_env!("ARBOR_KERNEL_PATH"), override: true, runtime: true},
        {:arbor_custody, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_CUSTODY_PATH"), override: true, runtime: true},
        {:arbor_support, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_SUPPORT_PATH"), override: true, runtime: true},
        {:arbor_oauth, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_OAUTH_PATH"), override: true, runtime: true},
        {:arbor_capabilities, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_CAPABILITIES_PATH"), override: true, runtime: false},
        {:arbor_persistence, "~> 0.1.0-dev",
         path: System.fetch_env!("ARBOR_PERSISTENCE_PATH"), override: true, runtime: true},
        {:arbor_trust, "~> 0.1.0",
         path: System.fetch_env!("ARBOR_TRUST_PATH"), override: true, runtime: false},
        {:phoenix_pubsub, "~> 2.1", runtime: false},
        {:jason, "~> 1.4"}
      ],
      releases: [
        trust_standalone_consumer: [
          include_erts: true,
          applications: [arbor_capabilities: :load, arbor_trust: :load, phoenix_pubsub: :load]
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {TrustStandaloneConsumer.Application, []}]
end
