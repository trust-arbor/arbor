defmodule ArborTui.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :arbor_tui,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps()
    ]
  end

  # A standalone client — NOT part of the Arbor umbrella. It connects to the
  # Gateway chat WebSocket API (`/api/chat/socket`) over the network and speaks
  # the JSON frame protocol. It reproduces only the tiny SignedRequest signing
  # surface (stdlib `:crypto` Ed25519), so it has zero coupling to the server's
  # umbrella build/deps/hierarchy. See clients/arbor_tui/README.md.
  def application do
    [
      extra_applications: [:logger, :crypto, :ssl]
    ]
  end

  defp escript do
    [
      main_module: ArborTui.CLI,
      name: "arbor-tui"
    ]
  end

  defp deps do
    [
      # Terminal UI (Elm Architecture, pure Elixir — no termbox C binding).
      {:term_ui, "~> 0.2"},
      # WebSocket client transport.
      {:mint_web_socket, "~> 1.0"},
      {:mint, "~> 1.0"},
      # JSON framing (matches the server's protocol + SignedRequest envelope).
      {:jason, "~> 1.4"}
    ]
  end
end
