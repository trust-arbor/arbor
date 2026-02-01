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

  @doc """
  Emit a signal when content is indexed.

  ## Metadata

  - `:entry_id` - The ID of the indexed entry
  - `:type` - The type of content indexed
  - `:source` - Source of the content (optional)
  """
  @spec emit_indexed(String.t(), map()) :: :ok
  def emit_indexed(agent_id, metadata) do
    Arbor.Signals.emit(:memory, :indexed, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :recalled, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :consolidation_started, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :consolidation_completed, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :fact_extracted, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :learning_extracted, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :knowledge_added, %{
      agent_id: agent_id,
      node_id: node_id,
      node_type: node_type
    })
  end

  @doc """
  Emit a signal when knowledge nodes are linked.
  """
  @spec emit_knowledge_linked(String.t(), String.t(), String.t(), atom()) :: :ok
  def emit_knowledge_linked(agent_id, source_id, target_id, relationship) do
    Arbor.Signals.emit(:memory, :knowledge_linked, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :knowledge_decayed, %{
      agent_id: agent_id,
      node_count: stats[:node_count],
      average_relevance: stats[:average_relevance]
    })
  end

  @doc """
  Emit a signal when nodes are pruned from the knowledge graph.
  """
  @spec emit_knowledge_pruned(String.t(), non_neg_integer()) :: :ok
  def emit_knowledge_pruned(agent_id, pruned_count) do
    Arbor.Signals.emit(:memory, :knowledge_pruned, %{
      agent_id: agent_id,
      pruned_count: pruned_count
    })
  end

  @doc """
  Emit a signal when a pending item is approved.
  """
  @spec emit_pending_approved(String.t(), String.t(), String.t()) :: :ok
  def emit_pending_approved(agent_id, pending_id, node_id) do
    Arbor.Signals.emit(:memory, :pending_approved, %{
      agent_id: agent_id,
      pending_id: pending_id,
      node_id: node_id
    })
  end

  @doc """
  Emit a signal when a pending item is rejected.
  """
  @spec emit_pending_rejected(String.t(), String.t()) :: :ok
  def emit_pending_rejected(agent_id, pending_id) do
    Arbor.Signals.emit(:memory, :pending_rejected, %{
      agent_id: agent_id,
      pending_id: pending_id
    })
  end

  @doc """
  Emit a signal when memory is initialized for an agent.
  """
  @spec emit_memory_initialized(String.t(), map()) :: :ok
  def emit_memory_initialized(agent_id, opts \\ %{}) do
    Arbor.Signals.emit(:memory, :initialized, %{
      agent_id: agent_id,
      index_enabled: Map.get(opts, :index_enabled, true),
      graph_enabled: Map.get(opts, :graph_enabled, true)
    })
  end

  @doc """
  Emit a signal when memory is cleaned up for an agent.
  """
  @spec emit_memory_cleaned_up(String.t()) :: :ok
  def emit_memory_cleaned_up(agent_id) do
    Arbor.Signals.emit(:memory, :cleaned_up, %{
      agent_id: agent_id
    })
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
    Arbor.Signals.emit(:memory, :working_memory_loaded, %{
      agent_id: agent_id,
      status: status,
      loaded_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when working memory is saved for an agent.
  """
  @spec emit_working_memory_saved(String.t(), map()) :: :ok
  def emit_working_memory_saved(agent_id, stats) do
    Arbor.Signals.emit(:memory, :working_memory_saved, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :thought_recorded, %{
      agent_id: agent_id,
      thought_preview: String.slice(thought_preview, 0, 100),
      recorded_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when facts are extracted from text.
  """
  @spec emit_facts_extracted(String.t(), map()) :: :ok
  def emit_facts_extracted(agent_id, extraction_info) do
    Arbor.Signals.emit(:memory, :facts_extracted, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :context_summarized, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :agent_stopped, %{
      agent_id: agent_id,
      stopped_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a heartbeat signal for an agent (lifecycle event).
  """
  @spec emit_heartbeat(String.t()) :: :ok
  def emit_heartbeat(agent_id) do
    Arbor.Signals.emit(:memory, :heartbeat, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :background_checks_started, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :background_checks_completed, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :pattern_detected, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :insight_detected, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :proposal_created, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :proposal_accepted, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :proposal_rejected, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :proposal_deferred, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :cognitive_adjustment, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :relationship_created, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :relationship_updated, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :moment_added, %{
      agent_id: agent_id,
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
    Arbor.Signals.emit(:memory, :relationship_accessed, %{
      agent_id: agent_id,
      relationship_id: relationship_id,
      accessed_at: DateTime.utc_now()
    })
  end
end
