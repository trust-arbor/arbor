defmodule Arbor.Bridge.Application do
  @moduledoc """
  Application supervisor for the Arbor Bridge.

  Starts the HTTP server that handles Claude Code hook requests.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_bridge, :start_server, true) do
        port = Application.get_env(:arbor_bridge, :port, 4000)
        Logger.info("Starting Arbor Bridge HTTP server on port #{port}")
        [{Plug.Cowboy, scheme: :http, plug: Arbor.Bridge.Router, options: [port: port]}]
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Bridge.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
