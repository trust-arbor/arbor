defmodule Arbor.Memory.Consolidation do
  @moduledoc """
  Memory maintenance: decay, reinforcement, pruning, archiving.

  Consolidation is a pure-function module that operates on KnowledgeGraph.
  It does NOT start a GenServer — it's called by Lifecycle or a future scheduler.

  ## Process

  A consolidation cycle consists of:

  1. **Decay** — Reduce relevance of all non-pinned nodes
  2. **Reinforce** — Boost recently-accessed nodes (based on last_accessed)
  3. **Prune** — Remove nodes below threshold (archive to EventLog first)
  4. **Quota check** — Evict lowest-relevance nodes if over type quotas

  ## Design Decisions

  - **Relationships don't decay** — This module only operates on KnowledgeGraph nodes.
    Relationships are permanent fixtures stored in RelationshipStore.
  - **Archive before prune** — Pruned nodes are recorded in EventLog before removal,
    so nothing is silently lost.
  - **Pure functions** — This module has no state. Callers are responsible for
    loading/saving the KnowledgeGraph.

  ## Usage

      # Check if consolidation is needed
      if Consolidation.should_consolidate?(graph) do
        # Run one consolidation cycle
        {:ok, new_graph, metrics} = Consolidation.consolidate(agent_id, graph)
      end
  """

  alias Arbor.Memory.{Events, GraphOps, KnowledgeGraph, Signals}

  require Logger

  @default_reinforce_window_hours 24
  @default_reinforce_boost 0.1
  @default_prune_threshold 0.1
  @default_min_interval_minutes 60
  @default_size_threshold 100

  # ============================================================================
  # Main Consolidation Function
  # ============================================================================

  @doc """
  Run one consolidation cycle for an agent's knowledge graph.

  ## Steps

  1. Apply decay to all non-pinned nodes
  2. Reinforce recently-accessed nodes
  3. Archive nodes below threshold to EventLog
  4. Prune archived nodes from graph
  5. Check type quotas and evict if needed

  ## Options

  - `:prune_threshold` - Relevance below which to prune (default: 0.1)
  - `:reinforce_window_hours` - How recent is "recently accessed" (default: 24)
  - `:reinforce_boost` - How much to boost recently-accessed nodes (default: 0.1)
  - `:archive` - Whether to archive pruned nodes to EventLog (default: true)

  ## Returns

  - `{:ok, new_graph, metrics}` where metrics includes:
    - `:decayed_count` — Nodes that had relevance reduced
    - `:reinforced_count` — Nodes that were boosted
    - `:archived_count` — Nodes archived to EventLog
    - `:pruned_count` — Nodes removed from graph
    - `:evicted_count` — Nodes evicted due to quota
    - `:duration_ms` — How long consolidation took
    - `:total_nodes` — Final node count
    - `:average_relevance` — Final average relevance
  """
  @spec consolidate(String.t(), KnowledgeGraph.t(), keyword()) ::
          {:ok, KnowledgeGraph.t(), map()}
  def consolidate(agent_id, graph, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    prune_threshold = Keyword.get(opts, :prune_threshold, @default_prune_threshold)
    reinforce_window = Keyword.get(opts, :reinforce_window_hours, @default_reinforce_window_hours)
    reinforce_boost = Keyword.get(opts, :reinforce_boost, @default_reinforce_boost)
    should_archive = Keyword.get(opts, :archive, true)

    initial_count = map_size(graph.nodes)

    # Step 1: Apply decay
    decayed_graph = KnowledgeGraph.decay(graph)

    # Step 2: Reinforce recently-accessed nodes
    {reinforced_graph, reinforced_count} =
      reinforce_recent(decayed_graph, reinforce_window, reinforce_boost)

    # Step 3 & 4: Archive and prune low-relevance nodes
    {final_graph, archived_count, pruned_count} =
      archive_and_prune(
        agent_id,
        reinforced_graph,
        prune_threshold,
        should_archive
      )

    # Step 5: Check type quotas
    {quota_graph, evicted_count} = enforce_quotas(agent_id, final_graph, should_archive)

    # Calculate metrics
    duration_ms = System.monotonic_time(:millisecond) - start_time
    final_stats = KnowledgeGraph.stats(quota_graph)

    metrics = %{
      decayed_count: initial_count,
      reinforced_count: reinforced_count,
      archived_count: archived_count,
      pruned_count: pruned_count,
      evicted_count: evicted_count,
      duration_ms: duration_ms,
      total_nodes: final_stats.node_count,
      average_relevance: final_stats.average_relevance
    }

    Logger.debug(
      "Consolidation completed for #{agent_id}: " <>
        "decayed=#{initial_count}, reinforced=#{reinforced_count}, " <>
        "pruned=#{pruned_count}, evicted=#{evicted_count}"
    )

    {:ok, quota_graph, metrics}
  end

  # ============================================================================
  # Check Functions
  # ============================================================================

  @doc """
  Check if consolidation is needed based on time and size.

  Returns `true` if:
  - The graph has more than `size_threshold` nodes, OR
  - It's been more than `min_interval_minutes` since last consolidation

  ## Options

  - `:size_threshold` - Consolidate if node count exceeds this (default: 100)
  - `:min_interval_minutes` - Minimum minutes between consolidations (default: 60)
  - `:last_consolidation` - DateTime of last consolidation (default: nil)
  """
  @spec should_consolidate?(KnowledgeGraph.t(), keyword()) :: boolean()
  def should_consolidate?(graph, opts \\ []) do
    size_threshold = Keyword.get(opts, :size_threshold, @default_size_threshold)
    min_interval = Keyword.get(opts, :min_interval_minutes, @default_min_interval_minutes)
    last_consolidation = Keyword.get(opts, :last_consolidation)

    node_count = map_size(graph.nodes)

    # Size-based trigger
    if node_count >= size_threshold do
      true
    else
      # Time-based trigger
      case last_consolidation do
        nil ->
          # Never consolidated, but also small — don't need to
          false

        %DateTime{} = last ->
          minutes_since = DateTime.diff(DateTime.utc_now(), last, :minute)
          minutes_since >= min_interval
      end
    end
  end

  @doc """
  Get nodes that would be pruned at a given threshold.

  Useful for previewing what consolidation would remove.
  """
  @spec candidates_for_pruning(KnowledgeGraph.t(), float()) :: [map()]
  def candidates_for_pruning(graph, threshold \\ @default_prune_threshold) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      not node.pinned and node.relevance < threshold
    end)
    |> Enum.sort_by(& &1.relevance)
  end

  @doc """
  Get statistics about what consolidation would do without actually doing it.

  Useful for dry-run / preview scenarios.
  """
  @spec preview(KnowledgeGraph.t(), keyword()) :: map()
  def preview(graph, opts \\ []) do
    prune_threshold = Keyword.get(opts, :prune_threshold, @default_prune_threshold)

    # Simulate decay
    decayed = KnowledgeGraph.decay(graph)

    # Count what would be pruned
    would_prune = candidates_for_pruning(decayed, prune_threshold)

    %{
      current_node_count: map_size(graph.nodes),
      would_prune_count: length(would_prune),
      nodes_below_threshold:
        Enum.map(would_prune, fn n ->
          %{id: n.id, type: n.type, relevance: n.relevance}
        end),
      average_relevance_before: avg_relevance(graph),
      average_relevance_after_decay: avg_relevance(decayed)
    }
  end

  # ============================================================================
  # Agent-Level Operations (with graph load/save/signals)
  # ============================================================================

  @doc """
  Run basic consolidation on an agent's knowledge graph.

  Loads the graph, applies decay + prune, saves, and emits signals.
  """
  @spec consolidate_basic(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate_basic(agent_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    Signals.emit_consolidation_started(agent_id)

    with {:ok, graph} <- GraphOps.get_graph(agent_id) do
      # Apply decay
      decayed_graph = KnowledgeGraph.decay(graph)
      decayed_count = map_size(graph.nodes)

      # Prune
      threshold = Keyword.get(opts, :prune_threshold, 0.1)
      {pruned_graph, pruned_count} = KnowledgeGraph.prune(decayed_graph, threshold)

      # Save
      GraphOps.save_graph(agent_id, pruned_graph)

      # Calculate duration
      duration_ms = System.monotonic_time(:millisecond) - start_time

      # Get final stats
      stats = KnowledgeGraph.stats(pruned_graph)

      metrics = %{
        decayed_count: decayed_count,
        pruned_count: pruned_count,
        duration_ms: duration_ms,
        total_nodes: stats.node_count,
        average_relevance: stats.average_relevance
      }

      # Emit signals
      Signals.emit_consolidation_completed(agent_id, metrics)
      Signals.emit_knowledge_decayed(agent_id, stats)

      if pruned_count > 0 do
        Signals.emit_knowledge_pruned(agent_id, pruned_count)
      end

      # Record permanent event
      Events.record_consolidation_completed(agent_id, metrics)

      {:ok, metrics}
    end
  end

  @doc """
  Run enhanced consolidation on an agent's knowledge graph.

  Loads the graph, runs full consolidation (decay + reinforce + archive + prune + quota),
  saves, and emits signals.
  """
  @spec run_enhanced(String.t(), keyword()) ::
          {:ok, KnowledgeGraph.t(), map()} | {:error, term()}
  def run_enhanced(agent_id, opts \\ []) do
    Signals.emit_consolidation_started(agent_id)

    with {:ok, graph} <- GraphOps.get_graph(agent_id),
         {:ok, new_graph, metrics} <- consolidate(agent_id, graph, opts) do
      # Save updated graph
      GraphOps.save_graph(agent_id, new_graph)

      # Emit completion signals
      Signals.emit_consolidation_completed(agent_id, metrics)

      if metrics.pruned_count > 0 do
        Signals.emit_knowledge_pruned(agent_id, metrics.pruned_count)
      end

      # Record permanent event
      Events.record_consolidation_completed(agent_id, metrics)

      {:ok, new_graph, metrics}
    end
  end

  @doc """
  Check if consolidation should run for an agent.
  """
  @spec should_run?(String.t(), keyword()) :: boolean()
  def should_run?(agent_id, opts \\ []) do
    case GraphOps.get_graph(agent_id) do
      {:ok, graph} -> should_consolidate?(graph, opts)
      {:error, _} -> false
    end
  end

  @doc """
  Preview what consolidation would do for an agent without doing it.
  """
  @spec preview_for_agent(String.t(), keyword()) :: map() | {:error, term()}
  def preview_for_agent(agent_id, opts \\ []) do
    case GraphOps.get_graph(agent_id) do
      {:ok, graph} -> preview(graph, opts)
      error -> error
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Reinforce nodes that were accessed within the window
  defp reinforce_recent(graph, window_hours, boost) do
    cutoff = DateTime.add(DateTime.utc_now(), -window_hours, :hour)

    {new_nodes, count} =
      Enum.reduce(graph.nodes, {%{}, 0}, fn {id, node}, {acc, cnt} ->
        if DateTime.compare(node.last_accessed, cutoff) == :gt do
          new_relevance = min(1.0, node.relevance + boost)
          {Map.put(acc, id, %{node | relevance: new_relevance}), cnt + 1}
        else
          {Map.put(acc, id, node), cnt}
        end
      end)

    {%{graph | nodes: new_nodes}, count}
  end

  # Archive nodes to EventLog then prune them
  defp archive_and_prune(agent_id, graph, threshold, should_archive) do
    to_prune = candidates_for_pruning(graph, threshold)

    # Archive to EventLog if requested
    archived_count =
      if should_archive do
        Enum.each(to_prune, fn node ->
          Events.record_knowledge_archived(agent_id, %{
            node_id: node.id,
            type: node.type,
            content: node.content,
            relevance: node.relevance,
            created_at: node.created_at,
            last_accessed: node.last_accessed,
            access_count: node.access_count,
            reason: :low_relevance
          })
        end)

        length(to_prune)
      else
        0
      end

    # Actually prune
    {pruned_graph, pruned_count} = KnowledgeGraph.prune(graph, threshold)

    {pruned_graph, archived_count, pruned_count}
  end

  # Enforce type quotas by evicting lowest-relevance nodes
  defp enforce_quotas(agent_id, graph, should_archive) do
    max_per_type = Map.get(graph.config, :max_nodes_per_type, 500)

    nodes_by_type =
      graph.nodes
      |> Map.values()
      |> Enum.group_by(& &1.type)

    {new_nodes, total_evicted} =
      Enum.reduce(nodes_by_type, {graph.nodes, 0}, fn {_type, nodes}, {acc_nodes, evict_count} ->
        evict_type_quota(nodes, max_per_type, agent_id, should_archive, acc_nodes, evict_count)
      end)

    # Also clean up edges to evicted nodes
    evicted_ids =
      MapSet.difference(
        MapSet.new(Map.keys(graph.nodes)),
        MapSet.new(Map.keys(new_nodes))
      )

    new_edges =
      graph.edges
      |> Enum.reject(fn {source_id, _} -> source_id in evicted_ids end)
      |> Map.new(fn {source_id, edges} ->
        {source_id, Enum.reject(edges, &(&1.target_id in evicted_ids))}
      end)

    {%{graph | nodes: new_nodes, edges: new_edges}, total_evicted}
  end

  defp evict_type_quota(nodes, max_per_type, _agent_id, _should_archive, acc_nodes, evict_count)
       when length(nodes) <= max_per_type do
    {acc_nodes, evict_count}
  end

  defp evict_type_quota(nodes, max_per_type, agent_id, should_archive, acc_nodes, evict_count) do
    sorted = Enum.sort_by(nodes, & &1.relevance)
    to_evict = Enum.take(sorted, length(nodes) - max_per_type)

    maybe_archive_evicted(to_evict, agent_id, should_archive)

    evict_ids = MapSet.new(to_evict, & &1.id)
    remaining = Map.reject(acc_nodes, fn {id, _} -> id in evict_ids end)

    {remaining, evict_count + length(to_evict)}
  end

  defp maybe_archive_evicted(_to_evict, _agent_id, false), do: :ok

  defp maybe_archive_evicted(to_evict, agent_id, true) do
    Enum.each(to_evict, fn node ->
      Events.record_knowledge_archived(agent_id, %{
        node_id: node.id,
        type: node.type,
        content: node.content,
        relevance: node.relevance,
        created_at: node.created_at,
        last_accessed: node.last_accessed,
        access_count: node.access_count,
        reason: :quota_exceeded
      })
    end)
  end

  defp avg_relevance(graph) do
    nodes = Map.values(graph.nodes)

    case nodes do
      [] ->
        0.0

      nodes ->
        total = Enum.sum(Enum.map(nodes, & &1.relevance))
        Float.round(total / length(nodes), 3)
    end
  end
end
