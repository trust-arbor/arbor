defmodule Arbor.Memory do
  @moduledoc """
  Public API facade for the Arbor memory system.

  Provides a unified interface for all memory operations, including:
  - Vector-based semantic search (Index)
  - Semantic knowledge graph (KnowledgeGraph)
  - Token budget management (TokenBudget)
  - Signal emissions and event logging

  ## Agent-Agnostic Design

  All functions take `agent_id` as the first parameter. The facade is completely
  agent-type agnostic — whether the caller is a native Jido agent (direct Elixir
  call) or a bridged agent (via gateway HTTP), the same functions are used.

  ## Quick Start

      # Initialize memory for an agent
      {:ok, _pid} = Arbor.Memory.init_for_agent("agent_001")

      # Index content
      {:ok, entry_id} = Arbor.Memory.index("agent_001", "Important fact", %{type: :fact})

      # Recall similar content
      {:ok, results} = Arbor.Memory.recall("agent_001", "fact query")

      # Add to knowledge graph
      {:ok, node_id} = Arbor.Memory.add_knowledge("agent_001", %{
        type: :fact,
        content: "The sky is blue"
      })

      # Cleanup when done
      :ok = Arbor.Memory.cleanup_for_agent("agent_001")

  ## Architecture

  The memory system consists of:

  1. **Index** - ETS-backed vector storage for fast semantic search
  2. **KnowledgeGraph** - Semantic network with decay and reinforcement
  3. **Signals** - Transient operational notifications
  4. **Events** - Permanent history records
  5. **TokenBudget** - Model-agnostic budget allocation

  See the module docs for each component for details.
  """

  alias Arbor.Memory.{
    ActionPatterns,
    BackgroundChecks,
    Bridge,
    CodeStore,
    Consolidation,
    Embedding,
    Events,
    GoalStore,
    IdentityConsolidator,
    Index,
    IndexSupervisor,
    InsightDetector,
    IntentStore,
    KnowledgeGraph,
    Patterns,
    Preconscious,
    Preferences,
    Proposal,
    ReflectionProcessor,
    Relationship,
    RelationshipStore,
    Retrieval,
    SelfKnowledge,
    Signals,
    Summarizer,
    Thinking,
    TokenBudget,
    WorkingMemory
  }

  require Logger

  # State storage for knowledge graphs (agent_id => KnowledgeGraph.t())
  # In production, this would be backed by a GenServer or persistence
  @graph_ets :arbor_memory_graphs

  # State storage for working memory (agent_id => WorkingMemory.t())
  @working_memory_ets :arbor_working_memory

  # ============================================================================
  # Agent Lifecycle
  # ============================================================================

  @doc """
  Initialize memory for an agent.

  Creates an isolated memory index and knowledge graph for the agent.
  Should be called when an agent starts.

  ## Options

  - `:max_entries` - Max entries in the index before LRU eviction
  - `:threshold` - Default similarity threshold for recall
  - `:decay_rate` - How fast knowledge graph nodes decay
  - `:index_enabled` - Whether to enable vector index (default: true)
  - `:graph_enabled` - Whether to enable knowledge graph (default: true)

  ## Examples

      {:ok, pid} = Arbor.Memory.init_for_agent("agent_001")
      {:ok, pid} = Arbor.Memory.init_for_agent("agent_001", max_entries: 5000)
  """
  @spec init_for_agent(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def init_for_agent(agent_id, opts \\ []) do
    # Merge caller opts with application config defaults
    opts = merge_config_defaults(opts)

    # Start index if enabled
    index_enabled = Keyword.get(opts, :index_enabled, true)
    graph_enabled = Keyword.get(opts, :graph_enabled, true)

    index_result =
      if index_enabled do
        IndexSupervisor.start_index(agent_id, opts)
      else
        {:ok, nil}
      end

    # Initialize knowledge graph if enabled
    if graph_enabled do
      graph = KnowledgeGraph.new(agent_id, opts)
      :ets.insert(@graph_ets, {agent_id, graph})
    end

    # Emit initialization signal
    Signals.emit_memory_initialized(agent_id, %{
      index_enabled: index_enabled,
      graph_enabled: graph_enabled
    })

    Logger.debug("Initialized memory for agent #{agent_id}")
    index_result
  end

  @doc """
  Cleanup memory for an agent.

  Stops the index and removes the knowledge graph.
  Should be called when an agent stops.

  ## Examples

      :ok = Arbor.Memory.cleanup_for_agent("agent_001")
  """
  @spec cleanup_for_agent(String.t()) :: :ok
  def cleanup_for_agent(agent_id) do
    # Stop index
    IndexSupervisor.stop_index(agent_id)

    # Remove knowledge graph
    :ets.delete(@graph_ets, agent_id)

    # Remove working memory (Phase 2)
    delete_working_memory(agent_id)

    # Emit cleanup signal
    Signals.emit_memory_cleaned_up(agent_id)

    Logger.debug("Cleaned up memory for agent #{agent_id}")
    :ok
  end

  @doc """
  Check if memory is initialized for an agent.
  """
  @spec initialized?(String.t()) :: boolean()
  def initialized?(agent_id) do
    IndexSupervisor.has_index?(agent_id) or has_graph?(agent_id)
  end

  # ============================================================================
  # Index Operations
  # ============================================================================

  @doc """
  Index content for semantic retrieval.

  Stores content with its embedding in the agent's memory index.

  ## Options

  - `:type` - Category type for the entry (atom)
  - `:source` - Source of the content
  - `:embedding` - Pre-computed embedding (skips embedding call)

  ## Examples

      {:ok, entry_id} = Arbor.Memory.index("agent_001", "Hello world", %{type: :fact})
  """
  @spec index(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def index(agent_id, content, metadata \\ %{}, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        result = Index.index(pid, content, metadata, opts)

        # Emit signal on success
        case result do
          {:ok, entry_id} ->
            Signals.emit_indexed(agent_id, %{
              entry_id: entry_id,
              type: metadata[:type],
              source: metadata[:source]
            })

            {:ok, entry_id}

          error ->
            error
        end

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Recall content similar to query.

  Performs semantic search in the agent's memory index.

  ## Options

  - `:limit` - Max results to return (default: 10)
  - `:threshold` - Minimum similarity threshold (default: 0.3)
  - `:type` - Filter by entry type
  - `:types` - Filter by multiple types

  ## Examples

      {:ok, results} = Arbor.Memory.recall("agent_001", "greeting")
      {:ok, facts} = Arbor.Memory.recall("agent_001", "query", type: :fact, limit: 5)
  """
  @spec recall(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def recall(agent_id, query, opts \\ []) do
    with {:ok, pid} <- IndexSupervisor.get_index(agent_id),
         {:ok, results} <- Index.recall(pid, query, opts) do
      emit_recall_signal(agent_id, query, results)
      {:ok, results}
    else
      {:error, :not_found} -> {:error, :index_not_initialized}
      error -> error
    end
  end

  defp emit_recall_signal(agent_id, query, results) do
    top_similarity = if results != [], do: hd(results).similarity, else: nil

    Signals.emit_recalled(agent_id, query, length(results), top_similarity: top_similarity)
  end

  @doc """
  Index multiple items in a batch.

  ## Examples

      items = [{"Fact one", %{type: :fact}}, {"Fact two", %{type: :fact}}]
      {:ok, ids} = Arbor.Memory.batch_index("agent_001", items)
  """
  @spec batch_index(String.t(), [{String.t(), map()}], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def batch_index(agent_id, items, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        Index.batch_index(pid, items, opts)

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  @doc """
  Get statistics for an agent's index.
  """
  @spec index_stats(String.t()) :: {:ok, map()} | {:error, term()}
  def index_stats(agent_id) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} -> {:ok, Index.stats(pid)}
      {:error, :not_found} -> {:error, :index_not_initialized}
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

      {:ok, node_id} = Arbor.Memory.add_knowledge("agent_001", %{
        type: :fact,
        content: "Paris is the capital of France"
      })
  """
  @spec add_knowledge(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def add_knowledge(agent_id, node_data) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, node_id} <- KnowledgeGraph.add_node(graph, node_data) do
      save_graph(agent_id, new_graph)

      # Emit signal
      Signals.emit_knowledge_added(agent_id, node_id, node_data[:type])

      {:ok, node_id}
    end
  end

  @doc """
  Link two knowledge nodes.

  ## Examples

      {:ok, _} = Arbor.Memory.link_knowledge("agent_001", node_a, node_b, :supports)
  """
  @spec link_knowledge(String.t(), String.t(), String.t(), atom(), keyword()) ::
          :ok | {:error, term()}
  def link_knowledge(agent_id, source_id, target_id, relationship, opts \\ []) do
    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph} <-
           KnowledgeGraph.add_edge(graph, source_id, target_id, relationship, opts) do
      save_graph(agent_id, new_graph)

      # Emit signal
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

      # Emit signal
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

      # Emit signal
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

  # ============================================================================
  # Consolidation (Decay and Pruning)
  # ============================================================================

  @doc """
  Run consolidation on the agent's knowledge graph.

  Consolidation applies decay to all non-pinned nodes and prunes
  nodes that fall below the relevance threshold.

  ## Options

  - `:prune_threshold` - Override the default prune threshold

  Returns metrics about what was consolidated.
  """
  @spec consolidate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def consolidate(agent_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    # Emit start signal
    Signals.emit_consolidation_started(agent_id)

    with {:ok, graph} <- get_graph(agent_id) do
      # Apply decay
      decayed_graph = KnowledgeGraph.decay(graph)
      decayed_count = map_size(graph.nodes)

      # Prune
      threshold = Keyword.get(opts, :prune_threshold, 0.1)
      {pruned_graph, pruned_count} = KnowledgeGraph.prune(decayed_graph, threshold)

      # Save
      save_graph(agent_id, pruned_graph)

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

  # ============================================================================
  # Token Budget Delegation
  # ============================================================================

  @doc """
  Resolve a token budget specification.

  See `Arbor.Memory.TokenBudget.resolve/2` for details.
  """
  defdelegate resolve_budget(budget, context_size), to: TokenBudget, as: :resolve

  @doc """
  Resolve a token budget for a specific model.

  See `Arbor.Memory.TokenBudget.resolve_for_model/2` for details.
  """
  defdelegate resolve_budget_for_model(budget, model_id), to: TokenBudget, as: :resolve_for_model

  @doc """
  Estimate tokens in text.

  See `Arbor.Memory.TokenBudget.estimate_tokens/1` for details.
  """
  defdelegate estimate_tokens(text), to: TokenBudget

  @doc """
  Get model context size.

  See `Arbor.Memory.TokenBudget.model_context_size/1` for details.
  """
  defdelegate model_context_size(model_id), to: TokenBudget

  # ============================================================================
  # Persistent Embeddings (Phase 6)
  # ============================================================================

  @doc """
  Store an embedding in the persistent vector store (pgvector).

  This bypasses the in-memory index and writes directly to Postgres.
  Use for bulk imports or when you want persistent-only storage.

  ## Examples

      {:ok, id} = Arbor.Memory.store_embedding("agent_001", "Some fact", embedding, %{type: "fact"})
  """
  @spec store_embedding(String.t(), String.t(), [float()], map()) ::
          {:ok, String.t()} | {:error, term()}
  def store_embedding(agent_id, content, embedding, metadata \\ %{}) do
    Embedding.store(agent_id, content, embedding, metadata)
  end

  @doc """
  Search the persistent vector store directly.

  Bypasses the in-memory index and queries pgvector directly.

  ## Options

  - `:limit` — max results (default 10)
  - `:threshold` — minimum similarity 0.0-1.0 (default 0.3)
  - `:type_filter` — filter by memory_type

  ## Examples

      {:ok, results} = Arbor.Memory.search_embeddings("agent_001", query_embedding)
  """
  @spec search_embeddings(String.t(), [float()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search_embeddings(agent_id, query_embedding, opts \\ []) do
    Embedding.search(agent_id, query_embedding, opts)
  end

  @doc """
  Get statistics for an agent's persistent embeddings.

  ## Examples

      stats = Arbor.Memory.embedding_stats("agent_001")
      #=> %{total: 100, by_type: %{"fact" => 50, ...}, oldest: ~U[...], newest: ~U[...]}
  """
  @spec embedding_stats(String.t()) :: map()
  def embedding_stats(agent_id) do
    Embedding.stats(agent_id)
  end

  @doc """
  Warm the in-memory index cache from persistent storage.

  Loads recent entries from pgvector into the ETS index.
  Only works when the index is running in `:dual` or `:pgvector` mode.

  ## Options

  - `:limit` — Maximum entries to load (default: 1000)

  ## Examples

      :ok = Arbor.Memory.warm_index_cache("agent_001")
      :ok = Arbor.Memory.warm_index_cache("agent_001", limit: 500)
  """
  @spec warm_index_cache(String.t(), keyword()) :: :ok | {:error, term()}
  def warm_index_cache(agent_id, opts \\ []) do
    case IndexSupervisor.get_index(agent_id) do
      {:ok, pid} ->
        Index.warm_cache(pid, opts)

      {:error, :not_found} ->
        {:error, :index_not_initialized}
    end
  end

  # ============================================================================
  # Working Memory (Phase 2)
  # ============================================================================

  @doc """
  Get working memory for an agent.

  Returns the current working memory or nil if not set.

  ## Examples

      wm = Arbor.Memory.get_working_memory("agent_001")
  """
  @spec get_working_memory(String.t()) :: WorkingMemory.t() | nil
  def get_working_memory(agent_id) do
    case :ets.lookup(@working_memory_ets, agent_id) do
      [{^agent_id, wm}] -> wm
      [] -> nil
    end
  end

  @doc """
  Save working memory for an agent.

  Stores the working memory in ETS (Phase 2) or Postgres (Phase 6+).

  ## Examples

      wm = WorkingMemory.new("agent_001")
      :ok = Arbor.Memory.save_working_memory("agent_001", wm)
  """
  @spec save_working_memory(String.t(), WorkingMemory.t()) :: :ok
  def save_working_memory(agent_id, working_memory) do
    :ets.insert(@working_memory_ets, {agent_id, working_memory})
    Signals.emit_working_memory_saved(agent_id, WorkingMemory.stats(working_memory))
    :ok
  end

  @doc """
  Load working memory for an agent.

  Returns existing working memory or creates a new one if none exists.
  This is the primary entry point for session startup.

  ## Examples

      wm = Arbor.Memory.load_working_memory("agent_001")
  """
  @spec load_working_memory(String.t(), keyword()) :: WorkingMemory.t()
  def load_working_memory(agent_id, opts \\ []) do
    case get_working_memory(agent_id) do
      nil ->
        wm = WorkingMemory.new(agent_id, opts)
        save_working_memory(agent_id, wm)
        Signals.emit_working_memory_loaded(agent_id, :created)
        wm

      wm ->
        Signals.emit_working_memory_loaded(agent_id, :existing)
        wm
    end
  end

  @doc """
  Delete working memory for an agent.

  Called during cleanup.
  """
  @spec delete_working_memory(String.t()) :: :ok
  def delete_working_memory(agent_id) do
    :ets.delete(@working_memory_ets, agent_id)
    :ok
  end

  # ============================================================================
  # Retrieval (Phase 2)
  # ============================================================================

  @doc """
  Semantic recall with human-readable formatting for LLM context injection.

  Delegates to `Arbor.Memory.Retrieval.let_me_recall/3`.

  ## Options

  - `:limit` - Max results (default: 10)
  - `:threshold` - Min similarity (default: 0.3)
  - `:max_tokens` - Max tokens in output (default: 500)
  - `:type` / `:types` - Type filtering

  ## Examples

      {:ok, text} = Arbor.Memory.let_me_recall("agent_001", "elixir patterns")
  """
  @spec let_me_recall(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate let_me_recall(agent_id, query, opts \\ []), to: Retrieval

  # ============================================================================
  # Context Building (Phase 2)
  # ============================================================================

  @doc """
  Build combined context for LLM injection.

  Combines working memory and optional relationship context into
  formatted text suitable for system prompt injection.

  ## Options

  - `:max_thoughts` - Max recent thoughts to include (default: 5)
  - `:include_relationship` - Include relationship context (default: true)

  ## Examples

      wm = Arbor.Memory.load_working_memory("agent_001")
      context = Arbor.Memory.build_context(wm)
      context = Arbor.Memory.build_context(wm, relationship: "Close collaborator...")
  """
  @spec build_context(WorkingMemory.t(), keyword()) :: String.t()
  def build_context(working_memory, opts \\ []) do
    relationship = Keyword.get(opts, :relationship)

    # If relationship provided in opts, set it on working memory first
    wm =
      if relationship do
        WorkingMemory.set_relationship_context(working_memory, relationship)
      else
        working_memory
      end

    WorkingMemory.to_prompt_text(wm, opts)
  end

  # ============================================================================
  # Summarization (Phase 2)
  # ============================================================================

  @doc """
  Summarize text with complexity-based model routing.

  Delegates to `Arbor.Memory.Summarizer.summarize/2`.

  Note: Returns `{:error, :llm_not_configured}` until arbor_ai integration.

  ## Examples

      {:error, {:llm_not_configured, info}} = Arbor.Memory.summarize("agent_001", text)
  """
  @spec summarize(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def summarize(_agent_id, text, opts \\ []) do
    # Currently always returns error until LLM integration.
    # When arbor_ai is wired in, this will emit context_summarized signal
    # on success via: Signals.emit_context_summarized(agent_id, info)
    Summarizer.summarize(text, opts)
  end

  @doc """
  Assess complexity of text.

  Delegates to `Arbor.Memory.Summarizer.assess_complexity/1`.

  ## Examples

      :moderate = Arbor.Memory.assess_complexity("Some technical text...")
  """
  @spec assess_complexity(String.t()) :: Summarizer.complexity()
  defdelegate assess_complexity(text), to: Summarizer

  # ============================================================================
  # Relationships (Phase 3)
  # ============================================================================

  @doc """
  Get a relationship by ID.

  ## Examples

      {:ok, rel} = Arbor.Memory.get_relationship("agent_001", relationship_id)
  """
  @spec get_relationship(String.t(), String.t()) ::
          {:ok, Relationship.t()} | {:error, :not_found}
  def get_relationship(agent_id, relationship_id) do
    case RelationshipStore.get(agent_id, relationship_id) do
      {:ok, rel} ->
        # Touch to update access tracking, emit signal
        RelationshipStore.touch(agent_id, relationship_id)
        Signals.emit_relationship_accessed(agent_id, relationship_id)
        {:ok, rel}

      error ->
        error
    end
  end

  @doc """
  Get a relationship by name.

  ## Examples

      {:ok, rel} = Arbor.Memory.get_relationship_by_name("agent_001", "Hysun")
  """
  @spec get_relationship_by_name(String.t(), String.t()) ::
          {:ok, Relationship.t()} | {:error, :not_found}
  def get_relationship_by_name(agent_id, name) do
    case RelationshipStore.get_by_name(agent_id, name) do
      {:ok, rel} ->
        # Touch to update access tracking
        RelationshipStore.touch(agent_id, rel.id)
        Signals.emit_relationship_accessed(agent_id, rel.id)
        {:ok, rel}

      error ->
        error
    end
  end

  @doc """
  Get the primary relationship (highest salience).

  ## Examples

      {:ok, rel} = Arbor.Memory.get_primary_relationship("agent_001")
  """
  @spec get_primary_relationship(String.t()) ::
          {:ok, Relationship.t()} | {:error, :not_found}
  def get_primary_relationship(agent_id) do
    case RelationshipStore.get_primary(agent_id) do
      {:ok, rel} ->
        # Touch to update access tracking
        RelationshipStore.touch(agent_id, rel.id)
        Signals.emit_relationship_accessed(agent_id, rel.id)
        {:ok, rel}

      error ->
        error
    end
  end

  @doc """
  Save a relationship.

  Creates or updates the relationship in the store.

  ## Examples

      rel = Relationship.new("Hysun", relationship_dynamic: "Collaborative partnership")
      {:ok, saved_rel} = Arbor.Memory.save_relationship("agent_001", rel)
  """
  @spec save_relationship(String.t(), Relationship.t()) ::
          {:ok, Relationship.t()} | {:error, term()}
  def save_relationship(agent_id, %Relationship{} = relationship) do
    # Check if this is a new relationship
    is_new =
      case RelationshipStore.get(agent_id, relationship.id) do
        {:ok, _} -> false
        {:error, :not_found} -> true
      end

    case RelationshipStore.put(agent_id, relationship) do
      {:ok, saved_rel} ->
        if is_new do
          Signals.emit_relationship_created(agent_id, saved_rel.id, saved_rel.name)
          Events.record_relationship_created(agent_id, saved_rel.id, saved_rel.name)
        else
          Signals.emit_relationship_updated(agent_id, saved_rel.id, %{action: :saved})
        end

        {:ok, saved_rel}

      error ->
        error
    end
  end

  @doc """
  Add a key moment to a relationship.

  ## Options

  - `:emotional_markers` - List of atoms describing emotional tone
  - `:salience` - Importance of this moment (default: 0.5)

  ## Examples

      {:ok, rel} = Arbor.Memory.add_moment("agent_001", rel_id, "First collaborative blog post",
        emotional_markers: [:connection, :accomplishment],
        salience: 0.8
      )
  """
  @spec add_moment(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Relationship.t()} | {:error, term()}
  def add_moment(agent_id, relationship_id, summary, opts \\ []) do
    case RelationshipStore.get(agent_id, relationship_id) do
      {:ok, rel} ->
        updated_rel = Relationship.add_moment(rel, summary, opts)

        case RelationshipStore.put(agent_id, updated_rel) do
          {:ok, saved_rel} ->
            Signals.emit_moment_added(agent_id, relationship_id, summary)

            Events.record_relationship_moment(agent_id, relationship_id, %{
              summary: summary,
              emotional_markers: Keyword.get(opts, :emotional_markers, []),
              salience: Keyword.get(opts, :salience, 0.5)
            })

            {:ok, saved_rel}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  List all relationships for an agent.

  ## Options

  - `:sort_by` - Sort by: `:salience` (default), `:last_interaction`, `:name`, `:access_count`
  - `:sort_dir` - Sort direction: `:desc` (default), `:asc`
  - `:limit` - Maximum relationships to return

  ## Examples

      {:ok, relationships} = Arbor.Memory.list_relationships("agent_001")
      {:ok, recent} = Arbor.Memory.list_relationships("agent_001", sort_by: :last_interaction, limit: 5)
  """
  @spec list_relationships(String.t(), keyword()) :: {:ok, [Relationship.t()]}
  def list_relationships(agent_id, opts \\ []) do
    RelationshipStore.list(agent_id, opts)
  end

  @doc """
  Delete a relationship.

  ## Examples

      :ok = Arbor.Memory.delete_relationship("agent_001", relationship_id)
  """
  @spec delete_relationship(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_relationship(agent_id, relationship_id) do
    RelationshipStore.delete(agent_id, relationship_id)
  end

  # ============================================================================
  # Enhanced Consolidation (Phase 3)
  # ============================================================================

  @doc """
  Run enhanced consolidation on the agent's knowledge graph.

  This uses the full Consolidation module which includes:
  - Decay (reduce relevance of non-pinned nodes)
  - Reinforce (boost recently-accessed nodes)
  - Archive (save pruned nodes to EventLog before removal)
  - Prune (remove nodes below threshold)
  - Quota enforcement (evict if over type limits)

  ## Options

  - `:prune_threshold` - Relevance below which to prune (default: 0.1)
  - `:reinforce_window_hours` - How recent is "recently accessed" (default: 24)
  - `:reinforce_boost` - How much to boost recent nodes (default: 0.1)
  - `:archive` - Whether to archive pruned nodes (default: true)

  ## Examples

      {:ok, new_graph, metrics} = Arbor.Memory.run_consolidation("agent_001")
  """
  @spec run_consolidation(String.t(), keyword()) ::
          {:ok, KnowledgeGraph.t(), map()} | {:error, term()}
  def run_consolidation(agent_id, opts \\ []) do
    # Emit start signal
    Signals.emit_consolidation_started(agent_id)

    with {:ok, graph} <- get_graph(agent_id),
         {:ok, new_graph, metrics} <- Consolidation.consolidate(agent_id, graph, opts) do
      # Save updated graph
      save_graph(agent_id, new_graph)

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

  Based on graph size and time since last consolidation.

  ## Options

  - `:size_threshold` - Consolidate if node count exceeds this (default: 100)
  - `:min_interval_minutes` - Minimum minutes between consolidations (default: 60)
  - `:last_consolidation` - DateTime of last consolidation

  ## Examples

      if Arbor.Memory.should_consolidate?("agent_001") do
        {:ok, _, _} = Arbor.Memory.run_consolidation("agent_001")
      end
  """
  @spec should_consolidate?(String.t(), keyword()) :: boolean()
  def should_consolidate?(agent_id, opts \\ []) do
    case get_graph(agent_id) do
      {:ok, graph} -> Consolidation.should_consolidate?(graph, opts)
      {:error, _} -> false
    end
  end

  @doc """
  Preview what consolidation would do without actually doing it.

  ## Examples

      preview = Arbor.Memory.preview_consolidation("agent_001")
  """
  @spec preview_consolidation(String.t(), keyword()) :: map() | {:error, term()}
  def preview_consolidation(agent_id, opts \\ []) do
    case get_graph(agent_id) do
      {:ok, graph} -> Consolidation.preview(graph, opts)
      error -> error
    end
  end

  # ============================================================================
  # Background Checks (Phase 4)
  # ============================================================================

  @doc """
  Run all background checks for an agent.

  Call this during heartbeats or on scheduled intervals. Returns:
  - `:actions` - Things that should happen now (e.g., run consolidation)
  - `:warnings` - Things the agent should know about
  - `:suggestions` - Proposals created for agent review

  ## Options

  - `:action_history` - List of recent tool actions for pattern detection
  - `:last_consolidation` - DateTime of last consolidation
  - `:skip_consolidation` - Skip consolidation check (default: false)
  - `:skip_patterns` - Skip action pattern detection (default: false)
  - `:skip_insights` - Skip insight detection (default: false)

  ## Examples

      result = Arbor.Memory.run_background_checks("agent_001")
      result = Arbor.Memory.run_background_checks("agent_001", action_history: history)
  """
  @spec run_background_checks(String.t(), keyword()) :: BackgroundChecks.check_result()
  defdelegate run_background_checks(agent_id, opts \\ []), to: BackgroundChecks, as: :run

  @doc """
  Analyze memory patterns for an agent.

  Returns comprehensive analysis including type distribution, access
  concentration (Gini coefficient), decay risk, and unused pins.

  ## Examples

      analysis = Arbor.Memory.analyze_memory_patterns("agent_001")
  """
  @spec analyze_memory_patterns(String.t()) :: Patterns.analysis() | {:error, term()}
  defdelegate analyze_memory_patterns(agent_id), to: Patterns, as: :analyze

  # ============================================================================
  # Proposals (Phase 4)
  # ============================================================================

  @doc """
  Create a proposal for agent review.

  ## Types

  - `:fact` - Auto-extracted facts
  - `:insight` - Behavioral insights
  - `:learning` - Tool usage patterns
  - `:pattern` - Recurring sequences

  ## Examples

      {:ok, proposal} = Arbor.Memory.create_proposal("agent_001", :fact, %{
        content: "User prefers dark mode",
        confidence: 0.8
      })
  """
  @spec create_proposal(String.t(), Proposal.proposal_type(), map()) ::
          {:ok, Proposal.t()} | {:error, term()}
  defdelegate create_proposal(agent_id, type, data), to: Proposal, as: :create

  @doc """
  List pending proposals for an agent.

  ## Options

  - `:type` - Filter by proposal type
  - `:limit` - Maximum proposals to return
  - `:sort_by` - Sort by: `:created_at` (default), `:confidence`

  ## Examples

      {:ok, proposals} = Arbor.Memory.get_proposals("agent_001")
      {:ok, facts} = Arbor.Memory.get_proposals("agent_001", type: :fact)
  """
  @spec get_proposals(String.t(), keyword()) :: {:ok, [Proposal.t()]}
  defdelegate get_proposals(agent_id, opts \\ []), to: Proposal, as: :list_pending

  @doc """
  Accept a proposal and integrate it into the knowledge graph.

  The proposal content is added as a knowledge node with a confidence boost.

  ## Examples

      {:ok, node_id} = Arbor.Memory.accept_proposal("agent_001", proposal_id)
  """
  @spec accept_proposal(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defdelegate accept_proposal(agent_id, proposal_id), to: Proposal, as: :accept

  @doc """
  Reject a proposal.

  The proposal is marked as rejected for calibration purposes.

  ## Options

  - `:reason` - Why the proposal was rejected

  ## Examples

      :ok = Arbor.Memory.reject_proposal("agent_001", proposal_id)
      :ok = Arbor.Memory.reject_proposal("agent_001", proposal_id, reason: "Not accurate")
  """
  @spec reject_proposal(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate reject_proposal(agent_id, proposal_id, opts \\ []), to: Proposal, as: :reject

  @doc """
  Defer a proposal for later review.

  ## Examples

      :ok = Arbor.Memory.defer_proposal("agent_001", proposal_id)
  """
  @spec defer_proposal(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate defer_proposal(agent_id, proposal_id), to: Proposal, as: :defer

  @doc """
  Accept all pending proposals, optionally filtered by type.

  ## Examples

      {:ok, results} = Arbor.Memory.accept_all_proposals("agent_001")
      {:ok, results} = Arbor.Memory.accept_all_proposals("agent_001", :fact)
  """
  @spec accept_all_proposals(String.t(), Proposal.proposal_type() | nil) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  defdelegate accept_all_proposals(agent_id, type \\ nil), to: Proposal, as: :accept_all

  @doc """
  Get proposal statistics for an agent.

  ## Examples

      stats = Arbor.Memory.proposal_stats("agent_001")
  """
  @spec proposal_stats(String.t()) :: map()
  defdelegate proposal_stats(agent_id), to: Proposal, as: :stats

  # ============================================================================
  # Action Patterns (Phase 4)
  # ============================================================================

  @doc """
  Analyze action history for patterns.

  Detects repeated sequences, failure-then-success patterns, and
  long sequences in tool usage history.

  ## Options

  - `:min_occurrences` - Minimum times a sequence must occur (default: 3)

  ## Examples

      patterns = Arbor.Memory.analyze_action_patterns(action_history)
  """
  @spec analyze_action_patterns([ActionPatterns.action()], keyword()) :: [
          ActionPatterns.pattern()
        ]
  defdelegate analyze_action_patterns(action_history, opts \\ []),
    to: ActionPatterns,
    as: :analyze

  @doc """
  Analyze action history and queue learnings as proposals.

  ## Examples

      {:ok, proposals} = Arbor.Memory.analyze_and_queue_learnings("agent_001", history)
  """
  @spec analyze_and_queue_learnings(String.t(), [ActionPatterns.action()], keyword()) ::
          {:ok, [Proposal.t()]} | {:error, term()}
  defdelegate analyze_and_queue_learnings(agent_id, history, opts \\ []),
    to: ActionPatterns,
    as: :analyze_and_queue

  # ============================================================================
  # Insight Detection (Phase 4)
  # ============================================================================

  @doc """
  Detect insights from knowledge graph patterns.

  Analyzes the knowledge graph to find patterns that might indicate
  personality traits, capabilities, values, or preferences.

  ## Options

  - `:include_low_confidence` - Include suggestions below 0.5 confidence
  - `:max_suggestions` - Maximum suggestions to return (default: 5)

  ## Examples

      suggestions = Arbor.Memory.detect_insights("agent_001")
  """
  @spec detect_insights(String.t(), keyword()) ::
          [InsightDetector.insight_suggestion()] | {:error, term()}
  defdelegate detect_insights(agent_id, opts \\ []), to: InsightDetector, as: :detect

  @doc """
  Detect insights and queue them as proposals.

  ## Examples

      {:ok, proposals} = Arbor.Memory.detect_and_queue_insights("agent_001")
  """
  @spec detect_and_queue_insights(String.t(), keyword()) ::
          {:ok, [Proposal.t()]} | {:error, term()}
  defdelegate detect_and_queue_insights(agent_id, opts \\ []),
    to: InsightDetector,
    as: :detect_and_queue

  # ============================================================================
  # Self-Knowledge (Phase 5)
  # ============================================================================

  @doc """
  Get the agent's self-knowledge.

  Returns the SelfKnowledge struct containing capabilities, traits,
  values, and preferences.

  ## Examples

      sk = Arbor.Memory.get_self_knowledge("agent_001")
  """
  @spec get_self_knowledge(String.t()) :: SelfKnowledge.t() | nil
  defdelegate get_self_knowledge(agent_id), to: IdentityConsolidator

  @doc """
  Query a specific aspect of self-knowledge.

  ## Aspects

  - `:memory_system` - Understanding of memory architecture
  - `:identity` - Core identity (traits + values)
  - `:tools` - Tool capabilities
  - `:cognition` - Cognitive patterns and preferences
  - `:capabilities` - Skills and proficiency
  - `:all` - Everything

  ## Examples

      identity = Arbor.Memory.query_self("agent_001", :identity)
  """
  @spec query_self(String.t(), atom()) :: map()
  def query_self(agent_id, aspect) do
    case get_self_knowledge(agent_id) do
      nil -> %{}
      sk -> SelfKnowledge.query(sk, aspect)
    end
  end

  # ============================================================================
  # Identity Consolidation (Phase 5)
  # ============================================================================

  @doc """
  Run identity consolidation for an agent.

  Promotes high-confidence insights from InsightDetector to
  permanent SelfKnowledge. Rate-limited to prevent identity thrashing.

  ## Options

  - `:force` - Skip rate limit checks (default: false)
  - `:min_confidence` - Minimum confidence for insights (default: 0.7)

  ## Examples

      {:ok, updated_sk} = Arbor.Memory.consolidate_identity("agent_001")
  """
  @spec consolidate_identity(String.t(), keyword()) ::
          {:ok, SelfKnowledge.t()} | {:ok, :no_changes} | {:error, term()}
  defdelegate consolidate_identity(agent_id, opts \\ []),
    to: IdentityConsolidator,
    as: :consolidate

  @doc """
  Rollback identity to a previous version.

  ## Examples

      {:ok, sk} = Arbor.Memory.rollback_identity("agent_001")
      {:ok, sk} = Arbor.Memory.rollback_identity("agent_001", 3)
  """
  @spec rollback_identity(String.t(), :previous | pos_integer()) ::
          {:ok, SelfKnowledge.t()} | {:error, term()}
  defdelegate rollback_identity(agent_id, version \\ :previous),
    to: IdentityConsolidator,
    as: :rollback

  @doc """
  Get identity change history for an agent.

  ## Examples

      {:ok, history} = Arbor.Memory.identity_history("agent_001")
  """
  @spec identity_history(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate identity_history(agent_id, opts \\ []), to: IdentityConsolidator, as: :history

  # ============================================================================
  # Preferences (Phase 5)
  # ============================================================================

  # ETS table for preferences storage
  @preferences_ets :arbor_preferences

  @doc """
  Get preferences for an agent.

  Returns the Preferences struct or nil if not set.

  ## Examples

      prefs = Arbor.Memory.get_preferences("agent_001")
  """
  @spec get_preferences(String.t()) :: Preferences.t() | nil
  def get_preferences(agent_id) do
    ensure_preferences_table()

    case :ets.lookup(@preferences_ets, agent_id) do
      [{^agent_id, prefs}] -> prefs
      [] -> nil
    end
  end

  @doc """
  Adjust a cognitive preference for an agent.

  ## Parameters

  - `:decay_rate` - 0.01 to 0.50
  - `:max_pins` - 1 to 200
  - `:retrieval_threshold` - 0.0 to 1.0
  - `:consolidation_interval` - 60,000ms to 3,600,000ms
  - `:attention_focus` - String or nil
  - `:type_quota` - Tuple of {type, quota}

  ## Examples

      {:ok, prefs} = Arbor.Memory.adjust_preference("agent_001", :decay_rate, 0.15)
  """
  @spec adjust_preference(String.t(), atom(), term()) :: {:ok, Preferences.t()} | {:error, term()}
  def adjust_preference(agent_id, param, value) do
    prefs = get_or_create_preferences(agent_id)

    case Preferences.adjust(prefs, param, value) do
      {:ok, updated_prefs} ->
        save_preferences(agent_id, updated_prefs)

        Signals.emit_cognitive_adjustment(agent_id, param, %{
          old_value: Map.get(prefs, param),
          new_value: value
        })

        {:ok, updated_prefs}

      error ->
        error
    end
  end

  @doc """
  Pin a memory to protect it from decay.

  ## Examples

      {:ok, prefs} = Arbor.Memory.pin_memory("agent_001", "memory_123")
  """
  @spec pin_memory(String.t(), String.t()) :: {:ok, Preferences.t()} | {:error, :max_pins_reached}
  def pin_memory(agent_id, memory_id) do
    prefs = get_or_create_preferences(agent_id)

    case Preferences.pin(prefs, memory_id) do
      {:error, _} = error ->
        error

      updated_prefs ->
        save_preferences(agent_id, updated_prefs)
        Signals.emit_cognitive_adjustment(agent_id, :pin_memory, %{memory_id: memory_id})
        {:ok, updated_prefs}
    end
  end

  @doc """
  Unpin a memory, allowing it to decay normally.

  ## Examples

      {:ok, prefs} = Arbor.Memory.unpin_memory("agent_001", "memory_123")
  """
  @spec unpin_memory(String.t(), String.t()) :: {:ok, Preferences.t()}
  def unpin_memory(agent_id, memory_id) do
    prefs = get_or_create_preferences(agent_id)
    updated_prefs = Preferences.unpin(prefs, memory_id)
    save_preferences(agent_id, updated_prefs)
    Signals.emit_cognitive_adjustment(agent_id, :unpin_memory, %{memory_id: memory_id})
    {:ok, updated_prefs}
  end

  @doc """
  Get a summary of current preferences and usage.

  ## Examples

      info = Arbor.Memory.inspect_preferences("agent_001")
  """
  @spec inspect_preferences(String.t()) :: map()
  def inspect_preferences(agent_id) do
    case get_preferences(agent_id) do
      nil -> %{agent_id: agent_id, status: :not_initialized}
      prefs -> Preferences.inspect_preferences(prefs)
    end
  end

  # ============================================================================
  # Reflection (Phase 5)
  # ============================================================================

  @doc """
  Perform a structured reflection with a specific prompt.

  Uses the configured LLM module (or mock in dev/test) to generate
  insights from the agent's context.

  ## Options

  - `:include_self_knowledge` - Include SelfKnowledge in context (default: true)
  - `:include_recent_activity` - Include recent activity summary (default: true)

  ## Examples

      {:ok, reflection} = Arbor.Memory.reflect("agent_001", "What patterns do I see?")
  """
  @spec reflect(String.t(), String.t(), keyword()) ::
          {:ok, ReflectionProcessor.reflection()} | {:error, term()}
  defdelegate reflect(agent_id, prompt, opts \\ []), to: ReflectionProcessor

  @doc """
  Get reflection history for an agent.

  ## Options

  - `:limit` - Maximum reflections to return (default: 10)
  - `:since` - Only reflections after this DateTime

  ## Examples

      {:ok, reflections} = Arbor.Memory.reflection_history("agent_001")
  """
  @spec reflection_history(String.t(), keyword()) :: {:ok, [ReflectionProcessor.reflection()]}
  defdelegate reflection_history(agent_id, opts \\ []), to: ReflectionProcessor, as: :history

  # ============================================================================
  # Preconscious (Phase 7)
  # ============================================================================

  @doc """
  Run a preconscious anticipation check.

  Analyzes the agent's current conversation context (thoughts, goals) and
  surfaces relevant long-term memories that might be useful.

  ## Options

  - `:relevance_threshold` - Minimum similarity to include (default: 0.4)
  - `:max_results` - Maximum memories to return (default: 3)
  - `:lookback_turns` - Number of recent thoughts to consider (default: 5)

  ## Examples

      {:ok, anticipation} = Arbor.Memory.run_preconscious_check("agent_001")
  """
  @spec run_preconscious_check(String.t(), keyword()) ::
          {:ok, Preconscious.anticipation()} | {:error, term()}
  defdelegate run_preconscious_check(agent_id, opts \\ []), to: Preconscious, as: :check

  @doc """
  Configure preconscious sensitivity for an agent.

  ## Options

  - `:relevance_threshold` - Minimum similarity to include (0.0-1.0)
  - `:max_per_check` - Maximum proposals per check (1-10)
  - `:lookback_turns` - Number of recent thoughts to consider (1-20)

  ## Examples

      :ok = Arbor.Memory.configure_preconscious("agent_001", relevance_threshold: 0.5)
  """
  @spec configure_preconscious(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate configure_preconscious(agent_id, opts), to: Preconscious, as: :configure

  # ============================================================================
  # Goals (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Add a goal for an agent.

  Accepts a `Goal` struct or a description string with options.

  ## Examples

      goal = Goal.new("Fix the login bug", type: :achieve, priority: 80)
      {:ok, goal} = Arbor.Memory.add_goal("agent_001", goal)
  """
  @spec add_goal(String.t(), struct()) :: {:ok, struct()}
  defdelegate add_goal(agent_id, goal), to: GoalStore

  @doc """
  Get all active goals for an agent, sorted by priority.
  """
  @spec get_active_goals(String.t()) :: [struct()]
  defdelegate get_active_goals(agent_id), to: GoalStore

  @doc """
  Update goal progress (0.0 to 1.0).
  """
  @spec update_goal_progress(String.t(), String.t(), float()) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate update_goal_progress(agent_id, goal_id, progress), to: GoalStore

  @doc """
  Mark a goal as achieved.
  """
  @spec achieve_goal(String.t(), String.t()) :: {:ok, struct()} | {:error, :not_found}
  defdelegate achieve_goal(agent_id, goal_id), to: GoalStore

  @doc """
  Mark a goal as abandoned with an optional reason.
  """
  @spec abandon_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate abandon_goal(agent_id, goal_id, reason \\ nil), to: GoalStore

  @doc """
  Get the goal tree starting from a given goal (with children hierarchy).
  """
  @spec get_goal_tree(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_goal_tree(agent_id, goal_id), to: GoalStore

  # ============================================================================
  # Intents & Percepts (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Record an intent for an agent.

  Intents represent what the Mind has decided to do.
  """
  @spec record_intent(String.t(), struct()) :: {:ok, struct()}
  defdelegate record_intent(agent_id, intent), to: IntentStore

  @doc """
  Get recent intents for an agent.

  ## Options

  - `:limit` — max intents (default: 10)
  - `:type` — filter by intent type
  - `:since` — only intents after this DateTime
  """
  @spec recent_intents(String.t(), keyword()) :: [struct()]
  defdelegate recent_intents(agent_id, opts \\ []), to: IntentStore

  @doc """
  Record a percept for an agent.

  Percepts represent the Body's observation after executing an intent.
  """
  @spec record_percept(String.t(), struct()) :: {:ok, struct()}
  defdelegate record_percept(agent_id, percept), to: IntentStore

  @doc """
  Get recent percepts for an agent.

  ## Options

  - `:limit` — max percepts (default: 10)
  - `:type` — filter by percept type
  - `:since` — only percepts after this DateTime
  """
  @spec recent_percepts(String.t(), keyword()) :: [struct()]
  defdelegate recent_percepts(agent_id, opts \\ []), to: IntentStore

  @doc """
  Get the percept (outcome) for a specific intent.
  """
  @spec get_percept_for_intent(String.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate get_percept_for_intent(agent_id, intent_id), to: IntentStore

  # ============================================================================
  # Bridge (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Emit an intent from Mind to Body via the signal bus.
  """
  @spec emit_intent(String.t(), struct()) :: :ok
  defdelegate emit_intent(agent_id, intent), to: Bridge

  @doc """
  Emit a percept from Body to Mind via the signal bus.
  """
  @spec emit_percept(String.t(), struct()) :: :ok
  defdelegate emit_percept(agent_id, percept), to: Bridge

  @doc """
  Execute an intent and wait for the percept response.

  ## Options

  - `:timeout` — maximum wait time in ms (default: 30_000)
  """
  @spec execute_and_wait(String.t(), struct(), keyword()) ::
          {:ok, struct()} | {:error, :timeout}
  defdelegate execute_and_wait(agent_id, intent, opts \\ []), to: Bridge

  # ============================================================================
  # Thinking (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Record a thinking block for an agent.

  ## Options

  - `:significant` — flag for reflection (default: false)
  - `:metadata` — additional metadata
  """
  @spec record_thinking(String.t(), String.t(), keyword()) :: {:ok, map()}
  defdelegate record_thinking(agent_id, text, opts \\ []), to: Thinking

  @doc """
  Get recent thinking entries for an agent.

  ## Options

  - `:limit` — max entries (default: 10)
  - `:since` — only entries after this DateTime
  - `:significant_only` — only significant entries (default: false)
  """
  @spec recent_thinking(String.t(), keyword()) :: [map()]
  defdelegate recent_thinking(agent_id, opts \\ []), to: Thinking

  # ============================================================================
  # CodeStore (Seed/Host Phase 3)
  # ============================================================================

  @doc """
  Store a code pattern for an agent.

  ## Required Fields

  - `:code` — the code text
  - `:language` — programming language
  - `:purpose` — description of what it does
  """
  @spec store_code(String.t(), map()) :: {:ok, map()} | {:error, :missing_fields}
  defdelegate store_code(agent_id, params), to: CodeStore, as: :store

  @doc """
  Find code patterns by purpose (keyword search).
  """
  @spec find_code_by_purpose(String.t(), String.t()) :: [map()]
  defdelegate find_code_by_purpose(agent_id, query), to: CodeStore, as: :find_by_purpose

  @doc """
  List all code patterns for an agent.

  ## Options

  - `:language` — filter by language
  - `:limit` — max results
  """
  @spec list_code(String.t(), keyword()) :: [map()]
  defdelegate list_code(agent_id, opts \\ []), to: CodeStore, as: :list

  # ============================================================================
  # Bridge Subscriptions (Seed/Host Phase 4)
  # ============================================================================

  @doc """
  Subscribe to intents emitted for a specific agent.

  The handler function receives the full signal when an intent is emitted
  for the given agent_id.

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  @spec subscribe_to_intents(String.t(), (map() -> :ok)) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate subscribe_to_intents(agent_id, handler), to: Bridge

  @doc """
  Subscribe to percepts emitted for a specific agent.

  The handler function receives the full signal when a percept is emitted
  for the given agent_id.

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  @spec subscribe_to_percepts(String.t(), (map() -> :ok)) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate subscribe_to_percepts(agent_id, handler), to: Bridge

  # ============================================================================
  # Private Helpers (Phase 5)
  # ============================================================================

  defp get_or_create_preferences(agent_id) do
    case get_preferences(agent_id) do
      nil ->
        prefs = Preferences.new(agent_id)
        save_preferences(agent_id, prefs)
        prefs

      prefs ->
        prefs
    end
  end

  defp save_preferences(agent_id, prefs) do
    ensure_preferences_table()
    :ets.insert(@preferences_ets, {agent_id, prefs})
    :ok
  end

  defp ensure_preferences_table do
    if :ets.whereis(@preferences_ets) == :undefined do
      try do
        :ets.new(@preferences_ets, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Merge caller-provided opts with application config defaults.
  # Caller opts take precedence over config.
  defp merge_config_defaults(opts) do
    defaults = [
      max_entries: Application.get_env(:arbor_memory, :index_max_entries, 10_000),
      threshold: Application.get_env(:arbor_memory, :index_default_threshold, 0.3),
      decay_rate: Application.get_env(:arbor_memory, :kg_default_decay_rate, 0.10),
      max_nodes_per_type: Application.get_env(:arbor_memory, :kg_max_nodes_per_type, 500)
    ]

    Keyword.merge(defaults, opts)
  end

  # Graph ETS table is created eagerly in Application.start/2
  # to avoid race conditions from lazy initialization.

  defp get_graph(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, graph}] -> {:ok, graph}
      [] -> {:error, :graph_not_initialized}
    end
  end

  defp save_graph(agent_id, graph) do
    :ets.insert(@graph_ets, {agent_id, graph})
    :ok
  end

  defp has_graph?(agent_id) do
    case :ets.lookup(@graph_ets, agent_id) do
      [{^agent_id, _}] -> true
      [] -> false
    end
  end
end
