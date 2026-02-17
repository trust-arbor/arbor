defmodule Arbor.Memory.Signals.Identity do
  @moduledoc """
  Identity and insight lifecycle signal emissions for memory operations.

  Handles all signals related to identity evolution (changes, rollbacks),
  self-insights (creation, reinforcement), insight lifecycle
  (promotion, deferral, blocking), full identity snapshots, and decisions.
  """

  alias Arbor.Memory.Signals

  # ============================================================================
  # Identity Evolution Signals
  # ============================================================================

  @doc """
  Emit a signal when identity traits evolve (name, personality, etc.).
  """
  @spec emit_identity_change(String.t(), atom(), map()) :: :ok
  def emit_identity_change(agent_id, change_type, details) do
    Signals.emit_memory_signal(agent_id, :identity_change, %{
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
    Signals.emit_memory_signal(agent_id, :identity_rollback, %{
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
    Signals.emit_memory_signal(agent_id, :self_insight_created, %{
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
    Signals.emit_memory_signal(agent_id, :self_insight_reinforced, %{
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
    Signals.emit_memory_signal(agent_id, :insight_promoted, %{
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
    Signals.emit_memory_signal(agent_id, :insight_deferred, %{
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
    Signals.emit_memory_signal(agent_id, :insight_blocked, %{
      insight_id: insight_id,
      reason: reason,
      blocked_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Identity Snapshot & Decision Signals
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
    Signals.emit_memory_signal(agent_id, :identity, %{
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
    Signals.emit_memory_signal(agent_id, :decision, %{
      type: :decision,
      description: description,
      details: details,
      reasoning: Keyword.get(opts, :reasoning),
      confidence: Keyword.get(opts, :confidence, 0.5),
      decided_at: DateTime.utc_now()
    })
  end
end
