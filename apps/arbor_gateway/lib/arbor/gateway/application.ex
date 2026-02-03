defmodule Arbor.Gateway.Application do
  @moduledoc """
  Application supervisor for the Arbor Gateway.

  Starts the HTTP server that serves as the single HTTP entry point
  for Arbor — bridge authorization, dev tools, and future API endpoints.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_gateway, :start_server, true) do
        port = Application.get_env(:arbor_gateway, :port, 4000)

        if port_available?(port) do
          bind_ip = Application.get_env(:arbor_gateway, :bind_ip, {127, 0, 0, 1})
          Logger.info("Starting Arbor Gateway HTTP server on #{:inet.ntoa(bind_ip)}:#{port}")

          [
            {Plug.Cowboy,
             scheme: :http,
             plug: Arbor.Gateway.Router,
             options: [port: port, ip: bind_ip]}
          ]
        else
          Logger.warning("Port #{port} already in use, starting Gateway without HTTP server")
          []
        end
      else
        []
      end

    opts = [strategy: :one_for_one, name: Arbor.Gateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :eaddrinuse} ->
        false
    end
  end
end
