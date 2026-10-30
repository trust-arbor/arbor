defmodule CapabilitiesStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :capabilities_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_kernel, "~> 2.0.0-dev",
         path: System.get_env("ARBOR_KERNEL_PATH") || "../../../arbor_kernel", override: true},
        {:arbor_custody, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_CUSTODY_PATH") || "../../../arbor_custody", override: true},
        {:arbor_support, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_SUPPORT_PATH") || "../../../arbor_support", override: true},
        {:arbor_oauth, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_OAUTH_PATH") || "../../../arbor_oauth", override: true},
        {:arbor_capabilities, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_CAPABILITIES_PATH") || "../..",
         override: true,
         runtime: false},
        {:jason, "~> 1.4"}
      ],
      releases: [
        capabilities_standalone_consumer: [
          include_erts: true,
          applications: [arbor_capabilities: :load]
        ]
      ]
    ]
  end

  def application,
    do: [
      extra_applications: [:logger, :crypto],
      mod: {CapabilitiesStandaloneConsumer.Application, []}
    ]
end
