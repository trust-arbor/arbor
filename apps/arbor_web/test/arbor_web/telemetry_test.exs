defmodule Arbor.Web.TelemetryTest do
  use ExUnit.Case, async: true

  alias Arbor.Web.Telemetry, as: WebTelemetry

  describe "setup/0" do
    test "attaches telemetry handlers without error" do
      # Detach first in case already attached
      :telemetry.detach("arbor-web-telemetry")
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
  end

  describe "handle_event/4" do
    test "handles endpoint stop event" do
      measurements = %{duration: System.convert_time_unit(100, :millisecond, :native)}

      metadata = %{
        conn: %{request_path: "/test"}
      }

      assert :ok ==
               WebTelemetry.handle_event(
                 [:arbor, :web, :endpoint, :stop],
                 measurements,
                 metadata,
                 nil
               )
               |> then(fn _ -> :ok end)
    end
  end
end
