defmodule Arbor.Orchestrator.Session.ContextBuilder do
  @moduledoc """
  Memory loading and context assembly for turn/heartbeat pipeline values.

  Provides session state accessors (messages, turn count, working memory, goals)
  and loads fresh data from the memory store for heartbeat context enrichment.
  """

  require Logger

  # ── Session state accessors (contract-aware) ──────────────────────

  def get_messages(%{session_state: %{messages: msgs}} = _state) when is_list(msgs), do: msgs
  def get_messages(state), do: state.messages

  def get_turn_count(%{session_state: %{turn_count: tc}} = _state)
      when is_integer(tc),
      do: tc

  def get_turn_count(state), do: state.turn_count

  def get_working_memory(%{session_state: %{working_memory: wm}} = _state) when is_map(wm),
    do: wm

  def get_working_memory(state), do: state.working_memory

  def get_goals(%{session_state: %{goals: goals}} = _state) when is_list(goals), do: goals
  def get_goals(state), do: state.goals

  def get_cognitive_mode(%{session_state: %{cognitive_mode: cm}} = _state) when is_atom(cm),
    do: cm

  def get_cognitive_mode(state), do: state.cognitive_mode

  def get_phase(%{session_state: %{phase: phase}} = _state) when is_atom(phase), do: phase
  def get_phase(state), do: state.phase

  # ── Context assembly ──────────────────────────────────────────────

  @doc false
  def session_base_values(state) do
    base = %{
      "session.id" => state.session_id,
      "session.agent_id" => state.agent_id,
      "session.trust_tier" => to_string(state.trust_tier),
      "session.trust_baseline" => to_string(Map.get(state, :trust_baseline, state.trust_tier)),
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

    # Inject LLM config from session config so compute nodes can read them
    config = state.config || %{}

    base
    |> maybe_put("session.llm_provider", config["llm_provider"] || config[:llm_provider])
    |> maybe_put("session.llm_model", config["llm_model"] || config[:llm_model])
    |> maybe_put("session.system_prompt", config["system_prompt"] || config[:system_prompt])
    |> Map.put("session.tools", resolve_session_tools(state))
    |> maybe_put("session.tenant_context", state.tenant_context)
  end

  @doc false
  def resolve_session_tools(state) do
    alias Arbor.Orchestrator.Session.ToolDisclosure

    config = state.config || %{}
    trust_tier = state.trust_tier || :new
    discovered = Map.get(state, :discovered_tools, MapSet.new())

    ToolDisclosure.resolve_tools(config, trust_tier, discovered, agent_id: state.agent_id)
  end

  # Use compactor's projected view if available, otherwise all messages
  def compactor_llm_messages(%{compactor: nil} = state), do: get_messages(state)

  def compactor_llm_messages(%{compactor: compactor}) when not is_nil(compactor) do
    apply_compactor(compactor, :llm_messages, [])
  end

  # Catch-all for sessions started before compactor field existed
  def compactor_llm_messages(state), do: get_messages(state)

  # ── Memory store runtime bridge ──────────────────────────────────

  def load_goals_from_memory(agent_id) do
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

  def load_working_memory_from_memory(agent_id) do
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
  def sanitize_working_memory(%{__struct__: _} = wm) do
    wm
    |> Map.from_struct()
    |> Map.drop(@wm_internal_keys)
    |> stringify_datetimes()
  end

  def sanitize_working_memory(wm) when is_map(wm), do: wm

  def stringify_datetimes(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, items} when is_list(items) -> {k, Enum.map(items, &stringify_value/1)}
      {k, v} -> {k, v}
    end)
  end

  def stringify_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  def stringify_value(%{} = map) do
    Map.new(map, fn
      {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
      {k, v} -> {k, v}
    end)
  end

  def stringify_value(v), do: v

  def load_knowledge_graph(agent_id) do
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

  def load_pending_proposals(agent_id) do
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

  def load_active_intents(agent_id) do
    if memory_available?(:pending_intentions, 1) do
      case apply(Arbor.Memory, :pending_intentions, [agent_id]) do
        intents when is_list(intents) ->
          Enum.map(intents, fn
            {intent, status} when is_map(intent) ->
              %{
                "id" => to_string(Map.get(intent, :id, "")),
                "action" => to_string(Map.get(intent, :action, "")),
                "description" => to_string(Map.get(intent, :description, "")),
                "goal_id" => to_string(Map.get(intent, :goal_id, "")),
                "status" => to_string(Map.get(status, :status, "pending"))
              }

            intent when is_map(intent) ->
              %{
                "id" => to_string(Map.get(intent, :id, "")),
                "action" => to_string(Map.get(intent, :action, "")),
                "description" => to_string(Map.get(intent, :description, "")),
                "goal_id" => to_string(Map.get(intent, :goal_id, "")),
                "status" => to_string(Map.get(intent, :status, ""))
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

  def load_recent_thinking(agent_id) do
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

  def load_recent_percepts(agent_id) do
    if memory_available?(:recent_percepts, 1) do
      case apply(Arbor.Memory, :recent_percepts, [agent_id, [limit: 5]]) do
        percepts when is_list(percepts) ->
          Enum.map(percepts, fn p ->
            %{
              "action_type" => get_percept_action_type(p),
              "outcome" => to_string(Map.get(p, :outcome, "")),
              "data" => Map.get(p, :data, %{})
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

  def get_percept_action_type(p) do
    data = Map.get(p, :data, %{})

    Map.get(data, :action_type) ||
      Map.get(data, "action_type", "unknown")
  end

  def memory_available?(function, arity) do
    Code.ensure_loaded?(Arbor.Memory) and
      function_exported?(Arbor.Memory, function, arity)
  end

  # ── Private helpers ───────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Runtime bridge: the compactor struct carries its own module via __struct__
  defp apply_compactor(%{__struct__: module} = compactor, fun, args) do
    apply(module, fun, [compactor | args])
  end
end
