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
    ChatHistory,
    CodeStore,
    Consolidation,
    ContextWindow,
    Embedding,
    GoalStore,
    GraphOps,
    IdentityConsolidator,
    Index,
    IndexSupervisor,
    InsightDetector,
    IntentStore,
    KnowledgeGraph,
    Patterns,
    Preconscious,
    Preferences,
    PreferencesStore,
    Proposal,
    ReflectionProcessor,
    RelationshipStore,
    Retrieval,
    SelfKnowledge,
    Signals,
    Summarizer,
    Thinking,
    TokenBudget,
    WorkingMemory,
    WorkingMemoryStore
  }

  require Logger

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
      GraphOps.save_graph(agent_id, graph)
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
    :ets.delete(:arbor_memory_graphs, agent_id)

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
    IndexSupervisor.has_index?(agent_id) or GraphOps.has_graph?(agent_id)
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

  @doc "Add a knowledge node to the agent's graph."
  defdelegate add_knowledge(agent_id, node_data), to: GraphOps

  @doc "Link two knowledge nodes."
  defdelegate link_knowledge(agent_id, source_id, target_id, relationship, opts \\ []),
    to: GraphOps

  @doc "Recall a knowledge node, reinforcing its relevance."
  defdelegate reinforce_knowledge(agent_id, node_id), to: GraphOps

  @doc "Search knowledge graph by content."
  defdelegate search_knowledge(agent_id, query, opts \\ []), to: GraphOps

  @doc "Find a knowledge node by name (case-insensitive exact match)."
  defdelegate find_knowledge_by_name(agent_id, name), to: GraphOps

  @doc "Get all pending proposals (facts and learnings awaiting approval)."
  defdelegate get_pending_proposals(agent_id), to: GraphOps

  @doc "Approve a pending fact or learning."
  defdelegate approve_pending(agent_id, pending_id), to: GraphOps

  @doc "Reject a pending fact or learning."
  defdelegate reject_pending(agent_id, pending_id), to: GraphOps

  @doc "Get knowledge graph statistics."
  defdelegate knowledge_stats(agent_id), to: GraphOps

  @doc "Trigger spreading activation from a node, boosting related nodes."
  defdelegate cascade_recall(agent_id, node_id, boost_amount, opts \\ []), to: GraphOps

  @doc "Get the lowest-relevance nodes approaching decay threshold."
  defdelegate near_threshold_nodes(agent_id, count \\ 10), to: GraphOps

  # ============================================================================
  # Consolidation (Decay and Pruning)
  # ============================================================================

  @doc "Run consolidation on the agent's knowledge graph."
  defdelegate consolidate(agent_id, opts \\ []), to: Consolidation, as: :consolidate_basic

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

  @doc "Get working memory for an agent."
  defdelegate get_working_memory(agent_id), to: WorkingMemoryStore

  @doc "Save working memory for an agent."
  defdelegate save_working_memory(agent_id, working_memory), to: WorkingMemoryStore

  @doc "Load working memory for an agent."
  defdelegate load_working_memory(agent_id, opts \\ []), to: WorkingMemoryStore

  @doc "Delete working memory for an agent."
  defdelegate delete_working_memory(agent_id), to: WorkingMemoryStore

  # ============================================================================
  # Working Memory Serialization
  # ============================================================================

  @doc """
  Serialize a working memory struct to a JSON-safe map.
  """
  @spec serialize_working_memory(WorkingMemory.t()) :: map()
  defdelegate serialize_working_memory(wm), to: WorkingMemory, as: :serialize

  @doc """
  Deserialize a map back into a WorkingMemory struct.
  """
  @spec deserialize_working_memory(map()) :: WorkingMemory.t()
  defdelegate deserialize_working_memory(data), to: WorkingMemory, as: :deserialize

  # ============================================================================
  # Context Window
  # ============================================================================

  @doc """
  Create a new context window for an agent.

  ## Options

  - `:max_tokens` — Maximum tokens (default: 10_000)
  - `:summary_threshold` — Threshold for summarization (default: 0.7)
  - `:preset` — Preset name (:balanced, :conservative, :expansive)
  """
  @spec new_context_window(String.t(), keyword()) :: ContextWindow.t()
  defdelegate new_context_window(agent_id, opts \\ []), to: ContextWindow, as: :new

  @doc """
  Add an entry to a context window.

  ## Entry Types

  - `:message` — Conversation message
  - `:system` — System prompt section
  - `:summary` — Summarized content
  """
  @spec add_context_entry(ContextWindow.t(), atom(), String.t()) :: ContextWindow.t()
  defdelegate add_context_entry(window, type, content), to: ContextWindow, as: :add_entry

  @doc """
  Serialize a context window to a JSON-safe map.
  """
  @spec serialize_context_window(ContextWindow.t()) :: map()
  defdelegate serialize_context_window(window), to: ContextWindow, as: :serialize

  @doc """
  Deserialize a map back into a ContextWindow struct.
  """
  @spec deserialize_context_window(map()) :: ContextWindow.t()
  defdelegate deserialize_context_window(data), to: ContextWindow, as: :deserialize

  @doc """
  Check if a context window should be summarized based on token usage.
  """
  @spec context_should_summarize?(ContextWindow.t()) :: boolean()
  defdelegate context_should_summarize?(window), to: ContextWindow, as: :should_summarize?

  @doc """
  Get the number of entries in a context window.
  """
  @spec context_entry_count(ContextWindow.t()) :: non_neg_integer()
  defdelegate context_entry_count(window), to: ContextWindow, as: :entry_count

  @doc """
  Convert a context window to formatted prompt text.
  """
  @spec context_to_prompt_text(ContextWindow.t()) :: String.t()
  defdelegate context_to_prompt_text(window), to: ContextWindow, as: :to_prompt_text

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

  @doc "Get a relationship by ID."
  defdelegate get_relationship(agent_id, relationship_id),
    to: RelationshipStore,
    as: :get_with_tracking

  @doc "Get a relationship by name."
  defdelegate get_relationship_by_name(agent_id, name),
    to: RelationshipStore,
    as: :get_by_name_with_tracking

  @doc "Get the primary relationship (highest salience)."
  defdelegate get_primary_relationship(agent_id),
    to: RelationshipStore,
    as: :get_primary_with_tracking

  @doc "Save a relationship."
  defdelegate save_relationship(agent_id, relationship), to: RelationshipStore, as: :save

  @doc "Add a key moment to a relationship."
  defdelegate add_moment(agent_id, relationship_id, summary, opts \\ []),
    to: RelationshipStore

  @doc "List all relationships for an agent."
  defdelegate list_relationships(agent_id, opts \\ []), to: RelationshipStore, as: :list

  @doc "Delete a relationship."
  defdelegate delete_relationship(agent_id, relationship_id), to: RelationshipStore, as: :delete

  # ============================================================================
  # Enhanced Consolidation (Phase 3)
  # ============================================================================

  @doc "Run enhanced consolidation on the agent's knowledge graph."
  defdelegate run_consolidation(agent_id, opts \\ []), to: Consolidation, as: :run_enhanced

  @doc "Check if consolidation should run for an agent."
  defdelegate should_consolidate?(agent_id, opts \\ []), to: Consolidation, as: :should_run?

  @doc "Preview what consolidation would do without actually doing it."
  defdelegate preview_consolidation(agent_id, opts \\ []),
    to: Consolidation,
    as: :preview_for_agent

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
  Get a specific proposal by ID.

  ## Examples

      {:ok, proposal} = Arbor.Memory.get_proposal("agent_001", "prop_abc123")
  """
  @spec get_proposal(String.t(), String.t()) :: {:ok, Proposal.t()} | {:error, :not_found}
  defdelegate get_proposal(agent_id, proposal_id), to: Proposal, as: :get

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

  @doc """
  Detect behavioral insights from working memory thoughts.

  Analyzes recent thoughts for patterns like curiosity, methodical,
  caution, and learning behaviors.
  """
  @spec detect_working_memory_insights(String.t(), keyword()) :: [map()]
  defdelegate detect_working_memory_insights(agent_id, opts \\ []),
    to: InsightDetector,
    as: :detect_from_working_memory

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
  Serialize a SelfKnowledge struct to a JSON-safe map.
  """
  @spec serialize_self_knowledge(SelfKnowledge.t()) :: map()
  defdelegate serialize_self_knowledge(sk), to: SelfKnowledge, as: :serialize

  @doc """
  Get a human-readable summary of self-knowledge for prompt injection.
  """
  @spec summarize_self_knowledge(SelfKnowledge.t()) :: String.t()
  defdelegate summarize_self_knowledge(sk), to: SelfKnowledge, as: :summarize

  @doc """
  Add a self-insight for an agent.

  Maps category to the appropriate SelfKnowledge function:
  - `:capability` → `SelfKnowledge.add_capability/4`
  - `:personality` / `:trait` → `SelfKnowledge.add_trait/4`
  - `:value` → `SelfKnowledge.add_value/4`
  - Other categories → stored as a knowledge node with type `:insight`

  ## Options

  - `:confidence` - Confidence score (default: 0.5)
  - `:evidence` - Evidence for the insight

  ## Examples

      {:ok, sk} = Arbor.Memory.add_insight("agent_001", "Good at pattern matching", :capability)
  """
  @spec add_insight(String.t(), String.t(), atom(), keyword()) ::
          {:ok, SelfKnowledge.t()} | {:ok, String.t()} | {:error, term()}
  def add_insight(agent_id, content, category, opts \\ []) do
    confidence = Keyword.get(opts, :confidence, 0.5)
    evidence = Keyword.get(opts, :evidence)

    sk = get_self_knowledge(agent_id) || SelfKnowledge.new(agent_id)

    case category do
      cat when cat in [:capability, :skill] ->
        updated = SelfKnowledge.add_capability(sk, content, confidence, evidence)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
        {:ok, updated}

      cat when cat in [:personality, :trait] ->
        trait_atom = safe_insight_atom(content)
        updated = SelfKnowledge.add_trait(sk, trait_atom, confidence, evidence)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
        {:ok, updated}

      :value ->
        value_atom = safe_insight_atom(content)
        updated = SelfKnowledge.add_value(sk, value_atom, confidence, evidence)
        IdentityConsolidator.save_self_knowledge(agent_id, updated)
        {:ok, updated}

      _other ->
        # Fall back to storing as a knowledge node
        add_knowledge(agent_id, %{
          type: :insight,
          content: content,
          relevance: confidence,
          metadata: %{category: category, evidence: evidence}
        })
    end
  end

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
  Apply an accepted identity change from a proposal.

  Called after the LLM accepts an identity-type proposal.
  """
  @spec apply_accepted_change(String.t(), map()) :: :ok | {:error, term()}
  defdelegate apply_accepted_change(agent_id, metadata), to: IdentityConsolidator

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

  @doc "Get preferences for an agent."
  defdelegate get_preferences(agent_id), to: PreferencesStore

  @doc "Adjust a cognitive preference for an agent."
  defdelegate adjust_preference(agent_id, param, value, opts \\ []), to: PreferencesStore

  @doc "Pin a memory to protect it from decay."
  defdelegate pin_memory(agent_id, memory_id, opts \\ []), to: PreferencesStore

  @doc "Unpin a memory, allowing it to decay normally."
  defdelegate unpin_memory(agent_id, memory_id), to: PreferencesStore

  @doc "Serialize a Preferences struct to a JSON-safe map."
  defdelegate serialize_preferences(prefs), to: Preferences, as: :serialize

  @doc "Deserialize a map back into a Preferences struct."
  defdelegate deserialize_preferences(data), to: Preferences, as: :deserialize

  @doc "Get a summary of current preferences and usage."
  defdelegate inspect_preferences(agent_id), to: PreferencesStore

  @doc "Get a trust-aware introspection of current preferences."
  defdelegate introspect_preferences(agent_id, trust_tier), to: PreferencesStore

  @doc "Set a context preference for prompt building."
  defdelegate set_context_preference(agent_id, key, value), to: PreferencesStore

  @doc "Get a context preference value."
  defdelegate get_context_preference(agent_id, key, default \\ nil), to: PreferencesStore

  # ============================================================================
  # Reflection (Phase 5)
  # ============================================================================

  @doc """
  Run a periodic reflection cycle for an agent.

  Gathers recent activity, generates a reflection prompt, and
  creates proposals from any insights found.
  """
  @spec periodic_reflection(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate periodic_reflection(agent_id), to: ReflectionProcessor

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
  Perform a deep reflection with full goal evaluation, knowledge graph
  integration, and insight detection.

  ## Options

  - `:provider` - LLM provider override
  - `:model` - LLM model override

  ## Examples

      {:ok, result} = Arbor.Memory.deep_reflect("agent_001")
  """
  @spec deep_reflect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate deep_reflect(agent_id, opts \\ []), to: ReflectionProcessor

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
  Get all goals for an agent, regardless of status.
  """
  @spec get_all_goals(String.t()) :: [struct()]
  defdelegate get_all_goals(agent_id), to: GoalStore

  @doc """
  Get a specific goal by ID.
  """
  @spec get_goal(String.t(), String.t()) :: {:ok, struct()} | {:error, :not_found}
  defdelegate get_goal(agent_id, goal_id), to: GoalStore

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
  Mark a goal as failed with an optional reason.
  """
  @spec fail_goal(String.t(), String.t(), String.t() | nil) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate fail_goal(agent_id, goal_id, reason \\ nil), to: GoalStore

  @doc """
  Update metadata for a goal, merging with existing metadata.

  ## Examples

      {:ok, goal} = Arbor.Memory.update_goal_metadata("agent_001", goal_id, %{decomposition_failed: true})
  """
  @spec update_goal_metadata(String.t(), String.t(), map()) ::
          {:ok, struct()} | {:error, :not_found}
  defdelegate update_goal_metadata(agent_id, goal_id, metadata), to: GoalStore

  @doc """
  Add a note to a goal's notes list.
  """
  @spec add_goal_note(String.t(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found}
  def add_goal_note(agent_id, goal_id, note) do
    GoalStore.add_note(agent_id, goal_id, note)
  end

  @doc """
  Export all goals for an agent as serializable maps.

  Used by Seed capture to snapshot goal state.
  """
  @spec export_all_goals(String.t()) :: [map()]
  defdelegate export_all_goals(agent_id), to: GoalStore

  @doc """
  Import goals from serializable maps.

  Used by Seed restore to restore goal state.
  """
  @spec import_goals(String.t(), [map()]) :: :ok
  defdelegate import_goals(agent_id, goal_maps), to: GoalStore

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

  @doc """
  Get pending intents linked to a specific goal.

  Returns intents that have the given `goal_id` and are not completed or failed.
  Used by the BDI loop to determine if a goal needs decomposition.
  """
  @spec pending_intents_for_goal(String.t(), String.t()) :: [struct()]
  defdelegate pending_intents_for_goal(agent_id, goal_id), to: IntentStore

  @doc """
  Get a specific intent by ID, with its status info.
  """
  @spec get_intent(String.t(), String.t()) :: {:ok, struct(), map()} | {:error, :not_found}
  defdelegate get_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Get pending intents sorted by urgency (highest first).
  """
  @spec pending_intentions(String.t(), keyword()) :: [{struct(), map()}]
  defdelegate pending_intentions(agent_id, opts \\ []), to: IntentStore

  @doc """
  Lock an intent for execution (peek-lock-ack pattern).
  """
  @spec lock_intent(String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  defdelegate lock_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Mark an intent as completed (terminal state).
  """
  @spec complete_intent(String.t(), String.t()) :: :ok | {:error, :not_found}
  defdelegate complete_intent(agent_id, intent_id), to: IntentStore

  @doc """
  Mark an intent as failed. Increments retry_count, returns to pending.
  """
  @spec fail_intent(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  defdelegate fail_intent(agent_id, intent_id, reason \\ "unknown"), to: IntentStore

  @doc """
  Unlock intents locked longer than timeout_ms (stale lock recovery).
  """
  @spec unlock_stale_intents(String.t(), pos_integer()) :: non_neg_integer()
  defdelegate unlock_stale_intents(agent_id, timeout_ms \\ 60_000), to: IntentStore

  @doc """
  Export non-completed intents with status info for Seed capture.

  Returns serializable maps suitable for `import_intents/2`.
  """
  @spec export_pending_intents(String.t()) :: [map()]
  defdelegate export_pending_intents(agent_id), to: IntentStore

  @doc """
  Import intents from a previous export, restoring pending work.

  Skips intents that already exist (by ID).
  """
  @spec import_intents(String.t(), [map()]) :: :ok
  defdelegate import_intents(agent_id, intent_maps), to: IntentStore

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
  # Chat History (Seed/Host Phase 3)
  # ============================================================================

  @doc "Append a chat message to an agent's conversation history."
  defdelegate append_chat_message(agent_id, msg), to: ChatHistory, as: :append

  @doc "Load chat history for an agent, sorted chronologically."
  defdelegate load_chat_history(agent_id), to: ChatHistory, as: :load

  @doc "Clear all chat history for an agent."
  defdelegate clear_chat_history(agent_id), to: ChatHistory, as: :clear

  # ============================================================================
  # read_self — Live System Introspection
  # ============================================================================

  @doc "Aggregate live stats from the memory system for a given aspect."
  defdelegate read_self(agent_id, aspect \\ :all, opts \\ []),
    to: Arbor.Memory.Introspection

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

  @doc """
  Extract thinking content from an LLM response.

  Supports multiple providers: `:anthropic`, `:deepseek`, `:openai`, `:generic`.

  ## Options

  - `:fallback_to_generic` — try generic extraction on failure (default: false)

  ## Returns

  - `{:ok, text}` — extracted thinking text
  - `{:none, reason}` — no thinking found (e.g., `:no_thinking_blocks`, `:hidden_reasoning`)
  """
  @spec extract_thinking(map(), atom(), keyword()) :: {:ok, String.t()} | {:none, atom()}
  def extract_thinking(response, provider, opts \\ []) do
    Thinking.extract(response, provider, opts)
  end

  @doc """
  Extract thinking from an LLM response and record it for the agent.

  Combines `extract/3` and `record_thinking/3`. Automatically flags
  identity-affecting thinking as significant.

  ## Returns

  - `{:ok, thinking_entry}` — extracted and recorded
  - `{:none, reason}` — no thinking found
  """
  @spec extract_and_record_thinking(String.t(), map(), atom(), keyword()) ::
          {:ok, map()} | {:none, atom()}
  def extract_and_record_thinking(agent_id, response, provider, opts \\ []) do
    Thinking.extract_and_record(agent_id, response, provider, opts)
  end

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
  Get a specific code pattern by ID.

  ## Examples

      {:ok, entry} = Arbor.Memory.get_code("agent_001", "code_abc123")
  """
  @spec get_code(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_code(agent_id, entry_id), to: CodeStore, as: :get

  @doc """
  Delete a specific code pattern.

  ## Examples

      :ok = Arbor.Memory.delete_code("agent_001", "code_abc123")
  """
  @spec delete_code(String.t(), String.t()) :: :ok
  defdelegate delete_code(agent_id, entry_id), to: CodeStore, as: :delete

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

  # Preferences operations delegated to PreferencesStore

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

  # Graph operations delegated to GraphOps

  # M3: Convert a string to an atom safely for insight categories.
  # Normalizes (downcase + underscores), then uses SafeAtom to prevent
  # atom table exhaustion from untrusted input.
  defp safe_insight_atom(name) when is_atom(name), do: name

  defp safe_insight_atom(name) when is_binary(name) do
    normalized =
      name
      |> String.downcase()
      |> String.replace(~r/\s+/, "_")

    case Arbor.Common.SafeAtom.to_existing(normalized) do
      {:ok, atom} -> atom
      {:error, _} -> normalized
    end
  end

  # ============================================================================
  # Export / Import (for Seed capture & restore)
  # ============================================================================

  @doc "Export the full knowledge graph for an agent as a serializable map."
  defdelegate export_knowledge_graph(agent_id), to: GraphOps

  @doc "Import a knowledge graph from a serializable map."
  defdelegate import_knowledge_graph(agent_id, graph_map), to: GraphOps

  @doc "Save preferences for an agent (public wrapper for Seed restore)."
  defdelegate save_preferences_for_agent(agent_id, prefs), to: PreferencesStore
end
