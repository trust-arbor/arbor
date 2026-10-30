defmodule OAuthStandaloneConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :oauth_standalone_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:arbor_oauth, "~> 0.1.0-dev",
         path: System.get_env("OAUTH_PACKAGE_PATH") || "../..", override: true},
        {:req, "~> 0.7.5", runtime: false},
        {:finch, "~> 0.24", runtime: false},
        {:mint, "~> 1.9.3", runtime: false}
      ],
      releases: [
        oauth_standalone_consumer: [
          include_erts: true,
          applications: [req: :load, finch: :load, mint: :load]
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
