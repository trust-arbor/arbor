defmodule Arbor.Dashboard.Router do
  @moduledoc false

  use Arbor.Web.Router

  # The pinned LiveView logger inspects mount sessions without parameter filtering.
  # Every routed Dashboard LiveView disables that optional logger with `log: false`;
  # live_view_logging_security_regression_test.exs exercises the actual routed views.
  @doc false
  def live_session_data(conn) do
    %{
      "agent_id" => Plug.Conn.get_session(conn, "agent_id"),
      "user_display_name" => Plug.Conn.get_session(conn, "user_display_name"),
      "session_token" => Plug.Conn.get_session(conn, "session_token"),
      "local_dev_operator" => Plug.Conn.get_session(conn, "local_dev_operator") == true
    }
  end

  scope "/", Arbor.Dashboard.Live do
    arbor_browser_pipeline()

    live_session :dashboard,
      layout: {Arbor.Web.Layouts, :app},
      session: {__MODULE__, :live_session_data, []},
      on_mount: Arbor.Dashboard.Nav do
      live "/", ConversationLive
      live "/console", LandingLive
      live "/signals", SignalsLive
      live "/eval", EvalLive
      live "/consensus", ConsensusLive
      live "/events", EventsLive
      live "/agents", AgentsLive
      live "/monitor", MonitorLive
      live "/roadmap", RoadmapLive
      live "/home", ConversationLive
      live "/c/:engagement_id", ConversationLive
      live "/conversation/:agent_id", ConversationLive
      live "/channels", ChannelsLive
      live "/memory", MemoryLive
      live "/memory/:agent_id", MemoryLive
      live "/telemetry", TelemetryLive
      live "/settings", SettingsLive
    end
  end

  scope "/" do
    pipe_through :browser
    get "/chat", Arbor.Dashboard.LegacyChatController, :index
  end
end
