defmodule Arbor.Memory.Signals.WorkingMemory do
  @moduledoc """
  Working memory state change signal emissions.

  Handles all signals related to working memory state changes including
  engagement levels, concerns, curiosity items, conversation context,
  and relationship context changes.
  """

  @doc """
  Emit a signal when engagement level changes.
  """
  @spec emit_engagement_changed(String.t(), float()) :: :ok
  def emit_engagement_changed(agent_id, level) do
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :engagement_changed, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :concern_added, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :concern_resolved, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :curiosity_added, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :curiosity_satisfied, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :conversation_changed, %{
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
    Arbor.Memory.Signals.emit_memory_signal(agent_id, :relationship_changed, %{
      type: :relationship,
      human_name: human_name,
      context: context,
      changed_at: DateTime.utc_now()
    })
  end
end
