defmodule OIDCStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :oidc_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_oauth, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_OAUTH_PATH") || "../../../arbor_oauth", override: true},
        {:arbor_capabilities_oidc, "~> 0.1.0-dev",
         path: System.get_env("ARBOR_CAPABILITIES_OIDC_PATH") || "../..", override: true},
        {:req, "~> 0.7.5", runtime: false},
        {:finch, "~> 0.24", runtime: false},
        {:mint, "~> 1.9.3", runtime: false},
        {:joken, "~> 2.7", runtime: false},
        {:jose, "~> 1.11.12", runtime: false},
        {:plug_crypto, "~> 2.0", runtime: false}
      ],
      releases: [
        oidc_standalone_consumer: [
          include_erts: true,
          applications: [
            req: :load,
            finch: :load,
            mint: :load,
            joken: :load,
            jose: :load,
            plug_crypto: :load
          ]
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
