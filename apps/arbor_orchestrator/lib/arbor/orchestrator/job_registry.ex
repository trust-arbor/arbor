defmodule Arbor.Orchestrator.JobRegistry do
  @moduledoc """
  Tracks running and recently completed pipeline executions.

  Subscribes to orchestrator EventEmitter events and maintains state in a
  public ETS table. All reads are direct ETS lookups for performance.
  """

  use GenServer

  alias Arbor.Orchestrator.EventEmitter

  @table_name :arbor_orchestrator_jobs
  @max_history 50

  defmodule Entry do
    @moduledoc """
    Represents a pipeline execution entry in the job registry.
    """
    defstruct [
      :pipeline_id,
      :graph_id,
      :started_at,
      :current_node,
      :completed_count,
      :total_nodes,
      :status,
      :node_durations,
      :finished_at,
      :duration_ms,
      :failure_reason
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
    with_table(fn ->
      @table_name
      |> :ets.tab2list()
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(fn %Entry{status: status} -> status == :running end)
    end)
  end

  @doc """
  Returns list of recently completed or failed pipelines, newest first.
  """
  def list_recent(limit \\ 20) do
    with_table(fn ->
      @table_name
      |> :ets.tab2list()
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(fn %Entry{status: status} -> status in [:completed, :failed] end)
      |> Enum.sort_by(fn %Entry{finished_at: finished_at} -> finished_at end, {:desc, DateTime})
      |> Enum.take(limit)
    end)
  end

  @doc """
  Returns a specific pipeline entry by ID, or nil if not found.
  """
  def get(pipeline_id) do
    with_table(fn ->
      case :ets.lookup(@table_name, pipeline_id) do
        [{^pipeline_id, entry}] -> entry
        [] -> nil
      end
    end)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create public ETS table
    :ets.new(@table_name, [:set, :public, :named_table, keypos: 1])

    # Subscribe to all pipeline events
    {:ok, _} = EventEmitter.subscribe(:all)

    {:ok, %{}}
  end

  @impl true
  def handle_info({:pipeline_event, %{type: :pipeline_started} = event}, state) do
    pipeline_id = determine_pipeline_id(event)

    entry = %Entry{
      pipeline_id: pipeline_id,
      graph_id: Map.get(event, :graph_id),
      started_at: DateTime.utc_now(),
      current_node: nil,
      completed_count: 0,
      total_nodes: Map.get(event, :node_count, 0),
      status: :running,
      node_durations: %{},
      finished_at: nil,
      duration_ms: nil,
      failure_reason: nil
    }

    insert_entry(pipeline_id, entry)
    {:noreply, state}
  end

  def handle_info({:pipeline_event, %{type: :stage_started, node_id: node_id} = event}, state) do
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
              node_durations: Map.put(entry.node_durations, node_id, duration_ms)
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
          %{entry | status: :completed, finished_at: DateTime.utc_now(), duration_ms: duration_ms}
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

  # Private helpers

  defp determine_pipeline_id(event) do
    case Map.get(event, :pipeline_id) do
      nil -> Map.get(event, :graph_id)
      :all -> Map.get(event, :graph_id)
      id -> id
    end
  end

  defp find_entry_key(event) do
    with_table(fn ->
      # Try to find by pipeline_id from event first
      pipeline_id = Map.get(event, :pipeline_id)
      graph_id = Map.get(event, :graph_id)

      cond do
        pipeline_id && pipeline_id != :all && entry_exists?(pipeline_id) ->
          pipeline_id

        graph_id && entry_exists?(graph_id) ->
          graph_id

        true ->
          # Scan table for matching graph_id
          find_by_graph_id(graph_id)
      end
    end)
  end

  defp entry_exists?(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, _}] -> true
      [] -> false
    end
  end

  defp find_by_graph_id(nil), do: nil

  defp find_by_graph_id(graph_id) do
    @table_name
    |> :ets.tab2list()
    |> Enum.find_value(fn {id, %Entry{graph_id: gid}} ->
      if gid == graph_id, do: id
    end)
  end

  defp with_table(fun) do
    if :ets.whereis(@table_name) != :undefined do
      try do
        fun.()
      rescue
        ArgumentError -> nil
      end
    else
      nil
    end
  end

  defp insert_entry(pipeline_id, entry) do
    if :ets.whereis(@table_name) != :undefined do
      try do
        :ets.insert(@table_name, {pipeline_id, entry})
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp update_entry(pipeline_id, update_fn) do
    if :ets.whereis(@table_name) != :undefined do
      try do
        case :ets.lookup(@table_name, pipeline_id) do
          [{^pipeline_id, entry}] ->
            updated_entry = update_fn.(entry)
            :ets.insert(@table_name, {pipeline_id, updated_entry})

          [] ->
            :ok
        end
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp cleanup_history do
    if :ets.whereis(@table_name) != :undefined do
      try do
        all_entries = :ets.tab2list(@table_name)

        finished_entries =
          all_entries
          |> Enum.map(fn {_id, entry} -> entry end)
          |> Enum.filter(fn %Entry{status: status} -> status in [:completed, :failed] end)
          |> Enum.sort_by(
            fn %Entry{finished_at: finished_at} -> finished_at end,
            {:desc, DateTime}
          )

        if length(finished_entries) > @max_history do
          to_delete = Enum.drop(finished_entries, @max_history)

          Enum.each(to_delete, fn %Entry{pipeline_id: id} ->
            :ets.delete(@table_name, id)
          end)
        end
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
