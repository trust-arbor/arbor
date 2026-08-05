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

  alias Arbor.Memory.GoalStore

  require Logger

  alias Arbor.Memory.KnowledgeGraphStore

  @working_memory_ets :arbor_working_memory
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
    "memory.goal_abandoned",
    "memory.goal_deleted",
    "memory.goals_cleared"
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
    _ ->
      Logger.warning("[DistributedSync] Error handling signal #{inspect(signal.type)}")
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
       when type in [
              :goal_created,
              :goal_progress,
              :goal_achieved,
              :goal_abandoned,
              :goal_deleted
            ] do
    reload_goal(agent_id, goal_id)
  end

  defp handle_remote_signal(:goals_cleared, %{agent_id: agent_id}) do
    reload_agent_goals(agent_id)
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
    case KnowledgeGraphStore.converge_projection(agent_id) do
      :ok ->
        Logger.debug("[DistributedSync] Converged knowledge graph for #{agent_id}")

      {:error, reason} ->
        Logger.warning(
          "[DistributedSync] Knowledge graph convergence failed for #{agent_id}: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp reload_goal(agent_id, goal_id) do
    case GoalStore.reload_goal_from_durable(agent_id, goal_id) do
      :ok ->
        Logger.debug("[DistributedSync] Reloaded goal #{goal_id} for #{agent_id}")

      {:error, _reason} ->
        Logger.warning("[DistributedSync] Failed to reload goal #{goal_id} for #{agent_id}")
    end

    :ok
  rescue
    _ ->
      Logger.warning("[DistributedSync] Failed to reload goal #{goal_id}")
      :ok
  end

  defp reload_agent_goals(agent_id) do
    case GoalStore.reload_for_agent(agent_id) do
      :ok ->
        Logger.debug("[DistributedSync] Reloaded goals for #{agent_id}")

      {:error, _reason} ->
        Logger.warning("[DistributedSync] Failed to reload goals for #{agent_id}")
    end

    :ok
  rescue
    _ ->
      Logger.warning("[DistributedSync] Failed to reload goals")
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

        Logger.info(
          "[DistributedSync] Subscribed to #{length(@subscribed_types)} memory signal types"
        )
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
end
