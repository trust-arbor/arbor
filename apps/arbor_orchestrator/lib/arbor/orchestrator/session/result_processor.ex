defmodule Arbor.Orchestrator.Session.ResultProcessor do
  @moduledoc """
  Applies results from turn/heartbeat execution, generates proposals, and emits signals.

  Handles heartbeat proposal generation (cognitive mode, goals, working memory,
  decomposition, identity), proposal creation via the Memory runtime bridge,
  and signal emission for turn/heartbeat lifecycle events.
  """

  require Logger

  alias Arbor.Contracts.Session.HeartbeatResult
  alias Arbor.Orchestrator.Session.ContextBuilder

  # ── Goal changes ──────────────────────────────────────────────────

  @doc false
  def apply_goal_changes(existing_goals, updates, new_goals) do
    updated =
      Enum.map(existing_goals, fn goal ->
        case Enum.find(updates, &(Map.get(&1, "id") == Map.get(goal, "id"))) do
          nil -> goal
          update -> Map.merge(goal, update)
        end
      end)

    updated ++ List.wrap(new_goals)
  end

  # ── Heartbeat proposal generation (Phase 3) ──────────────────────

  @doc false
  def generate_heartbeat_proposals(agent_id, state, result_ctx) do
    []
    |> maybe_add_cognitive_mode_proposal(state, result_ctx)
    |> maybe_add_goal_proposals(result_ctx)
    |> maybe_add_goal_update_proposals(result_ctx)
    |> maybe_add_wm_proposals(result_ctx)
    |> maybe_add_decomposition_proposals(result_ctx)
    |> maybe_add_identity_proposals(agent_id, result_ctx)
  end

  @doc false
  def maybe_add_cognitive_mode_proposal(proposals, state, result_ctx) do
    case Map.get(result_ctx, "session.cognitive_mode") do
      mode when is_binary(mode) and mode != "" ->
        current = to_string(ContextBuilder.get_cognitive_mode(state))

        if mode != current do
          [
            %{
              type: :cognitive_mode,
              content: "Switch to #{mode} mode",
              metadata: %{from: current, to: mode}
            }
            | proposals
          ]
        else
          proposals
        end

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_goal_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.new_goals", []) do
      goals when is_list(goals) and goals != [] ->
        goal_proposals =
          goals
          |> Enum.map(fn goal ->
            desc = Map.get(goal, "description", "")
            desc = if is_binary(desc), do: String.trim(desc), else: ""
            {desc, goal}
          end)
          |> Enum.reject(fn {desc, _goal} -> desc == "" end)
          |> Enum.map(fn {desc, goal} ->
            %{
              type: :goal,
              content: desc,
              metadata: %{goal_data: goal}
            }
          end)

        goal_proposals ++ proposals

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_goal_update_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.goal_updates", []) do
      updates when is_list(updates) and updates != [] ->
        update_proposals =
          Enum.map(updates, fn update ->
            %{
              type: :goal_update,
              content: "Update goal #{Map.get(update, "id", "?")}",
              metadata: %{update_data: update}
            }
          end)

        update_proposals ++ proposals

      _ ->
        proposals
    end
  end

  # Maximum observation proposals per heartbeat to prevent volume explosion
  @max_observations_per_heartbeat 5

  # Internal monologue prefixes — these are self-instructions, not observations
  @intention_prefixes [
    "Should ",
    "Need to ",
    "Want to ",
    "Must ",
    "Have to ",
    "I should ",
    "I need to ",
    "I want to ",
    "I must ",
    "I have to "
  ]

  @doc false
  def maybe_add_wm_proposals(proposals, result_ctx) do
    thoughts = Map.get(result_ctx, "session.memory_notes", [])
    concerns = Map.get(result_ctx, "session.concerns", [])
    curiosities = Map.get(result_ctx, "session.curiosity", [])

    thought_props =
      thoughts
      |> List.wrap()
      |> Enum.map(fn t ->
        {text, metadata} = extract_note_with_metadata(t)
        %{type: :thought, content: text, metadata: metadata}
      end)
      |> Enum.reject(&internal_monologue?/1)

    concern_props =
      Enum.map(List.wrap(concerns), fn c ->
        {text, metadata} = extract_note_with_metadata(c)
        %{type: :concern, content: text, metadata: metadata}
      end)

    curiosity_props =
      Enum.map(List.wrap(curiosities), fn c ->
        {text, metadata} = extract_note_with_metadata(c)
        %{type: :curiosity, content: text, metadata: metadata}
      end)

    wm_proposals = thought_props ++ concern_props ++ curiosity_props

    # Cap total observations per heartbeat — LLM puts most important first
    capped = Enum.take(wm_proposals, @max_observations_per_heartbeat)

    capped ++ proposals
  end

  @doc false
  def internal_monologue?(%{content: text}) do
    Enum.any?(@intention_prefixes, &String.starts_with?(text, &1))
  end

  @doc false
  def extract_note_with_metadata(note) when is_binary(note), do: {note, %{}}

  def extract_note_with_metadata(%{"text" => text} = note) when is_binary(text) do
    metadata =
      case Map.get(note, "referenced_date") do
        date_str when is_binary(date_str) -> %{referenced_date: date_str}
        _ -> %{}
      end

    {text, metadata}
  end

  def extract_note_with_metadata(other), do: {inspect(other), %{}}

  @doc false
  def maybe_add_decomposition_proposals(proposals, result_ctx) do
    case Map.get(result_ctx, "session.decompositions", []) do
      decomps when is_list(decomps) and decomps != [] ->
        intent_proposals =
          Enum.map(decomps, fn d ->
            %{
              type: :intent,
              content: Map.get(d, "description", "Decomposed intent"),
              metadata: %{decomposition: d}
            }
          end)

        intent_proposals ++ proposals

      _ ->
        proposals
    end
  end

  @doc false
  def maybe_add_identity_proposals(proposals, _agent_id, result_ctx) do
    case Map.get(result_ctx, "session.identity_insights", []) do
      insights when is_list(insights) and insights != [] ->
        identity_proposals =
          Enum.map(insights, fn insight ->
            text =
              if is_binary(insight), do: insight, else: Map.get(insight, "text", inspect(insight))

            %{type: :identity, content: text, metadata: %{source: "heartbeat"}}
          end)

        identity_proposals ++ proposals

      _ ->
        proposals
    end
  end

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
    emit_signal(:agent, :heartbeat_complete, HeartbeatResult.to_signal_data(hr), state.tenant_context)
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
