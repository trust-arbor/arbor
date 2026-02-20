defmodule Arbor.Memory.KnowledgeGraph.GraphSearch do
  @moduledoc """
  Search, query, and context generation for the knowledge graph.

  Provides content-based recall, semantic search, cascade recall (spreading
  activation), prompt text generation, type/criteria filtering, and
  statistical queries.

  This module operates on `%Arbor.Memory.KnowledgeGraph{}` structs and is
  called internally by the parent module.
  """

  alias Arbor.Common.LazyLoader
  alias Arbor.Memory.KnowledgeGraph

  # ============================================================================
  # Content Search
  # ============================================================================

  @doc """
  Search nodes by content similarity (simple substring match).

  ## Options

  - `:type` - Filter by node type
  - `:types` - Filter by multiple types
  - `:min_relevance` - Minimum relevance threshold
  - `:limit` - Maximum results
  """
  @spec recall(KnowledgeGraph.t(), String.t(), keyword()) :: {:ok, [KnowledgeGraph.knowledge_node()]}
  def recall(graph, query, opts \\ []) do
    type_filter = get_type_filter(opts)
    min_relevance = Keyword.get(opts, :min_relevance, 0.0)
    limit = Keyword.get(opts, :limit, 10)
    query_lower = String.downcase(query)

    results =
      graph.nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        matches_type?(node, type_filter) and
          node.relevance >= min_relevance and
          String.contains?(String.downcase(node.content), query_lower)
      end)
      |> Enum.sort_by(& &1.relevance, :desc)
      |> Enum.take(limit)

    {:ok, results}
  end

  @doc """
  Find a node by its content (exact match, case-insensitive).
  """
  @spec find_by_name(KnowledgeGraph.t(), String.t()) :: {:ok, KnowledgeGraph.node_id()} | {:error, :not_found}
  def find_by_name(graph, name) do
    name_lower = String.downcase(name)

    result =
      Enum.find(graph.nodes, fn {_id, node} ->
        String.downcase(node.content) == name_lower
      end)

    case result do
      {node_id, _node} -> {:ok, node_id}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Substring search across node content (case-insensitive).

  Returns all nodes whose content contains the query string, sorted by relevance.
  """
  @spec search_by_name(KnowledgeGraph.t(), String.t()) :: [KnowledgeGraph.knowledge_node()]
  def search_by_name(graph, query) do
    query_lower = String.downcase(query)

    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      String.contains?(String.downcase(node.content), query_lower)
    end)
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  @doc """
  Hybrid semantic + keyword search across knowledge nodes.

  When embeddings are available, combines embedding similarity (70% weight)
  with keyword score (30% weight). Falls back to pure keyword search when
  the embedding service is unavailable.

  ## Options

  - `:limit` - Max results (default 10)
  - `:types` - Filter by node types (list of atoms)
  - `:min_relevance` - Minimum node relevance threshold (default 0.0)
  """
  @spec semantic_search(KnowledgeGraph.t(), String.t(), keyword()) :: {:ok, [KnowledgeGraph.knowledge_node()]}
  def semantic_search(graph, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    types = Keyword.get(opts, :types)
    min_relevance = Keyword.get(opts, :min_relevance, 0.0)

    query_embedding = compute_node_embedding(query)

    candidates =
      graph.nodes
      |> Map.values()
      |> Enum.filter(fn node ->
        node.relevance >= min_relevance and
          (is_nil(types) or node.type in types)
      end)

    scored =
      Enum.map(candidates, fn node ->
        score = compute_search_score(query, query_embedding, node)
        {node, score}
      end)

    results =
      scored
      |> Enum.filter(fn {_, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {node, _score} -> node end)

    {:ok, results}
  end

  # ============================================================================
  # Cascade Recall (Spreading Activation)
  # ============================================================================

  @doc """
  Spreading activation: boosts a starting node and its neighbors recursively
  with a decaying boost factor.

  ## Options

  - `:max_depth` - Maximum recursion depth (default 3)
  - `:min_boost` - Stop spreading when boost falls below this (default 0.05)
  - `:decay_factor` - Multiplier for boost at each hop (default 0.5)
  """
  @spec cascade_recall(KnowledgeGraph.t(), KnowledgeGraph.node_id(), float(), keyword()) :: KnowledgeGraph.t()
  def cascade_recall(graph, node_id, boost_amount, opts \\ [])
      when is_number(boost_amount) do
    boost_amount = boost_amount / 1
    max_depth = Keyword.get(opts, :max_depth, 3)
    min_boost = Keyword.get(opts, :min_boost, 0.05)
    decay_factor = Keyword.get(opts, :decay_factor, 0.5)

    spread_activation(graph, [node_id], boost_amount, max_depth, min_boost, decay_factor, MapSet.new())
  end

  # ============================================================================
  # Context Generation
  # ============================================================================

  @doc """
  Generate LLM context text from the active set.

  Formats each node as `- [type] content (N% relevance)` and optionally
  includes relationship lines.

  ## Options

  - `:include_relationships` - Include edge info (default true)
  - `:model_context` - Override token budget
  """
  @spec to_prompt_text(KnowledgeGraph.t(), keyword()) :: String.t()
  def to_prompt_text(graph, opts \\ []) do
    include_rels = Keyword.get(opts, :include_relationships, true)
    nodes = KnowledgeGraph.active_set(graph, opts)

    if nodes == [] do
      ""
    else
      body =
        Enum.map_join(nodes, "\n", fn node ->
          format_node_prompt_line(graph, node, include_rels)
        end)

      "## Knowledge Graph (Active Context)\n\n" <> body
    end
  end

  # ============================================================================
  # Type and Criteria Queries
  # ============================================================================

  @doc """
  Alias for `list_by_type/2` (API compatibility).
  """
  @spec find_by_type(KnowledgeGraph.t(), KnowledgeGraph.node_type()) :: [KnowledgeGraph.knowledge_node()]
  def find_by_type(graph, type), do: list_by_type(graph, type)

  @doc """
  Filter nodes by type and a custom criteria function, with options.

  ## Options

  - `:limit` - Max results
  - `:sort_by` - Sort field (`:relevance`, `:created_at`, `:last_accessed`)
  """
  @spec find_by_type_and_criteria(
          KnowledgeGraph.t(),
          KnowledgeGraph.node_type(),
          (KnowledgeGraph.knowledge_node() -> boolean()),
          keyword()
        ) :: [KnowledgeGraph.knowledge_node()]
  def find_by_type_and_criteria(graph, type, criteria_fn, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    sort_by = Keyword.get(opts, :sort_by, :relevance)

    results =
      graph.nodes
      |> Map.values()
      |> Enum.filter(fn node -> node.type == type and criteria_fn.(node) end)
      |> Enum.sort_by(&Map.get(&1, sort_by, 0), :desc)

    if limit, do: Enum.take(results, limit), else: results
  end

  @doc """
  Get recently accessed or created nodes.

  ## Options

  - `:types` - Filter by node types
  - `:since` - Only nodes accessed/created after this DateTime
  - `:limit` - Max results (default 20)
  - `:sort_by` - `:last_accessed` (default) or `:created_at`
  """
  @spec recent_nodes(KnowledgeGraph.t(), keyword()) :: [KnowledgeGraph.knowledge_node()]
  def recent_nodes(graph, opts \\ []) do
    types = Keyword.get(opts, :types)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 20)
    sort_by = Keyword.get(opts, :sort_by, :last_accessed)

    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      type_ok = is_nil(types) or node.type in types
      since_ok = is_nil(since) or DateTime.compare(Map.get(node, sort_by), since) == :gt
      type_ok and since_ok
    end)
    |> Enum.sort_by(&Map.get(&1, sort_by), {:desc, DateTime})
    |> Enum.take(limit)
  end

  @doc """
  Get all skill nodes grouped by tool_name metadata.
  """
  @spec get_tool_learnings(KnowledgeGraph.t()) :: map()
  def get_tool_learnings(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :skill))
    |> Enum.group_by(fn node -> Map.get(node.metadata, :tool_name, "unknown") end)
  end

  @doc """
  Get skill nodes for a specific tool.
  """
  @spec get_tool_learnings(KnowledgeGraph.t(), String.t()) :: [KnowledgeGraph.knowledge_node()]
  def get_tool_learnings(graph, tool_name) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      node.type == :skill and Map.get(node.metadata, :tool_name) == tool_name
    end)
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  # ============================================================================
  # Statistics and Queries
  # ============================================================================

  @doc """
  Get statistics about the knowledge graph.
  """
  @spec stats(KnowledgeGraph.t()) :: map()
  def stats(graph) do
    node_values = Map.values(graph.nodes)

    nodes_by_type =
      node_values
      |> Enum.group_by(&flexible_get(&1, :type))
      |> Map.new(fn {type, nodes} -> {type, length(nodes)} end)

    tokens_by_type =
      node_values
      |> Enum.group_by(&flexible_get(&1, :type))
      |> Map.new(fn {type, nodes} ->
        {type, Enum.reduce(nodes, 0, fn n, acc -> acc + (flexible_get(n, :cached_tokens) || 0) end)}
      end)

    edges_by_relationship =
      graph.edges
      |> Map.values()
      |> List.flatten()
      |> Enum.group_by(&flexible_get(&1, :relationship))
      |> Map.new(fn {rel, edges} -> {rel, length(edges)} end)

    avg_relevance =
      if map_size(graph.nodes) > 0 do
        total = Enum.sum(Enum.map(node_values, &(flexible_get(&1, :relevance) || 0.0)))
        total / map_size(graph.nodes)
      else
        0.0
      end

    edge_count =
      graph.edges
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    %{
      agent_id: graph.agent_id,
      node_count: map_size(graph.nodes),
      nodes_by_type: nodes_by_type,
      tokens_by_type: tokens_by_type,
      edge_count: edge_count,
      edges_by_relationship: edges_by_relationship,
      average_relevance: Float.round(avg_relevance, 3),
      total_tokens: KnowledgeGraph.total_tokens(graph),
      active_set_size: length(graph.active_set),
      active_set_tokens: KnowledgeGraph.active_set_tokens(graph),
      pending_facts: length(graph.pending_facts),
      pending_learnings: length(graph.pending_learnings),
      max_active: graph.max_active,
      max_tokens: graph.max_tokens,
      last_decay_at: graph.last_decay_at,
      config: graph.config
    }
  end

  @doc """
  List all nodes of a specific type.
  """
  @spec list_by_type(KnowledgeGraph.t(), KnowledgeGraph.node_type()) :: [KnowledgeGraph.knowledge_node()]
  def list_by_type(graph, type) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == type))
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  @doc """
  Get nodes with lowest relevance (candidates for pruning).
  """
  @spec lowest_relevance(KnowledgeGraph.t(), non_neg_integer()) :: [KnowledgeGraph.knowledge_node()]
  def lowest_relevance(graph, count \\ 10) do
    graph.nodes
    |> Map.values()
    |> Enum.reject(& &1.pinned)
    |> Enum.sort_by(& &1.relevance)
    |> Enum.take(count)
  end

  @doc """
  Get nodes that haven't been accessed recently.
  """
  @spec stale_nodes(KnowledgeGraph.t(), non_neg_integer()) :: [KnowledgeGraph.knowledge_node()]
  def stale_nodes(graph, days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      DateTime.compare(node.last_accessed, cutoff) == :lt
    end)
    |> Enum.sort_by(& &1.last_accessed, DateTime)
  end

  # ============================================================================
  # Token Budget Selection
  # ============================================================================

  @doc """
  Select nodes that fit within a token budget, respecting per-type quotas.

  Fills the budget greedily with highest-relevance nodes. When `type_quotas`
  is provided (e.g., `%{fact: 0.4, skill: 0.3}`), each type gets at most
  that fraction of the total budget.

  Returns the selected nodes in relevance order.
  """
  @spec select_by_token_budget(
          [KnowledgeGraph.knowledge_node()],
          non_neg_integer(),
          map()
        ) :: [KnowledgeGraph.knowledge_node()]
  def select_by_token_budget(nodes, max_tokens, type_quotas \\ %{}) do
    sorted = Enum.sort_by(nodes, & &1.relevance, :desc)

    type_limits =
      Map.new(type_quotas, fn {type, fraction} ->
        {type, round(max_tokens * fraction)}
      end)

    {selected, _used, _type_used} =
      Enum.reduce(sorted, {[], 0, %{}}, fn node, {acc, total_used, type_used} ->
        tokens = node[:cached_tokens] || 0
        new_total = total_used + tokens

        if new_total > max_tokens do
          {acc, total_used, type_used}
        else
          maybe_add_within_type_budget(node, tokens, type_limits, acc, total_used, new_total, type_used)
        end
      end)

    Enum.reverse(selected)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_type_filter(opts) do
    cond do
      type = Keyword.get(opts, :type) -> {:single, type}
      types = Keyword.get(opts, :types) -> {:multiple, types}
      true -> :none
    end
  end

  defp matches_type?(_node, :none), do: true
  defp matches_type?(node, {:single, type}), do: node.type == type
  defp matches_type?(node, {:multiple, types}), do: node.type in types

  defp maybe_add_within_type_budget(node, tokens, type_limits, acc, total_used, new_total, type_used) do
    type_budget = Map.get(type_limits, node.type)
    current_type_used = Map.get(type_used, node.type, 0)

    if type_budget && current_type_used + tokens > type_budget do
      {acc, total_used, type_used}
    else
      new_type_used = Map.put(type_used, node.type, current_type_used + tokens)
      {[node | acc], new_total, new_type_used}
    end
  end

  # Spreading activation -- recursive frontier-based
  defp spread_activation(graph, _frontier, _boost, 0, _min_boost, _decay, _visited), do: graph
  defp spread_activation(graph, [], _boost, _depth, _min_boost, _decay, _visited), do: graph

  defp spread_activation(graph, frontier, boost, depth, min_boost, decay_factor, visited) do
    if boost < min_boost do
      graph
    else
      {graph, next_frontier} =
        Enum.reduce(frontier, {graph, []}, fn node_id, {g, next} ->
          boost_unvisited_node(g, next, node_id, boost, visited)
        end)

      new_visited = Enum.reduce(frontier, visited, &MapSet.put(&2, &1))
      spread_activation(graph, Enum.uniq(next_frontier), boost * decay_factor, depth - 1, min_boost, decay_factor, new_visited)
    end
  end

  defp boost_unvisited_node(graph, next, node_id, boost, visited) do
    if node_id in visited do
      {graph, next}
    else
      graph = KnowledgeGraph.boost_node(graph, node_id, boost)
      neighbors = get_neighbor_ids(graph, node_id) -- MapSet.to_list(visited)
      {graph, neighbors ++ next}
    end
  end

  defp get_neighbor_ids(graph, node_id) do
    # Outgoing targets
    outgoing =
      graph.edges
      |> Map.get(node_id, [])
      |> Enum.map(& &1.target_id)

    # Incoming sources
    incoming =
      graph.edges
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1.target_id == node_id))
      |> Enum.map(& &1.source_id)

    Enum.uniq(outgoing ++ incoming)
  end

  defp format_node_prompt_line(graph, node, include_rels) do
    pct = round(node.relevance * 100)
    line = "    - [#{node.type}] #{node.content} (#{pct}% relevance)"

    if include_rels do
      append_relationships(graph, node.id, line)
    else
      line
    end
  end

  defp append_relationships(graph, node_id, line) do
    rels = format_node_relationships(graph, node_id)
    if rels == "", do: line, else: line <> "\n" <> rels
  end

  defp format_node_relationships(graph, node_id) do
    outgoing = Map.get(graph.edges, node_id, [])

    outgoing_lines =
      Enum.map(outgoing, fn edge ->
        target = Map.get(graph.nodes, edge.target_id)
        target_text = if target, do: target.content, else: edge.target_id
        "        -> #{edge.relationship}: #{target_text}"
      end)

    # Incoming edges (other nodes pointing to this one)
    incoming_lines =
      graph.edges
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1.target_id == node_id))
      |> Enum.map(fn edge ->
        source = Map.get(graph.nodes, edge.source_id)
        source_text = if source, do: source.content, else: edge.source_id
        "        <- #{edge.relationship}: #{source_text}"
      end)

    (outgoing_lines ++ incoming_lines) |> Enum.join("\n")
  end

  # Embedding service helpers
  defp embedding_service_available? do
    LazyLoader.exported?(Arbor.AI, :embed, 2)
  end

  defp compute_node_embedding(text) when is_binary(text) do
    if embedding_service_available?() do
      case Arbor.AI.embed(text, []) do
        {:ok, embedding} when is_list(embedding) -> embedding
        _ -> nil
      end
    else
      nil
    end
  end

  defp compute_node_embedding(_), do: nil

  defp cosine_similarity([], _), do: 0.0
  defp cosine_similarity(_, []), do: 0.0

  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    mag_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    mag_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if mag_a == 0.0 or mag_b == 0.0, do: 0.0, else: dot / (mag_a * mag_b)
  end

  defp cosine_similarity(_, _), do: 0.0

  defp compute_search_score(query, query_embedding, node) do
    keyword_score = compute_keyword_score(query, node)

    semantic_score =
      if query_embedding && node.embedding do
        cosine_similarity(query_embedding, node.embedding)
      else
        0.0
      end

    if semantic_score > 0.0 do
      # Hybrid: 70% semantic + 30% keyword
      0.7 * semantic_score + 0.3 * keyword_score
    else
      keyword_score
    end
  end

  defp compute_keyword_score(query, node) do
    query_terms =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)

    content_lower = String.downcase(node.content)
    matching = Enum.count(query_terms, &String.contains?(content_lower, &1))

    if query_terms != [] do
      matching / length(query_terms)
    else
      0.0
    end
  end

  # Handles maps with mixed atom/string keys (e.g., after Postgres deserialization)
  defp flexible_get(map, key) when is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      val -> val
    end
  end
end
