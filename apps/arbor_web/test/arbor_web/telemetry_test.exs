defmodule Arbor.Web.TelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :fast

  alias Arbor.Web.Telemetry, as: WebTelemetry

  # Helper to build duration in native units from milliseconds
  defp native_duration(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  # Safely detach telemetry handler, ignoring errors when telemetry app isn't started
  defp safe_detach(handler_id) do
    :telemetry.detach(handler_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  describe "setup/0" do
    setup do
      # Ensure the telemetry application is started for these tests
      {:ok, _} = Application.ensure_all_started(:telemetry)
      safe_detach("arbor-web-telemetry")
      :ok
    end

    test "attaches telemetry handlers without error" do
      assert WebTelemetry.setup() == :ok
    end

    test "setup is idempotent when re-attached after detach" do
      assert WebTelemetry.setup() == :ok
      # Detach and re-attach again
      safe_detach("arbor-web-telemetry")
      assert WebTelemetry.setup() == :ok
    end
  end

  describe "metrics/0" do
    test "returns a list of telemetry metrics" do
      metrics = WebTelemetry.metrics()
      assert [_ | _] = metrics

      # All should be Telemetry.Metrics structs
      for metric <- metrics do
        assert is_struct(metric)

        assert metric.__struct__ in [
                 Telemetry.Metrics.Summary,
                 Telemetry.Metrics.Counter
               ]
      end
    end

    test "returns exactly 6 metrics" do
      metrics = WebTelemetry.metrics()
      assert length(metrics) == 6
    end

    test "includes endpoint metrics" do
      metrics = WebTelemetry.metrics()

      event_names =
        Enum.map(metrics, fn m -> m.event_name end)
        |> Enum.uniq()

      assert [:arbor, :web, :endpoint, :stop] in event_names
    end

    test "includes LiveView mount metrics" do
      metrics = WebTelemetry.metrics()

      event_names =
        Enum.map(metrics, fn m -> m.event_name end)
        |> Enum.uniq()

      assert [:phoenix, :live_view, :mount, :stop] in event_names
    end

    test "includes LiveView event metrics" do
      metrics = WebTelemetry.metrics()

      event_names =
        Enum.map(metrics, fn m -> m.event_name end)
        |> Enum.uniq()

      assert [:phoenix, :live_view, :handle_event, :stop] in event_names
    end

    test "endpoint metrics include both summary and counter" do
      metrics = WebTelemetry.metrics()

      endpoint_metrics =
        Enum.filter(metrics, fn m -> m.event_name == [:arbor, :web, :endpoint, :stop] end)

      types = Enum.map(endpoint_metrics, & &1.__struct__)
      assert Telemetry.Metrics.Summary in types
      assert Telemetry.Metrics.Counter in types
    end

    test "LiveView mount metrics are tagged with :view" do
      metrics = WebTelemetry.metrics()

      mount_metrics =
        Enum.filter(metrics, fn m -> m.event_name == [:phoenix, :live_view, :mount, :stop] end)

      for metric <- mount_metrics do
        assert :view in metric.tags
      end
    end

    test "LiveView event metrics are tagged with :view and :event" do
      metrics = WebTelemetry.metrics()

      event_metrics =
        Enum.filter(metrics, fn m ->
          m.event_name == [:phoenix, :live_view, :handle_event, :stop]
        end)

      for metric <- event_metrics do
        assert :view in metric.tags
        assert :event in metric.tags
      end
    end
  end

  describe "handle_event/4 - endpoint stop" do
    test "handles fast endpoint request without logging" do
      measurements = %{duration: native_duration(100)}
      metadata = %{conn: %{request_path: "/test"}}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:arbor, :web, :endpoint, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      refute log =~ "Slow request"
    end

    test "logs warning for slow endpoint request over 1000ms" do
      measurements = %{duration: native_duration(1500)}
      metadata = %{conn: %{request_path: "/slow-endpoint"}}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:arbor, :web, :endpoint, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      assert log =~ "[Arbor.Web] Slow request"
      assert log =~ "/slow-endpoint"
      assert log =~ "1500ms"
    end

    test "does not log for request at exactly 1000ms" do
      measurements = %{duration: native_duration(1000)}
      metadata = %{conn: %{request_path: "/borderline"}}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:arbor, :web, :endpoint, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      refute log =~ "Slow request"
    end
  end

  describe "handle_event/4 - LiveView mount stop" do
    test "handles fast mount without logging" do
      measurements = %{duration: native_duration(50)}
      metadata = %{socket: %{view: MyApp.SomeLive}}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :mount, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      refute log =~ "Slow LiveView mount"
    end

    test "logs warning for slow mount over 500ms" do
      measurements = %{duration: native_duration(800)}
      metadata = %{socket: %{view: MyApp.SlowMountLive}}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :mount, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      assert log =~ "[Arbor.Web] Slow LiveView mount"
      assert log =~ "SlowMountLive"
      assert log =~ "800ms"
    end

    test "does not log for mount at exactly 500ms" do
      measurements = %{duration: native_duration(500)}
      metadata = %{socket: %{view: MyApp.BorderlineLive}}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :mount, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      refute log =~ "Slow LiveView mount"
    end
  end

  describe "handle_event/4 - LiveView handle_event stop" do
    test "handles fast event without logging" do
      measurements = %{duration: native_duration(50)}
      metadata = %{socket: %{view: MyApp.DashLive}, event: "click"}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :handle_event, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      refute log =~ "Slow LiveView event"
    end

    test "logs warning for slow event over 200ms" do
      measurements = %{duration: native_duration(350)}
      metadata = %{socket: %{view: MyApp.SlowEventLive}, event: "submit_form"}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :handle_event, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      assert log =~ "[Arbor.Web] Slow LiveView event"
      assert log =~ "SlowEventLive"
      assert log =~ "submit_form"
      assert log =~ "350ms"
    end

    test "does not log for event at exactly 200ms" do
      measurements = %{duration: native_duration(200)}
      metadata = %{socket: %{view: MyApp.BorderlineLive}, event: "click"}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :handle_event, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      refute log =~ "Slow LiveView event"
    end

    test "includes both view and event name in slow event log" do
      measurements = %{duration: native_duration(500)}
      metadata = %{socket: %{view: MyApp.AgentDashboard}, event: "delete_agent"}

      log =
        capture_log(fn ->
          WebTelemetry.handle_event(
            [:phoenix, :live_view, :handle_event, :stop],
            measurements,
            metadata,
            nil
          )
        end)

      assert log =~ "AgentDashboard"
      assert log =~ "delete_agent"
    end
  end
end
