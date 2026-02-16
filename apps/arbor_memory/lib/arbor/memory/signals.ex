defmodule Arbor.Memory.Signals do
  @moduledoc """
  Transient signal emissions for memory operations.

  Emits signals to the arbor_signals bus for operational notifications.
  These are ephemeral, pub/sub signals stored in a circular buffer --
  designed for real-time observers, dashboards, and subconscious processors.

  All memory signals use category `:memory` with different types.
  See `memory_signal_types/0` for a complete list.

  ## Sub-modules

  Signal emissions are organized by domain:

  - `Arbor.Memory.Signals.Reflection` - Reflection cycle signals
  - `Arbor.Memory.Signals.Proposals` - Background checks and proposal lifecycle
  - `Arbor.Memory.Signals.Identity` - Identity evolution, insights, and decisions
  - `Arbor.Memory.Signals.WorkingMemory` - Working memory state changes
  - `Arbor.Memory.Signals.Lifecycle` - Goals, intents, episodic, bridge signals

  ## Examples

      :ok = Arbor.Memory.Signals.emit_indexed("agent_001", %{
        entry_id: "mem_123",
        type: :fact
      })
  """

  require Logger

  # ============================================================================
  # Delegated: Reflection Signals
  # ============================================================================

  defdelegate emit_reflection_started(agent_id, metadata), to: __MODULE__.Reflection
  defdelegate emit_reflection_completed(agent_id, metadata), to: __MODULE__.Reflection
  defdelegate emit_reflection_insight(agent_id, insight), to: __MODULE__.Reflection
  defdelegate emit_reflection_learning(agent_id, learning), to: __MODULE__.Reflection
  defdelegate emit_reflection_goal_update(agent_id, goal_id, update), to: __MODULE__.Reflection
  defdelegate emit_reflection_goal_created(agent_id, goal_id, data), to: __MODULE__.Reflection
  defdelegate emit_reflection_knowledge_graph(agent_id, stats), to: __MODULE__.Reflection
  defdelegate emit_reflection_knowledge_decay(agent_id, data), to: __MODULE__.Reflection
  defdelegate emit_reflection_llm_call(agent_id, metrics), to: __MODULE__.Reflection

  # ============================================================================
  # Delegated: Proposal / Background Check Signals
  # ============================================================================

  defdelegate emit_background_checks_started(agent_id), to: __MODULE__.Proposals
  defdelegate emit_background_checks_completed(agent_id, result_summary), to: __MODULE__.Proposals
  defdelegate emit_pattern_detected(agent_id, pattern), to: __MODULE__.Proposals
  defdelegate emit_insight_detected(agent_id, suggestion), to: __MODULE__.Proposals
  defdelegate emit_proposal_created(agent_id, proposal), to: __MODULE__.Proposals
  defdelegate emit_proposal_accepted(agent_id, proposal_id, node_id), to: __MODULE__.Proposals
  defdelegate emit_proposal_rejected(agent_id, proposal_id, proposal_type, reason), to: __MODULE__.Proposals
  defdelegate emit_proposal_deferred(agent_id, proposal_id), to: __MODULE__.Proposals
  defdelegate emit_cognitive_adjustment(agent_id, adjustment_type, details), to: __MODULE__.Proposals

  # ============================================================================
  # Delegated: Identity & Insight Lifecycle Signals
  # ============================================================================

  defdelegate emit_identity_change(agent_id, change_type, details), to: __MODULE__.Identity
  defdelegate emit_identity_rollback(agent_id, change_type, details), to: __MODULE__.Identity
  defdelegate emit_self_insight_created(agent_id, insight), to: __MODULE__.Identity
  defdelegate emit_self_insight_reinforced(agent_id, insight), to: __MODULE__.Identity
  defdelegate emit_insight_promoted(agent_id, insight_id, details), to: __MODULE__.Identity

  # Functions with default args cannot use defdelegate — use wrappers
  @doc "Emit a signal when an insight review is deferred."
  @spec emit_insight_deferred(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_insight_deferred(agent_id, insight_id, reason \\ nil),
    do: __MODULE__.Identity.emit_insight_deferred(agent_id, insight_id, reason)

  @doc "Emit a signal when an insight is blocked from integration."
  @spec emit_insight_blocked(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_insight_blocked(agent_id, insight_id, reason \\ nil),
    do: __MODULE__.Identity.emit_insight_blocked(agent_id, insight_id, reason)

  @doc """
  Emit a full identity snapshot signal.

  Called when the agent establishes or broadcasts its identity (e.g. on startup
  or after major identity changes). Unlike `:identity_change` which tracks
  mutations, this captures the complete identity state.

  ## Data

  - `:name` - Agent's name
  - `:traits` - Personality traits map
  - `:background` - Background/context string (optional)
  """
  @spec emit_identity(String.t(), keyword()) :: :ok
  def emit_identity(agent_id, opts \\ []),
    do: __MODULE__.Identity.emit_identity(agent_id, opts)

  @doc """
  Emit a decision event signal.

  Called when the agent makes an important decision worth recording
  for audit trails and decision replay.

  ## Options

  - `:reasoning` - Why the decision was made
  - `:confidence` - Confidence level (default: 0.5)
  """
  @spec emit_decision(String.t(), String.t(), map(), keyword()) :: :ok
  def emit_decision(agent_id, description, details, opts \\ []),
    do: __MODULE__.Identity.emit_decision(agent_id, description, details, opts)

  # ============================================================================
  # Delegated: WorkingMemory State Change Signals
  # ============================================================================

  defdelegate emit_engagement_changed(agent_id, level), to: __MODULE__.WorkingMemory
  defdelegate emit_concern_added(agent_id, concern), to: __MODULE__.WorkingMemory
  defdelegate emit_concern_resolved(agent_id, concern), to: __MODULE__.WorkingMemory
  defdelegate emit_curiosity_added(agent_id, item), to: __MODULE__.WorkingMemory
  defdelegate emit_curiosity_satisfied(agent_id, item), to: __MODULE__.WorkingMemory
  defdelegate emit_conversation_changed(agent_id, conversation), to: __MODULE__.WorkingMemory
  defdelegate emit_relationship_changed(agent_id, human_name, context), to: __MODULE__.WorkingMemory

  # ============================================================================
  # Query API
  # ============================================================================

  @doc """
  Query recent memory signals for an agent.

  Returns signals filtered by agent_id (via source URI) and optionally by type.

  ## Options

  - `:limit` - Maximum signals to return (default: 100)
  - `:types` - List of signal types to include (default: all)
  - `:since` - Only signals after this DateTime
  """
  @spec query_recent(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_recent(agent_id, opts \\ []) do
    if signals_available?() do
      limit = Keyword.get(opts, :limit, 100)
      source = memory_source(agent_id)

      filters = [category: :memory, source: source, limit: limit]
      filters = if since = Keyword.get(opts, :since), do: [{:since, since} | filters], else: filters

      with {:ok, signals} <- Arbor.Signals.recent(filters) do
        {:ok, filter_by_types(signals, Keyword.get(opts, :types))}
      end
    else
      {:ok, []}
    end
  end

  defp filter_by_types(signals, nil), do: signals
  defp filter_by_types(signals, types), do: Enum.filter(signals, &(&1.type in types))

  # ============================================================================
  # Core Emission API
  # ============================================================================

  @doc """
  Emit a signal when content is indexed.

  ## Metadata

  - `:entry_id` - The ID of the indexed entry
  - `:type` - The type of content indexed
  - `:source` - Source of the content (optional)
  """
  @spec emit_indexed(String.t(), map()) :: :ok
  def emit_indexed(agent_id, metadata) do
    emit_memory_signal(agent_id, :indexed, %{
      entry_id: metadata[:entry_id],
      type: metadata[:type],
      source: metadata[:source]
    })
  end

  @doc """
  Emit a signal when content is recalled.

  ## Metadata

  - `:query` - The recall query
  - `:result_count` - Number of results returned
  - `:top_similarity` - Highest similarity score (optional)
  """
  @spec emit_recalled(String.t(), String.t(), non_neg_integer(), keyword()) :: :ok
  def emit_recalled(agent_id, query, result_count, opts \\ []) do
    emit_memory_signal(agent_id, :recalled, %{
      query: query,
      result_count: result_count,
      top_similarity: Keyword.get(opts, :top_similarity)
    })
  end

  @doc """
  Emit a signal when consolidation starts.

  Consolidation is the process of decay, pruning, and archiving.
  """
  @spec emit_consolidation_started(String.t()) :: :ok
  def emit_consolidation_started(agent_id) do
    emit_memory_signal(agent_id, :consolidation_started, %{
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when consolidation completes.

  ## Metrics

  - `:decayed_count` - Nodes that had relevance reduced
  - `:pruned_count` - Nodes that were pruned
  - `:duration_ms` - How long consolidation took
  """
  @spec emit_consolidation_completed(String.t(), map()) :: :ok
  def emit_consolidation_completed(agent_id, metrics) do
    emit_memory_signal(agent_id, :consolidation_completed, %{
      decayed_count: metrics[:decayed_count],
      pruned_count: metrics[:pruned_count],
      duration_ms: metrics[:duration_ms],
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a fact is extracted (added to pending queue).
  """
  @spec emit_fact_extracted(String.t(), map()) :: :ok
  def emit_fact_extracted(agent_id, fact) do
    emit_memory_signal(agent_id, :fact_extracted, %{
      pending_id: fact[:id],
      content_preview: String.slice(fact[:content] || "", 0, 100),
      confidence: fact[:confidence],
      source: fact[:source]
    })
  end

  @doc """
  Emit a signal when a learning is extracted (added to pending queue).
  """
  @spec emit_learning_extracted(String.t(), map()) :: :ok
  def emit_learning_extracted(agent_id, learning) do
    emit_memory_signal(agent_id, :learning_extracted, %{
      pending_id: learning[:id],
      content_preview: String.slice(learning[:content] || "", 0, 100),
      confidence: learning[:confidence],
      source: learning[:source]
    })
  end

  @doc """
  Emit a signal when knowledge is added to the graph.
  """
  @spec emit_knowledge_added(String.t(), String.t(), atom()) :: :ok
  def emit_knowledge_added(agent_id, node_id, node_type) do
    emit_memory_signal(agent_id, :knowledge_added, %{
      node_id: node_id,
      node_type: node_type
    })
  end

  @doc """
  Emit a signal when knowledge nodes are linked.
  """
  @spec emit_knowledge_linked(String.t(), String.t(), String.t(), atom()) :: :ok
  def emit_knowledge_linked(agent_id, source_id, target_id, relationship) do
    emit_memory_signal(agent_id, :knowledge_linked, %{
      source_id: source_id,
      target_id: target_id,
      relationship: relationship
    })
  end

  @doc """
  Emit a signal when decay is applied to the knowledge graph.
  """
  @spec emit_knowledge_decayed(String.t(), map()) :: :ok
  def emit_knowledge_decayed(agent_id, stats) do
    emit_memory_signal(agent_id, :knowledge_decayed, %{
      node_count: stats[:node_count],
      average_relevance: stats[:average_relevance]
    })
  end

  @doc """
  Emit a signal when nodes are pruned from the knowledge graph.
  """
  @spec emit_knowledge_pruned(String.t(), non_neg_integer()) :: :ok
  def emit_knowledge_pruned(agent_id, pruned_count) do
    emit_memory_signal(agent_id, :knowledge_pruned, %{
      pruned_count: pruned_count
    })
  end

  @doc """
  Emit a signal when a pending item is approved.
  """
  @spec emit_pending_approved(String.t(), String.t(), String.t()) :: :ok
  def emit_pending_approved(agent_id, pending_id, node_id) do
    emit_memory_signal(agent_id, :pending_approved, %{
      pending_id: pending_id,
      node_id: node_id
    })
  end

  @doc """
  Emit a signal when a pending item is rejected.
  """
  @spec emit_pending_rejected(String.t(), String.t()) :: :ok
  def emit_pending_rejected(agent_id, pending_id) do
    emit_memory_signal(agent_id, :pending_rejected, %{
      pending_id: pending_id
    })
  end

  @doc """
  Emit a signal when memory is initialized for an agent.
  """
  @spec emit_memory_initialized(String.t(), map()) :: :ok
  def emit_memory_initialized(agent_id, opts \\ %{}) do
    emit_memory_signal(agent_id, :initialized, %{
      index_enabled: Map.get(opts, :index_enabled, true),
      graph_enabled: Map.get(opts, :graph_enabled, true)
    })
  end

  @doc """
  Emit a signal when memory is cleaned up for an agent.
  """
  @spec emit_memory_cleaned_up(String.t()) :: :ok
  def emit_memory_cleaned_up(agent_id) do
    emit_memory_signal(agent_id, :cleaned_up, %{})
  end

  # ============================================================================
  # Phase 2 Signals
  # ============================================================================

  @doc """
  Emit a signal when working memory is loaded for an agent.

  ## Status

  - `:created` - New working memory was created
  - `:existing` - Existing working memory was loaded
  """
  @spec emit_working_memory_loaded(String.t(), atom()) :: :ok
  def emit_working_memory_loaded(agent_id, status) do
    emit_memory_signal(agent_id, :working_memory_loaded, %{
      status: status,
      loaded_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when working memory is saved for an agent.
  """
  @spec emit_working_memory_saved(String.t(), map()) :: :ok
  def emit_working_memory_saved(agent_id, stats) do
    emit_memory_signal(agent_id, :working_memory_saved, %{
      thought_count: stats[:thought_count],
      goal_count: stats[:goal_count],
      engagement_level: stats[:engagement_level],
      saved_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a thought is recorded to working memory.
  """
  @spec emit_thought_recorded(String.t(), String.t()) :: :ok
  def emit_thought_recorded(agent_id, thought_preview) do
    emit_memory_signal(agent_id, :thought_recorded, %{
      thought_preview: String.slice(thought_preview, 0, 100),
      recorded_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when facts are extracted from text.
  """
  @spec emit_facts_extracted(String.t(), map()) :: :ok
  def emit_facts_extracted(agent_id, extraction_info) do
    emit_memory_signal(agent_id, :facts_extracted, %{
      fact_count: extraction_info[:fact_count],
      categories: extraction_info[:categories],
      source: extraction_info[:source],
      extracted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when context is summarized.
  """
  @spec emit_context_summarized(String.t(), map()) :: :ok
  def emit_context_summarized(agent_id, summary_info) do
    emit_memory_signal(agent_id, :context_summarized, %{
      complexity: summary_info[:complexity],
      model_used: summary_info[:model_used],
      summarized_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a chat message is added to history.
  """
  @spec emit_chat_message_added(String.t(), String.t()) :: :ok
  def emit_chat_message_added(agent_id, message_id) do
    emit_memory_signal(agent_id, :chat_message_added, %{
      message_id: message_id,
      added_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an agent stops (lifecycle event).
  """
  @spec emit_agent_stopped(String.t()) :: :ok
  def emit_agent_stopped(agent_id) do
    emit_memory_signal(agent_id, :agent_stopped, %{
      stopped_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a heartbeat signal for an agent (lifecycle event).
  """
  @spec emit_heartbeat(String.t()) :: :ok
  def emit_heartbeat(agent_id) do
    emit_memory_signal(agent_id, :heartbeat, %{
      timestamp: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Phase 3 Signals (Relationships)
  # ============================================================================

  @doc """
  Emit a signal when a relationship is created.
  """
  @spec emit_relationship_created(String.t(), String.t(), String.t()) :: :ok
  def emit_relationship_created(agent_id, relationship_id, name) do
    emit_memory_signal(agent_id, :relationship_created, %{
      relationship_id: relationship_id,
      name: name,
      created_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a relationship is updated.

  ## Changes

  A map describing what changed, e.g.:
  - `%{field: :salience, old_value: 0.5, new_value: 0.8}`
  """
  @spec emit_relationship_updated(String.t(), String.t(), map()) :: :ok
  def emit_relationship_updated(agent_id, relationship_id, changes) do
    emit_memory_signal(agent_id, :relationship_updated, %{
      relationship_id: relationship_id,
      changes: changes,
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a key moment is added to a relationship.
  """
  @spec emit_moment_added(String.t(), String.t(), String.t()) :: :ok
  def emit_moment_added(agent_id, relationship_id, moment_summary) do
    emit_memory_signal(agent_id, :moment_added, %{
      relationship_id: relationship_id,
      moment_preview: String.slice(moment_summary, 0, 100),
      added_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a relationship is accessed/touched.
  """
  @spec emit_relationship_accessed(String.t(), String.t()) :: :ok
  def emit_relationship_accessed(agent_id, relationship_id) do
    emit_memory_signal(agent_id, :relationship_accessed, %{
      relationship_id: relationship_id,
      accessed_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Phase 7 Signals (Preconscious)
  # ============================================================================

  @doc """
  Emit a signal when a preconscious check starts.
  """
  @spec emit_preconscious_check(String.t()) :: :ok
  def emit_preconscious_check(agent_id) do
    emit_memory_signal(agent_id, :preconscious_check, %{
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when preconscious surfaces relevant memories.

  ## Anticipation

  - `:query_used` - The search query derived from context
  - `:relevance_score` - Average relevance of surfaced memories
  - `:context_summary` - Summary of the context that triggered this
  """
  @spec emit_preconscious_surfaced(String.t(), map(), non_neg_integer()) :: :ok
  def emit_preconscious_surfaced(agent_id, anticipation, memory_count) do
    emit_memory_signal(agent_id, :preconscious_surfaced, %{
      memory_count: memory_count,
      query_used: anticipation.query_used,
      relevance_score: anticipation.relevance_score,
      context_summary: anticipation.context_summary,
      surfaced_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Delegated: Lifecycle Signals (Goals, Intents, Percepts, Episodic, Bridge)
  # ============================================================================

  defdelegate emit_goal_created(agent_id, goal), to: __MODULE__.Lifecycle
  defdelegate emit_goal_progress(agent_id, goal_id, progress), to: __MODULE__.Lifecycle
  defdelegate emit_goal_achieved(agent_id, goal_id), to: __MODULE__.Lifecycle
  defdelegate emit_goal_abandoned(agent_id, goal_id, reason), to: __MODULE__.Lifecycle
  defdelegate emit_intent_formed(agent_id, intent), to: __MODULE__.Lifecycle
  defdelegate emit_percept_received(agent_id, percept), to: __MODULE__.Lifecycle
  defdelegate emit_thinking_recorded(agent_id, text), to: __MODULE__.Lifecycle
  defdelegate emit_knowledge_archived(agent_id, node_data, reason), to: __MODULE__.Lifecycle
  defdelegate emit_episode_archived(agent_id, episode), to: __MODULE__.Lifecycle
  defdelegate emit_lesson_extracted(agent_id, lesson, details), to: __MODULE__.Lifecycle
  defdelegate emit_memory_promoted(agent_id, node_id, details), to: __MODULE__.Lifecycle
  defdelegate emit_memory_demoted(agent_id, node_id, details), to: __MODULE__.Lifecycle
  defdelegate emit_memory_corrected(agent_id, node_id, details), to: __MODULE__.Lifecycle
  defdelegate emit_bridge_interrupt(agent_id, target_id, reason), to: __MODULE__.Lifecycle
  defdelegate emit_bridge_interrupt_cleared(agent_id, target_id), to: __MODULE__.Lifecycle

  # ============================================================================
  # Query Functions
  # ============================================================================

  @doc """
  Query archived episodes for an agent.

  Returns episode signals filtered by agent and optional criteria.

  ## Options

  - `:limit` - Maximum episodes to return (default: 20)
  - `:outcome` - Filter by outcome (`:success`, `:failure`, `:neutral`)
  - `:search` - Text search in episode descriptions
  - `:since` - Only episodes after this DateTime
  """
  @spec query_episodes(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_episodes(agent_id, opts \\ []) do
    if signals_available?() do
      limit = Keyword.get(opts, :limit, 20)
      outcome_filter = Keyword.get(opts, :outcome)
      search_text = Keyword.get(opts, :search)

      filters = [category: :memory, type: :episode_archived, source: memory_source(agent_id), limit: limit * 2]
      filters = if since = Keyword.get(opts, :since), do: [{:since, since} | filters], else: filters

      with {:ok, signals} <- Arbor.Signals.query(filters) do
        episodes =
          signals
          |> Enum.map(& &1.data)
          |> Enum.filter(&episode_matches?(&1, outcome_filter, search_text))
          |> Enum.take(limit)

        {:ok, episodes}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Query archived knowledge nodes for an agent.

  Returns knowledge nodes that were archived from the graph due to decay.

  ## Options

  - `:limit` - Maximum nodes to return (default: 20)
  - `:node_type` - Filter by node type (e.g., "person", "concept")
  - `:search` - Text search in node content
  - `:since` - Only nodes archived after this DateTime
  """
  @spec query_archived_knowledge(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_archived_knowledge(agent_id, opts \\ []) do
    if signals_available?() do
      limit = Keyword.get(opts, :limit, 20)
      node_type_filter = Keyword.get(opts, :node_type)
      search_text = Keyword.get(opts, :search)

      filters = [category: :memory, type: :knowledge_archived, source: memory_source(agent_id), limit: limit * 2]
      filters = if since = Keyword.get(opts, :since), do: [{:since, since} | filters], else: filters

      with {:ok, signals} <- Arbor.Signals.query(filters) do
        nodes =
          signals
          |> Enum.map(& &1.data)
          |> Enum.filter(&knowledge_node_matches?(&1, node_type_filter, search_text))
          |> Enum.take(limit)

        {:ok, nodes}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Query the most recent memory signal of a specific type for an agent.

  Returns the data map of the most recent signal, or `{:error, :not_found}`.

  ## Examples

      {:ok, identity} = Signals.latest_memory("agent_001", :identity)
      {:error, :not_found} = Signals.latest_memory("agent_001", :decision)
  """
  @spec latest_memory(String.t(), atom()) :: {:ok, map()} | {:error, :not_found | term()}
  def latest_memory(agent_id, memory_type) do
    case query_recent(agent_id, types: [memory_type], limit: 1) do
      {:ok, [signal | _]} -> {:ok, signal.data}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  List all known memory signal types.

  Useful for introspection, validation, and documentation.
  """
  @spec memory_signal_types() :: [atom()]
  def memory_signal_types do
    [
      # Operational
      :indexed, :recalled, :consolidation_started, :consolidation_completed,
      :fact_extracted, :learning_extracted, :knowledge_added, :knowledge_linked,
      :knowledge_decayed, :knowledge_pruned, :knowledge_archived,
      :pending_approved, :pending_rejected, :initialized, :cleaned_up,
      # Working Memory
      :working_memory_loaded, :working_memory_saved, :thought_recorded,
      :facts_extracted, :context_summarized,
      # Lifecycle
      :agent_stopped, :heartbeat,
      # Background / Proposals
      :background_checks_started, :background_checks_completed,
      :pattern_detected, :insight_detected,
      :proposal_created, :proposal_accepted, :proposal_rejected, :proposal_deferred,
      :cognitive_adjustment,
      # Relationships
      :relationship_created, :relationship_updated, :moment_added, :relationship_accessed,
      # Preconscious
      :preconscious_check, :preconscious_surfaced,
      # Reflection
      :reflection_started, :reflection_completed, :reflection_insight,
      :reflection_learning, :reflection_goal_update, :reflection_goal_created,
      :reflection_knowledge_graph, :reflection_knowledge_decay, :reflection_llm_call,
      # Goals
      :goal_created, :goal_progress, :goal_achieved, :goal_abandoned,
      # Thinking
      :thinking_recorded,
      # Identity / Insight lifecycle
      :identity, :identity_change, :identity_rollback,
      :self_insight_created, :self_insight_reinforced,
      :insight_promoted, :insight_deferred, :insight_blocked,
      # Episodic
      :episode_archived, :lesson_extracted,
      # Memory operations
      :memory_promoted, :memory_demoted, :memory_corrected,
      # Decision
      :decision,
      # Bridge
      :bridge_interrupt, :bridge_interrupt_cleared,
      # WorkingMemory state
      :engagement_changed, :concern_added, :concern_resolved,
      :curiosity_added, :curiosity_satisfied,
      :conversation_changed, :relationship_changed,
      # Chat history
      :chat_message_added
    ]
  end

  # ============================================================================
  # Shared Helpers (used by sub-modules)
  # ============================================================================

  @doc false
  @spec emit_memory_signal(String.t(), atom(), map()) :: :ok
  def emit_memory_signal(agent_id, type, data) do
    Arbor.Signals.emit(:memory, type, Map.put(data, :agent_id, agent_id),
      source: memory_source(agent_id))
  end

  @doc false
  def memory_source(agent_id), do: "arbor://memory/#{agent_id}"

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp episode_matches?(ep, outcome_filter, search_text) do
    outcome_ok = outcome_filter == nil || ep[:outcome] == outcome_filter
    search_ok = text_matches?(ep[:description], search_text)
    outcome_ok && search_ok
  end

  defp knowledge_node_matches?(node, node_type_filter, search_text) do
    type_ok = node_type_filter == nil || node[:node_type] == node_type_filter
    search_ok = text_matches?(node[:content_preview], search_text)
    type_ok && search_ok
  end

  defp text_matches?(_field, nil), do: true

  defp text_matches?(field, search_text) do
    String.contains?(
      String.downcase(to_string(field || "")),
      String.downcase(search_text)
    )
  end

  defp signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      function_exported?(Arbor.Signals, :healthy?, 0) and
      Arbor.Signals.healthy?()
  rescue
    _ -> false
  end
end
