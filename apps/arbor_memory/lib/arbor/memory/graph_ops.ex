defmodule Arbor.Memory.GraphOps do
  @moduledoc """
  Knowledge graph operations with ETS persistence and signal emission.

  Wraps `KnowledgeGraph` calls with the load/save/signal pattern that
  the facade previously handled inline. All functions take `agent_id`
  as the first parameter and handle ETS lookup + save automatically.
  """

  alias Arbor.Memory.{KnowledgeGraph, MemoryStore, Signals}

  @graph_ets :arbor_memory_graphs

  # ============================================================================
  # Graph ETS Helpers
  # ============================================================================

  @doc """
  Get the knowledge graph for an agent from ETS.
  """
  @spec get_graph(String.t()) :: {:ok, KnowledgeGraph.t()} | {:error, :graph_not_initialized}
  def get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end

  @doc """
  Save the knowledge graph for an agent to ETS.
  """
  @spec save_graph(String.t(), KnowledgeGraph.t()) :: :ok
  def save_graph(agent_id, graph) do
    :ets.insert(@graph_ets, {agent_id, graph})
    :ok
  end

  @doc """
  Persist the knowledge graph to Postgres asynchronously.

  Serializes via `KnowledgeGraph.to_map/1` and writes through MemoryStore.
  Failures are logged but never affect the caller.
  """
  @spec persist_graph_async(String.t()) :: :ok
  def persist_graph_async(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} ->
        graph_map = KnowledgeGraph.to_map(graph)
        MemoryStore.persist_async("knowledge_graph", agent_id, graph_map)

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Load a persisted knowledge graph from Postgres.

  Returns `{:ok, graph}` if found, `{:error, :not_found}` otherwise.
  Used during agent restart to recover learned knowledge.
  """
  @spec load_persisted_graph(String.t()) :: {:ok, KnowledgeGraph.t()} | {:error, :not_found}
  def load_persisted_graph(agent_id) do
    case MemoryStore.load("knowledge_graph", agent_id) do
      {:ok, graph_map} when is_map(graph_map) ->
        graph = KnowledgeGraph.from_map(graph_map)
        {:ok, graph}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Check if an agent has an initialized knowledge graph.
  """
  @spec has_graph?(String.t()) :: boolean()
  def has_graph?(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, _}] -> true
      [] -> false
    end
  end

  @doc """
  Fetch graph with safe ETS access (returns nil on missing table or agent).
  """
  @spec fetch_graph(String.t()) :: KnowledgeGraph.t() | nil
  def fetch_graph(agent_id) do
    if :ets.whereis(@graph_ets) != :undefined do
      case :ets.lookup(@graph_ets, agent_id) do
        [{^agent_id, graph}] -> graph
        [] -> nil
      end
    end
  rescue
    _ -> nil
  end

  # ============================================================================
  # Knowledge Graph Operations
  # ============================================================================

  @doc """
  Add a knowledge node to the agent's graph.

  ## Node Data

  - `:type` - Node type (required): :fact, :experience, :skill, :insight, :relationship
  - `:content` - Node content (required)
  - `:relevance` - Initial relevance (optional, default: 1.0)
  - `:metadata` - Additional metadata (optional)
  - `:pinned` - Whether node is protected from decay (optional)

  ## Examples

      {:ok, node_id} = GraphOps.add_knowledge("agent_001", %{
        type: :fact,
        content: "Paris is the capital of France"
      })
  """
  @spec add_knowledge(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def add_knowledge(agent_id, node_data) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node_id} <- KnowledgeGraph.add_node(graph, node_data) do
      save_graph(agent_id, new_graph)
      persist_graph_async(agent_id)
      Signals.emit_knowledge_added(agent_id, node_id, node_data[:type])
      {:ok, node_id}
    end
  end

  @doc """
  Link two knowledge nodes.

  ## Examples

      {:ok, _} = GraphOps.link_knowledge("agent_001", node_a, node_b, :supports)
  """
  @spec link_knowledge(String.t(), String.t(), String.t(), atom(), keyword()) ::
          :ok | {:error, term()}
  def link_knowledge(agent_id, source_id, target_id, relationship, opts \\ []) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph} <-
           KnowledgeGraph.add_edge(graph, source_id, target_id, relationship, opts) do
      save_graph(agent_id, new_graph)
      persist_graph_async(agent_id)
      Signals.emit_knowledge_linked(agent_id, source_id, target_id, relationship)
      :ok
    end
  end

  @doc """
  Recall a knowledge node, reinforcing its relevance.
  """
  @spec reinforce_knowledge(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reinforce_knowledge(agent_id, node_id) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node} <- KnowledgeGraph.reinforce(graph, node_id) do
      save_graph(agent_id, new_graph)
      persist_graph_async(agent_id)
      {:ok, node}
    end
  end

  @doc """
  Search knowledge graph by content.
  """
  @spec search_knowledge(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search_knowledge(agent_id, query, opts \\ []) do
    with {:ok, graph} <- get_graph(agent_id) do
      KnowledgeGraph.recall(graph, query, opts)
    end
  end

  @doc """
  Find a knowledge node by name (case-insensitive exact match).

  Useful for deduplication — check if a node with this name exists
  before creating a new one.

  ## Examples

      {:ok, node_id} = GraphOps.find_knowledge_by_name("agent_001", "Elixir")
      {:error, :not_found} = GraphOps.find_knowledge_by_name("agent_001", "nonexistent")
  """
  @spec find_knowledge_by_name(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def find_knowledge_by_name(agent_id, name) do
    with {:ok, graph} <- get_graph(agent_id) do
      KnowledgeGraph.find_by_name(graph, name)
    end
  end

  @doc """
  Get all pending proposals (facts and learnings awaiting approval).
  """
  @spec get_pending_proposals(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_pending_proposals(agent_id) do
    with {:ok, graph} <- get_graph(agent_id) do
      {:ok, KnowledgeGraph.get_pending(graph)}
    end
  end

  @doc """
  Approve a pending fact or learning.
  """
  @spec approve_pending(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def approve_pending(agent_id, pending_id) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node_id} <- KnowledgeGraph.approve_pending(graph, pending_id) do
      save_graph(agent_id, new_graph)
      persist_graph_async(agent_id)
      Signals.emit_pending_approved(agent_id, pending_id, node_id)
      {:ok, node_id}
    end
  end

  @doc """
  Reject a pending fact or learning.
  """
  @spec reject_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def reject_pending(agent_id, pending_id) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph} <- KnowledgeGraph.reject_pending(graph, pending_id) do
      save_graph(agent_id, new_graph)
      persist_graph_async(agent_id)
      Signals.emit_pending_rejected(agent_id, pending_id)
      :ok
    end
  end

  @doc """
  Get knowledge graph statistics.
  """
  @spec knowledge_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def knowledge_stats(agent_id) do
    with {:ok, graph} <- get_graph(agent_id) do
      {:ok, KnowledgeGraph.stats(graph)}
    end
  end

  @doc """
  Trigger spreading activation from a node, boosting related nodes.

  Performs a breadth-first traversal from `node_id`, boosting each
  connected node's relevance with exponential decay per hop.

  ## Options

  - `:max_depth` - Maximum hops from starting node (default: 3)
  - `:min_boost` - Stop spreading when boost drops below this (default: 0.05)
  - `:decay_factor` - Multiply boost by this per hop (default: 0.5)

  ## Examples

      {:ok, graph} = GraphOps.cascade_recall("agent_001", node_id, 0.3)
  """
  @spec cascade_recall(String.t(), String.t(), float(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cascade_recall(agent_id, node_id, boost_amount, opts \\ []) do
    with {:ok, graph} <- get_graph(agent_id) do
      updated_graph = KnowledgeGraph.cascade_recall(graph, node_id, boost_amount, opts)
      save_graph(agent_id, updated_graph)
      persist_graph_async(agent_id)
      {:ok, KnowledgeGraph.stats(updated_graph)}
    end
  end

  @doc """
  Get the lowest-relevance nodes approaching decay threshold.

  Useful for inspecting which memories are at risk of being pruned.

  ## Examples

      {:ok, nodes} = GraphOps.near_threshold_nodes("agent_001", 10)
  """
  @spec near_threshold_nodes(String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def near_threshold_nodes(agent_id, count \\ 10) do
    with {:ok, graph} <- get_graph(agent_id) do
      {:ok, KnowledgeGraph.lowest_relevance(graph, count)}
    end
  end

  @doc """
  Export the full knowledge graph for an agent as a serializable map.

  Used by `Arbor.Agent.Seed.capture/2` to snapshot graph state.
  """
  @spec export_knowledge_graph(String.t()) :: {:ok, map()} | {:error, :graph_not_initialized}
  def export_knowledge_graph(agent_id) do
    case get_graph(agent_id) do
      {:ok, graph} -> {:ok, KnowledgeGraph.to_map(graph)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Import a knowledge graph from a serializable map.

  Used by `Arbor.Agent.Seed.restore/2` to restore graph state.
  """
  @spec import_knowledge_graph(String.t(), map()) :: :ok
  def import_knowledge_graph(agent_id, graph_map) do
    graph = KnowledgeGraph.from_map(graph_map)
    save_graph(agent_id, graph)
    persist_graph_async(agent_id)
  end
end
