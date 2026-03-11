defmodule Arbor.Orchestrator.JobRegistry do
  @moduledoc """
  Tracks running and recently completed pipeline executions.

  Subscribes to orchestrator EventEmitter events and maintains state in
  BufferedStore (ETS reads + optional durable backend). All reads are direct
  ETS lookups for performance. On restart, previously persisted entries are
  reloaded from the backend, enabling crash recovery of interrupted pipelines.
  """

  use GenServer

  alias Arbor.Orchestrator.EventEmitter

  @store_name :arbor_orchestrator_jobs
  @max_history 50

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
      :source_node
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

    # Subscribe to all pipeline events
    {:ok, _} = EventEmitter.subscribe(:all)

    {:ok, %{}}
  end

  @impl true
  def handle_info({:pipeline_event, %{type: :pipeline_started} = event}, state) do
    pipeline_id = determine_pipeline_id(event)
    run_id = Map.get(event, :run_id)

    entry = %Entry{
      pipeline_id: pipeline_id,
      run_id: run_id,
      graph_id: Map.get(event, :graph_id),
      graph_hash: Map.get(event, :graph_hash),
      dot_source_path: Map.get(event, :dot_source_path),
      logs_root: Map.get(event, :logs_root),
      started_at: DateTime.utc_now(),
      current_node: nil,
      completed_count: 0,
      total_nodes: Map.get(event, :node_count, 0),
      status: :running,
      node_durations: %{},
      finished_at: nil,
      duration_ms: nil,
      failure_reason: nil,
      source_node: Map.get(event, :source_node, Kernel.node())
    }

    put_entry(pipeline_id, entry)
    {:noreply, state}
  end

  def handle_info(
        {:pipeline_event, %{type: :stage_started, node_id: node_id} = event},
        state
      ) do
    case find_entry_key(event) do
      nil ->
        :ok

      pipeline_id ->
        update_entry(pipeline_id, fn entry ->
          %{entry | current_node: node_id}
        end)
    end

    {:noreply, state}
  end

  def handle_info({:pipeline_event, %{type: :stage_completed} = event}, state) do
    case find_entry_key(event) do
      nil ->
        :ok

      pipeline_id ->
        node_id = Map.get(event, :node_id)
        duration_ms = Map.get(event, :duration_ms, 0)

        update_entry(pipeline_id, fn entry ->
          %{
            entry
            | completed_count: entry.completed_count + 1,
              node_durations: Map.put(entry.node_durations || %{}, node_id, duration_ms)
          }
        end)
    end

    {:noreply, state}
  end

  def handle_info({:pipeline_event, %{type: :pipeline_completed} = event}, state) do
    case find_entry_key(event) do
      nil ->
        :ok

      pipeline_id ->
        duration_ms = Map.get(event, :duration_ms)

        update_entry(pipeline_id, fn entry ->
          %{
            entry
            | status: :completed,
              finished_at: DateTime.utc_now(),
              duration_ms: duration_ms
          }
        end)

        cleanup_history()
    end

    {:noreply, state}
  end

  def handle_info({:pipeline_event, %{type: :pipeline_failed} = event}, state) do
    case find_entry_key(event) do
      nil ->
        :ok

      pipeline_id ->
        duration_ms = Map.get(event, :duration_ms)
        failure_reason = Map.get(event, :reason)

        update_entry(pipeline_id, fn entry ->
          %{
            entry
            | status: :failed,
              finished_at: DateTime.utc_now(),
              duration_ms: duration_ms,
              failure_reason: failure_reason
          }
        end)

        cleanup_history()
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:mark_interrupted, pipeline_id}, _from, state) do
    result = update_entry(pipeline_id, fn entry -> %{entry | status: :interrupted} end)
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

  # Private helpers

  defp determine_pipeline_id(event) do
    # Prefer run_id (unique per execution) over pipeline_id or graph_id
    case Map.get(event, :run_id) do
      nil ->
        case Map.get(event, :pipeline_id) do
          nil -> Map.get(event, :graph_id)
          :all -> Map.get(event, :graph_id)
          id -> id
        end

      run_id ->
        run_id
    end
  end

  defp find_entry_key(event) do
    # Try to find by pipeline_id from event first
    pipeline_id = Map.get(event, :pipeline_id)
    graph_id = Map.get(event, :graph_id)

    cond do
      pipeline_id && pipeline_id != :all && entry_exists?(pipeline_id) ->
        pipeline_id

      graph_id && entry_exists?(graph_id) ->
        graph_id

      true ->
        # Scan for matching graph_id
        find_by_graph_id(graph_id)
    end
  end

  defp entry_exists?(key) do
    case Arbor.Persistence.BufferedStore.exists?(key, name: @store_name) do
      {:ok, exists} -> exists
      _ -> false
    end
  end

  defp find_by_graph_id(nil), do: nil

  defp find_by_graph_id(graph_id) do
    store_list()
    |> Enum.find_value(fn entry ->
      if entry.graph_id == graph_id, do: entry.pipeline_id || entry.run_id
    end)
  end

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

  defp cleanup_history do
    finished =
      store_list()
      |> Enum.filter(fn %Entry{status: status} -> status in [:completed, :failed] end)
      |> Enum.sort_by(
        fn %Entry{finished_at: finished_at} -> finished_at end,
        {:desc, DateTime}
      )

    if length(finished) > @max_history do
      to_delete = Enum.drop(finished, @max_history)

      Enum.each(to_delete, fn %Entry{pipeline_id: id, run_id: run_id} ->
        key = id || run_id
        if key, do: Arbor.Persistence.BufferedStore.delete(key, name: @store_name)
      end)
    end
  rescue
    _ -> :ok
  end

  defp mark_stale_running_entries do
    list_by_status([:running])
    |> Enum.each(fn entry ->
      key = entry.pipeline_id || entry.run_id

      if key do
        updated = %{entry | status: :interrupted}
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
      source_node: data["source_node"] || data[:source_node]
    }
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
