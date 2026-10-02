defmodule ConversationDemo.Endpoint do
  use Phoenix.Endpoint, otp_app: :conversation_demo

  @session [
    store: :cookie,
    key: "conversation_spike",
    signing_salt: "local-spike",
    same_site: "Lax"
  ]
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
  plug(Plug.Static, at: "/assets", from: {:conversation_demo, "priv/static"})
  plug(Plug.RequestId)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(Plug.Session, @session)
  plug(ConversationDemo.Router)
end
