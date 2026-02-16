defmodule Arbor.Memory.Signals.Lifecycle do
  @moduledoc """
  Agent lifecycle and cognition signal emissions for memory operations.

  Handles all signals related to goals (creation, progress, achievement,
  abandonment), intents, percepts, thinking blocks, episodic memory
  (episodes and lessons), and memory operations (promotion, demotion,
  correction).
  """

  # ============================================================================
  # Goal Signals
  # ============================================================================

  @doc """
  Emit a signal when a goal is created.
  """
  @spec emit_goal_created(String.t(), struct()) :: :ok
  def emit_goal_created(agent_id, goal) do
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :goal_created, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :goal_progress, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :goal_achieved, %{
      goal_id: goal_id,
      achieved_at: DateTime.utc_now()
    })
  end

  @doc """
  Emit a signal when a goal is abandoned.
  """
  @spec emit_goal_abandoned(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_goal_abandoned(agent_id, goal_id, reason) do
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :goal_abandoned, %{
      goal_id: goal_id,
      reason: reason,
      abandoned_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Intent & Percept Signals
  # ============================================================================

  @doc """
  Emit a signal when an intent is formed.
  """
  @spec emit_intent_formed(String.t(), struct()) :: :ok
  def emit_intent_formed(agent_id, intent) do
    # Uses :agent category (not :memory) -- intentionally not using emit_memory_signal
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
    # Uses :agent category (not :memory) -- intentionally not using emit_memory_signal
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :thinking_recorded, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :knowledge_archived, %{
      node_id: node_data[:id],
      node_type: node_data[:type],
      content_preview: String.slice(node_data[:content] || "", 0, 100),
      relevance: node_data[:relevance],
      reason: reason,
      archived_at: DateTime.utc_now()
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :episode_archived, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :lesson_extracted, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :memory_promoted, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :memory_demoted, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :memory_corrected, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :bridge_interrupt, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :bridge_interrupt_cleared, %{
      target_id: target_id,
      cleared_at: DateTime.utc_now()
    })
  end
end
