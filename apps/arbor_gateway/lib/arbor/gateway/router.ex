defmodule Arbor.Gateway.Router do
  @moduledoc """
  Main HTTP router for the Arbor Gateway.

  Routes requests to specialized sub-routers by namespace:

  - `/health` — liveness check
  - `/api/bridge/*` — Claude Code tool authorization
  - `/api/memory/*` — memory operations for bridged agents
  - `/api/dev/*` — development tools (eval, recompile, info)
  - `/api/signals/*` — signal ingestion from external sources (hooks, etc.)
  - `/mcp` — MCP server for progressive-disclosure Arbor tools (authenticated)
  """

  use Plug.Router

  alias Arbor.Gateway.Auth

  plug(Plug.Logger)
  plug(:match)
  plug(:conditional_parsers)
  plug(:require_auth_unless_health)
  # H13: Rate limiting on all authenticated endpoints
  plug(Arbor.Gateway.RateLimiter)
  plug(:dispatch)

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", service: "arbor_gateway"}))
  end

  # MCP endpoint — ExMCP handles its own body parsing
  # C1: CORS disabled — MCP is authenticated and should not accept browser-origin requests
  forward("/mcp",
    to: ExMCP.HttpPlug,
    init_opts: [
      handler: Arbor.Gateway.MCP.Handler,
      server_info: %{name: "arbor", version: "0.1.0"},
      sse_enabled: true,
      cors_enabled: false
    ]
  )

  forward("/api/bridge", to: Arbor.Gateway.Bridge.Router)
  forward("/api/memory", to: Arbor.Gateway.Memory.Router)
  forward("/api/signals", to: Arbor.Gateway.Signals.Router)
  # H4: Dev eval endpoint only compiled into dev/test builds
  if Mix.env() in [:dev, :test] do
    forward("/api/dev", to: Arbor.Gateway.Dev.Router)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Skip body parsing for MCP routes (ExMCP handles its own parsing)
  @parsers_opts Plug.Parsers.init(parsers: [:json], json_decoder: Jason)
  defp conditional_parsers(%{request_path: "/mcp" <> _} = conn, _opts), do: conn
  defp conditional_parsers(conn, _opts), do: Plug.Parsers.call(conn, @parsers_opts)

  # Skip auth for health check only — all other endpoints require API key auth
  # C1: MCP no longer bypasses auth (was unauthenticated, enabling action execution without authorization)
  defp require_auth_unless_health(%{request_path: "/health"} = conn, _opts), do: conn
  defp require_auth_unless_health(conn, _opts), do: Auth.call(conn, [])
end
