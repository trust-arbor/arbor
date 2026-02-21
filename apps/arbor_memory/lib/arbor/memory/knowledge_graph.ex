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
  - `:goal` - References to GoalStore entries
  - `:observation` - Thoughts, concerns, curiosity (abstract)
  - `:trait` - Identity/self-knowledge entries
  - `:intention` - Planned actions (IntentStore references)

  ## Decay and Reinforcement

  Nodes have a `relevance` score (0.0 - 1.0) that:
  - Decays over time if the node is not accessed
  - Increases when the node is recalled (reinforcement)
  - Falls below a threshold → candidate for pruning

  ## Sub-modules

  - `Arbor.Memory.KnowledgeGraph.DecayEngine` - Decay, pruning, and archival
  - `Arbor.Memory.KnowledgeGraph.GraphSearch` - Search, query, and context generation

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

  alias Arbor.Common.{LazyLoader, SafeAtom}
  alias Arbor.Memory.KnowledgeGraph.DecayEngine
  alias Arbor.Memory.KnowledgeGraph.GraphSearch
  alias Arbor.Memory.TokenBudget

  require Logger

  @type node_id :: String.t()
  @type edge_id :: String.t()

  @type node_type ::
          :fact | :experience | :skill | :insight | :relationship |
          :goal | :observation | :trait | :intention

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
          created_at: DateTime.t(),
          metadata: map()
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

  @allowed_node_types [:fact, :experience, :skill, :insight, :relationship,
                       :goal, :observation, :trait, :intention]
  @default_decay_rate 0.10
  @default_reinforce_amount 0.15
  @default_max_nodes_per_type 500
  @default_prune_threshold 0.1
  @min_relevance 0.01

  # ============================================================================
  # Delegated: Decay and Pruning (DecayEngine)
  # ============================================================================

  defdelegate decay(graph), to: DecayEngine
  defdelegate apply_decay(graph, opts \\ []), to: DecayEngine
  defdelegate prune(graph, threshold \\ @default_prune_threshold), to: DecayEngine
  defdelegate prune_and_archive(graph, opts \\ []), to: DecayEngine
  defdelegate decay_and_archive(graph, opts \\ []), to: DecayEngine

  # ============================================================================
  # Delegated: Search, Query, and Context (GraphSearch)
  # ============================================================================

  defdelegate recall(graph, query, opts \\ []), to: GraphSearch
  defdelegate find_by_name(graph, name), to: GraphSearch
  defdelegate search_by_name(graph, query), to: GraphSearch
  defdelegate semantic_search(graph, query, opts \\ []), to: GraphSearch
  defdelegate cascade_recall(graph, node_id, boost_amount, opts \\ []), to: GraphSearch
  defdelegate to_prompt_text(graph, opts \\ []), to: GraphSearch
  defdelegate find_by_type(graph, type), to: GraphSearch
  defdelegate find_by_type_and_criteria(graph, type, criteria_fn, opts \\ []), to: GraphSearch
  defdelegate recent_nodes(graph, opts \\ []), to: GraphSearch
  defdelegate get_tool_learnings(graph), to: GraphSearch
  defdelegate get_tool_learnings(graph, tool_name), to: GraphSearch
  defdelegate stats(graph), to: GraphSearch
  defdelegate list_by_type(graph, type), to: GraphSearch
  defdelegate lowest_relevance(graph, count \\ 10), to: GraphSearch
  defdelegate stale_nodes(graph, days \\ 7), to: GraphSearch
  defdelegate select_by_token_budget(nodes, max_tokens, type_quotas \\ %{}), to: GraphSearch

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
      text = node_to_text(content, metadata, type)
      embedding = compute_node_embedding(text)

      # Check for duplicates unless skipped
      case maybe_find_duplicate(graph, type, content, embedding, skip_dedup) do
        {:duplicate, existing_id} ->
          # Boost existing node instead of creating duplicate
          boosted = boost_node(graph, existing_id, 0.1)
          {:ok, boosted, existing_id}

        :no_duplicate ->
          node_id = generate_node_id(type)
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
  - `:metadata` - Arbitrary metadata map (default: %{}). Merged on duplicate edges.

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
      edge_metadata = Keyword.get(opts, :metadata, %{})

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
            created_at: DateTime.utc_now(),
            metadata: edge_metadata
          }

          new_edges = Map.put(graph.edges, source_id, [edge | existing_edges])
          {:ok, %{graph | edges: new_edges}}

        idx ->
          # Existing edge -- increment strength and merge metadata
          existing_edge = Enum.at(existing_edges, idx)
          merged_meta = Map.merge(Map.get(existing_edge, :metadata, %{}), edge_metadata)
          updated_edge = %{existing_edge | strength: min(10.0, existing_edge.strength + 0.5), metadata: merged_meta}

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
  """
  @spec boost_node(t(), node_id(), float()) :: t()
  def boost_node(graph, node_id, boost_amount) when is_number(boost_amount) do
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
        GraphSearch.select_by_token_budget(nodes, max_tokens, effective_quotas)
    end
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
    nodes = deserialize_nodes(data)
    edges = deserialize_edges(data)

    %__MODULE__{
      agent_id: get_field(data, :agent_id),
      nodes: nodes,
      edges: edges,
      pending_facts: get_field(data, :pending_facts, []),
      pending_learnings: get_field(data, :pending_learnings, []),
      config: get_field(data, :config, %{}),
      active_set: get_field(data, :active_set, []),
      max_active: get_field(data, :max_active, 50),
      dedup_threshold: get_field(data, :dedup_threshold, 0.85),
      max_tokens: get_field(data, :max_tokens),
      type_quotas: get_field(data, :type_quotas, %{}),
      last_decay_at: get_field(data, :last_decay_at)
    }
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Deserialization helpers for from_map/1

  defp deserialize_nodes(data) do
    (get_field(data, :nodes, %{}))
    |> Map.new(fn {id, node} ->
      {id, ensure_node_fields(node)}
    end)
  end

  defp deserialize_edges(data) do
    (get_field(data, :edges, %{}))
    |> Map.new(fn {source_id, edge_list} ->
      {source_id, Enum.map(edge_list, &ensure_edge_fields/1)}
    end)
  end

  defp get_field(data, key), do: data[key] || data[Atom.to_string(key)]

  defp get_field(data, key, default), do: get_field(data, key) || default

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

  defp generate_node_id(type) do
    "node_#{type}_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
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

  # Active set management: add node if relevant, evict lowest if at capacity
  defp maybe_add_to_active_set(graph, node) do
    if node.relevance >= @min_relevance do
      # Remove existing entry if present (to update position)
      active = List.delete(graph.active_set, node.id)
      new_active = [node.id | active]
      enforce_active_set_capacity(graph, new_active)
    else
      graph
    end
  end

  defp enforce_active_set_capacity(graph, new_active) do
    if length(new_active) > graph.max_active do
      trimmed = evict_lowest_relevance(graph, new_active)
      %{graph | active_set: trimmed}
    else
      %{graph | active_set: new_active}
    end
  end

  defp evict_lowest_relevance(graph, active_ids) do
    {_worst_id, trimmed} =
      active_ids
      |> Enum.map(fn id ->
        n = Map.get(graph.nodes, id)
        {id, node_relevance(n)}
      end)
      |> Enum.sort_by(fn {_id, rel} -> rel end, :asc)
      |> then(fn [{worst_id, _} | rest] ->
        {worst_id, Enum.map(rest, fn {id, _} -> id end)}
      end)

    trimmed
  end

  defp node_relevance(nil), do: 0.0
  defp node_relevance(node), do: node.relevance

  # Build text representation for token estimation and embedding
  defp node_to_text(content, metadata, type) when is_binary(content) do
    parts = []

    # Include type for richer semantic signal
    parts = if type, do: ["[#{type}]" | parts], else: parts

    # Include name from metadata if present (e.g., entity names, labels)
    name = Map.get(metadata, :name) || Map.get(metadata, "name")
    parts = if name && is_binary(name) && name != content, do: [name | parts], else: parts

    # Main content
    parts = [content | parts]

    # Include other string metadata values (description, context, etc.)
    skip_keys = [:name, "name", :tool_name, "tool_name"]

    metadata_text =
      metadata
      |> Map.drop(skip_keys)
      |> Map.values()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    parts = if metadata_text != "", do: [metadata_text | parts], else: parts

    parts |> Enum.reverse() |> Enum.join(" ")
  end

  defp node_to_text(content, _metadata, _type), do: to_string(content)

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

  # Ensure deserialized edges have all fields with defaults
  defp ensure_edge_fields(edge) when is_map(edge) do
    Map.put_new(edge, :metadata, %{})
  end

  # BFS traversal for find_related -- bidirectional with optional relationship filter
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

  defp maybe_find_duplicate(_graph, _type, _content, _embedding, true), do: :no_duplicate

  defp maybe_find_duplicate(graph, type, content, embedding, _skip) do
    same_type_nodes =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.type == type))

    # Try semantic dedup first if embeddings available
    if embedding && embedding != [] do
      check_semantic_duplicate(same_type_nodes, embedding, graph.dedup_threshold, content)
    else
      check_exact_duplicate(same_type_nodes, content)
    end
  end

  defp check_semantic_duplicate(nodes, embedding, threshold, content) do
    case Enum.find(nodes, &semantic_match?(&1, embedding, threshold)) do
      nil -> check_exact_duplicate(nodes, content)
      node -> {:duplicate, node.id}
    end
  end

  defp semantic_match?(node, embedding, threshold) do
    node.embedding && node.embedding != [] &&
      cosine_similarity(embedding, node.embedding) >= threshold
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
end
