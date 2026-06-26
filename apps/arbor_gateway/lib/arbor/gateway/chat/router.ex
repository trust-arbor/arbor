defmodule Arbor.Gateway.Chat.Router do
  @moduledoc """
  Chat sub-router — upgrades `GET /api/chat/socket` to a WebSocket handled by
  `Arbor.Gateway.Chat.Socket`, and serves `GET /api/chat/agents` (a signed HTTP
  GET listing the agents the principal may chat with — works while DETACHED).

  Auth already ran in the parent `Arbor.Gateway.Router` pipeline (SignedRequest /
  JWT / API key), so by here the connection is authenticated and
  `conn.assigns.agent_id` holds the principal (the human, via the device-flow →
  SignedRequest path the TUI uses). See `0-inbox/gateway-chat-api.md`.
  """

  use Plug.Router

  alias Arbor.Gateway.Chat.Agents

  plug(:match)
  plug(:dispatch)

  # WebSocket upgrade. The authenticated principal is threaded into the socket's
  # initial state; the client then `attach`es to an engagement and exchanges turns.
  get "/socket" do
    case conn.assigns[:agent_id] do
      principal when is_binary(principal) ->
        conn
        |> WebSockAdapter.upgrade(
          Arbor.Gateway.Chat.Socket,
          %{principal: principal},
          timeout: 120_000
        )
        |> halt()

      _ ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  # Signed HTTP GET listing the agents this principal may chat with. Used by the
  # TUI's `/agents` command — it works whether or not a WS is attached, since
  # discovery is exactly the detached case. The principal is the authenticated
  # `conn.assigns.agent_id` (same as the socket route); the listing is derived
  # from that principal's `arbor://chat/agent/<id>` capabilities.
  get "/agents" do
    case conn.assigns[:agent_id] do
      principal when is_binary(principal) ->
        agents = Agents.list_for_principal(principal)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{agents: agents}))

      _ ->
        send_resp(conn, 401, "unauthorized")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
