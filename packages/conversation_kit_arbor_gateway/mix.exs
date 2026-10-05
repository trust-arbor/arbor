defmodule ConversationKit.Arbor.Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :conversation_kit_arbor_gateway,
      version: "0.1.0-dev",
      elixir: "~> 1.19",
      test_ignore_filters: [~r"^test/support/"],
      deps: [
        {:conversation_kit_arbor, path: "../conversation_kit_arbor"},
        {:arbor_client, path: "../../clients/arbor_client"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
