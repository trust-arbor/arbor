defmodule ConversationKit.Arbor.Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :conversation_kit_arbor_gateway,
      version: "0.1.0-spike",
      elixir: "~> 1.19",
      deps: [
        {:conversation_kit_arbor, path: "../adapter"},
        {:arbor_client, path: "../../source/clients/arbor_client"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
