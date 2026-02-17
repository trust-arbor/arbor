defmodule Arbor.Memory.Signals.Reflection do
  @moduledoc """
  Reflection-domain signal emissions for memory operations.

  Handles all signals related to deep reflection cycles including
  insights, learnings, goal updates, knowledge graph changes,
  and LLM call metrics during reflection.
  """

  alias Arbor.Memory.Signals

  @doc """
  Emit a signal when a deep reflection starts.
  """
  @spec emit_reflection_started(String.t(), map()) :: :ok
  def emit_reflection_started(agent_id, metadata) do
    Signals.emit_memory_signal(agent_id, :reflection_started, %{
      started_at: DateTime.utc_now(),
      metadata: metadata
    })
  end

  @doc """
  Emit a signal when a deep reflection completes.
  """
  @spec emit_reflection_completed(String.t(), map()) :: :ok
  def emit_reflection_completed(agent_id, metadata) do
    Signals.emit_memory_signal(agent_id, :reflection_completed, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_insight, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_learning, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_goal_update, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_goal_created, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_knowledge_graph, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_knowledge_decay, %{
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
    Signals.emit_memory_signal(agent_id, :reflection_llm_call, %{
      provider: metrics[:provider],
      model: metrics[:model],
      prompt_chars: metrics[:prompt_chars],
      input_tokens: metrics[:input_tokens],
      output_tokens: metrics[:output_tokens],
      duration_ms: metrics[:duration_ms],
      success: metrics[:success]
    })
  end
end
