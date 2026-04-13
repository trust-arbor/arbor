defmodule Arbor.Orchestrator.JobRegistry do
  @moduledoc """
  Tracks running and recently completed pipeline executions.

  Subscribes to orchestrator EventEmitter events and maintains state in
  BufferedStore (ETS reads + optional durable backend). All reads are direct
  ETS lookups for performance. On restart, previously persisted entries are
  reloaded from the backend, enabling crash recovery of interrupted pipelines.
  """

  use GenServer

  @store_name :arbor_orchestrator_jobs

  defmodule Entry do
    @moduledoc """
    Represents a pipeline execution entry in the job registry.
    """
    @derive Jason.Encoder
    defstruct [
      :pipeline_id,
      :run_id,
      :graph_id,
      :graph_hash,
      :dot_source_path,
      :logs_root,
      :started_at,
      :current_node,
      :completed_count,
      :total_nodes,
      :status,
      :node_durations,
      :finished_at,
      :duration_ms,
      :failure_reason,
      :source_node,
      # Phase 5: Distributed pipeline durability
      :owner_node,
      :origin_trust_zone,
      :last_heartbeat,
      # The PID of the process that spawned this pipeline (e.g., the Session
      # GenServer). Used by RecoveryCoordinator to check process-level
      # liveness — the BEAM node may stay connected even after the spawning
      # process dies (agent stopped, crash without cleanup).
      :spawning_pid
    ]
  end

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns list of currently running pipelines.
  """
  def list_active do
    list_by_status([:running])
  end

  @doc """
  Returns list of interrupted (crash-orphaned) pipelines that may be resumable.
  """
  def list_interrupted do
    list_by_status([:interrupted])
  end

  @doc """
  Returns list of recently completed or failed pipelines, newest first.
  """
  def list_recent(limit \\ 20) do
    store_list()
    |> Enum.filter(fn %Entry{status: status} -> status in [:completed, :failed] end)
    |> Enum.sort_by(
      fn %Entry{finished_at: finished_at} -> finished_at end,
      {:desc, DateTime}
    )
    |> Enum.take(limit)
  end

  @doc """
  Returns a specific pipeline entry by ID, or nil if not found.
  """
  def get(pipeline_id) do
    case Arbor.Persistence.BufferedStore.get(pipeline_id, name: @store_name) do
      {:ok, %Entry{} = entry} -> entry
      {:ok, data} when is_map(data) -> entry_from_map(data)
      _ -> nil
    end
  end

  @doc """
  Marks a running entry as interrupted (for crash recovery).
  Called by RecoveryCoordinator on boot for orphaned :running entries.
  """
  def mark_interrupted(pipeline_id) do
    GenServer.call(__MODULE__, {:mark_interrupted, pipeline_id})
  end

  @doc """
  Marks an entry as abandoned (will not be recovered).
  """
  def mark_abandoned(pipeline_id) do
    GenServer.call(__MODULE__, {:mark_abandoned, pipeline_id})
  end

  @doc """
  Marks an entry as recovering (resume in progress).
  """
  def mark_recovering(pipeline_id) do
    GenServer.call(__MODULE__, {:mark_recovering, pipeline_id})
  end

  @doc """
  Updates the heartbeat timestamp for a running pipeline.
  Called periodically by the engine loop to signal liveness.
  """
  def touch_heartbeat(pipeline_id) do
    GenServer.cast(__MODULE__, {:touch_heartbeat, pipeline_id})
  end

  @doc """
  Returns pipelines whose heartbeat has gone stale (older than `max_age_ms`).
  Used by RecoveryCoordinator to detect hung pipelines.
  """
  def list_stale_heartbeats(max_age_ms \\ 90_000) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_ms, :millisecond)

    store_list()
    |> Enum.filter(fn entry ->
      entry.status == :running and
        entry.last_heartbeat != nil and
        DateTime.compare(entry.last_heartbeat, cutoff) == :lt
    end)
  end

  @doc """
  Returns all entries owned by a specific node.
  Used by RecoveryCoordinator to find orphaned pipelines after nodedown.
  """
  def list_by_owner(node_name) do
    node_str = to_string(node_name)

    store_list()
    |> Enum.filter(fn entry ->
      entry.status in [:running, :interrupted] and
        to_string(entry.owner_node) == node_str
    end)
  end

  @doc """
  Attempts to atomically claim an interrupted pipeline for recovery.
  Returns {:ok, entry} if this node wins the claim, {:error, reason} otherwise.
  On shared Postgres, relies on GenServer serialization + owner_node check.
  """
  def claim_for_recovery(pipeline_id, claiming_node \\ Kernel.node()) do
    GenServer.call(__MODULE__, {:claim_for_recovery, pipeline_id, claiming_node})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    # Start BufferedStore for durable job tracking
    backend = Keyword.get(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])

    store_opts =
      [name: @store_name, collection: "orchestrator_jobs"] ++
        if backend do
          [backend: backend, backend_opts: backend_opts]
        else
          []
        end

    case Arbor.Persistence.BufferedStore.start_link(store_opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Mark any :running entries from a previous life as :interrupted
    mark_stale_running_entries()

    # NOTE: EventEmitter subscription REMOVED as part of the Engine lifecycle
    # redesign. Pipeline tracking is now owned by the Engine process via
    # RunState CRC core + ETS table. The JobRegistry retains its BufferedStore
    # for historical data and recovery operations, but no longer receives
    # pipeline lifecycle events. New pipeline runs are tracked in the
    # :arbor_pipeline_runs ETS table, queried via PipelineStatus Facade.
    #
    # See .arbor/roadmap/2-planned/engine-lifecycle-redesign.md

    {:ok, %{}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:mark_interrupted, pipeline_id}, _from, state) do
    result =
      update_entry(pipeline_id, fn entry ->
        %{entry | status: :interrupted, owner_node: nil}
      end)

    {:reply, result, state}
  end

  def handle_call({:mark_abandoned, pipeline_id}, _from, state) do
    result =
      update_entry(pipeline_id, fn entry ->
        %{entry | status: :abandoned, finished_at: DateTime.utc_now()}
      end)

    {:reply, result, state}
  end

  def handle_call({:mark_recovering, pipeline_id}, _from, state) do
    result = update_entry(pipeline_id, fn entry -> %{entry | status: :recovering} end)
    {:reply, result, state}
  end

  def handle_call({:claim_for_recovery, pipeline_id, claiming_node}, _from, state) do
    result =
      case Arbor.Persistence.BufferedStore.get(pipeline_id, name: @store_name) do
        {:ok, %Entry{status: :interrupted, owner_node: nil} = entry} ->
          updated = %{entry | owner_node: claiming_node, status: :recovering}
          put_entry(pipeline_id, updated)
          {:ok, updated}

        {:ok, %Entry{status: :interrupted, owner_node: owner} = entry}
        when owner == claiming_node ->
          updated = %{entry | status: :recovering}
          put_entry(pipeline_id, updated)
          {:ok, updated}

        {:ok, %Entry{status: :interrupted}} ->
          {:error, :already_claimed}

        {:ok, %Entry{status: status}} ->
          {:error, {:invalid_status, status}}

        {:ok, data} when is_map(data) ->
          entry = entry_from_map(data)

          if entry.status == :interrupted do
            updated = %{entry | owner_node: claiming_node, status: :recovering}
            put_entry(pipeline_id, updated)
            {:ok, updated}
          else
            {:error, {:invalid_status, entry.status}}
          end

        _ ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:touch_heartbeat, pipeline_id}, state) do
    update_entry(pipeline_id, fn entry ->
      %{entry | last_heartbeat: DateTime.utc_now()}
    end)

    {:noreply, state}
  end

  # Private helpers

  # NOTE: find_entry_key/1, entry_exists?/1, find_by_graph_id/1, and
  # determine_pipeline_id/1 were
  # removed as part of the Engine lifecycle redesign. These functions were
  # used by the event handlers (also removed) to correlate incoming events
  # with stored entries. The entry_exists?/1 function had a contract mismatch
  # bug (expected {:ok, bool} from BufferedStore but got raw bool) that caused
  # ALL event-based updates to fail silently for months.
  #
  # Pipeline tracking is now handled by the Engine's RunState CRC core
  # writing directly to the :arbor_pipeline_runs ETS table, queried via
  # the PipelineStatus Facade. No event correlation needed.

  defp store_list do
    case Arbor.Persistence.BufferedStore.list(name: @store_name) do
      {:ok, keys} ->
        keys
        |> Enum.map(fn key ->
          case Arbor.Persistence.BufferedStore.get(key, name: @store_name) do
            {:ok, %Entry{} = entry} -> entry
            {:ok, data} when is_map(data) -> entry_from_map(data)
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp list_by_status(statuses) do
    store_list()
    |> Enum.filter(fn %Entry{status: status} -> status in statuses end)
  end

  defp put_entry(pipeline_id, entry) do
    Arbor.Persistence.BufferedStore.put(pipeline_id, entry, name: @store_name)
  rescue
    _ -> :ok
  end

  defp update_entry(pipeline_id, update_fn) do
    case Arbor.Persistence.BufferedStore.get(pipeline_id, name: @store_name) do
      {:ok, %Entry{} = entry} ->
        updated = update_fn.(entry)
        put_entry(pipeline_id, updated)

      {:ok, data} when is_map(data) ->
        entry = entry_from_map(data)
        updated = update_fn.(entry)
        put_entry(pipeline_id, updated)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp mark_stale_running_entries do
    list_by_status([:running])
    |> Enum.each(fn entry ->
      key = entry.pipeline_id || entry.run_id

      if key do
        updated = %{entry | status: :interrupted, owner_node: nil}
        put_entry(key, updated)
      end
    end)
  rescue
    _ -> :ok
  end

  # Reconstruct an Entry from a plain map (loaded from backend)
  defp entry_from_map(data) when is_map(data) do
    %Entry{
      pipeline_id: data["pipeline_id"] || data[:pipeline_id],
      run_id: data["run_id"] || data[:run_id],
      graph_id: data["graph_id"] || data[:graph_id],
      graph_hash: data["graph_hash"] || data[:graph_hash],
      dot_source_path: data["dot_source_path"] || data[:dot_source_path],
      logs_root: data["logs_root"] || data[:logs_root],
      started_at: parse_datetime(data["started_at"] || data[:started_at]),
      current_node: data["current_node"] || data[:current_node],
      completed_count: data["completed_count"] || data[:completed_count] || 0,
      total_nodes: data["total_nodes"] || data[:total_nodes] || 0,
      status: parse_status(data["status"] || data[:status]),
      node_durations: data["node_durations"] || data[:node_durations] || %{},
      finished_at: parse_datetime(data["finished_at"] || data[:finished_at]),
      duration_ms: data["duration_ms"] || data[:duration_ms],
      failure_reason: data["failure_reason"] || data[:failure_reason],
      source_node: data["source_node"] || data[:source_node],
      owner_node: parse_node_name(data["owner_node"] || data[:owner_node]),
      origin_trust_zone: data["origin_trust_zone"] || data[:origin_trust_zone],
      last_heartbeat: parse_datetime(data["last_heartbeat"] || data[:last_heartbeat])
    }
  end

  defp parse_node_name(nil), do: nil
  defp parse_node_name(n) when is_atom(n), do: n

  defp parse_node_name(n) when is_binary(n) do
    String.to_existing_atom(n)
  rescue
    ArgumentError -> String.to_atom(n)
  end

  defp parse_status(s) when is_atom(s), do: s
  defp parse_status("running"), do: :running
  defp parse_status("completed"), do: :completed
  defp parse_status("failed"), do: :failed
  defp parse_status("interrupted"), do: :interrupted
  defp parse_status("abandoned"), do: :abandoned
  defp parse_status("recovering"), do: :recovering
  defp parse_status(_), do: :unknown

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
