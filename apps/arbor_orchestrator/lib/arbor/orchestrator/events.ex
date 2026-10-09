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

  Historian's `:durable_event_log_target` owns the persistent event target.
  """

  alias Arbor.Orchestrator.JsonSafe
  alias Arbor.Persistence.Event, as: PersistenceEvent

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

    # arbor_signals is a hard dep — durable_emit is always available. It handles
    # signal bus + EventLog + Postgres centrally, so the legacy split
    # persist+emit fallback (and the function_exported? guard around it) is gone.
    Arbor.Signals.durable_emit(:orchestrator, event_type, sanitize_data(event),
      stream_id: stream_id
    )

    :ok
  end

  @doc """
  Query pipeline events for a specific run.

  Reads from Historian's configured durable target, the same target used by
  `dual_emit` through the Signals durable sink.
  """
  @spec read_run_events(String.t(), keyword()) :: {:ok, [PersistenceEvent.t()]} | {:error, term()}
  def read_run_events(run_id, opts \\ []) do
    stream_id = stream_id(run_id)
    Arbor.Historian.read_durable_event_stream(stream_id, opts)
  end

  @doc "Returns the stream ID for a given pipeline run."
  @spec stream_id(String.t() | nil) :: String.t()
  def stream_id(nil), do: "orchestrator:pipeline:unknown"
  def stream_id(run_id), do: "orchestrator:pipeline:#{run_id}"

  # --- Private ---

  # Coerce event data into a JSON-encodable shape before persistence.
  # Engine events are plain maps, but enriched ones (e.g. stage_completed with a
  # node's context_updates) can carry typed structs, pids, tuples — which would
  # raise at the EventLog's Jason.encode / Ecto :map cast. JsonSafe.coerce/1
  # recursively flattens those (lossy is fine — this is an audit record), so the
  # durable persist boundary can never crash the run.
  defp sanitize_data(event) when is_map(event) do
    event
    |> Map.drop([:timestamp])
    |> JsonSafe.coerce()
  end
end
