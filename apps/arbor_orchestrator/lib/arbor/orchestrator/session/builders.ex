defmodule Arbor.Orchestrator.Session.Builders do
  @moduledoc """
  Builder and application helpers for Session turn/heartbeat pipelines.

  Extracted from `Arbor.Orchestrator.Session` to reduce module size.
  Contains context value builders, result application, signal emission,
  checkpoint management, contract struct construction, and related utilities.
  """

  require Logger

  alias Arbor.Orchestrator.Engine

  # ── Context value builders ───────────────────────────────────────────

  @doc false
  @spec build_turn_values(Arbor.Orchestrator.Session.t(), String.t() | map()) :: map()
  def build_turn_values(state, message) do
    user_msg = %{"role" => "user", "content" => normalize_message(message)}
    messages = get_messages(state)
    messages_with_input = messages ++ [user_msg]

    base = session_base_values(state)

    Map.merge(base, %{
      "session.messages" => messages_with_input,
      "session.input" => normalize_message(message)
    })
  end

  @doc false
  @spec build_heartbeat_values(Arbor.Orchestrator.Session.t()) :: map()
  def build_heartbeat_values(state) do
    base = session_base_values(state)
    agent_id = state.agent_id

    # Load fresh data from the memory store (source of truth),
    # since the Session state may not have them (not populated at session creation).
    goals = load_goals_from_memory(agent_id) || Map.get(base, "session.goals", [])
    wm = load_working_memory_from_memory(agent_id) || Map.get(base, "session.working_memory", %{})
    knowledge_graph = load_knowledge_graph(agent_id)
    pending_proposals = load_pending_proposals(agent_id)
    active_intents = load_active_intents(agent_id)
    recent_thoughts = load_recent_thinking(agent_id)

    base
    |> Map.put("session.messages", [])
    |> Map.put("session.is_heartbeat", true)
    |> Map.put("session.goals", goals)
    |> Map.put("session.working_memory", wm)
    |> Map.put("session.knowledge_graph", knowledge_graph)
    |> Map.put("session.pending_proposals", pending_proposals)
    |> Map.put("session.active_intents", active_intents)
    |> Map.put("session.recent_thinking", recent_thoughts)
  end

  @doc false
  def session_base_values(state) do
    %{
      "session.id" => state.session_id,
      "session.agent_id" => state.agent_id,
      "session.trust_tier" => to_string(state.trust_tier),
      "session.turn_count" => get_turn_count(state),
      "session.working_memory" => get_working_memory(state),
      "session.goals" => get_goals(state),
      "session.cognitive_mode" => to_string(get_cognitive_mode(state)),
      "session.phase" => to_string(get_phase(state)),
      "session.session_type" => to_string(state.session_type),
      "session.trace_id" => state.trace_id,
      "session.config" => state.config,
      "session.signal_topic" => state.signal_topic
    }
  end

  @doc false
  def build_engine_opts(state, initial_values) do
    logs_root =
      Path.join([
        System.tmp_dir!(),
        "arbor_sessions",
        state.session_id
      ])

    [
      session_adapters: state.adapters,
      logs_root: logs_root,
      max_steps: 100,
      initial_values: initial_values,
      authorization: false
    ]
  end

  # ── Result application ───────────────────────────────────────────────

  @doc false
  @spec apply_turn_result(Arbor.Orchestrator.Session.t(), String.t() | map(), Engine.run_result()) ::
          Arbor.Orchestrator.Session.t()
  def apply_turn_result(state, message, %{context: result_ctx}) do
    response = Map.get(result_ctx, "session.response", "")

    user_msg = %{"role" => "user", "content" => normalize_message(message)}
    assistant_msg = %{"role" => "assistant", "content" => response}

    updated_messages =
      case Map.get(result_ctx, "session.messages") do
        msgs when is_list(msgs) ->
          msgs ++ [assistant_msg]

        _ ->
          get_messages(state) ++ [user_msg, assistant_msg]
      end

    updated_wm =
      case Map.get(result_ctx, "session.working_memory") do
        wm when is_map(wm) -> wm
        _ -> get_working_memory(state)
      end

    new_turn_count = get_turn_count(state) + 1

    state = %{
      state
      | messages: updated_messages,
        working_memory: updated_wm,
        turn_count: new_turn_count
    }

    update_session_state(state, fn ss ->
      ss
      |> Map.put(:messages, updated_messages)
      |> Map.put(:working_memory, updated_wm)
      |> maybe_call_increment_turn()
    end)
  end

  @doc false
  @spec apply_heartbeat_result(Arbor.Orchestrator.Session.t(), Engine.run_result()) ::
          Arbor.Orchestrator.Session.t()
  def apply_heartbeat_result(state, %{context: result_ctx}) do
    cognitive_mode =
      case Map.get(result_ctx, "session.cognitive_mode") do
        mode when is_binary(mode) and mode != "" ->
          safe_to_atom(mode, get_cognitive_mode(state))

        _ ->
          get_cognitive_mode(state)
      end

    goal_updates = Map.get(result_ctx, "session.goal_updates", [])
    new_goals = Map.get(result_ctx, "session.new_goals", [])
    current_goals = get_goals(state)
    goals = apply_goal_changes(current_goals, goal_updates, new_goals)

    state = %{state | cognitive_mode: cognitive_mode, goals: goals}

    update_session_state(state, fn ss ->
      ss
      |> Map.put(:cognitive_mode, cognitive_mode)
      |> Map.put(:goals, goals)
      |> maybe_call_touch()
    end)
  end

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

  # ── Signal emission (runtime bridge) ──────────────────────────────

  @doc false
  def emit_turn_signal(state, %{context: result_ctx}) do
    tool_calls = Map.get(result_ctx, "session.tool_calls", [])
    response = Map.get(result_ctx, "session.response", "")

    emit_signal(:agent, :query_completed, %{
      id: state.agent_id,
      agent_id: state.agent_id,
      session_id: state.session_id,
      type: :session,
      model: Map.get(result_ctx, "llm.model", "unknown"),
      tool_calls_count: length(List.wrap(tool_calls)),
      response_length: String.length(response),
      turn_count: get_turn_count(state)
    })
  end

  def emit_turn_signal(_state, _result), do: :ok

  @doc false
  def emit_heartbeat_signal(state, %{context: result_ctx}) do
    actions = Map.get(result_ctx, "session.actions", [])
    goal_updates = Map.get(result_ctx, "session.goal_updates", [])
    new_goals = Map.get(result_ctx, "session.new_goals", [])
    memory_notes = Map.get(result_ctx, "session.memory_notes", [])
    cognitive_mode = Map.get(result_ctx, "session.cognitive_mode", "reflection")
    concerns = Map.get(result_ctx, "session.concerns", [])
    curiosity = Map.get(result_ctx, "session.curiosity", [])
    identity_insights = Map.get(result_ctx, "session.identity_insights", [])
    decompositions = Map.get(result_ctx, "session.decompositions", [])
    proposal_decisions = Map.get(result_ctx, "session.proposal_decisions", [])

    emit_signal(:agent, :heartbeat_complete, %{
      agent_id: state.agent_id,
      session_id: state.session_id,
      cognitive_mode: cognitive_mode,
      llm_actions: length(List.wrap(actions)),
      goal_updates_count: length(List.wrap(goal_updates)) + length(List.wrap(new_goals)),
      memory_notes_count: length(List.wrap(memory_notes)),
      memory_notes: List.wrap(memory_notes),
      concerns: List.wrap(concerns),
      curiosity: List.wrap(curiosity),
      identity_insights: List.wrap(identity_insights),
      decompositions: List.wrap(decompositions),
      proposal_decisions: List.wrap(proposal_decisions),
      goal_updates: List.wrap(goal_updates),
      new_goals: List.wrap(new_goals),
      agent_thinking: Map.get(result_ctx, "llm.content"),
      completed_nodes: Map.get(result_ctx, "__completed_nodes__", [])
    })
  end

  def emit_heartbeat_signal(_state, _result), do: :ok

  @doc false
  def emit_signal(category, event, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) and
         Process.whereis(Arbor.Signals.Bus) != nil do
      agent_id = data[:agent_id]
      meta = if agent_id, do: %{agent_id: agent_id}, else: %{}
      apply(Arbor.Signals, :emit, [category, event, data, [metadata: meta]])
    end
  rescue
    _ -> :ok
  end

  # ── Checkpoint management ───────────────────────────────────────────

  @doc false
  def apply_checkpoint(state, checkpoint) when is_map(checkpoint) do
    state
    |> maybe_restore(:messages, Map.get(checkpoint, "session.messages"))
    |> maybe_restore(:working_memory, Map.get(checkpoint, "session.working_memory"))
    |> maybe_restore(:goals, Map.get(checkpoint, "session.goals"))
    |> maybe_restore(:turn_count, Map.get(checkpoint, "session.turn_count"))
    |> maybe_restore_cognitive_mode(Map.get(checkpoint, "session.cognitive_mode"))
    |> sync_checkpoint_to_session_state()
  end

  @doc false
  def maybe_restore(state, _field, nil), do: state
  def maybe_restore(state, field, value), do: %{state | field => value}

  @doc false
  def maybe_restore_cognitive_mode(state, nil), do: state

  def maybe_restore_cognitive_mode(state, mode) when is_atom(mode),
    do: %{state | cognitive_mode: mode}

  def maybe_restore_cognitive_mode(state, mode) when is_binary(mode),
    do: %{state | cognitive_mode: safe_to_atom(mode, state.cognitive_mode)}

  @doc false
  def sync_checkpoint_to_session_state(%{session_state: nil} = state), do: state

  def sync_checkpoint_to_session_state(state) do
    update_session_state(state, fn ss ->
      ss
      |> Map.put(:messages, state.messages)
      |> Map.put(:working_memory, state.working_memory)
      |> Map.put(:goals, state.goals)
      |> Map.put(:turn_count, state.turn_count)
      |> Map.put(:cognitive_mode, state.cognitive_mode)
    end)
  end

  # ── Trust tier verification ─────────────────────────────────────────

  @doc false
  def verify_trust_tier(declared_tier, agent_id, adapters) do
    case Map.get(adapters, :trust_tier_resolver) do
      resolver when is_function(resolver, 1) ->
        case resolver.(agent_id) do
          {:ok, verified_tier} -> verified_tier
          _ -> declared_tier
        end

      _ ->
        declared_tier
    end
  end

  # ── Contract struct helpers ─────────────────────────────────────────

  @doc false
  def contracts_available? do
    Code.ensure_loaded?(config_module()) and
      Code.ensure_loaded?(state_module()) and
      Code.ensure_loaded?(behavior_module())
  end

  @doc false
  def build_contract_structs(opts) do
    if contracts_available?() do
      session_config = build_session_config(opts)
      session_state = build_session_state(opts)
      behavior = build_behavior(opts)
      {session_config, session_state, behavior}
    else
      {nil, nil, nil}
    end
  end

  # ── DOT parsing ─────────────────────────────────────────────────────

  @doc false
  def parse_dot_file(path) do
    with {:ok, source} <- File.read(path) do
      Arbor.Orchestrator.parse(source)
    end
  end

  # ── Message normalization ───────────────────────────────────────────

  @doc false
  def normalize_message(message) when is_binary(message), do: message
  def normalize_message(%{"content" => content}), do: content
  def normalize_message(%{content: content}), do: content
  def normalize_message(message), do: inspect(message)

  @doc false
  def safe_to_atom(string, fallback) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> fallback
  end

  # ── Private helpers (contract-aware accessors) ──────────────────────
  #
  # Duplicated from parent to avoid circular module dependencies.
  # These read from session_state when available, falling back to flat fields.

  defp get_messages(%{session_state: %{messages: msgs}} = _state) when is_list(msgs), do: msgs
  defp get_messages(state), do: state.messages

  defp get_turn_count(%{session_state: %{turn_count: tc}} = _state)
       when is_integer(tc),
       do: tc

  defp get_turn_count(state), do: state.turn_count

  defp get_working_memory(%{session_state: %{working_memory: wm}} = _state) when is_map(wm),
    do: wm

  defp get_working_memory(state), do: state.working_memory

  defp get_goals(%{session_state: %{goals: goals}} = _state) when is_list(goals), do: goals
  defp get_goals(state), do: state.goals

  defp get_cognitive_mode(%{session_state: %{cognitive_mode: cm}} = _state) when is_atom(cm),
    do: cm

  defp get_cognitive_mode(state), do: state.cognitive_mode

  defp get_phase(%{session_state: %{phase: phase}} = _state) when is_atom(phase), do: phase
  defp get_phase(state), do: state.phase

  # ── Private helpers (contract-aware mutation) ───────────────────────

  defp update_session_state(%{session_state: nil} = state, _update_fn), do: state

  defp update_session_state(%{session_state: ss} = state, update_fn) when not is_nil(ss) do
    updated_ss = update_fn.(ss)
    %{state | session_state: updated_ss}
  end

  defp maybe_call_increment_turn(ss) do
    if contracts_available?() do
      apply(state_module(), :increment_turn, [ss])
    else
      %{ss | turn_count: ss.turn_count + 1}
    end
  end

  defp maybe_call_touch(ss) do
    if contracts_available?() do
      apply(state_module(), :touch, [ss])
    else
      ss
    end
  end

  # Module references via functions to avoid compile-time warnings
  defp config_module, do: Arbor.Contracts.Session.Config
  defp state_module, do: Arbor.Contracts.Session.State
  defp behavior_module, do: Arbor.Contracts.Session.Behavior

  # ── Contract struct construction helpers ─────────────────────────────

  defp build_session_config(opts) do
    case apply(config_module(), :new, [
           [
             session_id: Keyword.fetch!(opts, :session_id),
             agent_id: Keyword.fetch!(opts, :agent_id),
             trust_tier: Keyword.fetch!(opts, :trust_tier),
             session_type: Keyword.get(opts, :session_type, :primary),
             metadata: Keyword.get(opts, :config, %{})
           ]
         ]) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.warning("[Session] Failed to create Session.Config: #{inspect(reason)}, using nil")

        nil
    end
  end

  defp build_session_state(opts) do
    case apply(state_module(), :new, [[trace_id: Keyword.get(opts, :trace_id)]]) do
      {:ok, session_state} ->
        session_state

      {:error, reason} ->
        Logger.warning("[Session] Failed to create Session.State: #{inspect(reason)}, using nil")

        nil
    end
  end

  defp build_behavior(opts) do
    case Keyword.get(opts, :behavior) do
      nil ->
        case apply(behavior_module(), :default, []) do
          {:ok, behavior} -> behavior
          _ -> nil
        end

      %{__struct__: _} = behavior ->
        behavior

      _other ->
        Logger.warning("[Session] Invalid behavior option, using default")

        case apply(behavior_module(), :default, []) do
          {:ok, behavior} -> behavior
          _ -> nil
        end
    end
  end

  # ── Memory store runtime bridge ──────────────────────────────────

  defp load_goals_from_memory(agent_id) do
    if Code.ensure_loaded?(Arbor.Memory) and
         function_exported?(Arbor.Memory, :get_active_goals, 1) do
      case apply(Arbor.Memory, :get_active_goals, [agent_id]) do
        goals when is_list(goals) and goals != [] ->
          Enum.map(goals, fn goal ->
            %{
              "id" => to_string(Map.get(goal, :id, "")),
              "description" => to_string(Map.get(goal, :description, "")),
              "progress" => Map.get(goal, :progress, 0.0),
              "status" => to_string(Map.get(goal, :status, :active)),
              "priority" => Map.get(goal, :priority, 50),
              "type" => to_string(Map.get(goal, :type, :achieve))
            }
          end)

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp load_working_memory_from_memory(agent_id) do
    if memory_available?(:get_working_memory, 1) do
      case apply(Arbor.Memory, :get_working_memory, [agent_id]) do
        wm when is_map(wm) and map_size(wm) > 0 -> sanitize_working_memory(wm)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Convert WorkingMemory struct (or any map) to a plain JSON-serializable map.
  # The engine checkpoint serializes context values via Jason — structs without
  # Jason.Encoder will crash.
  @wm_internal_keys ~w(agent_id max_tokens model __struct__)a
  defp sanitize_working_memory(%{__struct__: _} = wm) do
    wm
    |> Map.from_struct()
    |> Map.drop(@wm_internal_keys)
    |> stringify_datetimes()
  end

  defp sanitize_working_memory(wm) when is_map(wm), do: wm

  defp stringify_datetimes(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, items} when is_list(items) -> {k, Enum.map(items, &stringify_value/1)}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp stringify_value(%{} = map) do
    Map.new(map, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_value(v), do: v

  defp load_knowledge_graph(agent_id) do
    if memory_available?(:export_knowledge_graph, 1) do
      case apply(Arbor.Memory, :export_knowledge_graph, [agent_id]) do
        {:ok, %{nodes: nodes}} when is_map(nodes) and map_size(nodes) > 0 ->
          nodes
          |> Enum.take(20)
          |> Enum.map(fn {_id, node} ->
            %{
              "content" => node["content"] || Map.get(node, :content, ""),
              "type" => node["type"] || to_string(Map.get(node, :type, "")),
              "confidence" => node["confidence"] || Map.get(node, :confidence, 0.5)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_pending_proposals(agent_id) do
    if memory_available?(:get_proposals, 1) do
      case apply(Arbor.Memory, :get_proposals, [agent_id]) do
        {:ok, proposals} when is_list(proposals) ->
          Enum.map(proposals, fn p ->
            %{
              "id" => to_string(Map.get(p, :id, "")),
              "type" => to_string(Map.get(p, :type, "")),
              "content" => to_string(Map.get(p, :content, Map.get(p, :description, ""))),
              "source" => to_string(Map.get(p, :source, ""))
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_active_intents(agent_id) do
    if memory_available?(:pending_intentions, 1) do
      case apply(Arbor.Memory, :pending_intentions, [agent_id]) do
        intents when is_list(intents) ->
          Enum.map(intents, fn i ->
            %{
              "id" => to_string(Map.get(i, :id, "")),
              "action" => to_string(Map.get(i, :action, "")),
              "description" => to_string(Map.get(i, :description, "")),
              "goal_id" => to_string(Map.get(i, :goal_id, "")),
              "status" => to_string(Map.get(i, :status, ""))
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp load_recent_thinking(agent_id) do
    if memory_available?(:recent_thinking, 1) do
      case apply(Arbor.Memory, :recent_thinking, [agent_id]) do
        thoughts when is_list(thoughts) ->
          thoughts
          |> Enum.take(5)
          |> Enum.map(fn t ->
            %{
              "text" => to_string(Map.get(t, :text, "")),
              "significant" => Map.get(t, :significant, false)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp memory_available?(function, arity) do
    Code.ensure_loaded?(Arbor.Memory) and
      function_exported?(Arbor.Memory, function, arity)
  end
end
