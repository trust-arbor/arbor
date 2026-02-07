defmodule Arbor.Memory.KnowledgeGraph do
  @moduledoc """
  Semantic knowledge graph with decay and reinforcement.

  A structured memory system for storing interconnected knowledge nodes with:
  - Multiple node types (facts, experiences, skills, insights, relationships)
  - Weighted edges representing relationships between nodes
  - Relevance decay over time (unused memories fade)
  - Access-based reinforcement (recalled memories strengthen)
  - Pending queues for fact and learning proposals

  ## The "Subconscious Proposes, Agent Decides" Pattern

  The KnowledgeGraph implements a proposal mechanism where the subconscious
  processes can suggest facts and learnings, but the agent (conscious mind)
  decides whether to accept or reject them:

  - `pending_facts` - Auto-extracted facts awaiting agent approval
  - `pending_learnings` - Action pattern learnings awaiting review

  ## Node Types

  - `:fact` - Verified facts about the world
  - `:experience` - Personal experiences and observations
  - `:skill` - Learned capabilities
  - `:insight` - Self-reflective insights
  - `:relationship` - Information about relationships

  ## Decay and Reinforcement

  Nodes have a `relevance` score (0.0 - 1.0) that:
  - Decays over time if the node is not accessed
  - Increases when the node is recalled (reinforcement)
  - Falls below a threshold → candidate for pruning

  ## Examples

      # Create a new graph for an agent
      graph = Arbor.Memory.KnowledgeGraph.new("agent_001")

      # Add a fact node
      {:ok, graph, node_id} = Arbor.Memory.KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "The sky is blue"
      })

      # Link two nodes
      {:ok, graph} = Arbor.Memory.KnowledgeGraph.add_edge(graph, node_a, node_b, :supports)

      # Decay all nodes
      graph = Arbor.Memory.KnowledgeGraph.decay(graph)

      # Prune low-relevance nodes
      {graph, pruned_count} = Arbor.Memory.KnowledgeGraph.prune(graph, 0.1)
  """

  alias Arbor.Common.SafeAtom
  alias Arbor.Memory.TokenBudget

  require Logger

  @type node_id :: String.t()
  @type edge_id :: String.t()

  @type node_type :: :fact | :experience | :skill | :insight | :relationship | :custom

  @type knowledge_node :: %{
          id: node_id(),
          type: node_type(),
          content: String.t(),
          relevance: float(),
          confidence: float(),
          access_count: non_neg_integer(),
          created_at: DateTime.t(),
          last_accessed: DateTime.t(),
          metadata: map(),
          pinned: boolean(),
          embedding: [float()] | nil,
          cached_tokens: non_neg_integer()
        }

  @type edge :: %{
          id: edge_id(),
          source_id: node_id(),
          target_id: node_id(),
          relationship: atom(),
          strength: float(),
          created_at: DateTime.t()
        }

  @type pending_item :: %{
          id: String.t(),
          type: :fact | :learning,
          content: String.t(),
          confidence: float(),
          source: String.t() | nil,
          extracted_at: DateTime.t(),
          metadata: map()
        }

  @type t :: %__MODULE__{
          agent_id: String.t(),
          nodes: %{node_id() => knowledge_node()},
          edges: %{node_id() => [edge()]},
          pending_facts: [pending_item()],
          pending_learnings: [pending_item()],
          config: map(),
          active_set: [node_id()],
          max_active: non_neg_integer(),
          dedup_threshold: float(),
          max_tokens: TokenBudget.budget() | nil,
          type_quotas: map(),
          last_decay_at: DateTime.t() | nil
        }

  defstruct [
    :agent_id,
    nodes: %{},
    edges: %{},
    pending_facts: [],
    pending_learnings: [],
    config: %{},
    active_set: [],
    max_active: 50,
    dedup_threshold: 0.85,
    max_tokens: nil,
    type_quotas: %{},
    last_decay_at: nil
  ]

  @allowed_node_types [:fact, :experience, :skill, :insight, :relationship, :custom]
  @default_decay_rate 0.10
  @default_reinforce_amount 0.15
  @default_max_nodes_per_type 500
  @default_prune_threshold 0.1
  @min_relevance 0.01

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Create a new knowledge graph for an agent.

  ## Options

  - `:decay_rate` - How much relevance decays per cycle (default: 0.10)
  - `:max_nodes_per_type` - Maximum nodes per type (default: 500)
  - `:prune_threshold` - Relevance below which to prune (default: 0.1)

  ## Examples

      graph = Arbor.Memory.KnowledgeGraph.new("agent_001")
      graph = Arbor.Memory.KnowledgeGraph.new("agent_001", decay_rate: 0.05)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(agent_id, opts \\ []) do
    config = %{
      decay_rate: Keyword.get(opts, :decay_rate, @default_decay_rate),
      max_nodes_per_type: Keyword.get(opts, :max_nodes_per_type, @default_max_nodes_per_type),
      prune_threshold: Keyword.get(opts, :prune_threshold, @default_prune_threshold)
    }

    %__MODULE__{
      agent_id: agent_id,
      config: config,
      max_active: Keyword.get(opts, :max_active, 50),
      dedup_threshold: Keyword.get(opts, :dedup_threshold, 0.85),
      max_tokens: Keyword.get(opts, :max_tokens),
      type_quotas: Keyword.get(opts, :type_quotas, %{})
    }
  end

  # ============================================================================
  # Node Operations
  # ============================================================================

  @doc """
  Add a node to the knowledge graph.

  ## Node Data

  - `:type` - Node type (required): :fact, :experience, :skill, :insight, :relationship
  - `:content` - Node content (required): string describing the knowledge
  - `:relevance` - Initial relevance (optional, default: 1.0)
  - `:metadata` - Additional metadata (optional)
  - `:pinned` - Whether node is protected from decay/pruning (optional, default: false)

  ## Examples

      {:ok, graph, node_id} = KnowledgeGraph.add_node(graph, %{
        type: :fact,
        content: "Paris is the capital of France"
      })
  """
  @spec add_node(t(), map()) :: {:ok, t(), node_id()} | {:error, term()}
  def add_node(graph, node_data) do
    with {:ok, type} <- validate_node_type(node_data),
         {:ok, content} <- validate_content(node_data),
         :ok <- check_quota(graph, type) do
      skip_dedup = Map.get(node_data, :skip_dedup, false)
      metadata = Map.get(node_data, :metadata, %{})
      text = node_to_text(content, metadata)
      embedding = compute_node_embedding(text)

      # Check for duplicates unless skipped
      case maybe_find_duplicate(graph, type, content, embedding, skip_dedup) do
        {:duplicate, existing_id} ->
          # Boost existing node instead of creating duplicate
          boosted = boost_node(graph, existing_id, 0.1)
          {:ok, boosted, existing_id}

        :no_duplicate ->
          node_id = generate_node_id()
          now = DateTime.utc_now()

          node = %{
            id: node_id,
            type: type,
            content: content,
            relevance: Map.get(node_data, :relevance, 1.0),
            confidence: Map.get(node_data, :confidence, 0.5),
            access_count: 0,
            created_at: now,
            last_accessed: now,
            metadata: metadata,
            pinned: Map.get(node_data, :pinned, false),
            embedding: embedding,
            cached_tokens: TokenBudget.estimate_tokens(text)
          }

          new_graph =
            %{graph | nodes: Map.put(graph.nodes, node_id, node)}
            |> maybe_add_to_active_set(node)

          {:ok, new_graph, node_id}
      end
    end
  end

  @doc """
  Get a node by ID.

  Does NOT update access time/count. Use `recall/2` for that.
  """
  @spec get_node(t(), node_id()) :: {:ok, knowledge_node()} | {:error, :not_found}
  def get_node(graph, node_id) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Update a node's content or metadata.
  """
  @spec update_node(t(), node_id(), map()) :: {:ok, t()} | {:error, :not_found}
  def update_node(graph, node_id, updates) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, node} ->
        updated_node =
          node
          |> maybe_update(:content, updates)
          |> maybe_update(:metadata, updates)
          |> maybe_update(:pinned, updates)

        new_graph = %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}
        {:ok, new_graph}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Remove a node and all its edges from the graph.
  """
  @spec remove_node(t(), node_id()) :: {:ok, t()} | {:error, :not_found}
  def remove_node(graph, node_id) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, _node} ->
        # Remove node
        new_nodes = Map.delete(graph.nodes, node_id)

        # Remove all edges from/to this node
        new_edges =
          graph.edges
          |> Map.delete(node_id)
          |> Map.new(fn {source, edges} ->
            {source, Enum.reject(edges, &(&1.target_id == node_id))}
          end)

        new_active_set = List.delete(graph.active_set, node_id)
        {:ok, %{graph | nodes: new_nodes, edges: new_edges, active_set: new_active_set}}

      :error ->
        {:error, :not_found}
    end
  end

  # ============================================================================
  # Edge Operations
  # ============================================================================

  @doc """
  Add an edge between two nodes.

  ## Options

  - `:strength` - Edge strength (default: 1.0)

  ## Relationship Types

  Common relationship types include:
  - `:supports` - Source supports/validates target
  - `:contradicts` - Source contradicts target
  - `:relates_to` - General relation
  - `:derived_from` - Source was derived from target
  - `:example_of` - Source is an example of target

  ## Examples

      {:ok, graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports)
      {:ok, graph} = KnowledgeGraph.add_edge(graph, node_a, node_b, :supports, strength: 0.8)
  """
  @spec add_edge(t(), node_id(), node_id(), atom(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def add_edge(graph, source_id, target_id, relationship, opts \\ []) do
    with {:ok, _source} <- get_node(graph, source_id),
         {:ok, _target} <- get_node(graph, target_id) do
      existing_edges = Map.get(graph.edges, source_id, [])
      strength = Keyword.get(opts, :strength, 1.0)

      # Check for existing edge with same source/target/relationship
      case Enum.find_index(existing_edges, fn e ->
             e.target_id == target_id and e.relationship == relationship
           end) do
        nil ->
          # New edge
          edge = %{
            id: generate_edge_id(),
            source_id: source_id,
            target_id: target_id,
            relationship: relationship,
            strength: strength,
            created_at: DateTime.utc_now()
          }

          new_edges = Map.put(graph.edges, source_id, [edge | existing_edges])
          {:ok, %{graph | edges: new_edges}}

        idx ->
          # Existing edge — increment strength
          existing_edge = Enum.at(existing_edges, idx)
          updated_edge = %{existing_edge | strength: min(10.0, existing_edge.strength + 0.5)}

          updated_list = List.replace_at(existing_edges, idx, updated_edge)
          new_edges = Map.put(graph.edges, source_id, updated_list)
          {:ok, %{graph | edges: new_edges}}
      end
    end
  end

  @doc """
  Get all edges from a node.
  """
  @spec get_edges(t(), node_id()) :: [edge()]
  def get_edges(graph, node_id) do
    Map.get(graph.edges, node_id, [])
  end

  @doc """
  Get all incoming edges to a node (scans all edge lists).
  """
  @spec edges_to(t(), node_id()) :: [edge()]
  def edges_to(graph, target_id) do
    graph.edges
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.target_id == target_id))
  end

  @doc """
  Remove an edge matching source, target, and relationship.
  """
  @spec unlink(t(), node_id(), node_id(), atom()) :: {:ok, t()} | {:error, :not_found}
  def unlink(graph, source_id, target_id, relationship) do
    existing_edges = Map.get(graph.edges, source_id, [])

    case Enum.find_index(existing_edges, fn e ->
           e.target_id == target_id and e.relationship == relationship
         end) do
      nil ->
        {:error, :not_found}

      idx ->
        updated_list = List.delete_at(existing_edges, idx)
        new_edges = Map.put(graph.edges, source_id, updated_list)
        {:ok, %{graph | edges: new_edges}}
    end
  end

  @doc """
  Find nodes related to a given node via multi-hop BFS traversal.

  Traverses both outgoing and incoming edges. Returns related nodes
  sorted by relevance, excluding the starting node.

  ## Options

  - `:depth` - Maximum hops to traverse (default 1)
  - `:relationship` - Only follow edges with this relationship type
  """
  @spec find_related(t(), node_id(), keyword()) :: [knowledge_node()]
  def find_related(graph, node_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    relationship = Keyword.get(opts, :relationship)

    visited = find_related_recursive(graph, [node_id], MapSet.new([node_id]), depth, relationship)

    visited
    |> MapSet.delete(node_id)
    |> MapSet.to_list()
    |> Enum.map(&Map.get(graph.nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  @doc """
  Get nodes connected to a given node (1-hop outgoing + incoming).

  Convenience wrapper around `find_related/3` with depth 1.
  """
  @spec get_connected_nodes(t(), node_id()) :: [knowledge_node()]
  def get_connected_nodes(graph, node_id) do
    find_related(graph, node_id, depth: 1)
  end

  # ============================================================================
  # Recall and Reinforcement
  # ============================================================================

  @doc """
  Recall a node, updating its access time and reinforcing its relevance.

  This is the primary way to "use" a memory - it strengthens the memory
  through access-based reinforcement.
  """
  @spec reinforce(t(), node_id()) :: {:ok, t(), knowledge_node()} | {:error, :not_found}
  def reinforce(graph, node_id) do
    case Map.fetch(graph.nodes, node_id) do
      {:ok, node} ->
        now = DateTime.utc_now()
        new_relevance = min(1.0, node.relevance + @default_reinforce_amount)

        updated_node = %{
          node
          | relevance: new_relevance,
            access_count: node.access_count + 1,
            last_accessed: now
        }

        new_graph =
          %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}
          |> maybe_add_to_active_set(updated_node)

        {:ok, new_graph, updated_node}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Boost a node's relevance by a specific amount.

  The relevance is capped at 1.0. This is a manual boost, unlike `reinforce/2`
  which uses a fixed increment.

  ## Parameters

  - `graph` - The knowledge graph
  - `node_id` - ID of the node to boost
  - `boost_amount` - Amount to add to relevance (capped at 1.0)
  """
  @spec boost_node(t(), node_id(), float()) :: t()
  def boost_node(graph, node_id, boost_amount) when is_float(boost_amount) do
    case Map.get(graph.nodes, node_id) do
      nil ->
        graph

      node ->
        new_relevance = max(@min_relevance, min(1.0, node.relevance + boost_amount))

        updated_node = %{
          node
          | relevance: new_relevance,
            last_accessed: DateTime.utc_now()
        }

        %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}
        |> maybe_add_to_active_set(updated_node)
    end
  end

  @doc """
  Get total token count across all nodes in the graph.
  """
  @spec total_tokens(t()) :: non_neg_integer()
  def total_tokens(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.reduce(0, fn node, acc -> acc + (node[:cached_tokens] || 0) end)
  end

  @doc """
  Get total token count for nodes in the active set.
  """
  @spec active_set_tokens(t()) :: non_neg_integer()
  def active_set_tokens(graph) do
    graph.active_set
    |> Enum.map(&Map.get(graph.nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(0, fn node, acc -> acc + (node[:cached_tokens] || 0) end)
  end

  @doc """
  Get nodes in the active set, sorted by relevance descending.

  When `max_tokens` is configured on the graph, delegates to `select_by_token_budget/4`
  to fit within the token budget.

  ## Options

  - `:model_context` - Override the token budget for this call
  """
  @spec active_set(t(), keyword()) :: [knowledge_node()]
  def active_set(graph, opts \\ []) do
    budget = Keyword.get(opts, :model_context, graph.max_tokens)

    nodes =
      graph.active_set
      |> Enum.map(&Map.get(graph.nodes, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.relevance, :desc)

    case budget do
      nil ->
        nodes

      budget ->
        max_tokens = TokenBudget.resolve(budget, TokenBudget.default_context_size())
        cognitive_prefs = Keyword.get(opts, :cognitive_preferences)
        effective_quotas = merge_quotas_with_preferences(graph.type_quotas, cognitive_prefs)
        select_by_token_budget(nodes, max_tokens, effective_quotas)
    end
  end

  @doc """
  Select nodes that fit within a token budget, respecting per-type quotas.

  Fills the budget greedily with highest-relevance nodes. When `type_quotas`
  is provided (e.g., `%{fact: 0.4, skill: 0.3}`), each type gets at most
  that fraction of the total budget.

  Returns the selected nodes in relevance order.
  """
  @spec select_by_token_budget([knowledge_node()], non_neg_integer(), map()) :: [knowledge_node()]
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
          type_budget = Map.get(type_limits, node.type)
          current_type_used = Map.get(type_used, node.type, 0)

          if type_budget && current_type_used + tokens > type_budget do
            {acc, total_used, type_used}
          else
            new_type_used = Map.put(type_used, node.type, current_type_used + tokens)
            {[node | acc], new_total, new_type_used}
          end
        end
      end)

    Enum.reverse(selected)
  end

  @doc """
  Recompute the active set from all nodes in the graph.

  Selects the top `max_active` nodes by relevance (minimum `@min_relevance`).
  """
  @spec refresh_active_set(t()) :: t()
  def refresh_active_set(graph) do
    new_active =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.relevance >= @min_relevance))
      |> Enum.sort_by(& &1.relevance, :desc)
      |> Enum.take(graph.max_active)
      |> Enum.map(& &1.id)

    %{graph | active_set: new_active}
  end

  @doc """
  Manually promote a node to the active set.

  If the active set is at capacity, the lowest-relevance node is evicted.
  """
  @spec promote_to_active(t(), node_id()) :: t()
  def promote_to_active(graph, node_id) do
    case Map.get(graph.nodes, node_id) do
      nil -> graph
      node -> maybe_add_to_active_set(graph, node)
    end
  end

  @doc """
  Search nodes by content similarity (simple substring match for now).

  ## Options

  - `:type` - Filter by node type
  - `:types` - Filter by multiple types
  - `:min_relevance` - Minimum relevance threshold
  - `:limit` - Maximum results

  ## Examples

      {:ok, nodes} = KnowledgeGraph.recall(graph, "Paris")
      {:ok, facts} = KnowledgeGraph.recall(graph, "capital", type: :fact)
  """
  @spec recall(t(), String.t(), keyword()) :: {:ok, [knowledge_node()]}
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

  Useful for deduplication — check if a node with this name already exists
  before adding a new one.

  ## Examples

      {:ok, node_id} = KnowledgeGraph.find_by_name(graph, "Elixir")
      {:error, :not_found} = KnowledgeGraph.find_by_name(graph, "nonexistent")
  """
  @spec find_by_name(t(), String.t()) :: {:ok, node_id()} | {:error, :not_found}
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

  Unlike `find_by_name/2` which requires an exact match and returns a single ID,
  this returns all nodes whose content contains the query string.

  Results are sorted by relevance (descending).
  """
  @spec search_by_name(t(), String.t()) :: [knowledge_node()]
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
  @spec semantic_search(t(), String.t(), keyword()) :: {:ok, [knowledge_node()]}
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
  # Cascade Recall + Context Generation + Query Helpers
  # ============================================================================

  @doc """
  Spreading activation: boosts a starting node and its neighbors recursively
  with a decaying boost factor.

  Starting from `node_id`, applies `boost_amount` to that node, then
  `boost_amount * decay_factor` to its immediate neighbors, and so on up to `max_depth`.

  ## Options

  - `:max_depth` - Maximum recursion depth (default 3)
  - `:min_boost` - Stop spreading when boost falls below this (default 0.05)
  - `:decay_factor` - Multiplier for boost at each hop (default 0.5)
  """
  @spec cascade_recall(t(), node_id(), float(), keyword()) :: t()
  def cascade_recall(graph, node_id, boost_amount, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 3)
    min_boost = Keyword.get(opts, :min_boost, 0.05)
    decay_factor = Keyword.get(opts, :decay_factor, 0.5)

    spread_activation(graph, [node_id], boost_amount, max_depth, min_boost, decay_factor, MapSet.new())
  end

  @doc """
  Generate LLM context text from the active set.

  Formats each node as `- [type] content (N% relevance)` and optionally
  includes relationship lines `  → relationship: target_content`.

  ## Options

  - `:include_relationships` - Include edge info (default true)
  - `:model_context` - Override token budget
  """
  @spec to_prompt_text(t(), keyword()) :: String.t()
  def to_prompt_text(graph, opts \\ []) do
    include_rels = Keyword.get(opts, :include_relationships, true)
    nodes = active_set(graph, opts)

    if nodes == [] do
      ""
    else
      body =
        nodes
        |> Enum.map(fn node ->
          pct = round(node.relevance * 100)
          line = "    - [#{node.type}] #{node.content} (#{pct}% relevance)"

          if include_rels do
            rels = format_node_relationships(graph, node.id)

            if rels == "" do
              line
            else
              line <> "\n" <> rels
            end
          else
            line
          end
        end)
        |> Enum.join("\n")

      "## Knowledge Graph (Active Context)\n\n" <> body
    end
  end

  @doc """
  Alias for `list_by_type/2` (API compatibility).
  """
  @spec find_by_type(t(), node_type()) :: [knowledge_node()]
  def find_by_type(graph, type), do: list_by_type(graph, type)

  @doc """
  Filter nodes by type and a custom criteria function, with options.

  ## Options

  - `:limit` - Max results
  - `:sort_by` - Sort field (`:relevance`, `:created_at`, `:last_accessed`)
  """
  @spec find_by_type_and_criteria(t(), node_type(), (knowledge_node() -> boolean()), keyword()) ::
          [knowledge_node()]
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
  @spec recent_nodes(t(), keyword()) :: [knowledge_node()]
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
  @spec get_tool_learnings(t()) :: map()
  def get_tool_learnings(graph) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :skill))
    |> Enum.group_by(fn node -> Map.get(node.metadata, :tool_name, "unknown") end)
  end

  @doc """
  Get skill nodes for a specific tool.
  """
  @spec get_tool_learnings(t(), String.t()) :: [knowledge_node()]
  def get_tool_learnings(graph, tool_name) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(fn node ->
      node.type == :skill and Map.get(node.metadata, :tool_name) == tool_name
    end)
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  # ============================================================================
  # Decay and Pruning
  # ============================================================================

  @doc """
  Apply decay to all non-pinned nodes.

  Reduces relevance of each node by the configured decay rate.
  Pinned nodes are not affected.
  """
  @spec decay(t()) :: t()
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
  Prune nodes below the relevance threshold.

  Pinned nodes are never pruned.

  Returns `{updated_graph, pruned_count}`.
  """
  @spec prune(t(), float()) :: {t(), non_neg_integer()}
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

  @doc """
  Apply exponential time-based decay to all non-pinned nodes.

  Uses the formula: `relevance * e^(-λ * days_since_access)` where λ is the
  decay rate. This produces a smooth exponential curve that decays faster
  initially and slows down over time, unlike the linear `decay/1`.

  ## Options

  - `:pinned_ids` - Set of node IDs to skip (in addition to pinned nodes)
  - `:decay_rate_override` - Override the graph's decay rate for this call
  """
  @spec apply_decay(t(), keyword()) :: t()
  def apply_decay(graph, opts \\ []) do
    now = DateTime.utc_now()
    lambda = Keyword.get(opts, :decay_rate_override, Map.get(graph.config, :decay_rate, @default_decay_rate))
    pinned_ids = normalize_pinned_ids(Keyword.get(opts, :pinned_ids))

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

    %{graph | nodes: new_nodes, last_decay_at: now}
    |> refresh_active_set()
  end

  @doc """
  Prune nodes below threshold and emit archival signals for each removed node.

  Returns `{updated_graph, archived_count}`.
  """
  @spec prune_and_archive(t(), keyword()) :: {t(), non_neg_integer()}
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
      Arbor.Memory.Signals.emit_knowledge_archived(graph.agent_id, node, :low_relevance)
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
  Combined operation: decay → prune/archive → refresh active set.

  Skips processing when the graph is under capacity unless `:force` is set.

  ## Options

  - `:force` - Run even when under capacity
  - `:threshold` - Override prune threshold
  - All options from `apply_decay/2`
  """
  @spec decay_and_archive(t(), keyword()) :: {t(), non_neg_integer()}
  def decay_and_archive(graph, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    total_capacity = Map.get(graph.config, :max_nodes_per_type, @default_max_nodes_per_type) * length(@allowed_node_types)

    if not force and map_size(graph.nodes) < total_capacity * 0.8 do
      {graph, 0}
    else
      graph = apply_decay(graph, opts)
      prune_and_archive(graph, opts)
    end
  end

  # ============================================================================
  # Pending Queues (Proposal Mechanism)
  # ============================================================================

  @doc """
  Add a pending fact for agent review.

  Facts are auto-extracted by background processes and await agent approval.
  """
  @spec add_pending_fact(t(), map()) :: {:ok, t(), String.t()}
  def add_pending_fact(graph, fact_data) do
    pending_id = generate_pending_id()

    pending = %{
      id: pending_id,
      type: :fact,
      content: Map.fetch!(fact_data, :content),
      confidence: Map.get(fact_data, :confidence, 0.5),
      source: Map.get(fact_data, :source),
      extracted_at: DateTime.utc_now(),
      metadata: Map.get(fact_data, :metadata, %{})
    }

    new_graph = %{graph | pending_facts: [pending | graph.pending_facts]}
    {:ok, new_graph, pending_id}
  end

  @doc """
  Add a pending learning for agent review.

  Learnings are action patterns detected by background analysis.
  """
  @spec add_pending_learning(t(), map()) :: {:ok, t(), String.t()}
  def add_pending_learning(graph, learning_data) do
    pending_id = generate_pending_id()

    pending = %{
      id: pending_id,
      type: :learning,
      content: Map.fetch!(learning_data, :content),
      confidence: Map.get(learning_data, :confidence, 0.5),
      source: Map.get(learning_data, :source),
      extracted_at: DateTime.utc_now(),
      metadata: Map.get(learning_data, :metadata, %{})
    }

    new_graph = %{graph | pending_learnings: [pending | graph.pending_learnings]}
    {:ok, new_graph, pending_id}
  end

  @doc """
  Approve a pending item and add it to the graph as a node.
  """
  @spec approve_pending(t(), String.t()) :: {:ok, t(), node_id()} | {:error, :not_found}
  def approve_pending(graph, pending_id) do
    case find_and_remove_pending(graph, pending_id) do
      {:ok, pending, new_graph} ->
        node_type = pending_type_to_node_type(pending.type)

        add_node(new_graph, %{
          type: node_type,
          content: pending.content,
          metadata:
            Map.merge(pending.metadata, %{
              source: pending.source,
              original_confidence: pending.confidence
            })
        })

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Reject a pending item (remove without adding to graph).
  """
  @spec reject_pending(t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def reject_pending(graph, pending_id) do
    case find_and_remove_pending(graph, pending_id) do
      {:ok, _pending, new_graph} ->
        {:ok, new_graph}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Get all pending items (facts and learnings).
  """
  @spec get_pending(t()) :: [pending_item()]
  def get_pending(graph) do
    graph.pending_facts ++ graph.pending_learnings
  end

  @doc """
  Get pending facts only.
  """
  @spec get_pending_facts(t()) :: [pending_item()]
  def get_pending_facts(graph), do: graph.pending_facts

  @doc """
  Get pending learnings only.
  """
  @spec get_pending_learnings(t()) :: [pending_item()]
  def get_pending_learnings(graph), do: graph.pending_learnings

  @doc """
  Approve all pending facts at once, creating nodes for each.

  Returns `{:ok, graph, node_ids}` with the IDs of all created nodes.
  """
  @spec approve_all_facts(t()) :: {:ok, t(), [node_id()]}
  def approve_all_facts(%{pending_facts: []} = graph), do: {:ok, graph, []}

  def approve_all_facts(graph) do
    {updated_graph, ids} =
      Enum.reduce(graph.pending_facts, {graph, []}, fn pending, {g, acc} ->
        {:ok, g, node_id} = approve_pending(g, pending.id)
        {g, [node_id | acc]}
      end)

    {:ok, updated_graph, Enum.reverse(ids)}
  end

  @doc """
  Approve all pending learnings at once, creating nodes for each.

  Returns `{:ok, graph, node_ids}` with the IDs of all created nodes.
  """
  @spec approve_all_learnings(t()) :: {:ok, t(), [node_id()]}
  def approve_all_learnings(%{pending_learnings: []} = graph), do: {:ok, graph, []}

  def approve_all_learnings(graph) do
    {updated_graph, ids} =
      Enum.reduce(graph.pending_learnings, {graph, []}, fn pending, {g, acc} ->
        {:ok, g, node_id} = approve_pending(g, pending.id)
        {g, [node_id | acc]}
      end)

    {:ok, updated_graph, Enum.reverse(ids)}
  end

  # ============================================================================
  # Statistics and Queries
  # ============================================================================

  @doc """
  Get statistics about the knowledge graph.
  """
  @spec stats(t()) :: map()
  def stats(graph) do
    node_values = Map.values(graph.nodes)

    nodes_by_type =
      node_values
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, nodes} -> {type, length(nodes)} end)

    tokens_by_type =
      node_values
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, nodes} ->
        {type, Enum.reduce(nodes, 0, fn n, acc -> acc + (n[:cached_tokens] || 0) end)}
      end)

    edges_by_relationship =
      graph.edges
      |> Map.values()
      |> List.flatten()
      |> Enum.group_by(& &1.relationship)
      |> Map.new(fn {rel, edges} -> {rel, length(edges)} end)

    avg_relevance =
      if map_size(graph.nodes) > 0 do
        total = Enum.sum(Enum.map(node_values, & &1.relevance))
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
      total_tokens: total_tokens(graph),
      active_set_size: length(graph.active_set),
      active_set_tokens: active_set_tokens(graph),
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
  @spec list_by_type(t(), node_type()) :: [knowledge_node()]
  def list_by_type(graph, type) do
    graph.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == type))
    |> Enum.sort_by(& &1.relevance, :desc)
  end

  @doc """
  Get nodes with lowest relevance (candidates for pruning).
  """
  @spec lowest_relevance(t(), non_neg_integer()) :: [knowledge_node()]
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
  @spec stale_nodes(t(), non_neg_integer()) :: [knowledge_node()]
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
  # Serialization
  # ============================================================================

  @doc """
  Convert the graph to a map for persistence.
  """
  @spec to_map(t()) :: map()
  def to_map(graph) do
    # Strip embeddings from nodes for serialization (recompute on load)
    serialized_nodes =
      Map.new(graph.nodes, fn {id, node} ->
        {id, Map.drop(node, [:embedding])}
      end)

    %{
      agent_id: graph.agent_id,
      nodes: serialized_nodes,
      edges: graph.edges,
      pending_facts: graph.pending_facts,
      pending_learnings: graph.pending_learnings,
      config: graph.config,
      active_set: graph.active_set,
      max_active: graph.max_active,
      dedup_threshold: graph.dedup_threshold,
      max_tokens: graph.max_tokens,
      type_quotas: graph.type_quotas,
      last_decay_at: graph.last_decay_at
    }
  end

  @doc """
  Restore a graph from a persisted map.
  """
  @spec from_map(map()) :: t()
  def from_map(data) do
    # Ensure nodes have all expected fields (backward compat)
    nodes =
      (data[:nodes] || data["nodes"] || %{})
      |> Map.new(fn {id, node} ->
        {id, ensure_node_fields(node)}
      end)

    %__MODULE__{
      agent_id: data[:agent_id] || data["agent_id"],
      nodes: nodes,
      edges: data[:edges] || data["edges"] || %{},
      pending_facts: data[:pending_facts] || data["pending_facts"] || [],
      pending_learnings: data[:pending_learnings] || data["pending_learnings"] || [],
      config: data[:config] || data["config"] || %{},
      active_set: data[:active_set] || data["active_set"] || [],
      max_active: data[:max_active] || data["max_active"] || 50,
      dedup_threshold: data[:dedup_threshold] || data["dedup_threshold"] || 0.85,
      max_tokens: data[:max_tokens] || data["max_tokens"],
      type_quotas: data[:type_quotas] || data["type_quotas"] || %{},
      last_decay_at: data[:last_decay_at] || data["last_decay_at"]
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp validate_node_type(%{type: type}) when is_atom(type) do
    if type in @allowed_node_types do
      {:ok, type}
    else
      case SafeAtom.to_allowed(type, @allowed_node_types) do
        {:ok, atom} -> {:ok, atom}
        {:error, _} -> {:error, {:invalid_type, type}}
      end
    end
  end

  defp validate_node_type(%{type: type}) when is_binary(type) do
    case SafeAtom.to_allowed(type, @allowed_node_types) do
      {:ok, atom} -> {:ok, atom}
      {:error, _} -> {:error, {:invalid_type, type}}
    end
  end

  defp validate_node_type(_), do: {:error, :missing_type}

  defp validate_content(%{content: content}) when is_binary(content) and content != "" do
    {:ok, content}
  end

  defp validate_content(_), do: {:error, :missing_content}

  defp check_quota(graph, type) do
    max = Map.get(graph.config, :max_nodes_per_type, @default_max_nodes_per_type)
    count = graph.nodes |> Map.values() |> Enum.count(&(&1.type == type))

    if count < max do
      :ok
    else
      {:error, {:quota_exceeded, type}}
    end
  end

  defp generate_node_id do
    "node_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_edge_id do
    "edge_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_pending_id do
    "pend_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp maybe_update(node, key, updates) do
    case Map.fetch(updates, key) do
      {:ok, value} -> Map.put(node, key, value)
      :error -> node
    end
  end

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

  defp find_and_remove_pending(graph, pending_id) do
    case Enum.find(graph.pending_facts, &(&1.id == pending_id)) do
      nil ->
        case Enum.find(graph.pending_learnings, &(&1.id == pending_id)) do
          nil ->
            :error

          learning ->
            new_learnings = Enum.reject(graph.pending_learnings, &(&1.id == pending_id))
            {:ok, learning, %{graph | pending_learnings: new_learnings}}
        end

      fact ->
        new_facts = Enum.reject(graph.pending_facts, &(&1.id == pending_id))
        {:ok, fact, %{graph | pending_facts: new_facts}}
    end
  end

  defp pending_type_to_node_type(:fact), do: :fact
  defp pending_type_to_node_type(:learning), do: :skill

  defp merge_quotas_with_preferences(system_quotas, nil), do: system_quotas
  defp merge_quotas_with_preferences(system_quotas, %{type_quotas: nil}), do: system_quotas

  defp merge_quotas_with_preferences(system_quotas, %{type_quotas: agent_quotas})
       when is_map(agent_quotas) do
    Map.merge(system_quotas, agent_quotas)
  end

  defp merge_quotas_with_preferences(system_quotas, _), do: system_quotas

  defp normalize_pinned_ids(nil), do: MapSet.new()
  defp normalize_pinned_ids(%MapSet{} = set), do: set
  defp normalize_pinned_ids(list) when is_list(list), do: MapSet.new(list)

  # Active set management: add node if relevant, evict lowest if at capacity
  defp maybe_add_to_active_set(graph, node) do
    if node.relevance >= @min_relevance do
      # Remove existing entry if present (to update position)
      active = List.delete(graph.active_set, node.id)
      new_active = [node.id | active]

      if length(new_active) > graph.max_active do
        # Evict the lowest-relevance node
        {_worst_id, trimmed} =
          new_active
          |> Enum.map(fn id ->
            n = Map.get(graph.nodes, id)
            relevance = if n, do: n.relevance, else: 0.0
            {id, relevance}
          end)
          |> Enum.sort_by(fn {_id, rel} -> rel end, :asc)
          |> then(fn [{worst_id, _} | rest] ->
            {worst_id, Enum.map(rest, fn {id, _} -> id end)}
          end)

        %{graph | active_set: trimmed}
      else
        %{graph | active_set: new_active}
      end
    else
      graph
    end
  end

  # Build text representation for token estimation and embedding
  defp node_to_text(content, metadata) when is_binary(content) do
    metadata_text =
      metadata
      |> Map.values()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    if metadata_text == "" do
      content
    else
      content <> " " <> metadata_text
    end
  end

  defp node_to_text(content, _metadata), do: to_string(content)

  # Ensure deserialized nodes have all fields with defaults
  defp ensure_node_fields(node) when is_map(node) do
    node
    |> Map.put_new(:confidence, 0.5)
    |> Map.put_new(:embedding, nil)
    |> Map.put_new(:cached_tokens, 0)
    |> Map.put_new(:pinned, false)
    |> Map.put_new(:access_count, 0)
    |> Map.put_new(:metadata, %{})
  end

  # BFS traversal for find_related — bidirectional with optional relationship filter
  defp find_related_recursive(_graph, _frontier, visited, 0, _relationship), do: visited
  defp find_related_recursive(_graph, [], visited, _depth, _relationship), do: visited

  defp find_related_recursive(graph, frontier, visited, depth, relationship) do
    neighbors =
      frontier
      |> Enum.flat_map(&get_neighbor_ids_filtered(graph, &1, relationship))
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    if neighbors == [] do
      visited
    else
      new_visited = Enum.reduce(neighbors, visited, &MapSet.put(&2, &1))
      find_related_recursive(graph, neighbors, new_visited, depth - 1, relationship)
    end
  end

  defp get_neighbor_ids_filtered(graph, node_id, nil) do
    get_neighbor_ids(graph, node_id)
  end

  defp get_neighbor_ids_filtered(graph, node_id, relationship) do
    outgoing =
      graph.edges
      |> Map.get(node_id, [])
      |> Enum.filter(&(&1.relationship == relationship))
      |> Enum.map(& &1.target_id)

    incoming =
      graph.edges
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1.target_id == node_id and &1.relationship == relationship))
      |> Enum.map(& &1.source_id)

    Enum.uniq(outgoing ++ incoming)
  end

  # Spreading activation — recursive frontier-based
  defp spread_activation(graph, _frontier, _boost, 0, _min_boost, _decay, _visited), do: graph
  defp spread_activation(graph, [], _boost, _depth, _min_boost, _decay, _visited), do: graph

  defp spread_activation(graph, frontier, boost, depth, min_boost, decay_factor, visited) do
    if boost < min_boost do
      graph
    else
      {graph, next_frontier} =
        Enum.reduce(frontier, {graph, []}, fn node_id, {g, next} ->
          if node_id in visited do
            {g, next}
          else
            g = boost_node(g, node_id, boost)
            neighbors = get_neighbor_ids(g, node_id) -- MapSet.to_list(visited)
            {g, neighbors ++ next}
          end
        end)

      new_visited = Enum.reduce(frontier, visited, &MapSet.put(&2, &1))
      spread_activation(graph, Enum.uniq(next_frontier), boost * decay_factor, depth - 1, min_boost, decay_factor, new_visited)
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

  defp format_node_relationships(graph, node_id) do
    outgoing = Map.get(graph.edges, node_id, [])

    outgoing_lines =
      Enum.map(outgoing, fn edge ->
        target = Map.get(graph.nodes, edge.target_id)
        target_text = if target, do: target.content, else: edge.target_id
        "        → #{edge.relationship}: #{target_text}"
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
        "        ← #{edge.relationship}: #{source_text}"
      end)

    (outgoing_lines ++ incoming_lines) |> Enum.join("\n")
  end

  # Embedding service helpers
  defp embedding_service_available? do
    Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :embed, 2)
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

  defp maybe_find_duplicate(_graph, _type, _content, _embedding, true), do: :no_duplicate

  defp maybe_find_duplicate(graph, type, content, embedding, _skip) do
    same_type_nodes =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.type == type))

    # Try semantic dedup first if embeddings available
    if embedding && length(embedding) > 0 do
      case Enum.find(same_type_nodes, fn node ->
             node.embedding && length(node.embedding) > 0 &&
               cosine_similarity(embedding, node.embedding) >= graph.dedup_threshold
           end) do
        nil -> check_exact_duplicate(same_type_nodes, content)
        node -> {:duplicate, node.id}
      end
    else
      check_exact_duplicate(same_type_nodes, content)
    end
  end

  defp check_exact_duplicate(nodes, content) do
    content_lower = String.downcase(content)

    case Enum.find(nodes, fn node ->
           String.downcase(node.content) == content_lower
         end) do
      nil -> :no_duplicate
      node -> {:duplicate, node.id}
    end
  end

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

    if length(query_terms) > 0 do
      matching / length(query_terms)
    else
      0.0
    end
  end
end
