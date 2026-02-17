defmodule Arbor.Memory.Signals.Proposals do
  @moduledoc """
  Proposal and background-check signal emissions for memory operations.

  Handles all signals related to Phase 4 background checks, pattern detection,
  insight detection, proposal lifecycle (created/accepted/rejected/deferred),
  and cognitive adjustments.
  """

  alias Arbor.Memory.Signals

  @doc """
  Emit a signal when background checks start.
  """
  @spec emit_background_checks_started(String.t()) :: :ok
  def emit_background_checks_started(agent_id) do
    Signals.emit_memory_signal(agent_id, :background_checks_started, %{
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
    Signals.emit_memory_signal(agent_id, :background_checks_completed, %{
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
    Signals.emit_memory_signal(agent_id, :pattern_detected, %{
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
    Signals.emit_memory_signal(agent_id, :insight_detected, %{
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
    Signals.emit_memory_signal(agent_id, :proposal_created, %{
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
    Signals.emit_memory_signal(agent_id, :proposal_accepted, %{
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
    Signals.emit_memory_signal(agent_id, :proposal_rejected, %{
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
    Signals.emit_memory_signal(agent_id, :proposal_deferred, %{
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
    Signals.emit_memory_signal(agent_id, :cognitive_adjustment, %{
      adjustment_type: adjustment_type,
      details: details,
      emitted_at: DateTime.utc_now()
    })
  end
end
