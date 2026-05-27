defmodule Arbor.Signals.Telemetry do
  @moduledoc """
  Shared telemetry handling for Arbor — the observability counterpart to emission.

  Telemetry *emission* (`:telemetry.span` / `:telemetry.execute`) is decentralized:
  each library instruments its own work sites. *Handling* those events — logging
  them for profiling, or bridging them into the Signal bus — is a cross-cutting
  concern, and lives here because `arbor_signals` is the universal observability
  dependency (and already emits telemetry of its own).

  Two attach modes, both opt-in (telemetry events are ~free with no handler attached):

    * `attach_logger/2` — log each event (durations for spans). Dev profiling without
      a profiler. e.g. `attach_logger([[:arbor, :preprocessor, :run, :stop], [:arbor, :preprocessor, :stage]])`.
    * `attach_bridge/2` — re-emit selected telemetry events as **signals** (via
      `Arbor.Signals.emit/4`), so they land in the same stream Historian and the
      dashboards already consume.

  ## Bridge caution

  Bridging is **selective + sampled** on purpose. The signal bus has authorization
  and (optionally) durable persistence overhead, so do not pipe high-frequency
  telemetry through it wholesale — pass only the event prefixes you want as signals,
  and use `:sample` for hot ones. Pure metric aggregation (p50/p95) should use
  `:telemetry_metrics` reporters instead, which don't touch the bus.

  A feedback guard drops any `[:arbor, :signals | _]` event so the bridge can't loop
  on the telemetry that signal emission itself produces.
  """

  require Logger

  @logger_id "arbor-signals-telemetry-logger"
  @bridge_id "arbor-signals-telemetry-bridge"

  @doc """
  Attach a logging handler to `events`. Span `:stop`/`:exception` and any event
  carrying `%{duration: native}` are logged with a millisecond duration.

  Options: `:id` (handler id, default `#{@logger_id}`).
  """
  @spec attach_logger([[atom()]], keyword()) :: {:ok, binary()}
  def attach_logger(events, opts \\ []) when is_list(events) do
    id = Keyword.get(opts, :id, @logger_id)
    detach(id)
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_log/4, %{})
    {:ok, id}
  end

  @doc """
  Attach a bridge that re-emits `events` as signals via `Arbor.Signals`.

  Options:
    * `:id` — handler id (default `#{@bridge_id}`)
    * `:category` — signal category (default `:telemetry`)
    * `:durable` — use `durable_emit/4` (default `false`)
    * `:sample` — fraction 0.0–1.0 of events to bridge (default `1.0`)
  """
  @spec attach_bridge([[atom()]], keyword()) :: {:ok, binary()}
  def attach_bridge(events, opts \\ []) when is_list(events) do
    id = Keyword.get(opts, :id, @bridge_id)
    detach(id)

    config = %{
      category: Keyword.get(opts, :category, :telemetry),
      durable: Keyword.get(opts, :durable, false),
      sample: Keyword.get(opts, :sample, 1.0)
    }

    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_bridge/4, config)
    {:ok, id}
  end

  @doc "Detach a handler by id."
  @spec detach(binary()) :: :ok
  def detach(id) do
    :telemetry.detach(id)
  rescue
    _ -> :ok
  catch
    _ -> :ok
  end

  # ── handlers ──────────────────────────────────────────────────────────

  @doc false
  def handle_log(event, measurements, metadata, _config) do
    dur = measurements[:duration]
    suffix = if is_integer(dur), do: " — #{ms(dur)}ms", else: ""
    meta = Map.drop(metadata, [:telemetry_span_context])
    Logger.info("[telemetry] #{Enum.join(event, ".")}#{suffix} #{inspect(meta)}")
  end

  @doc false
  # Feedback guard: never bridge the telemetry that signal emission itself emits.
  def handle_bridge([:arbor, :signals | _], _m, _meta, _config), do: :ok

  def handle_bridge(event, measurements, metadata, config) do
    if sampled?(config.sample) do
      type = Enum.join(event, ".")

      data = %{
        event: event,
        measurements: measurements,
        metadata: Map.drop(metadata, [:telemetry_span_context])
      }

      if config.durable do
        Arbor.Signals.durable_emit(config.category, type, data, [])
      else
        Arbor.Signals.emit(config.category, type, data, [])
      end
    end

    :ok
  rescue
    # A telemetry handler must never crash (telemetry would detach it).
    _ -> :ok
  end

  defp sampled?(rate) when rate >= 1.0, do: true
  defp sampled?(rate) when rate <= 0.0, do: false
  defp sampled?(rate), do: :rand.uniform() <= rate

  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000
end
