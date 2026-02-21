defmodule Arbor.Memory.KnowledgeGraph.DecayEngine do
  @moduledoc """
  Decay, pruning, and archival logic for the knowledge graph.

  Handles time-based relevance decay (both linear and exponential),
  threshold-based pruning, and archival with signal emission.

  This module operates on `%Arbor.Memory.KnowledgeGraph{}` structs and
  returns updated structs. It is called internally by the parent module.
  """

  alias Arbor.Memory.KnowledgeGraph
  alias Arbor.Memory.Signals

  @default_decay_rate 0.10
  @default_prune_threshold 0.1
  @default_max_nodes_per_type 500
  @min_relevance 0.01
  @allowed_node_types [:fact, :experience, :skill, :insight, :relationship,
                       :goal, :observation, :trait, :intention]

  # ============================================================================
  # Decay
  # ============================================================================

  @doc """
  Apply linear decay to all non-pinned nodes.

  Reduces relevance of each node by the configured decay rate.
  Pinned nodes are not affected.
  """
  @spec decay(KnowledgeGraph.t()) :: KnowledgeGraph.t()
  def decay(graph) do
    decay_rate = Map.get(graph.config, :decay_rate, @default_decay_rate)

    new_nodes =
      Map.new(graph.nodes, fn {id, node} ->
        if node.pinned do
          {id, node}
        else
          new_relevance = max(0.0, node.relevance - decay_rate)
          {id, %{node | relevance: new_relevance}}
        end
      end)

    %{graph | nodes: new_nodes}
  end

  @doc """
  Apply exponential time-based decay to all non-pinned nodes.

  Uses the formula: `relevance * e^(-lambda * days_since_access)` where lambda is the
  decay rate. This produces a smooth exponential curve that decays faster
  initially and slows down over time, unlike the linear `decay/1`.

  ## Options

  - `:pinned_ids` - Set of node IDs to skip (in addition to pinned nodes)
  - `:decay_rate_override` - Override the graph's decay rate for this call
  - `:auto_prune` - Prune low-relevance nodes after decay (default: true)
  """
  @spec apply_decay(KnowledgeGraph.t(), keyword()) :: KnowledgeGraph.t()
  def apply_decay(graph, opts \\ []) do
    now = DateTime.utc_now()
    lambda = Keyword.get(opts, :decay_rate_override, Map.get(graph.config, :decay_rate, @default_decay_rate))
    pinned_ids = normalize_pinned_ids(Keyword.get(opts, :pinned_ids))

    auto_prune = Keyword.get(opts, :auto_prune, true)

    new_nodes =
      Map.new(graph.nodes, fn {id, node} ->
        if node.pinned or id in pinned_ids do
          {id, node}
        else
          days = DateTime.diff(now, node.last_accessed, :second) / 86_400.0
          decay_factor = :math.exp(-lambda * days)
          new_relevance = max(@min_relevance, node.relevance * decay_factor)
          {id, %{node | relevance: new_relevance}}
        end
      end)

    decayed = %{graph | nodes: new_nodes, last_decay_at: now}

    if auto_prune do
      {pruned, _count} = prune(decayed)
      KnowledgeGraph.refresh_active_set(pruned)
    else
      KnowledgeGraph.refresh_active_set(decayed)
    end
  end

  # ============================================================================
  # Pruning
  # ============================================================================

  @doc """
  Prune nodes below the relevance threshold.

  Pinned nodes are never pruned.

  Returns `{updated_graph, pruned_count}`.
  """
  @spec prune(KnowledgeGraph.t(), float()) :: {KnowledgeGraph.t(), non_neg_integer()}
  def prune(graph, threshold \\ @default_prune_threshold) do
    {to_keep, to_prune} =
      graph.nodes
      |> Map.values()
      |> Enum.split_with(fn node ->
        node.pinned or node.relevance >= threshold
      end)

    pruned_ids = MapSet.new(to_prune, & &1.id)
    pruned_count = length(to_prune)

    new_nodes = Map.new(to_keep, &{&1.id, &1})

    # Remove edges from/to pruned nodes
    new_edges =
      graph.edges
      |> Enum.reject(fn {source_id, _} -> source_id in pruned_ids end)
      |> Map.new(fn {source_id, edges} ->
        {source_id, Enum.reject(edges, &(&1.target_id in pruned_ids))}
      end)

    new_active_set = Enum.reject(graph.active_set, &(&1 in pruned_ids))
    {%{graph | nodes: new_nodes, edges: new_edges, active_set: new_active_set}, pruned_count}
  end

  # ============================================================================
  # Archival
  # ============================================================================

  @doc """
  Prune nodes below threshold and emit archival signals for each removed node.

  Returns `{updated_graph, archived_count}`.
  """
  @spec prune_and_archive(KnowledgeGraph.t(), keyword()) :: {KnowledgeGraph.t(), non_neg_integer()}
  def prune_and_archive(graph, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, Map.get(graph.config, :prune_threshold, @default_prune_threshold))

    {to_keep, to_archive} =
      graph.nodes
      |> Map.values()
      |> Enum.split_with(fn node ->
        node.pinned or node.relevance >= threshold
      end)

    # Emit signals for archived nodes
    Enum.each(to_archive, fn node ->
      Signals.emit_knowledge_archived(graph.agent_id, node, :low_relevance)
    end)

    archived_ids = MapSet.new(to_archive, & &1.id)
    new_nodes = Map.new(to_keep, &{&1.id, &1})

    new_edges =
      graph.edges
      |> Enum.reject(fn {source_id, _} -> source_id in archived_ids end)
      |> Map.new(fn {source_id, edges} ->
        {source_id, Enum.reject(edges, &(&1.target_id in archived_ids))}
      end)

    new_active_set = Enum.reject(graph.active_set, &(&1 in archived_ids))
    archived_count = length(to_archive)

    {%{graph | nodes: new_nodes, edges: new_edges, active_set: new_active_set}, archived_count}
  end

  @doc """
  Combined operation: decay -> prune/archive -> refresh active set.

  Skips processing when the graph is under capacity unless `:force` is set.

  ## Options

  - `:force` - Run even when under capacity
  - `:threshold` - Override prune threshold
  - All options from `apply_decay/2`
  """
  @spec decay_and_archive(KnowledgeGraph.t(), keyword()) :: {KnowledgeGraph.t(), non_neg_integer()}
  def decay_and_archive(graph, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    total_capacity = Map.get(graph.config, :max_nodes_per_type, @default_max_nodes_per_type) * length(@allowed_node_types)

    if not force and map_size(graph.nodes) < total_capacity * 0.8 do
      {graph, 0}
    else
      # Disable auto_prune in apply_decay since prune_and_archive handles pruning with signal emission
      graph = apply_decay(graph, Keyword.put(opts, :auto_prune, false))
      prune_and_archive(graph, opts)
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_pinned_ids(nil), do: MapSet.new()
  defp normalize_pinned_ids(%MapSet{} = set), do: set
  defp normalize_pinned_ids(list) when is_list(list), do: MapSet.new(list)
end
