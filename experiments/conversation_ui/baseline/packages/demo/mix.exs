defmodule ConversationDemo.MixProject do
  use Mix.Project

  def project do
    [app: :conversation_demo, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application do
    [mod: {ConversationDemo.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp deps do
    [
      {:conversation_kit, path: "../core"},
      {:conversation_kit_arbor, path: "../adapter"},
      {:conversation_kit_arbor_gateway, path: "../remote"},
      {:phoenix, "== 1.8.9"},
      {:phoenix_live_view, "== 1.1.33"},
      {:phoenix_html, "== 4.3.0"},
      {:plug_cowboy, "== 2.9.0"},
      {:jason, "~> 1.4"},
      {:breeze, "== 0.5.3"},
      {:term_ui, "== 0.2.0"},
      {:lazy_html, "~> 0.1", only: :test}
    ]
  end
end
