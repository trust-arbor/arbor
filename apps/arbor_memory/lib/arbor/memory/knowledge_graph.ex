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

  @type node_id :: String.t()
  @type edge_id :: String.t()

  @type node_type :: :fact | :experience | :skill | :insight | :relationship | :custom

  @type knowledge_node :: %{
          id: node_id(),
          type: node_type(),
          content: String.t(),
          relevance: float(),
          access_count: non_neg_integer(),
          created_at: DateTime.t(),
          last_accessed: DateTime.t(),
          metadata: map(),
          pinned: boolean()
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
          config: map()
        }

  defstruct [
    :agent_id,
    nodes: %{},
    edges: %{},
    pending_facts: [],
    pending_learnings: [],
    config: %{}
  ]

  @allowed_node_types [:fact, :experience, :skill, :insight, :relationship, :custom]
  @default_decay_rate 0.10
  @default_reinforce_amount 0.15
  @default_max_nodes_per_type 500
  @default_prune_threshold 0.1

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
      config: config
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
      node_id = generate_node_id()
      now = DateTime.utc_now()

      node = %{
        id: node_id,
        type: type,
        content: content,
        relevance: Map.get(node_data, :relevance, 1.0),
        access_count: 0,
        created_at: now,
        last_accessed: now,
        metadata: Map.get(node_data, :metadata, %{}),
        pinned: Map.get(node_data, :pinned, false)
      }

      new_graph = %{graph | nodes: Map.put(graph.nodes, node_id, node)}
      {:ok, new_graph, node_id}
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

        {:ok, %{graph | nodes: new_nodes, edges: new_edges}}

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
      edge_id = generate_edge_id()
      strength = Keyword.get(opts, :strength, 1.0)

      edge = %{
        id: edge_id,
        source_id: source_id,
        target_id: target_id,
        relationship: relationship,
        strength: strength,
        created_at: DateTime.utc_now()
      }

      existing_edges = Map.get(graph.edges, source_id, [])
      new_edges = Map.put(graph.edges, source_id, [edge | existing_edges])

      {:ok, %{graph | edges: new_edges}}
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
  Get nodes connected to a given node (outgoing edges).
  """
  @spec get_connected_nodes(t(), node_id()) :: [knowledge_node()]
  def get_connected_nodes(graph, node_id) do
    graph
    |> get_edges(node_id)
    |> Enum.map(& &1.target_id)
    |> Enum.map(&Map.get(graph.nodes, &1))
    |> Enum.reject(&is_nil/1)
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

        new_graph = %{graph | nodes: Map.put(graph.nodes, node_id, updated_node)}
        {:ok, new_graph, updated_node}

      :error ->
        {:error, :not_found}
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

    {%{graph | nodes: new_nodes, edges: new_edges}, pruned_count}
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

  # ============================================================================
  # Statistics and Queries
  # ============================================================================

  @doc """
  Get statistics about the knowledge graph.
  """
  @spec stats(t()) :: map()
  def stats(graph) do
    nodes_by_type =
      graph.nodes
      |> Map.values()
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, nodes} -> {type, length(nodes)} end)

    avg_relevance =
      if map_size(graph.nodes) > 0 do
        total = Enum.sum(Enum.map(Map.values(graph.nodes), & &1.relevance))
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
      edge_count: edge_count,
      average_relevance: Float.round(avg_relevance, 3),
      pending_facts: length(graph.pending_facts),
      pending_learnings: length(graph.pending_learnings),
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
    %{
      agent_id: graph.agent_id,
      nodes: graph.nodes,
      edges: graph.edges,
      pending_facts: graph.pending_facts,
      pending_learnings: graph.pending_learnings,
      config: graph.config
    }
  end

  @doc """
  Restore a graph from a persisted map.
  """
  @spec from_map(map()) :: t()
  def from_map(data) do
    %__MODULE__{
      agent_id: data.agent_id,
      nodes: data.nodes || %{},
      edges: data.edges || %{},
      pending_facts: data.pending_facts || [],
      pending_learnings: data.pending_learnings || [],
      config: data.config || %{}
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
end
