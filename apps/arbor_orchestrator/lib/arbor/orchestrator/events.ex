defmodule Arbor.Orchestrator.Events do
  @moduledoc """
  Durable event persistence for pipeline execution using the dual-emit pattern.

  Every engine event is:
  1. Appended to the EventLog (durable, queryable via Historian)
  2. Emitted as a signal (real-time, for dashboards and subscribers)

  Follows the same pattern used by `Arbor.Security.Events`,
  `Arbor.Memory.Events`, and `Arbor.Consensus.EventEmitter`.

  ## Stream ID Convention

      "orchestrator:pipeline:{run_id}"

  Each pipeline run gets its own event stream, queryable by run_id.

  ## Configuration

      config :arbor_orchestrator,
        event_log_name: :orchestrator_events,
        event_log_backend: Arbor.Persistence.EventLog.ETS
  """

  require Logger

  alias Arbor.Persistence.Event, as: PersistenceEvent

  @event_log_name :orchestrator_events
  @event_log_backend Arbor.Persistence.EventLog.ETS

  # --- Public API ---

  @doc """
  Dual-emit a pipeline engine event.

  Persists to EventLog and emits on the `:orchestrator` signal category.
  Gracefully handles unavailability of either subsystem.
  """
  @spec dual_emit(map(), keyword()) :: :ok
  def dual_emit(%{type: event_type} = event, opts \\ []) do
    run_id = Keyword.get(opts, :run_id)
    stream_id = stream_id(run_id)

    # Persist to EventLog
    persist_event(stream_id, event_type, event, opts)

    # Emit on signal bus
    emit_signal(event_type, event)

    :ok
  end

  @doc """
  Query pipeline events for a specific run.
  """
  @spec read_run_events(String.t(), keyword()) :: {:ok, [PersistenceEvent.t()]} | {:error, term()}
  def read_run_events(run_id, opts \\ []) do
    stream_id = stream_id(run_id)

    Arbor.Persistence.read_stream(
      event_log_name(),
      event_log_backend(),
      stream_id,
      opts
    )
  end

  @doc "Returns the stream ID for a given pipeline run."
  @spec stream_id(String.t() | nil) :: String.t()
  def stream_id(nil), do: "orchestrator:pipeline:unknown"
  def stream_id(run_id), do: "orchestrator:pipeline:#{run_id}"

  # --- Private ---

  defp persist_event(stream_id, event_type, event_data, opts) do
    if Process.whereis(event_log_name()) do
      event =
        PersistenceEvent.new(
          stream_id,
          to_string(event_type),
          sanitize_data(event_data),
          metadata: build_metadata(opts),
          correlation_id: Keyword.get(opts, :run_id),
          timestamp: Map.get(event_data, :timestamp, DateTime.utc_now())
        )

      Arbor.Persistence.append(
        event_log_name(),
        event_log_backend(),
        stream_id,
        event
      )
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("[Orchestrator.Events] EventLog persistence failed: #{Exception.message(e)}")
      {:error, :persistence_unavailable}
  catch
    :exit, reason ->
      Logger.warning("[Orchestrator.Events] EventLog persistence crashed: #{inspect(reason)}")
      {:error, :persistence_unavailable}
  end

  defp emit_signal(event_type, event_data) do
    Arbor.Signals.emit(
      :orchestrator,
      event_type,
      Map.put(event_data, :permanent, true)
    )
  rescue
    _ -> :ok
  end

  defp build_metadata(opts) do
    %{
      source_node: node(),
      agent_id: Keyword.get(opts, :agent_id),
      pipeline_id: Keyword.get(opts, :pipeline_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Strip non-serializable values from event data before persistence.
  # Engine events are plain maps, but some may contain structs or pids.
  defp sanitize_data(event) when is_map(event) do
    event
    |> Map.drop([:timestamp])
    |> Map.reject(fn {_k, v} -> is_pid(v) or is_reference(v) or is_function(v) end)
  end

  defp event_log_name do
    Application.get_env(:arbor_orchestrator, :event_log_name, @event_log_name)
  end

  defp event_log_backend do
    Application.get_env(:arbor_orchestrator, :event_log_backend, @event_log_backend)
  end
end
