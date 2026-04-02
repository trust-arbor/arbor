defmodule Arbor.Memory.DistributedSync do
  @moduledoc """
  Cross-node cache invalidation for memory ETS tables.

  Subscribes to cluster-scoped memory signals and invalidates local ETS
  entries when remote nodes write or delete memory data. Each node independently
  rebuilds from the shared Postgres backend on startup; this GenServer provides
  near-real-time cache coherence during runtime.

  Handles three ETS tables:
  - `:arbor_working_memory` — working memory per agent
  - `:arbor_memory_graphs` — knowledge graph per agent
  - `:arbor_memory_goals` — goals per agent (keyed `{agent_id, goal_id}`)

  Signals from the local node are ignored (origin_node filtering).
  """

  use GenServer

  require Logger

  @working_memory_ets :arbor_working_memory
  @graph_ets :arbor_memory_graphs
  @goals_ets :arbor_memory_goals

  # Signal types we subscribe to and their categories
  @subscribed_types [
    # Working memory
    "memory.working_memory_saved",
    # Knowledge graph
    "memory.knowledge_added",
    "memory.knowledge_linked",
    # Goals
    "memory.goal_created",
    "memory.goal_progress",
    "memory.goal_achieved",
    "memory.goal_abandoned"
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    subscribe_to_distributed_signals()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:signal_received, signal}, state) do
    handle_distributed_signal(signal, state)
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Signal Handling
  # ============================================================================

  defp handle_distributed_signal(%{data: %{origin_node: origin}} = signal, state)
       when origin == node() do
    # Ignore signals from our own node — we already have the state
    Logger.debug("[DistributedSync] Ignoring self-signal: #{signal.type}")
    {:noreply, state}
  end

  defp handle_distributed_signal(%{type: type, data: data} = signal, state) do
    origin = Map.get(data, :origin_node, :unknown)
    Logger.debug("[DistributedSync] Remote signal from #{origin}: #{type}")

    handle_remote_signal(type, data)
    {:noreply, state}
  rescue
    e ->
      Logger.warning("[DistributedSync] Error handling signal #{inspect(signal.type)}: #{inspect(e)}")
      {:noreply, state}
  end

  # Working memory — invalidate and reload from Postgres
  defp handle_remote_signal(:working_memory_saved, %{agent_id: agent_id}) do
    invalidate_working_memory(agent_id)
  end

  # Knowledge graph — invalidate and reload from Postgres
  defp handle_remote_signal(type, %{agent_id: agent_id})
       when type in [:knowledge_added, :knowledge_linked] do
    invalidate_knowledge_graph(agent_id)
  end

  # Goals — reload specific goal from Postgres
  defp handle_remote_signal(type, %{agent_id: agent_id, goal_id: goal_id})
       when type in [:goal_created, :goal_progress, :goal_achieved, :goal_abandoned] do
    reload_goal(agent_id, goal_id)
  end

  defp handle_remote_signal(type, _data) do
    Logger.debug("[DistributedSync] Unhandled signal type: #{type}")
    :ok
  end

  # ============================================================================
  # ETS Invalidation
  # ============================================================================

  defp invalidate_working_memory(agent_id) do
    if ets_exists?(@working_memory_ets) do
      # Delete the cached version — next load_working_memory will reload from Postgres
      :ets.delete(@working_memory_ets, agent_id)
      Logger.debug("[DistributedSync] Invalidated working memory for #{agent_id}")
    end

    :ok
  end

  defp invalidate_knowledge_graph(agent_id) do
    if ets_exists?(@graph_ets) do
      # Delete the cached graph — next get_graph will miss and trigger reload
      :ets.delete(@graph_ets, agent_id)
      Logger.debug("[DistributedSync] Invalidated knowledge graph for #{agent_id}")
    end

    :ok
  end

  defp reload_goal(agent_id, goal_id) do
    if ets_exists?(@goals_ets) do
      # Reload this specific goal from Postgres via GoalStore
      # GoalStore.reload_for_agent loads all goals for the agent,
      # but we only need one. For now, do a targeted reload.
      memory_store = Arbor.Memory.MemoryStore

      if memory_store.available?() do
        key = "#{agent_id}:#{goal_id}"

        case memory_store.load("goals", key) do
          {:ok, goal_map} when is_map(goal_map) ->
            goal = goal_from_map(goal_map)
            :ets.insert(@goals_ets, {{agent_id, goal.id}, goal})
            Logger.debug("[DistributedSync] Reloaded goal #{goal_id} for #{agent_id}")

          _ ->
            # Goal may have been deleted — remove from ETS
            :ets.delete(@goals_ets, {agent_id, goal_id})
            Logger.debug("[DistributedSync] Removed goal #{goal_id} for #{agent_id}")
        end
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("[DistributedSync] Failed to reload goal #{goal_id}: #{inspect(e)}")
      :ok
  end

  # ============================================================================
  # Signal Subscription
  # ============================================================================

  defp subscribe_to_distributed_signals do
    if distributed_signals_enabled?() do
      bus = Arbor.Signals.Bus

      if Code.ensure_loaded?(bus) and Process.whereis(bus) do
        me = self()

        for pattern <- @subscribed_types do
          Arbor.Signals.subscribe(pattern, fn signal ->
            send(me, {:signal_received, signal})
            :ok
          end)
        end

        Logger.info("[DistributedSync] Subscribed to #{length(@subscribed_types)} memory signal types")
      end
    end

    :ok
  catch
    kind, reason ->
      Logger.debug("[DistributedSync] signal subscription failed: #{kind} #{inspect(reason)}")
      :ok
  end

  defp distributed_signals_enabled? do
    Application.get_env(:arbor_memory, :distributed_signals, true)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp ets_exists?(table) do
    :ets.whereis(table) != :undefined
  rescue
    _ -> false
  end

  # Goal deserialization — mirrors GoalStore.goal_from_map/1
  defp goal_from_map(map) do
    alias Arbor.Contracts.Memory.Goal

    map = atomize_keys(map)

    %Goal{
      id: map[:id],
      description: map[:description],
      type: safe_atom(map[:type], :achieve),
      status: safe_atom(map[:status], :active),
      priority: map[:priority] || 50,
      parent_id: map[:parent_id],
      progress: map[:progress] || 0.0,
      created_at: parse_datetime(map[:created_at]),
      achieved_at: parse_datetime(map[:achieved_at]),
      deadline: parse_datetime(map[:deadline]),
      success_criteria: map[:success_criteria],
      notes: map[:notes] || [],
      assigned_by: safe_atom(map[:assigned_by], nil),
      metadata: map[:metadata] || %{}
    }
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  defp safe_atom(val, _default) when is_atom(val), do: val

  defp safe_atom(val, default) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError -> default
  end

  defp safe_atom(_, default), do: default

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
