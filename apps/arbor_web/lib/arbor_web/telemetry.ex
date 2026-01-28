defmodule Arbor.Web.Telemetry do
  @moduledoc """
  Dashboard instrumentation for Arbor.Web.

  Provides telemetry event definitions and metric specifications
  for monitoring Arbor dashboard performance.

  ## Setup

  Call `Arbor.Web.Telemetry.setup/0` in your application start:

      def start(_type, _args) do
        Arbor.Web.Telemetry.setup()
        # ...
      end

  ## Events

  The following telemetry events are emitted:

    * `[:arbor, :web, :endpoint, :start]` — HTTP request started
    * `[:arbor, :web, :endpoint, :stop]` — HTTP request completed
    * `[:arbor, :web, :live_view, :mount, :start]` — LiveView mount started
    * `[:arbor, :web, :live_view, :mount, :stop]` — LiveView mount completed
    * `[:arbor, :web, :live_view, :handle_event, :start]` — LiveView event handling started
    * `[:arbor, :web, :live_view, :handle_event, :stop]` — LiveView event handling completed
  """

  require Logger

  @doc """
  Attaches telemetry handlers for Arbor.Web dashboard metrics.
  """
  @spec setup() :: :ok
  def setup do
    events = [
      [:arbor, :web, :endpoint, :stop],
      [:phoenix, :live_view, :mount, :stop],
      [:phoenix, :live_view, :handle_event, :stop]
    ]

    :telemetry.attach_many(
      "arbor-web-telemetry",
      events,
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc """
  Returns telemetry metric definitions for use with `Telemetry.Metrics`.

  ## Example

      def metrics do
        Arbor.Web.Telemetry.metrics()
      end
  """
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    import Telemetry.Metrics

    [
      # HTTP request metrics
      summary("arbor.web.endpoint.stop.duration",
        unit: {:native, :millisecond},
        description: "HTTP request duration"
      ),
      counter("arbor.web.endpoint.stop.duration",
        description: "HTTP request count"
      ),

      # LiveView mount metrics
      summary("phoenix.live_view.mount.stop.duration",
        unit: {:native, :millisecond},
        tags: [:view],
        description: "LiveView mount duration"
      ),
      counter("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        description: "LiveView mount count"
      ),

      # LiveView event handling metrics
      summary("phoenix.live_view.handle_event.stop.duration",
        unit: {:native, :millisecond},
        tags: [:view, :event],
        description: "LiveView event handling duration"
      ),
      counter("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        description: "LiveView event count"
      )
    ]
  end

  @doc false
  def handle_event([:arbor, :web, :endpoint, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 1000 do
      Logger.warning("[Arbor.Web] Slow request: #{metadata.conn.request_path} took #{duration_ms}ms")
    end
  end

  def handle_event([:phoenix, :live_view, :mount, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 500 do
      view = inspect(metadata.socket.view)
      Logger.warning("[Arbor.Web] Slow LiveView mount: #{view} took #{duration_ms}ms")
    end
  end

  def handle_event([:phoenix, :live_view, :handle_event, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 200 do
      view = inspect(metadata.socket.view)
      event = metadata.event

      Logger.warning(
        "[Arbor.Web] Slow LiveView event: #{view}##{event} took #{duration_ms}ms"
      )
    end
  end
end
