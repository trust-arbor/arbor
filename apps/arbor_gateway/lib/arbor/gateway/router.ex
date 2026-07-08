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
  alias Arbor.Gateway.JwtAuth

  plug(Plug.Logger)
  plug(:match)
  # L (codex rate-limit.gateway-auth-failures-before-limiter): the IP-keyed rate
  # limiter must run BEFORE authentication so that FAILED auth attempts are also
  # counted — otherwise auth plugs halt the conn first and brute-force/credential
  # stuffing attempts never hit the limiter. (Skips /health so monitoring probes
  # aren't throttled.)
  plug(:rate_limit_unless_health)
  # M (codex authn.signed-request-body-parser-order): signed-request verification
  # must run BEFORE body parsing so the Ed25519 signature is verified over the
  # RAW request body and bound to exactly what downstream routes consume. The
  # plug caches the raw body in `assigns[:raw_body]`; :conditional_parsers then
  # reuses it via the cached body_reader (so the stream isn't consumed twice).
  plug(:try_signed_request_auth)
  plug(:conditional_parsers)
  plug(:try_jwt_auth)
  plug(:require_auth_unless_health)
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
      handler_opts: {Arbor.Gateway.MCP.Handler, :handler_opts_from_conn, []},
      server_info: %{name: "arbor", version: "0.1.0"},
      sse_enabled: true,
      cors_enabled: false
    ]
  )

  forward("/api/bridge", to: Arbor.Gateway.Bridge.Router)
  forward("/api/memory", to: Arbor.Gateway.Memory.Router)
  forward("/api/signals", to: Arbor.Gateway.Signals.Router)
  # Streaming chat for external clients (TUI, mobile): WS upgrade at
  # /api/chat/socket — see 0-inbox/gateway-chat-api.md.
  forward("/api/chat", to: Arbor.Gateway.Chat.Router)
  # H4: Dev eval endpoint only compiled into dev/test builds
  if Mix.env() in [:dev, :test] do
    forward("/api/dev", to: Arbor.Gateway.Dev.Router)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # Rate limit everything except the liveness probe. Runs before auth so failed
  # authentication attempts are counted (brute-force hardening).
  defp rate_limit_unless_health(%{request_path: "/health"} = conn, _opts), do: conn
  defp rate_limit_unless_health(conn, _opts), do: Arbor.Gateway.RateLimiter.call(conn, [])

  # Skip body parsing for MCP routes (ExMCP handles its own parsing).
  # body_reader reuses the raw body already read+cached by SignedRequestAuth so
  # the request stream isn't consumed twice (and the parsed body is exactly the
  # bytes whose signature was verified). When no signature was present, raw_body
  # is absent and the reader falls back to reading the stream normally.
  @parsers_opts Plug.Parsers.init(
                  parsers: [:json],
                  json_decoder: Jason,
                  body_reader: {__MODULE__, :cached_body_reader, []}
                )
  defp conditional_parsers(%{request_path: "/mcp" <> _} = conn, _opts), do: conn
  defp conditional_parsers(conn, _opts), do: Plug.Parsers.call(conn, @parsers_opts)

  @doc false
  def cached_body_reader(conn, opts) do
    case conn.assigns do
      %{raw_body: body} when is_binary(body) -> {:ok, body, conn}
      _ -> Plug.Conn.read_body(conn, opts)
    end
  end

  # Try SignedRequest auth before JWT — non-destructive passthrough.
  # External agents (Claude Code, etc.) authenticate per-request via Ed25519
  # signatures over method+path+body, with the public key registered via the
  # dashboard "External Agents" UI.
  defp try_signed_request_auth(%{request_path: "/health"} = conn, _opts), do: conn

  defp try_signed_request_auth(conn, _opts) do
    Arbor.Gateway.SignedRequestAuth.call(conn, [])
  end

  # Try JWT bearer token auth before API key auth — non-destructive passthrough
  defp try_jwt_auth(%{request_path: "/health"} = conn, _opts), do: conn
  defp try_jwt_auth(%{assigns: %{signed_request_authenticated: true}} = conn, _opts), do: conn
  defp try_jwt_auth(conn, _opts), do: JwtAuth.call(conn, [])

  # Skip auth for health check only — all other endpoints require auth.
  # Three accepted credentials in priority order:
  #   1. SignedRequest (Ed25519 per-request signature, for external agents)
  #   2. JWT bearer (OIDC, for human dashboard sessions)
  #   3. API key (shared secret, for machine-to-machine clients)
  defp require_auth_unless_health(%{request_path: "/health"} = conn, _opts), do: conn

  defp require_auth_unless_health(
         %{assigns: %{signed_request_authenticated: true}} = conn,
         _opts
       ),
       do: conn

  defp require_auth_unless_health(%{assigns: %{jwt_authenticated: true}} = conn, _opts), do: conn
  defp require_auth_unless_health(conn, _opts), do: Auth.call(conn, [])
end
