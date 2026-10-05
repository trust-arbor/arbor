defmodule Arbor.Dashboard.LegacyChatController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  alias Arbor.Dashboard.ConversationNavigationCore

  def index(conn, _params) do
    conn = Plug.Conn.put_resp_header(conn, "cache-control", "no-store")

    case ConversationNavigationCore.legacy_destination(conn.query_string) do
      {:ok, destination} ->
        redirect(conn, to: destination)

      {:error, :invalid_target} ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(
          400,
          "Conversation link is invalid. Open Home and select a conversation."
        )
    end
  end
end
