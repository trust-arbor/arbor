defmodule ArborBreeze.MixProject do
  use Mix.Project

  def project do
    [
      app: :arbor_breeze,
      version: "0.1.0-dev",
      elixir: "~> 1.19",
      description: "Arbor terminal conversation client built on Breeze",
      escript: [main_module: ArborBreeze.CLI, name: "arbor-tui"],
      deps: [
        {:breeze, path: "vendor/breeze"},
        {:termite, path: "vendor/termite", override: true},
        {:conversation_kit_arbor_gateway, path: "../../packages/conversation_kit_arbor_gateway"},
        {:arbor_client, path: "../arbor_client"}
      ],
      package: [
        licenses: ["MIT"],
        files: ["lib", "config", "vendor", "mix.exs", "README.md", "LICENSE", "VENDOR.md"]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto, :ssl]]
end
