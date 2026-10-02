defmodule ConversationKit.Arbor.MixProject do
  use Mix.Project

  def project do
    [
      app: :conversation_kit_arbor,
      version: "0.1.0-spike",
      elixir: "~> 1.19",
      deps: [{:conversation_kit, path: "../core"}]
    ]
  end

  def application, do: []
end
