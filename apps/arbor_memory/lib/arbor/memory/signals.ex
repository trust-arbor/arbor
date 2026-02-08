defmodule Arbor.Memory.Signals do
  @moduledoc """
  Transient signal emissions for memory operations.

  Emits signals to the arbor_signals bus for operational notifications.
  These are ephemeral, pub/sub signals stored in a circular buffer —
  designed for real-time observers, dashboards, and subconscious processors.

  ## Signal Categories

  All memory signals use category `:memory` with different types:

  | Signal Type | Purpose |
  |-------------|---------|
  | `:indexed` | Content was indexed |
  | `:recalled` | Content was recalled |
  | `:consolidation_started` | Consolidation cycle began |
  | `:consolidation_completed` | Consolidation cycle ended |
  | `:fact_extracted` | Fact was extracted (pending) |
  | `:knowledge_added` | Node added to knowledge graph |
  | `:knowledge_linked` | Nodes linked in knowledge graph |
  | `:knowledge_decayed` | Decay cycle completed |
  | `:knowledge_pruned` | Nodes were pruned |
  | `:working_memory_loaded` | Working memory loaded/created (Phase 2) |
  | `:working_memory_saved` | Working memory saved (Phase 2) |
  | `:thought_recorded` | Thought added to working memory (Phase 2) |
  | `:facts_extracted` | Facts extracted from text (Phase 2) |
  | `:context_summarized` | Context was summarized (Phase 2) |
  | `:preconscious_check` | Preconscious anticipation check started (Phase 7) |
  | `:preconscious_surfaced` | Preconscious surfaced relevant memories (Phase 7) |
  | `:identity_change` | Identity traits evolved |
  | `:identity_rollback` | Identity change reverted |
  | `:self_insight_created` | Self-insight first discovered |
  | `:self_insight_reinforced` | Existing self-insight confirmed |
  | `:insight_promoted` | Pending insight promoted to active |
  | `:insight_deferred` | Insight review deferred |
  | `:insight_blocked` | Insight blocked from integration |
  | `:episode_archived` | Complete episode archived |
  | `:lesson_extracted` | Lesson extracted from episode |
  | `:memory_promoted` | Memory promoted in relevance |
  | `:memory_demoted` | Memory demoted in relevance |
  | `:memory_corrected` | Memory content corrected |
  | `:bridge_interrupt` | Interrupt sent via Bridge |
  | `:bridge_interrupt_cleared` | Interrupt cleared via Bridge |
  | `:engagement_changed` | Engagement level changed |
  | `:concern_added` | Concern added to working memory |
  | `:concern_resolved` | Concern resolved in working memory |
  | `:curiosity_added` | Curiosity item added |
  | `:curiosity_satisfied` | Curiosity item satisfied |
  | `:conversation_changed` | Conversation context changed |
  | `:relationship_changed` | Relationship context changed |
  | `:identity` | Full identity snapshot broadcast |
  | `:decision` | Important decision recorded |

  ## Examples

      # Emit an indexed signal
      :ok = Arbor.Memory.Signals.emit_indexed("agent_001", %{
        entry_id: "mem_123",
        type: :fact
      })

      # Subscribe to memory signals
      {:ok, _sub_id} = Arbor.Signals.subscribe("memory.*", fn signal ->
        IO.inspect(signal.data, label: "Memory event")
        :ok
      end)
  """

  require Logger

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

      case Arbor.Signals.recent(filters) do
        {:ok, signals} ->
          case Keyword.get(opts, :types) do
            nil -> {:ok, signals}
            types -> {:ok, Enum.filter(signals, &(&1.type in types))}
          end

        {:error, _} = error ->
          error
      end
    else
      {:ok, []}
    end
  end

  # ============================================================================
  # Emission API
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
  # Phase 4 Signals (Background Checks and Proposals)
  # ============================================================================

  @doc """
  Emit a signal when background checks start.
  """
  @spec emit_background_checks_started(String.t()) :: :ok
  def emit_background_checks_started(agent_id) do
    emit_memory_signal(agent_id, :background_checks_started, %{
      started_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when background checks complete.

  ## Result Summary

  - `:action_count` - Number of actions to take
  - `:warning_count` - Number of warnings
  - `:suggestion_count` - Number of suggestions created
  - `:duration_ms` - How long checks took
  """
  @spec emit_background_checks_completed(String.t(), map()) :: :ok
  def emit_background_checks_completed(agent_id, result_summary) do
    emit_memory_signal(agent_id, :background_checks_completed, %{
      action_count: result_summary[:action_count],
      warning_count: result_summary[:warning_count],
      suggestion_count: result_summary[:suggestion_count],
      duration_ms: result_summary[:duration_ms],
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a pattern is detected in action history.
  """
  @spec emit_pattern_detected(String.t(), map()) :: :ok
  def emit_pattern_detected(agent_id, pattern) do
    emit_memory_signal(agent_id, :pattern_detected, %{
      pattern_type: pattern[:type],
      tools: pattern[:tools],
      occurrences: pattern[:occurrences],
      confidence: pattern[:confidence],
      detected_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an insight is detected.
  """
  @spec emit_insight_detected(String.t(), map()) :: :ok
  def emit_insight_detected(agent_id, suggestion) do
    emit_memory_signal(agent_id, :insight_detected, %{
      category: suggestion[:category],
      content_preview: String.slice(suggestion[:content] || "", 0, 100),
      confidence: suggestion[:confidence],
      detected_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a proposal is created.
  """
  @spec emit_proposal_created(String.t(), struct()) :: :ok
  def emit_proposal_created(agent_id, proposal) do
    emit_memory_signal(agent_id, :proposal_created, %{
      proposal_id: proposal.id,
      type: proposal.type,
      content_preview: String.slice(proposal.content || "", 0, 100),
      confidence: proposal.confidence,
      source: proposal.source,
      created_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a proposal is accepted.
  """
  @spec emit_proposal_accepted(String.t(), String.t(), String.t()) :: :ok
  def emit_proposal_accepted(agent_id, proposal_id, node_id) do
    emit_memory_signal(agent_id, :proposal_accepted, %{
      proposal_id: proposal_id,
      node_id: node_id,
      accepted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a proposal is rejected.
  """
  @spec emit_proposal_rejected(String.t(), String.t(), atom(), String.t() | nil) :: :ok
  def emit_proposal_rejected(agent_id, proposal_id, proposal_type, reason) do
    emit_memory_signal(agent_id, :proposal_rejected, %{
      proposal_id: proposal_id,
      proposal_type: proposal_type,
      reason: reason,
      rejected_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a proposal is deferred.
  """
  @spec emit_proposal_deferred(String.t(), String.t()) :: :ok
  def emit_proposal_deferred(agent_id, proposal_id) do
    emit_memory_signal(agent_id, :proposal_deferred, %{
      proposal_id: proposal_id,
      deferred_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a cognitive adjustment signal.

  Called when background checks or external systems detect the need
  for agent behavior adjustment.

  ## Types

  - `:consolidation_needed` - Too many nodes, consider consolidating
  - `:decay_risk` - Many nodes near decay threshold
  - `:unused_pins` - Pinned memories not being accessed
  - `:pending_pileup` - Too many unreviewed proposals
  """
  @spec emit_cognitive_adjustment(String.t(), atom(), map()) :: :ok
  def emit_cognitive_adjustment(agent_id, adjustment_type, details) do
    emit_memory_signal(agent_id, :cognitive_adjustment, %{
      adjustment_type: adjustment_type,
      details: details,
      emitted_at: DateTime.utc_now()
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
  # Reflection Signals
  # ============================================================================

  @doc """
  Emit a signal when a deep reflection starts.
  """
  @spec emit_reflection_started(String.t(), map()) :: :ok
  def emit_reflection_started(agent_id, metadata) do
    emit_memory_signal(agent_id, :reflection_started, %{
      started_at: DateTime.utc_now(),
      metadata: metadata
    })
  end

  @doc """
  Emit a signal when a deep reflection completes.
  """
  @spec emit_reflection_completed(String.t(), map()) :: :ok
  def emit_reflection_completed(agent_id, metadata) do
    emit_memory_signal(agent_id, :reflection_completed, %{
      duration_ms: metadata[:duration_ms],
      insight_count: metadata[:insight_count],
      goal_updates: metadata[:goal_update_count],
      completed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an insight is discovered during reflection.
  """
  @spec emit_reflection_insight(String.t(), map()) :: :ok
  def emit_reflection_insight(agent_id, insight) do
    emit_memory_signal(agent_id, :reflection_insight, %{
      content: insight[:content],
      importance: insight[:importance],
      related_goal_id: insight[:related_goal_id],
      detected_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a learning is integrated during reflection.
  """
  @spec emit_reflection_learning(String.t(), map()) :: :ok
  def emit_reflection_learning(agent_id, learning) do
    emit_memory_signal(agent_id, :reflection_learning, %{
      content: learning[:content],
      confidence: learning[:confidence],
      category: learning[:category],
      integrated_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a goal is updated during reflection.
  """
  @spec emit_reflection_goal_update(String.t(), String.t(), map()) :: :ok
  def emit_reflection_goal_update(agent_id, goal_id, update) do
    emit_memory_signal(agent_id, :reflection_goal_update, %{
      goal_id: goal_id,
      new_progress: update["new_progress"],
      status: update["status"],
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a new goal is created during reflection.
  """
  @spec emit_reflection_goal_created(String.t(), String.t(), map()) :: :ok
  def emit_reflection_goal_created(agent_id, goal_id, data) do
    emit_memory_signal(agent_id, :reflection_goal_created, %{
      goal_id: goal_id,
      description: data["description"],
      priority: data["priority"],
      created_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when knowledge graph is updated during reflection.
  """
  @spec emit_reflection_knowledge_graph(String.t(), map()) :: :ok
  def emit_reflection_knowledge_graph(agent_id, stats) do
    emit_memory_signal(agent_id, :reflection_knowledge_graph, %{
      nodes_added: stats[:nodes_added],
      edges_added: stats[:edges_added],
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when knowledge graph decay occurs during post-reflection consolidation.
  """
  @spec emit_reflection_knowledge_decay(String.t(), map()) :: :ok
  def emit_reflection_knowledge_decay(agent_id, data) do
    emit_memory_signal(agent_id, :reflection_knowledge_decay, %{
      archived_count: data[:archived_count],
      remaining_nodes: data[:remaining_nodes],
      decayed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal for LLM call metrics during reflection.
  """
  @spec emit_reflection_llm_call(String.t(), map()) :: :ok
  def emit_reflection_llm_call(agent_id, metrics) do
    emit_memory_signal(agent_id, :reflection_llm_call, %{
      provider: metrics[:provider],
      model: metrics[:model],
      prompt_chars: metrics[:prompt_chars],
      input_tokens: metrics[:input_tokens],
      output_tokens: metrics[:output_tokens],
      duration_ms: metrics[:duration_ms],
      success: metrics[:success]
    })
  end

  # ============================================================================
  # Seed/Host Phase 3 Signals (Goals, Intents, Percepts, Thinking)
  # ============================================================================

  @doc """
  Emit a signal when a goal is created.
  """
  @spec emit_goal_created(String.t(), struct()) :: :ok
  def emit_goal_created(agent_id, goal) do
    emit_memory_signal(agent_id, :goal_created, %{
      goal_id: goal.id,
      description: goal.description,
      type: goal.type,
      priority: goal.priority,
      parent_id: goal.parent_id,
      created_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when goal progress is updated.
  """
  @spec emit_goal_progress(String.t(), String.t(), float()) :: :ok
  def emit_goal_progress(agent_id, goal_id, progress) do
    emit_memory_signal(agent_id, :goal_progress, %{
      goal_id: goal_id,
      progress: progress,
      updated_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a goal is achieved.
  """
  @spec emit_goal_achieved(String.t(), String.t()) :: :ok
  def emit_goal_achieved(agent_id, goal_id) do
    emit_memory_signal(agent_id, :goal_achieved, %{
      goal_id: goal_id,
      achieved_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a goal is abandoned.
  """
  @spec emit_goal_abandoned(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_goal_abandoned(agent_id, goal_id, reason) do
    emit_memory_signal(agent_id, :goal_abandoned, %{
      goal_id: goal_id,
      reason: reason,
      abandoned_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an intent is formed.
  """
  @spec emit_intent_formed(String.t(), struct()) :: :ok
  def emit_intent_formed(agent_id, intent) do
    # Uses :agent category (not :memory) — intentionally not using emit_memory_signal
    Arbor.Signals.emit(:agent, :intent_formed, %{
      agent_id: agent_id,
      intent_id: intent.id,
      intent_type: intent.type,
      action: intent.action,
      goal_id: intent.goal_id,
      formed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a percept is received.
  """
  @spec emit_percept_received(String.t(), struct()) :: :ok
  def emit_percept_received(agent_id, percept) do
    # Uses :agent category (not :memory) — intentionally not using emit_memory_signal
    Arbor.Signals.emit(:agent, :percept_received, %{
      agent_id: agent_id,
      percept_id: percept.id,
      percept_type: percept.type,
      intent_id: percept.intent_id,
      outcome: percept.outcome,
      duration_ms: percept.duration_ms,
      received_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a thinking block is recorded.
  """
  @spec emit_thinking_recorded(String.t(), String.t()) :: :ok
  def emit_thinking_recorded(agent_id, text) do
    emit_memory_signal(agent_id, :thinking_recorded, %{
      text_preview: String.slice(text, 0, 100),
      text_length: String.length(text),
      recorded_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit when a knowledge node is archived (removed during decay/prune).
  """
  @spec emit_knowledge_archived(String.t(), map(), term()) :: :ok
  def emit_knowledge_archived(agent_id, node_data, reason) do
    emit_memory_signal(agent_id, :knowledge_archived, %{
      node_id: node_data[:id],
      node_type: node_data[:type],
      content_preview: String.slice(node_data[:content] || "", 0, 100),
      relevance: node_data[:relevance],
      reason: reason,
      archived_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Identity Evolution Signals
  # ============================================================================

  @doc """
  Emit a signal when identity traits evolve (name, personality, etc.).
  """
  @spec emit_identity_change(String.t(), atom(), map()) :: :ok
  def emit_identity_change(agent_id, change_type, details) do
    emit_memory_signal(agent_id, :identity_change, %{
      change_type: change_type,
      details: details,
      changed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an identity change is reverted.
  """
  @spec emit_identity_rollback(String.t(), atom(), map()) :: :ok
  def emit_identity_rollback(agent_id, change_type, details) do
    emit_memory_signal(agent_id, :identity_rollback, %{
      change_type: change_type,
      details: details,
      rolled_back_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a self-insight is first discovered.
  """
  @spec emit_self_insight_created(String.t(), map()) :: :ok
  def emit_self_insight_created(agent_id, insight) do
    emit_memory_signal(agent_id, :self_insight_created, %{
      category: insight[:category],
      content_preview: String.slice(insight[:content] || "", 0, 100),
      confidence: insight[:confidence],
      created_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an existing self-insight is confirmed/reinforced.
  """
  @spec emit_self_insight_reinforced(String.t(), map()) :: :ok
  def emit_self_insight_reinforced(agent_id, insight) do
    emit_memory_signal(agent_id, :self_insight_reinforced, %{
      category: insight[:category],
      content_preview: String.slice(insight[:content] || "", 0, 100),
      new_confidence: insight[:confidence],
      reinforced_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Insight Lifecycle Signals
  # ============================================================================

  @doc """
  Emit a signal when a pending insight is promoted to active knowledge.
  """
  @spec emit_insight_promoted(String.t(), String.t(), map()) :: :ok
  def emit_insight_promoted(agent_id, insight_id, details) do
    emit_memory_signal(agent_id, :insight_promoted, %{
      insight_id: insight_id,
      content_preview: String.slice(details[:content] || "", 0, 100),
      promoted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an insight review is deferred.
  """
  @spec emit_insight_deferred(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_insight_deferred(agent_id, insight_id, reason \\ nil) do
    emit_memory_signal(agent_id, :insight_deferred, %{
      insight_id: insight_id,
      reason: reason,
      deferred_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an insight is blocked from integration.
  """
  @spec emit_insight_blocked(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_insight_blocked(agent_id, insight_id, reason \\ nil) do
    emit_memory_signal(agent_id, :insight_blocked, %{
      insight_id: insight_id,
      reason: reason,
      blocked_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Episodic Memory Signals
  # ============================================================================

  @doc """
  Emit a signal when a complete episode is archived.
  """
  @spec emit_episode_archived(String.t(), map()) :: :ok
  def emit_episode_archived(agent_id, episode) do
    emit_memory_signal(agent_id, :episode_archived, %{
      episode_id: episode[:id],
      description: episode[:description],
      outcome: episode[:outcome],
      importance: episode[:importance],
      archived_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a lesson is extracted from an episode.
  """
  @spec emit_lesson_extracted(String.t(), String.t(), map()) :: :ok
  def emit_lesson_extracted(agent_id, lesson, details) do
    emit_memory_signal(agent_id, :lesson_extracted, %{
      lesson_preview: String.slice(lesson, 0, 100),
      source_episode_id: details[:episode_id],
      importance: details[:importance],
      extracted_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Memory Operation Signals
  # ============================================================================

  @doc """
  Emit a signal when a memory is promoted in relevance or layer.
  """
  @spec emit_memory_promoted(String.t(), String.t(), map()) :: :ok
  def emit_memory_promoted(agent_id, node_id, details) do
    emit_memory_signal(agent_id, :memory_promoted, %{
      node_id: node_id,
      old_relevance: details[:old_relevance],
      new_relevance: details[:new_relevance],
      reason: details[:reason],
      promoted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a memory is demoted in relevance or layer.
  """
  @spec emit_memory_demoted(String.t(), String.t(), map()) :: :ok
  def emit_memory_demoted(agent_id, node_id, details) do
    emit_memory_signal(agent_id, :memory_demoted, %{
      node_id: node_id,
      old_relevance: details[:old_relevance],
      new_relevance: details[:new_relevance],
      reason: details[:reason],
      demoted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a memory's content is corrected.
  """
  @spec emit_memory_corrected(String.t(), String.t(), map()) :: :ok
  def emit_memory_corrected(agent_id, node_id, details) do
    emit_memory_signal(agent_id, :memory_corrected, %{
      node_id: node_id,
      field: details[:field],
      old_preview: String.slice(to_string(details[:old_value] || ""), 0, 80),
      new_preview: String.slice(to_string(details[:new_value] || ""), 0, 80),
      corrected_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Bridge Signals
  # ============================================================================

  @doc """
  Emit a signal when an interrupt is sent via Bridge.
  """
  @spec emit_bridge_interrupt(String.t(), String.t(), atom()) :: :ok
  def emit_bridge_interrupt(agent_id, target_id, reason) do
    emit_memory_signal(agent_id, :bridge_interrupt, %{
      target_id: target_id,
      reason: reason,
      interrupted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when an interrupt is cleared via Bridge.
  """
  @spec emit_bridge_interrupt_cleared(String.t(), String.t()) :: :ok
  def emit_bridge_interrupt_cleared(agent_id, target_id) do
    emit_memory_signal(agent_id, :bridge_interrupt_cleared, %{
      target_id: target_id,
      cleared_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # WorkingMemory State Change Signals
  # ============================================================================

  @doc """
  Emit a signal when engagement level changes.
  """
  @spec emit_engagement_changed(String.t(), float()) :: :ok
  def emit_engagement_changed(agent_id, level) do
    emit_memory_signal(agent_id, :engagement_changed, %{
      type: :engagement,
      level: level,
      changed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a concern is added to working memory.
  """
  @spec emit_concern_added(String.t(), String.t()) :: :ok
  def emit_concern_added(agent_id, concern) do
    emit_memory_signal(agent_id, :concern_added, %{
      type: :concern,
      concern: concern,
      action: :added,
      added_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a concern is resolved in working memory.
  """
  @spec emit_concern_resolved(String.t(), String.t()) :: :ok
  def emit_concern_resolved(agent_id, concern) do
    emit_memory_signal(agent_id, :concern_resolved, %{
      type: :concern,
      concern: concern,
      action: :resolved,
      resolved_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a curiosity item is added.
  """
  @spec emit_curiosity_added(String.t(), String.t()) :: :ok
  def emit_curiosity_added(agent_id, item) do
    emit_memory_signal(agent_id, :curiosity_added, %{
      type: :curiosity,
      item: item,
      action: :added,
      added_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a curiosity item is satisfied.
  """
  @spec emit_curiosity_satisfied(String.t(), String.t()) :: :ok
  def emit_curiosity_satisfied(agent_id, item) do
    emit_memory_signal(agent_id, :curiosity_satisfied, %{
      type: :curiosity,
      item: item,
      action: :satisfied,
      satisfied_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when the conversation context changes.
  """
  @spec emit_conversation_changed(String.t(), map() | nil) :: :ok
  def emit_conversation_changed(agent_id, conversation) do
    emit_memory_signal(agent_id, :conversation_changed, %{
      type: :conversation,
      conversation: conversation,
      changed_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when the relationship context changes in working memory.
  """
  @spec emit_relationship_changed(String.t(), String.t(), term()) :: :ok
  def emit_relationship_changed(agent_id, human_name, context) do
    emit_memory_signal(agent_id, :relationship_changed, %{
      type: :relationship,
      human_name: human_name,
      context: context,
      changed_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Identity & Decision Signals
  # ============================================================================

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
  def emit_identity(agent_id, opts \\ []) do
    emit_memory_signal(agent_id, :identity, %{
      type: :identity,
      name: Keyword.get(opts, :name),
      traits: Keyword.get(opts, :traits, %{}),
      background: Keyword.get(opts, :background),
      emitted_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a decision event signal.

  Called when the agent makes an important decision worth recording
  for audit trails and decision replay.

  ## Options

  - `:reasoning` - Why the decision was made
  - `:confidence` - Confidence level (default: 0.5)
  """
  @spec emit_decision(String.t(), String.t(), map(), keyword()) :: :ok
  def emit_decision(agent_id, description, details, opts \\ []) do
    emit_memory_signal(agent_id, :decision, %{
      type: :decision,
      description: description,
      details: details,
      reasoning: Keyword.get(opts, :reasoning),
      confidence: Keyword.get(opts, :confidence, 0.5),
      decided_at: DateTime.utc_now()
    })
  end

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

      case Arbor.Signals.query(filters) do
        {:ok, signals} ->
          episodes =
            signals
            |> Enum.map(& &1.data)
            |> Enum.filter(fn ep ->
              outcome_match = outcome_filter == nil || ep[:outcome] == outcome_filter

              search_match =
                search_text == nil ||
                  String.contains?(
                    String.downcase(to_string(ep[:description] || "")),
                    String.downcase(search_text)
                  )

              outcome_match && search_match
            end)
            |> Enum.take(limit)

          {:ok, episodes}

        {:error, _} = error ->
          error
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

      case Arbor.Signals.query(filters) do
        {:ok, signals} ->
          nodes =
            signals
            |> Enum.map(& &1.data)
            |> Enum.filter(fn node ->
              type_match = node_type_filter == nil || node[:node_type] == node_type_filter

              search_match =
                search_text == nil ||
                  String.contains?(
                    String.downcase(to_string(node[:content_preview] || "")),
                    String.downcase(search_text)
                  )

              type_match && search_match
            end)
            |> Enum.take(limit)

          {:ok, nodes}

        {:error, _} = error ->
          error
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
      :conversation_changed, :relationship_changed
    ]
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @doc false
  defp memory_source(agent_id), do: "arbor://memory/#{agent_id}"

  @doc false
  defp emit_memory_signal(agent_id, type, data) do
    Arbor.Signals.emit(:memory, type, Map.put(data, :agent_id, agent_id),
      source: memory_source(agent_id))
  end

  defp signals_available? do
    Code.ensure_loaded?(Arbor.Signals) and
      function_exported?(Arbor.Signals, :healthy?, 0) and
      Arbor.Signals.healthy?()
  rescue
    _ -> false
  end
end
