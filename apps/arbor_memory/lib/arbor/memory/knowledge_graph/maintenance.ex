defmodule Arbor.Memory.KnowledgeGraph.Maintenance do
  @moduledoc false

  alias Arbor.Memory.KnowledgeGraph

  @default_reinforce_window_hours 24
  @default_reinforce_boost 0.1
  @default_prune_threshold 0.1

  @type archive_entry :: %{node: KnowledgeGraph.knowledge_node(), reason: atom()}
  @type result :: %{
          archive_entries: [archive_entry()],
          metrics: map(),
          replayed: boolean()
        }

  @spec run(KnowledgeGraph.t(), :basic | :enhanced, keyword(), DateTime.t()) ::
          {:ok, KnowledgeGraph.t(), result()} | {:error, :invalid_graph}
  def run(%KnowledgeGraph{} = graph, :basic, opts, %DateTime{}) do
    threshold = Keyword.get(opts, :prune_threshold, @default_prune_threshold)
    decayed = KnowledgeGraph.decay(graph)
    to_prune = candidates_for_pruning(decayed, threshold)
    {updated, pruned_count} = KnowledgeGraph.prune(decayed, threshold)

    {:ok, updated,
     result(updated,
       decayed_count: map_size(graph.nodes),
       reinforced_count: 0,
       archive_entries: archive_entries(to_prune, :low_relevance),
       pruned_count: pruned_count,
       evicted_count: 0
     )}
  end

  def run(%KnowledgeGraph{} = graph, :enhanced, opts, %DateTime{} = occurred_at) do
    threshold = Keyword.get(opts, :prune_threshold, @default_prune_threshold)
    window_hours = Keyword.get(opts, :reinforce_window_hours, @default_reinforce_window_hours)
    boost = Keyword.get(opts, :reinforce_boost, @default_reinforce_boost)
    archive? = Keyword.get(opts, :archive, true)

    decayed = KnowledgeGraph.decay(graph)
    {reinforced, reinforced_count} = reinforce_recent(decayed, occurred_at, window_hours, boost)
    to_prune = candidates_for_pruning(reinforced, threshold)
    {pruned, pruned_count} = KnowledgeGraph.prune(reinforced, threshold)
    {updated, evicted} = enforce_quotas(pruned)

    archive_entries =
      if archive? do
        archive_entries(to_prune, :low_relevance) ++ archive_entries(evicted, :quota_exceeded)
      else
        []
      end

    {:ok, updated,
     result(updated,
       decayed_count: map_size(graph.nodes),
       reinforced_count: reinforced_count,
       archive_entries: archive_entries,
       pruned_count: pruned_count,
       evicted_count: length(evicted)
     )}
  end

  def run(_graph, _mode, _opts, _occurred_at), do: {:error, :invalid_graph}

  @spec replay(KnowledgeGraph.t()) :: result()
  def replay(%KnowledgeGraph{} = graph) do
    result(graph,
      decayed_count: 0,
      reinforced_count: 0,
      archive_entries: [],
      pruned_count: 0,
      evicted_count: 0,
      replayed: true
    )
  end

  defp reinforce_recent(graph, occurred_at, window_hours, boost) do
    cutoff = DateTime.add(occurred_at, -window_hours * 3_600, :second)

    {nodes, count} =
      Enum.reduce(graph.nodes, {%{}, 0}, fn {id, node}, {acc, count} ->
        if DateTime.compare(node.last_accessed, cutoff) == :gt do
          updated = %{node | relevance: min(1.0, node.relevance + boost)}
          {Map.put(acc, id, updated), count + 1}
        else
          {Map.put(acc, id, node), count}
        end
      end)

    {%{graph | nodes: nodes}, count}
  end

  defp enforce_quotas(graph) do
    max_per_type = Map.fetch!(graph.config, :max_nodes_per_type)

    evicted =
      graph.nodes
      |> Map.values()
      |> Enum.group_by(& &1.type)
      |> Enum.sort_by(fn {type, _nodes} -> Atom.to_string(type) end)
      |> Enum.flat_map(fn {_type, nodes} ->
        nodes
        |> Enum.sort_by(&{&1.relevance, &1.id})
        |> Enum.take(max(length(nodes) - max_per_type, 0))
      end)

    evicted_ids = MapSet.new(evicted, & &1.id)
    nodes = Map.reject(graph.nodes, fn {id, _node} -> MapSet.member?(evicted_ids, id) end)

    edges =
      graph.edges
      |> Enum.reject(fn {source_id, _edges} -> MapSet.member?(evicted_ids, source_id) end)
      |> Map.new(fn {source_id, edges} ->
        {source_id,
         Enum.reject(edges, fn edge -> MapSet.member?(evicted_ids, edge.target_id) end)}
      end)

    active_set = Enum.reject(graph.active_set, &MapSet.member?(evicted_ids, &1))
    {%{graph | nodes: nodes, edges: edges, active_set: active_set}, evicted}
  end

  defp candidates_for_pruning(graph, threshold) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(not &1.pinned and &1.relevance < threshold))
    |> Enum.sort_by(&{&1.relevance, &1.id})
  end

  defp archive_entries(nodes, reason),
    do: Enum.map(nodes, &%{node: &1, reason: reason})

  defp result(graph, opts) do
    stats = KnowledgeGraph.stats(graph)
    entries = Keyword.fetch!(opts, :archive_entries)

    %{
      archive_entries: entries,
      replayed: Keyword.get(opts, :replayed, false),
      metrics: %{
        decayed_count: Keyword.fetch!(opts, :decayed_count),
        reinforced_count: Keyword.fetch!(opts, :reinforced_count),
        archived_count: length(entries),
        pruned_count: Keyword.fetch!(opts, :pruned_count),
        evicted_count: Keyword.fetch!(opts, :evicted_count),
        total_nodes: stats.node_count,
        average_relevance: stats.average_relevance
      }
    }
  end
end
