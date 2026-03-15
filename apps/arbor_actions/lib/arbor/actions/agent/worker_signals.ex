defmodule Arbor.Actions.Agent.WorkerSignals do
  @moduledoc """
  Structured progress signals for spawned workers.

  Emits signals with a parent correlation ID so the parent agent
  and dashboard can track worker progress in real-time.

  ## Signal Types

  - `worker.spawned` — worker created with scoped capabilities
  - `worker.started` — worker query began
  - `worker.tool_call` — worker used a tool (name, duration)
  - `worker.completed` — worker finished (result summary, cost)
  - `worker.failed` — worker errored or timed out
  - `worker.destroyed` — worker cleaned up

  ## Subscribing

  Parent agents receive these via the signal bus:

      Arbor.Signals.subscribe("worker", filter: %{parent_id: my_agent_id})
  """

  @signals_mod Arbor.Signals

  @doc "Emit a worker lifecycle signal (durable — persisted to Historian)."
  def emit(type, data) do
    if Code.ensure_loaded?(@signals_mod) and function_exported?(@signals_mod, :durable_emit, 3) do
      apply(@signals_mod, :durable_emit, [:worker, type, data])
    else
      if Code.ensure_loaded?(@signals_mod) do
        apply(@signals_mod, :emit, [:worker, type, data])
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Worker was created with scoped capabilities."
  def spawned(parent_id, worker_id, capabilities, tools) do
    emit(:spawned, %{
      parent_id: parent_id,
      worker_id: worker_id,
      capabilities: capabilities,
      tools: tools,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc "Worker query started."
  def started(parent_id, worker_id, task) do
    emit(:started, %{
      parent_id: parent_id,
      worker_id: worker_id,
      task: String.slice(task, 0..200),
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc "Worker executed a tool call."
  def tool_call(parent_id, worker_id, tool_name, duration_ms, success) do
    emit(:tool_call, %{
      parent_id: parent_id,
      worker_id: worker_id,
      tool: tool_name,
      duration_ms: duration_ms,
      success: success,
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc "Worker completed successfully."
  def completed(parent_id, worker_id, report) do
    emit(:completed, %{
      parent_id: parent_id,
      worker_id: worker_id,
      duration_ms: report.duration_ms,
      tool_calls: length(report.tool_calls),
      result_length: String.length(report.result),
      cost: get_in(report, [:usage, :cost]),
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc "Worker failed or timed out."
  def failed(parent_id, worker_id, reason) do
    emit(:failed, %{
      parent_id: parent_id,
      worker_id: worker_id,
      reason: inspect(reason),
      timestamp: System.system_time(:millisecond)
    })
  end

  @doc "Worker cleaned up."
  def destroyed(parent_id, worker_id) do
    emit(:destroyed, %{
      parent_id: parent_id,
      worker_id: worker_id,
      timestamp: System.system_time(:millisecond)
    })
  end
end
