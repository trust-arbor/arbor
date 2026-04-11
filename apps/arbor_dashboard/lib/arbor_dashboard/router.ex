defmodule Arbor.Dashboard.Router do
  @moduledoc false

  use Arbor.Web.Router

  @doc false
  def live_session_data(conn) do
    %{
      "agent_id" => Plug.Conn.get_session(conn, "agent_id"),
      "user_display_name" => Plug.Conn.get_session(conn, "user_display_name"),
      "session_token" => Plug.Conn.get_session(conn, "session_token")
    }
  end

  scope "/", Arbor.Dashboard.Live do
    arbor_browser_pipeline()

    live_session :dashboard,
      layout: {Arbor.Web.Layouts, :app},
      session: {__MODULE__, :live_session_data, []},
      on_mount: Arbor.Dashboard.Nav do
      live "/", LandingLive
      live "/signals", SignalsLive
      live "/eval", EvalLive
      live "/consensus", ConsensusLive
      live "/events", EventsLive
      live "/agents", AgentsLive
      live "/monitor", MonitorLive
      live "/roadmap", RoadmapLive
      live "/chat", ChatLive
      live "/channels", ChannelsLive
      live "/memory", MemoryLive
      live "/memory/:agent_id", MemoryLive
      live "/telemetry", TelemetryLive
      live "/settings", SettingsLive
    end
  end
end
