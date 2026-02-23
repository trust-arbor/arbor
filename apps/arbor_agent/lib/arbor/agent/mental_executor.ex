defmodule Arbor.Agent.MentalExecutor do
  @moduledoc """
  Executes store-backed mental capabilities directly, no Host routing.

  Pattern-matches on mental handler atoms from `Capabilities.resolve/2`
  and dispatches to GoalStore, IntentStore, ExecSession, Memory, etc.

  All mental actions return `{:ok, result}` or `{:error, reason}` for
  uniform handling by `PerceptFormatter.from_mental_result/2`.

  ## Handler Atoms

  - `:goal_add` / `:goal_update` / `:goal_list` / `:goal_assess`
  - `:plan_add` / `:plan_list` / `:plan_update` / `:plan_assess`
  - `:proposal_list` / `:proposal_accept` / `:proposal_reject` / `:proposal_defer`
  - `:compute_run`
  - `:think_reflect` / `:think_observe` / `:think_describe` / `:think_introspect`
  """

  alias Arbor.Agent.PerceptFormatter
  alias Arbor.Contracts.Memory.Intent

  require Logger

  @type agent_id :: String.t()
  @type handler :: atom()
  @type params :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @max_compute_timeout 30_000

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Execute a mental action and return a formatted Percept.

  Takes an intent with capability/op/target fields and dispatches to the
  appropriate store. Returns a Percept suitable for Mind context.
  """
  @spec execute(Intent.t(), agent_id()) :: {:ok, map()}
  def execute(%Intent{} = intent, agent_id) when is_binary(agent_id) do
    handler = mental_handler(intent)
    params = intent.params || %{}

    result = execute_handler(handler, agent_id, params)
    percept = PerceptFormatter.from_mental_result(intent, result)
    {:ok, percept}
  end

  @doc """
  Execute a mental handler atom directly with params.

  Lower-level API for when you have a handler atom and params
  but not a full Intent struct.
  """
  @spec execute_handler(handler(), agent_id(), params()) :: result()

  # ── Goal Handlers ───────────────────────────────────────────────────

  def execute_handler(:goal_add, agent_id, params) do
    description = Map.get(params, :description) || Map.get(params, "description", "")
    priority = Map.get(params, :priority) || Map.get(params, "priority")
    parent_id = Map.get(params, :parent_id) || Map.get(params, "parent_id")

    opts =
      []
      |> maybe_add(:priority, priority)
      |> maybe_add(:parent_id, parent_id)

    with_memory_bridge(:add_goal, [agent_id, description | opts_to_args(opts)])
  end

  def execute_handler(:goal_update, agent_id, params) do
    goal_id = Map.get(params, :goal_id) || Map.get(params, "goal_id")
    progress = Map.get(params, :progress) || Map.get(params, "progress")
    metadata = Map.get(params, :metadata) || Map.get(params, "metadata")
    note = Map.get(params, :note) || Map.get(params, "note")

    cond do
      is_nil(goal_id) ->
        {:error, :missing_goal_id}

      not is_nil(progress) ->
        with_memory_bridge(:update_goal_progress, [agent_id, goal_id, progress])

      not is_nil(metadata) ->
        with_memory_bridge(:update_goal_metadata, [agent_id, goal_id, metadata])

      not is_nil(note) ->
        with_memory_bridge(:add_goal_note, [agent_id, goal_id, note])

      true ->
        {:error, :no_update_specified}
    end
  end

  def execute_handler(:goal_list, agent_id, params) do
    filter = Map.get(params, :filter) || Map.get(params, "filter", "active")

    result =
      case filter do
        f when f in ["active", :active] ->
          with_memory_bridge(:get_active_goals, [agent_id])

        f when f in ["all", :all] ->
          with_memory_bridge(:get_all_goals, [agent_id])

        _ ->
          with_memory_bridge(:get_active_goals, [agent_id])
      end

    case result do
      {:ok, goals} ->
        {:ok, %{goals: summarize_goals(goals), count: length(goals)}}

      error ->
        error
    end
  end

  def execute_handler(:goal_assess, agent_id, params) do
    goal_id = Map.get(params, :goal_id) || Map.get(params, "goal_id")

    if is_nil(goal_id) do
      # Assess all active goals
      case with_memory_bridge(:get_active_goals, [agent_id]) do
        {:ok, goals} ->
          assessments =
            Enum.map(goals, fn goal ->
              %{
                id: goal_id(goal),
                description: goal_description(goal),
                progress: goal_progress(goal),
                status: goal_status(goal),
                has_pending_intents: has_pending_intents?(agent_id, goal)
              }
            end)

          {:ok, %{assessments: assessments, count: length(assessments)}}

        error ->
          error
      end
    else
      case with_memory_bridge(:get_goal, [agent_id, goal_id]) do
        {:ok, goal} ->
          {:ok,
           %{
             id: goal_id(goal),
             description: goal_description(goal),
             progress: goal_progress(goal),
             status: goal_status(goal),
             has_pending_intents: has_pending_intents?(agent_id, goal),
             tree: get_goal_tree(agent_id, goal_id)
           }}

        error ->
          error
      end
    end
  end

  # ── Plan Handlers (IntentStore) ─────────────────────────────────────

  def execute_handler(:plan_add, agent_id, params) do
    description = Map.get(params, :description) || Map.get(params, "description", "")
    goal_id = Map.get(params, :goal_id) || Map.get(params, "goal_id")
    urgency = Map.get(params, :urgency) || Map.get(params, "urgency", 5)

    intent =
      Intent.capability_intent("plan", :add, description,
        reasoning: Map.get(params, :reasoning) || Map.get(params, "reasoning"),
        params: %{goal_id: goal_id, urgency: urgency}
      )

    with_memory_bridge(:record_intent, [agent_id, intent])
  end

  def execute_handler(:plan_list, agent_id, params) do
    limit = Map.get(params, :limit) || Map.get(params, "limit", 20)

    case with_memory_bridge(:recent_intents, [agent_id, [limit: limit]]) do
      {:ok, intents} ->
        {:ok, %{intents: summarize_intents(intents), count: length(intents)}}

      error ->
        error
    end
  end

  def execute_handler(:plan_update, agent_id, params) do
    intent_id = Map.get(params, :intent_id) || Map.get(params, "intent_id")
    action = Map.get(params, :action) || Map.get(params, "action", "complete")

    if is_nil(intent_id) do
      {:error, :missing_intent_id}
    else
      case action do
        a when a in ["complete", :complete] ->
          with_memory_bridge(:complete_intent, [agent_id, intent_id])

        a when a in ["fail", :fail] ->
          reason = Map.get(params, :reason) || Map.get(params, "reason", "failed")
          with_memory_bridge(:fail_intent, [agent_id, intent_id, reason])

        a when a in ["lock", :lock] ->
          with_memory_bridge(:lock_intent, [agent_id, intent_id])

        _ ->
          {:error, {:unknown_action, action}}
      end
    end
  end

  def execute_handler(:plan_assess, agent_id, params) do
    goal_id = Map.get(params, :goal_id) || Map.get(params, "goal_id")

    if goal_id do
      case with_memory_bridge(:pending_intents_for_goal, [agent_id, goal_id]) do
        {:ok, intents} ->
          {:ok,
           %{
             goal_id: goal_id,
             pending_count: length(intents),
             intents: summarize_intents(intents)
           }}

        error ->
          error
      end
    else
      case with_memory_bridge(:pending_intentions, [agent_id, []]) do
        {:ok, pending} ->
          items =
            Enum.map(pending, fn
              {intent, status} -> %{intent: summarize_intent(intent), status: status}
              intent -> %{intent: summarize_intent(intent)}
            end)

          {:ok, %{pending: items, count: length(items)}}

        error ->
          error
      end
    end
  end

  # ── Proposal Handlers ──────────────────────────────────────────────

  def execute_handler(:proposal_list, agent_id, params) do
    type = Map.get(params, :type) || Map.get(params, "type")
    limit = Map.get(params, :limit) || Map.get(params, "limit")

    opts =
      []
      |> maybe_add(:type, safe_atom(type))
      |> maybe_add(:limit, limit)

    case with_memory_bridge(:get_proposals, [agent_id, opts]) do
      {:ok, proposals} ->
        {:ok, %{proposals: summarize_proposals(proposals), count: length(proposals)}}

      error ->
        error
    end
  end

  def execute_handler(:proposal_accept, agent_id, params) do
    proposal_id = Map.get(params, :proposal_id) || Map.get(params, "proposal_id")

    if is_nil(proposal_id) do
      {:error, :missing_proposal_id}
    else
      with_proposal_bridge(:accept, [agent_id, proposal_id])
    end
  end

  def execute_handler(:proposal_reject, agent_id, params) do
    proposal_id = Map.get(params, :proposal_id) || Map.get(params, "proposal_id")

    if is_nil(proposal_id) do
      {:error, :missing_proposal_id}
    else
      reason = Map.get(params, :reason) || Map.get(params, "reason")
      opts = if reason, do: [reason: reason], else: []
      with_proposal_bridge(:reject, [agent_id, proposal_id, opts])
    end
  end

  def execute_handler(:proposal_defer, agent_id, params) do
    proposal_id = Map.get(params, :proposal_id) || Map.get(params, "proposal_id")

    if is_nil(proposal_id) do
      {:error, :missing_proposal_id}
    else
      with_memory_bridge(:defer_proposal, [agent_id, proposal_id])
    end
  end

  # ── Compute Handler (ExecSession) ──────────────────────────────────

  def execute_handler(:compute_run, agent_id, params) do
    code = Map.get(params, :code) || Map.get(params, "code", "")
    timeout = Map.get(params, :timeout) || Map.get(params, "timeout", 10_000)
    timeout = min(timeout, @max_compute_timeout)

    if code == "" do
      {:error, :empty_code}
    else
      with_exec_session(agent_id, code, timeout: timeout)
    end
  end

  # ── Think Handlers ─────────────────────────────────────────────────

  def execute_handler(:think_reflect, agent_id, params) do
    topic = Map.get(params, :topic) || Map.get(params, "topic")

    # Gather recent context for reflection
    recent_thoughts = get_recent_thinking(agent_id, 5)
    active_goals = get_active_goals_summary(agent_id)

    {:ok,
     %{
       type: :reflection,
       topic: topic,
       recent_thoughts: recent_thoughts,
       active_goals: active_goals,
       prompt: "Reflect on #{topic || "recent activity"}. What patterns do you notice?"
     }}
  end

  def execute_handler(:think_observe, agent_id, params) do
    focus = Map.get(params, :focus) || Map.get(params, "focus", "environment")

    # Aggregate observable state
    wm = get_working_memory_summary(agent_id)
    goals = get_active_goals_summary(agent_id)

    {:ok,
     %{
       type: :observation,
       focus: focus,
       working_memory: wm,
       goals: goals,
       prompt: "Observe the current state. Focus: #{focus}."
     }}
  end

  def execute_handler(:think_describe, agent_id, params) do
    aspect = Map.get(params, :aspect) || Map.get(params, "aspect", "all")

    aspect_atom =
      case aspect do
        a when is_atom(a) -> a
        s when is_binary(s) -> safe_atom(s) || :all
      end

    case with_introspection(:read_self, [agent_id, aspect_atom]) do
      {:ok, data} ->
        {:ok, %{type: :description, aspect: aspect_atom, data: data}}

      error ->
        error
    end
  end

  def execute_handler(:think_introspect, agent_id, _params) do
    # Deep self-examination: gather all self-knowledge
    case with_introspection(:read_self, [agent_id, :all]) do
      {:ok, data} ->
        recent_thoughts = get_recent_thinking(agent_id, 10)

        {:ok,
         %{
           type: :introspection,
           self_knowledge: data,
           recent_thoughts: recent_thoughts,
           prompt: "Examine your own reasoning patterns. What do you notice about yourself?"
         }}

      error ->
        error
    end
  end

  # Catch-all for unknown handlers
  def execute_handler(handler, _agent_id, _params) do
    {:error, {:unknown_handler, handler}}
  end

  # ── Private Helpers ────────────────────────────────────────────────

  defp mental_handler(%Intent{capability: cap, op: op})
       when is_binary(cap) and is_atom(op) do
    # Construct handler atom from capability + op (e.g., "think" + :reflect -> :think_reflect)
    handler_name = "#{cap}_#{op}"

    try do
      String.to_existing_atom(handler_name)
    rescue
      ArgumentError -> op
    end
  end

  defp mental_handler(%Intent{op: op}) when is_atom(op) do
    op
  end

  # ── Runtime Bridge to Arbor.Memory ─────────────────────────────────

  defp with_memory_bridge(function, args) do
    if Code.ensure_loaded?(Arbor.Memory) do
      try do
        apply(Arbor.Memory, function, args)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:memory_unavailable, reason}}
      end
    else
      {:error, :memory_not_available}
    end
  end

  defp with_proposal_bridge(function, args) do
    if Code.ensure_loaded?(Arbor.Memory.Proposal) do
      try do
        apply(Arbor.Memory.Proposal, function, args)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:proposal_unavailable, reason}}
      end
    else
      {:error, :proposal_not_available}
    end
  end

  defp with_introspection(function, args) do
    if Code.ensure_loaded?(Arbor.Memory.Introspection) do
      try do
        apply(Arbor.Memory.Introspection, function, args)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:introspection_unavailable, reason}}
      end
    else
      {:error, :introspection_not_available}
    end
  end

  defp with_exec_session(agent_id, code, opts) do
    if Code.ensure_loaded?(Arbor.Sandbox.ExecSupervisor) do
      try do
        case apply(Arbor.Sandbox.ExecSupervisor, :get_or_start_session, [agent_id, []]) do
          {:ok, pid} ->
            apply(Arbor.Sandbox.ExecSession, :eval, [pid, code, opts])

          {:error, reason} ->
            {:error, {:session_start_failed, reason}}
        end
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, {:sandbox_unavailable, reason}}
      end
    else
      {:error, :sandbox_not_available}
    end
  end

  # ── Goal Helpers ───────────────────────────────────────────────────

  defp summarize_goals(goals) when is_list(goals) do
    Enum.map(goals, fn goal ->
      %{
        id: goal_id(goal),
        description: goal_description(goal),
        progress: goal_progress(goal),
        status: goal_status(goal)
      }
    end)
  end

  defp goal_id(goal) when is_map(goal) do
    Map.get(goal, :id) || Map.get(goal, "id")
  end

  defp goal_description(goal) when is_map(goal) do
    Map.get(goal, :description) || Map.get(goal, "description", "")
  end

  defp goal_progress(goal) when is_map(goal) do
    Map.get(goal, :progress) || Map.get(goal, "progress", 0.0)
  end

  defp goal_status(goal) when is_map(goal) do
    Map.get(goal, :status) || Map.get(goal, "status", :active)
  end

  defp has_pending_intents?(agent_id, goal) do
    gid = goal_id(goal)

    case with_memory_bridge(:pending_intents_for_goal, [agent_id, gid]) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp get_goal_tree(agent_id, goal_id) do
    case with_memory_bridge(:get_goal_tree, [agent_id, goal_id]) do
      {:ok, tree} -> tree
      _ -> nil
    end
  end

  # ── Intent Helpers ─────────────────────────────────────────────────

  defp summarize_intents(intents) when is_list(intents) do
    Enum.map(intents, &summarize_intent/1)
  end

  defp summarize_intent(%Intent{} = intent) do
    %{
      id: intent.id,
      type: intent.type,
      capability: intent.capability,
      op: intent.op,
      target: intent.target,
      reasoning: intent.reasoning
    }
  end

  defp summarize_intent(intent) when is_map(intent) do
    %{
      id: Map.get(intent, :id) || Map.get(intent, "id"),
      type: Map.get(intent, :type) || Map.get(intent, "type"),
      capability: Map.get(intent, :capability) || Map.get(intent, "capability"),
      op: Map.get(intent, :op) || Map.get(intent, "op"),
      target: Map.get(intent, :target) || Map.get(intent, "target")
    }
  end

  # ── Proposal Helpers ───────────────────────────────────────────────

  defp summarize_proposals(proposals) when is_list(proposals) do
    Enum.map(proposals, fn p ->
      %{
        id: Map.get(p, :id) || Map.get(p, "id"),
        type: Map.get(p, :type) || Map.get(p, "type"),
        status: Map.get(p, :status) || Map.get(p, "status"),
        data: truncate_proposal_data(Map.get(p, :data) || Map.get(p, "data"))
      }
    end)
  end

  defp truncate_proposal_data(nil), do: nil

  defp truncate_proposal_data(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      {k, if(is_binary(v) and byte_size(v) > 500, do: String.slice(v, 0, 500) <> "...", else: v)}
    end)
  end

  defp truncate_proposal_data(data), do: data

  # ── Think Helpers ──────────────────────────────────────────────────

  defp get_recent_thinking(agent_id, limit) do
    if Code.ensure_loaded?(Arbor.Memory.Thinking) do
      try do
        case apply(Arbor.Memory.Thinking, :recent, [agent_id, limit]) do
          {:ok, thoughts} -> thoughts
          _ -> []
        end
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end
    else
      []
    end
  end

  defp get_active_goals_summary(agent_id) do
    case with_memory_bridge(:get_active_goals, [agent_id]) do
      {:ok, goals} -> summarize_goals(goals)
      _ -> []
    end
  end

  defp get_working_memory_summary(agent_id) do
    case with_memory_bridge(:get_working_memory, [agent_id]) do
      {:ok, wm} when is_map(wm) ->
        %{
          thoughts: Map.get(wm, :thoughts, []) |> length(),
          goals: Map.get(wm, :goals, []) |> length(),
          concerns: Map.get(wm, :concerns, []) |> length(),
          curiosities: Map.get(wm, :curiosities, []) |> length(),
          engagement: Map.get(wm, :engagement_level, 0.0)
        }

      _ ->
        %{thoughts: 0, goals: 0, concerns: 0, curiosities: 0, engagement: 0.0}
    end
  end

  # ── Utility ────────────────────────────────────────────────────────

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: [{key, value} | opts]

  defp opts_to_args([]), do: []
  defp opts_to_args(opts), do: [opts]

  defp safe_atom(nil), do: nil

  defp safe_atom(value) when is_atom(value), do: value

  defp safe_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
