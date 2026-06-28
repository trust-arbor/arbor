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
  alias Arbor.Gateway.Chat.Lifecycle

  plug(:match)
  plug(:dispatch)

  # JSON request bodies are already parsed by the parent `Arbor.Gateway.Router`'s
  # `:conditional_parsers` plug (which reuses the signature-verified raw body), so
  # by here `conn.body_params` holds the decoded body for the POST routes below.

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

  # Signed HTTP POST: create+start a new agent from a template, granting the
  # principal chat access to it. Gated on `arbor://agent/lifecycle/create`.
  # Body: {"template": "...", "name": "..."(opt), "model": "..."(opt)}.
  post "/agents" do
    with_principal(conn, fn principal ->
      lifecycle_result(conn, Lifecycle.create(principal, conn.body_params || %{}, sr_opts(conn)))
    end)
  end

  # Signed HTTP POST: start an existing stopped agent. Gated on
  # `arbor://agent/lifecycle/restore`.
  post "/agents/:id/start" do
    with_principal(conn, fn principal ->
      lifecycle_result(conn, Lifecycle.start(principal, id, sr_opts(conn)))
    end)
  end

  # Signed HTTP POST: stop a running agent. Gated on `arbor://agent/stop/<id>`.
  post "/agents/:id/stop" do
    with_principal(conn, fn principal ->
      lifecycle_result(conn, Lifecycle.stop(principal, id, sr_opts(conn)))
    end)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # The parent pipeline rejects unauthenticated requests; this only ensures we
  # never act without a principal in assigns.
  defp with_principal(conn, fun) do
    case conn.assigns[:agent_id] do
      principal when is_binary(principal) -> fun.(principal)
      _ -> send_resp(conn, 401, "unauthorized")
    end
  end

  # The parent pipeline's SignedRequestAuth verified the Ed25519 signature and
  # stashed the bound `SignedRequest` struct in assigns. Forward it so the
  # capability-gated lifecycle ops can satisfy AuthDecision's identity-binding
  # step (`identity_verification` is config-ON in dev/prod) — without it the
  # gates reject authenticated requests as `:missing_signed_request`.
  defp sr_opts(conn), do: [signed_request: conn.assigns[:signed_request]]

  defp lifecycle_result(conn, {:ok, body}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp lifecycle_result(conn, {:error, status, message}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
  end
end
