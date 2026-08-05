defmodule Arbor.Memory.Consolidation do
  @moduledoc """
  Memory maintenance: decay, reinforcement, pruning, archiving.

  Consolidation is a pure-function module that operates on KnowledgeGraph.
  It does NOT start a GenServer — it's called by Lifecycle or a future scheduler.

  ## Process

  A consolidation cycle consists of:

  1. **Decay** — Reduce relevance of all non-pinned nodes
  2. **Reinforce** — Boost recently-accessed nodes (based on last_accessed)
  3. **Prune** — Remove nodes below threshold while creating a labelled archive outbox
  4. **Quota check** — Evict lowest-relevance nodes if over type quotas
  5. **Drain** — Archive committed outbox entries idempotently, then acknowledge them

  ## Design Decisions

  - **Relationships don't decay** — This module only operates on KnowledgeGraph nodes.
    Relationships are permanent fixtures stored in RelationshipStore.
  - **Durable state before effects** — The graph mutation and exact labelled archive
    outbox commit atomically. EventLog archival happens only after that commit.
  - **Pure transition plus authority shell** — `consolidate/3` previews the pure
    transition; agent-level functions use `KnowledgeGraphStore` typed operations.

  ## Usage

      # Check if consolidation is needed
      if Consolidation.should_consolidate?(graph) do
        # Run one consolidation cycle
        {:ok, new_graph, metrics} = Consolidation.consolidate(agent_id, graph)
      end
  """

  alias Arbor.Memory.{Events, GraphOps, KnowledgeGraph, KnowledgeGraphStore, Signals}
  alias Arbor.Memory.KnowledgeGraph.{Codec, Maintenance}

  require Logger

  @default_prune_threshold 0.1
  @default_min_interval_minutes 60

  # ============================================================================
  # Main Consolidation Function
  # ============================================================================

  @doc """
  Run one consolidation cycle for an agent's knowledge graph.

  ## Steps

  1. Apply decay to all non-pinned nodes
  2. Reinforce recently-accessed nodes
  3. Build labelled archive effects for nodes below threshold
  4. Prune those nodes from the returned graph
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

    with {:ok, updated, result} <- Maintenance.run(graph, :enhanced, opts, DateTime.utc_now()) do
      metrics =
        Map.put(result.metrics, :duration_ms, System.monotonic_time(:millisecond) - start_time)

      Logger.debug(
        "Consolidation completed for #{agent_id}: " <>
          "decayed=#{metrics.decayed_count}, reinforced=#{metrics.reinforced_count}, " <>
          "pruned=#{metrics.pruned_count}, evicted=#{metrics.evicted_count}"
      )

      {:ok, updated, metrics}
    end
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

  - `:size_threshold` - Consolidate if node count reaches 75% of the strict content capacity
  - `:min_interval_minutes` - Minimum minutes between consolidations (default: 60)
  - `:last_consolidation` - DateTime of last consolidation (default: nil)
  """
  @spec should_consolidate?(KnowledgeGraph.t(), keyword()) :: boolean()
  def should_consolidate?(graph, opts \\ []) do
    size_threshold = Keyword.get(opts, :size_threshold, default_size_threshold())
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

    with :ok <- drain_prior_effect(agent_id),
         {operation_id, maintenance_opts} <- maintenance_request(opts, "basic"),
         {:ok, _graph, effect} <-
           reconcile_maintenance(agent_id, operation_id, :basic, maintenance_opts),
         {:ok, drain_status} <- drain_and_ack(agent_id, effect),
         {:ok, graph} <- KnowledgeGraphStore.get_graph(agent_id) do
      metrics = with_duration(effect.metrics, start_time)
      maybe_emit_completion(agent_id, graph, metrics, drain_status, :basic)
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
    start_time = System.monotonic_time(:millisecond)

    with :ok <- drain_prior_effect(agent_id),
         {operation_id, maintenance_opts} <- maintenance_request(opts, "enhanced"),
         {:ok, _graph, effect} <-
           reconcile_maintenance(agent_id, operation_id, :enhanced, maintenance_opts),
         {:ok, drain_status} <- drain_and_ack(agent_id, effect),
         {:ok, graph} <- KnowledgeGraphStore.get_graph(agent_id) do
      metrics = with_duration(effect.metrics, start_time)
      maybe_emit_completion(agent_id, graph, metrics, drain_status, :enhanced)
      {:ok, graph, metrics}
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

  defp drain_prior_effect(agent_id) do
    case KnowledgeGraphStore.pending_maintenance_effect(agent_id) do
      {:ok, nil} -> :ok
      {:ok, effect} -> drain_and_ack(agent_id, effect) |> normalize_prior_drain(agent_id, effect)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_prior_drain({:ok, status}, agent_id, effect) do
    maybe_emit_completion(agent_id, nil, effect.metrics, status, effect.mode)
    :ok
  end

  defp normalize_prior_drain({:error, _reason} = error, _agent_id, _effect), do: error

  defp reconcile_maintenance(agent_id, operation_id, mode, opts) do
    case KnowledgeGraphStore.consolidate(agent_id, operation_id, mode, opts) do
      {:error, :outcome_unknown} ->
        KnowledgeGraphStore.consolidate(agent_id, operation_id, mode, opts)

      result ->
        result
    end
  end

  defp drain_and_ack(_agent_id, %{drained: true}), do: {:ok, :already_drained}

  defp drain_and_ack(agent_id, effect) do
    with :ok <- drain_archive_entries(agent_id, effect),
         :ok <- reconcile_ack(agent_id, effect.operation_id) do
      {:ok, :drained_now}
    end
  end

  defp drain_archive_entries(agent_id, effect) do
    Enum.reduce_while(effect.archive_entries, :ok, fn entry, :ok ->
      case Events.archive_knowledge_once(agent_id, entry, effect.occurred_at) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reconcile_ack(agent_id, operation_id) do
    case KnowledgeGraphStore.acknowledge_maintenance_effect(agent_id, operation_id) do
      {:error, :outcome_unknown} ->
        KnowledgeGraphStore.acknowledge_maintenance_effect(agent_id, operation_id)

      result ->
        result
    end
  end

  defp maybe_emit_completion(_agent_id, _graph, _metrics, :already_drained, _mode), do: :ok

  defp maybe_emit_completion(agent_id, graph, metrics, :drained_now, mode) do
    if mode == :basic and graph do
      Signals.emit_knowledge_decayed(agent_id, KnowledgeGraph.stats(graph))
    end

    if metrics.pruned_count > 0 do
      Signals.emit_knowledge_pruned(agent_id, metrics.pruned_count)
    end

    Events.record_consolidation_completed(agent_id, metrics)
    :ok
  end

  defp maintenance_request(opts, mode) do
    {operation_id, maintenance_opts} = Keyword.pop(opts, :operation_id)
    {operation_id || new_operation_id(mode), maintenance_opts}
  end

  defp new_operation_id(mode) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "knowledge_consolidation_#{mode}_#{nonce}"
  end

  defp with_duration(metrics, start_time) do
    Map.put(metrics, :duration_ms, System.monotonic_time(:millisecond) - start_time)
  end

  defp default_size_threshold, do: div(Codec.max_content_items() * 3, 4)

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
