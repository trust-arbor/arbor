defmodule Arbor.Dashboard.LiveViewLoggingSecurityRegressionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbor.Dashboard.Router
  alias Phoenix.LiveView.Socket

  @moduletag :fast
  @mount_event [:phoenix, :live_view, :mount, :start]
  @views Router.__routes__()
         |> Enum.flat_map(fn route ->
           case route.metadata[:phoenix_live_view] do
             {view, _action, _opts, _session} -> [view]
             _ -> []
           end
         end)
         |> Enum.uniq()

  setup do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, @mount_event, &Phoenix.LiveView.Logger.lv_mount_start/4, %{})

    Logger.put_process_level(self(), :debug)

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "production router includes the authenticated chat and agents views" do
    assert Arbor.Dashboard.Live.ChatLive in @views
    assert Arbor.Dashboard.Live.AgentsLive in @views
  end

  for view <- @views do
    test "security regression: #{inspect(view)} mount logging never discloses the session" do
      token = "mount-session-token-private-sentinel"
      nested_token = "nested-session-token-private-sentinel"
      password = "nested-password-private-sentinel"

      session =
        :get
        |> Plug.Test.conn("/")
        |> Plug.Test.init_test_session(%{
          "session_token" => token,
          "agent_id" => "human_logging_test",
          "user_display_name" => "Logging test"
        })
        |> Router.live_session_data()
        |> Map.put("nested", [%{"session_token" => nested_token, "password" => password}])

      socket = %Socket{view: unquote(view), transport_pid: self()}

      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(@mount_event, %{system_time: System.system_time()}, %{
            socket: socket,
            params: %{},
            session: session,
            uri: "http://localhost/"
          })
        end)

      refute log =~ token
      refute log =~ nested_token
      refute log =~ password
      refute log =~ "Session:"
    end
  end

  test "Phoenix default parameter filtering protects passwords and session tokens recursively" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "password" => "password-private-sentinel",
        "token" => "generic-token-private-sentinel",
        "session_token" => "session-token-private-sentinel",
        "nested" => [%{"session_token" => "nested-private-sentinel"}],
        "visible" => "ordinary-value"
      })

    assert filtered == %{
             "password" => "[FILTERED]",
             "token" => "[FILTERED]",
             "session_token" => "[FILTERED]",
             "nested" => [%{"session_token" => "[FILTERED]"}],
             "visible" => "ordinary-value"
           }
  end
end
