defmodule Arbor.Agent.Test.ConversationTransportWeb do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  # This router exists only in the opt-in transport fixture, bound to loopback.
  # The randomized path provisions a real session token from a test identity;
  # it does not replace any production conversation authorization check.
  def call(conn, _) do
    fixture = Application.fetch_env!(:arbor_agent, :conversation_transport_fixture)
    prefix = "/_journey/" <> fixture.secret

    case conn.request_path do
      path when path == prefix <> "/login" ->
        session =
          Plug.Session.init(
            store: :cookie,
            key: "_arbor_arbor_dashboard_key",
            signing_salt: "arbor_arbor_dashboard"
          )

        conn
        |> Map.put(:secret_key_base, Arbor.Dashboard.Endpoint.config(:secret_key_base))
        |> Plug.Session.call(session)
        |> fetch_session()
        |> put_session("agent_id", fixture.primary.agent_id)
        |> put_session("session_token", fixture.token)
        |> put_session("user_display_name", "Isolated conversation journey")
        |> put_resp_header("location", "/chat?agent_id=" <> fixture.target)
        |> send_resp(302, "")

      path when path == prefix <> "/revoke" ->
        :ok = Arbor.Security.revoke(fixture.primary_cap.id)
        :ok = Arbor.Security.revoke(fixture.secondary_cap.id)
        send(fixture.owner, :transport_revoked)
        send_resp(conn, 200, "revoked")

      path when path == prefix <> "/finish" ->
        send(fixture.owner, :transport_finish)
        send_resp(conn, 200, "finishing")

      _ ->
        Arbor.Dashboard.Endpoint.call(conn, Arbor.Dashboard.Endpoint.init([]))
    end
  end
end
