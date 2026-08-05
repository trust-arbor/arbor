defmodule Arbor.Memory.GraphOps do
  @moduledoc """
  Knowledge graph compatibility operations backed by durable authority.

  `KnowledgeGraphStore` owns authoritative state. ETS is only its replaceable
  projection; callers never read or write it through this module. Typed writes
  use one operation identity per invocation and reuse it when reconciling an
  ambiguous durable outcome.
  """

  alias Arbor.Memory.{KnowledgeGraph, KnowledgeGraphStore, Signals}
  alias Arbor.Memory.KnowledgeGraph.Codec

  # ============================================================================
  # Graph Authority Helpers
  # ============================================================================

  @doc """
  Get the authoritative knowledge graph for an agent.
  """
  @spec get_graph(String.t()) :: {:ok, KnowledgeGraph.t()} | {:error, term()}
  def get_graph(agent_id), do: KnowledgeGraphStore.get_graph(agent_id)

  @doc """
  Initialize an agent's authoritative knowledge graph if none exists.

  Whole-graph replacement is intentionally unsupported. Existing graphs must
  be changed through typed operations so concurrent updates cannot be lost.
  """
  @spec save_graph(String.t(), KnowledgeGraph.t()) :: :ok | {:error, term()}
  def save_graph(agent_id, graph) do
    case KnowledgeGraphStore.save_graph(agent_id, graph) do
      :ok -> :ok
      {:error, :outcome_unknown} -> reconcile_ambiguous_initialization(agent_id, graph)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Preserve the legacy persistence hook after durable-authority migration.

  Typed writes and initialization are already durable before returning, and the
  owner schedules projection convergence itself. There is no second write to
  enqueue.
  """
  @spec persist_graph_async(String.t()) :: :ok
  def persist_graph_async(_agent_id), do: :ok

  @doc """
  Load the authoritative durable knowledge graph.

  Returns `{:ok, graph}` if found, `{:error, :not_found}` otherwise.
  Used during agent restart to recover learned knowledge.
  """
  @spec load_persisted_graph(String.t()) :: {:ok, KnowledgeGraph.t()} | {:error, term()}
  def load_persisted_graph(agent_id) do
    case KnowledgeGraphStore.get_graph(agent_id) do
      {:ok, graph} -> {:ok, graph}
      {:error, :graph_not_initialized} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Check if an agent has an initialized knowledge graph.
  """
  @spec has_graph?(String.t()) :: boolean()
  def has_graph?(agent_id) do
    case KnowledgeGraphStore.get_graph(agent_id) do
      {:ok, _graph} -> true
      {:error, _reason} -> false
    end
  end

  @doc """
  Fetch authoritative graph, returning nil on absence or authority failure.
  """
  @spec fetch_graph(String.t()) :: KnowledgeGraph.t() | nil
  def fetch_graph(agent_id) do
    case KnowledgeGraphStore.get_graph(agent_id) do
      {:ok, graph} -> graph
      {:error, _reason} -> nil
    end
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
    operation_id = new_operation_id("add_node")

    case reconcile_ambiguous(fn ->
           KnowledgeGraphStore.add_node(agent_id, operation_id, node_data)
         end) do
      {:ok, node_id} = success ->
        safe_emit(fn -> Signals.emit_knowledge_added(agent_id, node_id, node_data[:type]) end)
        success

      {:error, _reason} = error ->
        error
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
    operation_id = new_operation_id("add_edge")

    case reconcile_ambiguous(fn ->
           KnowledgeGraphStore.add_edge(
             agent_id,
             operation_id,
             source_id,
             target_id,
             relationship,
             opts
           )
         end) do
      :ok ->
        safe_emit(fn ->
          Signals.emit_knowledge_linked(agent_id, source_id, target_id, relationship)
        end)

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Recall a knowledge node, reinforcing its relevance.
  """
  @spec reinforce_knowledge(String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reinforce_knowledge(agent_id, node_id) do
    operation_id = new_operation_id("reinforce")

    reconcile_ambiguous(fn ->
      KnowledgeGraphStore.reinforce(agent_id, operation_id, node_id)
    end)
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
    case reconcile_ambiguous(fn -> KnowledgeGraphStore.approve_pending(agent_id, pending_id) end) do
      {:ok, node_id} = success ->
        safe_emit(fn -> Signals.emit_pending_approved(agent_id, pending_id, node_id) end)
        success

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Reject a pending fact or learning.
  """
  @spec reject_pending(String.t(), String.t()) :: :ok | {:error, term()}
  def reject_pending(agent_id, pending_id) do
    case reconcile_ambiguous(fn -> KnowledgeGraphStore.reject_pending(agent_id, pending_id) end) do
      :ok ->
        safe_emit(fn -> Signals.emit_pending_rejected(agent_id, pending_id) end)
        :ok

      {:error, _reason} = error ->
        error
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
    operation_id = new_operation_id("cascade_recall")

    reconcile_ambiguous(fn ->
      KnowledgeGraphStore.cascade_recall(agent_id, operation_id, node_id, boost_amount, opts)
    end)
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
  @spec export_knowledge_graph(String.t()) :: {:ok, map()} | {:error, term()}
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
  @spec import_knowledge_graph(String.t(), map()) :: :ok | {:error, term()}
  def import_knowledge_graph(agent_id, graph_map) do
    case KnowledgeGraphStore.import_legacy_graph(agent_id, graph_map) do
      :ok -> :ok
      {:error, :outcome_unknown} -> reconcile_ambiguous_import(agent_id, graph_map)
      {:error, _reason} = error -> error
    end
  end

  # A typed replay is a fresh authority read, not a blind retry of the
  # ambiguous CAS. The durable receipt suppresses a second effect if the first
  # call committed before its transport failed.
  defp reconcile_ambiguous(operation) do
    case operation.() do
      {:error, :outcome_unknown} -> operation.()
      result -> result
    end
  end

  defp reconcile_ambiguous_import(agent_id, graph_map) do
    with {:ok, expected} <- Codec.decode_legacy_graph(agent_id, graph_map),
         {:ok, current} <- KnowledgeGraphStore.get_graph(agent_id) do
      if current == expected, do: :ok, else: {:error, :conflict}
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp reconcile_ambiguous_initialization(agent_id, expected) do
    case KnowledgeGraphStore.get_graph(agent_id) do
      {:ok, ^expected} -> :ok
      {:ok, _different} -> {:error, :conflict}
      {:error, _reason} -> {:error, :outcome_unknown}
    end
  end

  defp new_operation_id(kind) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "graph_ops_#{kind}_#{nonce}"
  end

  defp safe_emit(emit) do
    _ = emit.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
