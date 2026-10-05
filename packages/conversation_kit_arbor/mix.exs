defmodule ConversationKit.Arbor.MixProject do
  use Mix.Project

  def project do
    [
      app: :conversation_kit_arbor,
      version: "0.1.0-dev",
      elixir: "~> 1.19",
      deps: [{:conversation_kit, path: "../conversation_kit"}]
    ]
  end

  def application, do: []
end
