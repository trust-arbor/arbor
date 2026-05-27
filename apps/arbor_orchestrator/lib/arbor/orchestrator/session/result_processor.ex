defmodule Arbor.Orchestrator.Session.ResultProcessor do
  @moduledoc """
  Effectful boundary for applying turn/heartbeat results.

  Persists proposals via the Memory runtime bridge, enqueues notification percepts,
  and emits turn/heartbeat lifecycle signals.

  The **pure** proposal-generation and goal-aggregation logic lives in
  `Arbor.Orchestrator.Session.ResultProcessor.Core` — this module calls that core to
  construct proposals and then performs the side effects (create + notify + emit).
  """

  alias Arbor.Contracts.Session.HeartbeatResult
  alias Arbor.Orchestrator.Session.ContextBuilder

  @doc false
  def create_proposals(agent_id, proposals) do
    proposal_module = Arbor.Memory.Proposal

    if Code.ensure_loaded?(proposal_module) and
         function_exported?(proposal_module, :create, 3) do
      Enum.count(proposals, fn prop ->
        case apply(proposal_module, :create, [
               agent_id,
               prop.type,
               %{
                 content: prop.content,
                 source: "heartbeat",
                 metadata: prop.metadata,
                 confidence: 0.7
               }
             ]) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)
    else
      0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc false
  def emit_notification_percept(agent_id, count, proposals) do
    by_type = Enum.group_by(proposals, & &1.type)

    summary_parts =
      Enum.map(by_type, fn {type, items} ->
        "#{length(items)} #{type}"
      end)

    summary = "#{count} proposals waiting: #{Enum.join(summary_parts, ", ")}"

    # Enqueue notification to ActionCycleServer via runtime bridge
    action_cycle_sup = Arbor.Agent.ActionCycleSupervisor

    if Code.ensure_loaded?(action_cycle_sup) do
      case apply(action_cycle_sup, :lookup, [agent_id]) do
        {:ok, pid} ->
          send(
            pid,
            {:percept,
             %{
               type: :notification,
               summary: summary,
               proposal_count: count,
               by_type: Map.new(by_type, fn {k, v} -> {k, length(v)} end)
             }}
          )

        :error ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Signal emission (runtime bridge) ──────────────────────────────

  @doc false
  def emit_turn_signal(state, %{context: result_ctx}) do
    tool_calls = Map.get(result_ctx, "session.tool_calls", [])
    response = Map.get(result_ctx, "session.response", "")

    emit_signal(
      :agent,
      :query_completed,
      %{
        id: state.agent_id,
        agent_id: state.agent_id,
        session_id: state.session_id,
        type: :session,
        model: Map.get(result_ctx, "llm.model", "unknown"),
        tool_calls_count: length(List.wrap(tool_calls)),
        response_length: String.length(response),
        turn_count: ContextBuilder.get_turn_count(state)
      },
      state.tenant_context
    )
  end

  def emit_turn_signal(_state, _result), do: :ok

  @doc false
  def emit_heartbeat_signal(state, %{context: _ctx} = result) do
    hr = HeartbeatResult.from_result_ctx(state, result)

    emit_signal(
      :agent,
      :heartbeat_complete,
      HeartbeatResult.to_signal_data(hr),
      state.tenant_context
    )
  end

  def emit_heartbeat_signal(_state, _result), do: :ok

  @doc false
  def emit_signal(category, event, data, tenant_context \\ nil) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) and
         Process.whereis(Arbor.Signals.Bus) != nil do
      agent_id = data[:agent_id]
      meta = if agent_id, do: %{agent_id: agent_id}, else: %{}

      # Merge tenant context into signal metadata when present
      meta = merge_tenant_metadata(meta, tenant_context)

      apply(Arbor.Signals, :emit, [category, event, data, [metadata: meta]])
    end
  rescue
    _ -> :ok
  end

  @doc false
  def merge_tenant_metadata(meta, nil), do: meta

  def merge_tenant_metadata(meta, tenant_context) do
    if Code.ensure_loaded?(Arbor.Contracts.TenantContext) and
         function_exported?(Arbor.Contracts.TenantContext, :to_signal_metadata, 1) do
      Map.merge(meta, apply(Arbor.Contracts.TenantContext, :to_signal_metadata, [tenant_context]))
    else
      meta
    end
  end
end
