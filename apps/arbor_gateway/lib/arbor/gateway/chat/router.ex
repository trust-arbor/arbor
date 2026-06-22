defmodule Arbor.Gateway.Chat.Router do
  @moduledoc """
  Chat sub-router — upgrades `GET /api/chat/socket` to a WebSocket handled by
  `Arbor.Gateway.Chat.Socket`.

  Auth already ran in the parent `Arbor.Gateway.Router` pipeline (SignedRequest /
  JWT / API key), so by here the connection is authenticated and
  `conn.assigns.agent_id` holds the principal (the human, via the device-flow →
  SignedRequest path the TUI uses). See `0-inbox/gateway-chat-api.md`.
  """

  use Plug.Router

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

  match _ do
    send_resp(conn, 404, "not found")
  end
end
