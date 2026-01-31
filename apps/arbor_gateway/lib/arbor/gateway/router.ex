defmodule Arbor.Gateway.Router do
  @moduledoc """
  Main HTTP router for the Arbor Gateway.

  Routes requests to specialized sub-routers by namespace:

  - `/health` — liveness check
  - `/api/bridge/*` — Claude Code tool authorization
  - `/api/memory/*` — memory operations for bridged agents
  - `/api/dev/*` — development tools (eval, recompile, info)
  - `/api/signals/*` — signal ingestion from external sources (hooks, etc.)
  """

  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", service: "arbor_gateway"}))
  end

  forward("/api/bridge", to: Arbor.Gateway.Bridge.Router)
  forward("/api/memory", to: Arbor.Gateway.Memory.Router)
  forward("/api/signals", to: Arbor.Gateway.Signals.Router)
  forward("/api/dev", to: Arbor.Gateway.Dev.Router)

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
