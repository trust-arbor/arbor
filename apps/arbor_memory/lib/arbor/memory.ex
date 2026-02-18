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

  ## Sub-facades

  Operations are organized into domain sub-facades for maintainability:

  - `Arbor.Memory.IndexOps` - Vector index and embedding operations
  - `Arbor.Memory.KnowledgeOps` - Knowledge graph and consolidation
  - `Arbor.Memory.IdentityOps` - Self-knowledge, preferences, reflection, insights
  - `Arbor.Memory.GoalIntentOps` - Goals, intents, percepts, bridge
  - `Arbor.Memory.SessionOps` - Working memory, context, chat, thinking, code, proposals

  All functions remain accessible via `Arbor.Memory` for backward compatibility.
  """

  alias Arbor.Memory.{
    GoalIntentOps,
    GraphOps,
    IdentityOps,
    IndexOps,
    IndexSupervisor,
    KnowledgeGraph,
    KnowledgeOps,
    SessionOps,
    Signals,
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
    opts = merge_config_defaults(opts)

    index_enabled = Keyword.get(opts, :index_enabled, true)
    graph_enabled = Keyword.get(opts, :graph_enabled, true)

    index_result =
      if index_enabled do
        IndexSupervisor.start_index(agent_id, opts)
      else
        {:ok, nil}
      end

    if graph_enabled do
      case GraphOps.load_persisted_graph(agent_id) do
        {:ok, graph} ->
          GraphOps.save_graph(agent_id, graph)

        {:error, _} ->
          graph = KnowledgeGraph.new(agent_id, opts)
          GraphOps.save_graph(agent_id, graph)
      end
    end

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
    IndexSupervisor.stop_index(agent_id)
    :ets.delete(:arbor_memory_graphs, agent_id)
    WorkingMemoryStore.delete_working_memory(agent_id)
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
  # Index Operations (delegated to IndexOps)
  # ============================================================================

  defdelegate index(agent_id, content, metadata \\ %{}, opts \\ []), to: IndexOps
  defdelegate recall(agent_id, query, opts \\ []), to: IndexOps
  defdelegate batch_index(agent_id, items, opts \\ []), to: IndexOps
  defdelegate index_stats(agent_id), to: IndexOps
  defdelegate store_embedding(agent_id, content, embedding, metadata \\ %{}), to: IndexOps
  defdelegate search_embeddings(agent_id, query_embedding, opts \\ []), to: IndexOps
  defdelegate embedding_stats(agent_id), to: IndexOps
  defdelegate warm_index_cache(agent_id, opts \\ []), to: IndexOps

  # ============================================================================
  # Knowledge Graph Operations (delegated to KnowledgeOps)
  # ============================================================================

  defdelegate add_knowledge(agent_id, node_data), to: KnowledgeOps
  defdelegate link_knowledge(agent_id, source_id, target_id, relationship, opts \\ []),
    to: KnowledgeOps
  defdelegate reinforce_knowledge(agent_id, node_id), to: KnowledgeOps
  defdelegate search_knowledge(agent_id, query, opts \\ []), to: KnowledgeOps
  defdelegate find_knowledge_by_name(agent_id, name), to: KnowledgeOps
  defdelegate get_pending_proposals(agent_id), to: KnowledgeOps
  defdelegate approve_pending(agent_id, pending_id), to: KnowledgeOps
  defdelegate reject_pending(agent_id, pending_id), to: KnowledgeOps
  defdelegate knowledge_stats(agent_id), to: KnowledgeOps
  defdelegate cascade_recall(agent_id, node_id, boost_amount, opts \\ []), to: KnowledgeOps
  defdelegate near_threshold_nodes(agent_id, count \\ 10), to: KnowledgeOps
  defdelegate consolidate(agent_id, opts \\ []), to: KnowledgeOps
  defdelegate run_consolidation(agent_id, opts \\ []), to: KnowledgeOps
  defdelegate should_consolidate?(agent_id, opts \\ []), to: KnowledgeOps
  defdelegate preview_consolidation(agent_id, opts \\ []), to: KnowledgeOps
  defdelegate export_knowledge_graph(agent_id), to: KnowledgeOps
  defdelegate import_knowledge_graph(agent_id, graph_map), to: KnowledgeOps

  # ============================================================================
  # Identity Operations (delegated to IdentityOps)
  # ============================================================================

  defdelegate get_self_knowledge(agent_id), to: IdentityOps
  defdelegate serialize_self_knowledge(sk), to: IdentityOps
  defdelegate summarize_self_knowledge(sk), to: IdentityOps
  defdelegate add_insight(agent_id, content, category, opts \\ []), to: IdentityOps
  defdelegate query_self(agent_id, aspect), to: IdentityOps
  defdelegate apply_accepted_change(agent_id, metadata), to: IdentityOps
  defdelegate consolidate_identity(agent_id, opts \\ []), to: IdentityOps
  defdelegate rollback_identity(agent_id, version \\ :previous), to: IdentityOps
  defdelegate identity_history(agent_id, opts \\ []), to: IdentityOps
  defdelegate get_preferences(agent_id), to: IdentityOps
  defdelegate adjust_preference(agent_id, param, value, opts \\ []), to: IdentityOps
  defdelegate pin_memory(agent_id, memory_id, opts \\ []), to: IdentityOps
  defdelegate unpin_memory(agent_id, memory_id), to: IdentityOps
  defdelegate serialize_preferences(prefs), to: IdentityOps
  defdelegate deserialize_preferences(data), to: IdentityOps
  defdelegate inspect_preferences(agent_id), to: IdentityOps
  defdelegate introspect_preferences(agent_id, trust_tier), to: IdentityOps
  defdelegate set_context_preference(agent_id, key, value), to: IdentityOps
  defdelegate get_context_preference(agent_id, key, default \\ nil), to: IdentityOps
  defdelegate save_preferences_for_agent(agent_id, prefs), to: IdentityOps
  defdelegate periodic_reflection(agent_id), to: IdentityOps
  defdelegate reflect(agent_id, prompt, opts \\ []), to: IdentityOps
  defdelegate deep_reflect(agent_id, opts \\ []), to: IdentityOps
  defdelegate reflection_history(agent_id, opts \\ []), to: IdentityOps
  defdelegate detect_insights(agent_id, opts \\ []), to: IdentityOps
  defdelegate detect_and_queue_insights(agent_id, opts \\ []), to: IdentityOps
  defdelegate detect_working_memory_insights(agent_id, opts \\ []), to: IdentityOps

  # ============================================================================
  # Goal & Intent Operations (delegated to GoalIntentOps)
  # ============================================================================

  defdelegate add_goal(agent_id, goal), to: GoalIntentOps
  defdelegate get_active_goals(agent_id), to: GoalIntentOps
  defdelegate get_all_goals(agent_id), to: GoalIntentOps
  defdelegate get_goal(agent_id, goal_id), to: GoalIntentOps
  defdelegate update_goal_progress(agent_id, goal_id, progress), to: GoalIntentOps
  defdelegate achieve_goal(agent_id, goal_id), to: GoalIntentOps
  defdelegate abandon_goal(agent_id, goal_id, reason \\ nil), to: GoalIntentOps
  defdelegate fail_goal(agent_id, goal_id, reason \\ nil), to: GoalIntentOps
  defdelegate update_goal_metadata(agent_id, goal_id, metadata), to: GoalIntentOps
  defdelegate add_goal_note(agent_id, goal_id, note), to: GoalIntentOps
  defdelegate export_all_goals(agent_id), to: GoalIntentOps
  defdelegate import_goals(agent_id, goal_maps), to: GoalIntentOps
  defdelegate get_goal_tree(agent_id, goal_id), to: GoalIntentOps
  defdelegate record_intent(agent_id, intent), to: GoalIntentOps
  defdelegate recent_intents(agent_id, opts \\ []), to: GoalIntentOps
  defdelegate record_percept(agent_id, percept), to: GoalIntentOps
  defdelegate recent_percepts(agent_id, opts \\ []), to: GoalIntentOps
  defdelegate get_percept_for_intent(agent_id, intent_id), to: GoalIntentOps
  defdelegate pending_intents_for_goal(agent_id, goal_id), to: GoalIntentOps
  defdelegate get_intent(agent_id, intent_id), to: GoalIntentOps
  defdelegate pending_intentions(agent_id, opts \\ []), to: GoalIntentOps
  defdelegate lock_intent(agent_id, intent_id), to: GoalIntentOps
  defdelegate complete_intent(agent_id, intent_id), to: GoalIntentOps
  defdelegate fail_intent(agent_id, intent_id, reason \\ "unknown"), to: GoalIntentOps
  defdelegate unlock_stale_intents(agent_id, timeout_ms \\ 60_000), to: GoalIntentOps
  defdelegate export_pending_intents(agent_id), to: GoalIntentOps
  defdelegate import_intents(agent_id, intent_maps), to: GoalIntentOps
  defdelegate emit_intent(agent_id, intent), to: GoalIntentOps
  defdelegate emit_percept(agent_id, percept), to: GoalIntentOps
  defdelegate execute_and_wait(agent_id, intent, opts \\ []), to: GoalIntentOps
  defdelegate subscribe_to_intents(agent_id, handler), to: GoalIntentOps
  defdelegate subscribe_to_percepts(agent_id, handler), to: GoalIntentOps

  # ============================================================================
  # Session Operations (delegated to SessionOps)
  # ============================================================================

  defdelegate get_working_memory(agent_id), to: SessionOps
  defdelegate save_working_memory(agent_id, working_memory), to: SessionOps
  defdelegate load_working_memory(agent_id, opts \\ []), to: SessionOps
  defdelegate delete_working_memory(agent_id), to: SessionOps
  defdelegate serialize_working_memory(wm), to: SessionOps
  defdelegate deserialize_working_memory(data), to: SessionOps
  defdelegate new_context_window(agent_id, opts \\ []), to: SessionOps
  defdelegate add_context_entry(window, type, content), to: SessionOps
  defdelegate serialize_context_window(window), to: SessionOps
  defdelegate deserialize_context_window(data), to: SessionOps
  defdelegate context_should_summarize?(window), to: SessionOps
  defdelegate context_entry_count(window), to: SessionOps
  defdelegate context_to_prompt_text(window), to: SessionOps
  defdelegate let_me_recall(agent_id, query, opts \\ []), to: SessionOps
  defdelegate build_context(working_memory, opts \\ []), to: SessionOps
  defdelegate summarize(agent_id, text, opts \\ []), to: SessionOps
  defdelegate assess_complexity(text), to: SessionOps
  defdelegate resolve_budget(budget, context_size), to: SessionOps
  defdelegate resolve_budget_for_model(budget, model_id), to: SessionOps
  defdelegate estimate_tokens(text), to: SessionOps
  defdelegate model_context_size(model_id), to: SessionOps
  defdelegate get_relationship(agent_id, relationship_id), to: SessionOps
  defdelegate get_relationship_by_name(agent_id, name), to: SessionOps
  defdelegate get_primary_relationship(agent_id), to: SessionOps
  defdelegate save_relationship(agent_id, relationship), to: SessionOps
  defdelegate add_moment(agent_id, relationship_id, summary, opts \\ []), to: SessionOps
  defdelegate list_relationships(agent_id, opts \\ []), to: SessionOps
  defdelegate delete_relationship(agent_id, relationship_id), to: SessionOps
  defdelegate run_background_checks(agent_id, opts \\ []), to: SessionOps
  defdelegate analyze_memory_patterns(agent_id), to: SessionOps
  defdelegate get_proposal(agent_id, proposal_id), to: SessionOps
  defdelegate create_proposal(agent_id, type, data), to: SessionOps
  defdelegate get_proposals(agent_id, opts \\ []), to: SessionOps
  defdelegate accept_proposal(agent_id, proposal_id), to: SessionOps
  defdelegate reject_proposal(agent_id, proposal_id, opts \\ []), to: SessionOps
  defdelegate defer_proposal(agent_id, proposal_id), to: SessionOps
  defdelegate accept_all_proposals(agent_id, type \\ nil), to: SessionOps
  defdelegate proposal_stats(agent_id), to: SessionOps
  defdelegate analyze_action_patterns(action_history, opts \\ []), to: SessionOps
  defdelegate analyze_and_queue_learnings(agent_id, history, opts \\ []), to: SessionOps
  defdelegate run_preconscious_check(agent_id, opts \\ []), to: SessionOps
  defdelegate configure_preconscious(agent_id, opts), to: SessionOps
  defdelegate append_chat_message(agent_id, msg), to: SessionOps
  defdelegate load_chat_history(agent_id), to: SessionOps
  defdelegate clear_chat_history(agent_id), to: SessionOps
  defdelegate read_self(agent_id, aspect \\ :all, opts \\ []), to: SessionOps
  defdelegate record_thinking(agent_id, text, opts \\ []), to: SessionOps
  defdelegate recent_thinking(agent_id, opts \\ []), to: SessionOps
  defdelegate extract_thinking(response, provider, opts \\ []), to: SessionOps
  defdelegate extract_and_record_thinking(agent_id, response, provider, opts \\ []), to: SessionOps
  defdelegate store_code(agent_id, params), to: SessionOps
  defdelegate find_code_by_purpose(agent_id, query), to: SessionOps
  defdelegate get_code(agent_id, entry_id), to: SessionOps
  defdelegate delete_code(agent_id, entry_id), to: SessionOps
  defdelegate list_code(agent_id, opts \\ []), to: SessionOps

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp merge_config_defaults(opts) do
    defaults = [
      max_entries: Application.get_env(:arbor_memory, :index_max_entries, 10_000),
      threshold: Application.get_env(:arbor_memory, :index_default_threshold, 0.3),
      decay_rate: Application.get_env(:arbor_memory, :kg_default_decay_rate, 0.10),
      max_nodes_per_type: Application.get_env(:arbor_memory, :kg_max_nodes_per_type, 500)
    ]

    Keyword.merge(defaults, opts)
  end
end
