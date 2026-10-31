defmodule PairedStandaloneConsumer.MixProject do
  use Mix.Project

  @packages [
    {:arbor_kernel, "~> 2.0.0-dev", "ARBOR_KERNEL_PATH"},
    {:arbor_custody, "~> 0.1.0-dev", "ARBOR_CUSTODY_PATH"},
    {:arbor_support, "~> 0.1.0-dev", "ARBOR_SUPPORT_PATH"},
    {:arbor_oauth, "~> 0.1.0-dev", "ARBOR_OAUTH_PATH"},
    {:arbor_capabilities, "~> 0.1.0-dev", "ARBOR_CAPABILITIES_PATH"},
    {:arbor_persistence, "~> 0.1.0-dev", "ARBOR_PERSISTENCE_PATH"},
    {:arbor_persistence_sql, "~> 0.1.0-dev", "ARBOR_PERSISTENCE_SQL_PATH"},
    {:arbor_trust, "~> 0.1.0", "ARBOR_TRUST_PATH"},
    {:arbor_historian, "~> 0.1.0", "ARBOR_HISTORIAN_PATH"}
  ]

  def project do
    [
      app: :paired_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps:
        Enum.map(@packages, fn {app, version, variable} ->
          {app, version, path: System.fetch_env!(variable), override: true, runtime: false}
        end) ++ [{:phoenix_pubsub, "~> 2.1"}, {:jason, "~> 1.4"}],
      releases: [
        paired_standalone_consumer: [
          include_erts: true,
          applications: Enum.map(@packages, fn {app, _, _} -> {app, :load} end)
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto], mod: {PairedStandaloneConsumer.Application, []}]
end
