defmodule Arbor.Orchestrator.Handlers.SessionHandler do
  @moduledoc """
  Unified handler for Session-as-DOT nodes.

  Dispatches by `type` attribute (e.g. "session.classify", "session.llm_call").
  All external dependencies are injected via `opts[:session_adapters]` — a map
  of adapter functions. Missing or nil adapters degrade gracefully to no-op.

  ## Adapter contract

  Each adapter is a function stored by key in the `session_adapters` map:

    * `:llm_call`          — `fn messages, mode, call_opts -> {:ok, response} | {:error, reason}`
    * `:tool_dispatch`     — `fn tool_calls, agent_id -> {:ok, results} | {:error, reason}`
    * `:memory_recall`     — `fn agent_id, query -> {:ok, memories} | {:error, reason} | [memories]`
    * `:recall_goals`      — `fn agent_id -> {:ok, goals} | {:error, reason} | [goals]`
    * `:recall_intents`    — `fn agent_id -> {:ok, intents} | {:error, reason} | [intents]`
    * `:recall_beliefs`    — `fn agent_id -> {:ok, beliefs} | {:error, reason} | beliefs`
    * `:memory_update`     — `fn agent_id, turn_data -> :ok`
    * `:checkpoint`        — `fn session_id, turn_count, snapshot -> :ok`
    * `:route_actions`            — `fn actions, agent_id -> :ok`
    * `:route_intents`            — `fn agent_id -> :ok`
    * `:update_goals`             — `fn goal_updates, new_goals, agent_id -> :ok`
    * `:apply_identity_insights`  — `fn insights, agent_id -> :ok`
    * `:store_decompositions`     — `fn decompositions, agent_id -> :ok`
    * `:process_proposal_decisions` — `fn decisions, agent_id -> :ok`
    * `:consolidate`              — `fn agent_id -> :ok`
    * `:background_checks`        — `fn agent_id -> results`

  If an adapter key is missing, the handler returns success with empty
  context_updates (graceful degradation). If an adapter raises or throws,
  the handler returns a failure outcome with the error details — no silent
  degradation on security-critical paths.

  ## BDI Extensions

  Several handler types support attribute-driven dispatch for BDI cycle graphs:

    * `session.memory_recall` — reads `recall_type` node attribute:
      `"goals"` (uses `:recall_goals`), `"intents"` (`:recall_intents`),
      `"beliefs"` (`:recall_beliefs`), or default query (`:memory_recall`)

    * `session.mode_select` — reads goals, intents, and user_waiting from
      context for full BDI cognitive mode selection (conversation, consolidation,
      plan_execution, goal_pursuit, reflection)

    * `session.process_results` — also extracts `decompositions`, `new_intents`,
      and `proposal_decisions` from LLM JSON response

    * `session.route_actions` — reads `intent_source` node attribute:
      `"intent_store"` uses `:route_intents` adapter, default uses `:route_actions`
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  require Logger

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @side_effecting ~w(session.llm_call session.tool_dispatch session.memory_update
                     session.checkpoint session.route_actions session.update_goals
                     session.store_decompositions session.process_proposal_decisions
                     session.consolidate session.update_working_memory
                     session.store_identity session.execute_actions
                     session.llm_tool_followup)

  # --- Behaviour callbacks ---

  @impl true
  def execute(node, context, graph, opts) do
    type = Map.get(node.attrs, "type", "session.classify")
    adapters = Keyword.get(opts, :session_adapters, %{})
    handle_type(type, context, adapters, {node, graph, opts})
  rescue
    e ->
      Logger.warning(
        "[SessionHandler] #{Map.get(node.attrs, "type")} crashed: #{Exception.message(e)}"
      )

      fail("#{Map.get(node.attrs, "type")}: #{Exception.message(e)}")
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Private dispatch by type ---

  defp handle_type("session.classify", ctx, _adapters, _meta) do
    input = Context.get(ctx, "session.input", "")

    input_type =
      cond do
        is_binary(input) and String.starts_with?(input, "/") -> "command"
        is_map(input) and Map.has_key?(input, "tool_result") -> "tool_result"
        Context.get(ctx, "session.blocked") -> "blocked"
        true -> "query"
      end

    ok(%{"session.input_type" => input_type})
  end

  defp handle_type("session.memory_recall", ctx, adapters, meta) do
    {node, _graph, _opts} = meta
    recall_type = Map.get(node.attrs, "recall_type")
    agent_id = Context.get(ctx, "session.agent_id")

    case recall_type do
      "goals" ->
        with_adapter(adapters, :recall_goals, fn recall ->
          safe_recall("recall_goals", "session.goals", fn -> recall.(agent_id) end)
        end)

      "intents" ->
        with_adapter(adapters, :recall_intents, fn recall ->
          safe_recall("recall_intents", "session.active_intents", fn -> recall.(agent_id) end)
        end)

      "beliefs" ->
        with_adapter(adapters, :recall_beliefs, fn recall ->
          safe_recall("recall_beliefs", "session.beliefs", fn -> recall.(agent_id) end)
        end)

      _ ->
        with_adapter(adapters, :memory_recall, fn recall ->
          query = Context.get(ctx, "session.input", "")

          safe_recall("memory_recall", "session.recalled_memories", fn ->
            recall.(agent_id, query)
          end)
        end)
    end
  end

  defp handle_type("session.mode_select", ctx, _adapters, _meta) do
    goals = Context.get(ctx, "session.goals", [])
    intents = Context.get(ctx, "session.active_intents", [])
    turn = Context.get(ctx, "session.turn_count", 0)
    user_waiting = Context.get(ctx, "session.user_waiting", false)

    mode =
      cond do
        # 1. User waiting → conversation (highest priority)
        user_waiting ->
          "conversation"

        # 2. Maintenance floor → consolidation
        rem(turn, 5) == 0 and turn > 0 ->
          "consolidation"

        # 3. Goals exist but no pending intents → plan_execution (need decomposition)
        List.wrap(goals) != [] and List.wrap(intents) == [] ->
          "plan_execution"

        # 4. Goals exist (with or without intents) → goal_pursuit
        List.wrap(goals) != [] ->
          "goal_pursuit"

        # 5. Otherwise → reflection
        true ->
          "reflection"
      end

    Logger.info(
      "[SessionHandler] mode_select: goals=#{length(List.wrap(goals))}, intents=#{length(List.wrap(intents))}, turn=#{turn} → #{mode}"
    )

    ok(%{"session.cognitive_mode" => mode})
  end

  defp handle_type("session.llm_call", ctx, adapters, _meta) do
    with_adapter(adapters, :llm_call, fn llm_call ->
      messages = Context.get(ctx, "session.messages", [])
      mode = Context.get(ctx, "session.cognitive_mode", "reflection")
      agent_id = Context.get(ctx, "session.agent_id")
      is_heartbeat = Context.get(ctx, "session.is_heartbeat", false)
      call_opts = %{mode: mode, agent_id: agent_id}

      # Only inject heartbeat context for heartbeat calls, not user chat turns.
      # The heartbeat needs volatile state (goals, WM, mode instructions, response format).
      # Chat turns already have the user's message in session.messages.
      final_messages =
        if is_heartbeat do
          heartbeat_msg = build_heartbeat_context(ctx, mode)
          [%{"role" => "user", "content" => heartbeat_msg}]
        else
          inject_timestamps(messages)
        end

      try do
        result = llm_call.(final_messages, mode, call_opts)

        case result do
          {:ok, %{tool_calls: calls}} when is_list(calls) and calls != [] ->
            ok(%{"llm.response_type" => "tool_call", "llm.tool_calls" => calls})

          {:ok, %{content: content}} ->
            base_updates = %{
              "llm.response_type" => "text",
              "llm.content" => content
            }

            # Only store conversation history + tool_turn for heartbeat calls.
            # The heartbeat tool loop (llm_followup) needs the conversation
            # history to build on. Turn calls use apply_turn_result for messages.
            updates =
              if is_heartbeat do
                updated_messages =
                  final_messages ++
                    [%{"role" => "assistant", "content" => content}]

                Map.merge(base_updates, %{
                  "session.messages" => updated_messages,
                  "session.tool_turn" => 0
                })
              else
                base_updates
              end

            ok(updates)

          {:error, reason} ->
            Logger.warning("[SessionHandler] LLM call failed: #{inspect(reason)}")
            fail("llm_call: #{inspect(reason)}")

          other ->
            Logger.warning("[SessionHandler] LLM call unexpected result: #{inspect(other)}")
            fail("llm_call: unexpected result")
        end
      catch
        kind, reason ->
          Logger.warning("[SessionHandler] LLM call crashed: #{inspect({kind, reason})}")
          fail("llm_call: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.tool_dispatch", ctx, adapters, _meta) do
    with_adapter(adapters, :tool_dispatch, fn tool_dispatch ->
      tool_calls = Context.get(ctx, "llm.tool_calls", [])
      agent_id = Context.get(ctx, "session.agent_id")

      start_time = System.monotonic_time(:millisecond)

      try do
        case tool_dispatch.(tool_calls, agent_id) do
          {:ok, results} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            messages = Context.get(ctx, "session.messages", [])
            updated = messages ++ Enum.map(results, &%{"role" => "tool", "content" => &1})

            # Accumulate tool history across loop iterations
            existing_history = Context.get(ctx, "session.tool_history", [])
            round_count = Context.get(ctx, "session.tool_round_count", 0)
            now = DateTime.to_iso8601(DateTime.utc_now())

            new_entries =
              tool_calls
              |> Enum.zip(List.wrap(results))
              |> Enum.map(fn {call, result} ->
                %{
                  "name" => Map.get(call, :name) || Map.get(call, "name", "unknown"),
                  "args" => Map.get(call, :args) || Map.get(call, "args", %{}),
                  "result" => truncate_tool_result(result),
                  "duration_ms" => duration_ms,
                  "timestamp" => now
                }
              end)

            ok(%{
              "session.tool_results" => results,
              "session.messages" => updated,
              "session.tool_history" => existing_history ++ new_entries,
              "session.tool_round_count" => round_count + 1
            })

          {:error, reason} ->
            fail("tool_dispatch: #{inspect(reason)}")
        end
      catch
        kind, reason -> fail("tool_dispatch: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.memory_update", ctx, adapters, _meta) do
    with_adapter(adapters, :memory_update, fn memory_update ->
      agent_id = Context.get(ctx, "session.agent_id")
      turn_data = Context.get(ctx, "session.turn_data", %{})

      try do
        memory_update.(agent_id, turn_data)
        ok(%{})
      catch
        kind, reason -> fail("memory_update: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.checkpoint", ctx, adapters, _meta) do
    with_adapter(adapters, :checkpoint, fn checkpoint ->
      session_id = Context.get(ctx, "session.id")
      turn_count = Context.get(ctx, "session.turn_count", 0)
      snapshot = Context.snapshot(ctx)

      try do
        checkpoint.(session_id, turn_count, snapshot)
        ok(%{"session.last_checkpoint" => turn_count})
      catch
        kind, reason -> fail("checkpoint: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.format", ctx, _adapters, _meta) do
    content = Context.get(ctx, "llm.content", "")
    ok(%{"session.response" => content})
  end

  defp handle_type("session.background_checks", ctx, adapters, _meta) do
    with_adapter(adapters, :background_checks, fn bg ->
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        results = bg.(agent_id)
        ok(%{"session.background_check_results" => results})
      catch
        kind, reason -> fail("background_checks: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.process_results", ctx, _adapters, _meta) do
    raw = Context.get(ctx, "llm.content", "")

    case Jason.decode(raw) do
      {:ok, parsed} when is_map(parsed) ->
        ok(%{
          "session.actions" => validated_list(parsed, "actions", &valid_action?/1),
          "session.goal_updates" => validated_list(parsed, "goal_updates", &is_map/1),
          "session.new_goals" => validated_list(parsed, "new_goals", &is_map/1),
          "session.memory_notes" => validated_list(parsed, "memory_notes", &valid_memory_note?/1),
          "session.concerns" => validated_list(parsed, "concerns", &is_binary/1),
          "session.curiosity" => validated_list(parsed, "curiosity", &is_binary/1),
          "session.decompositions" => validated_list(parsed, "decompositions", &is_map/1),
          "session.new_intents" => validated_list(parsed, "new_intents", &is_map/1),
          "session.proposal_decisions" =>
            validated_list(parsed, "proposal_decisions", &valid_proposal_decision?/1),
          "session.identity_insights" => validated_list(parsed, "identity_insights", &is_map/1)
        })

      _ ->
        ok(%{
          "session.actions" => [],
          "session.goal_updates" => [],
          "session.new_goals" => [],
          "session.memory_notes" => [],
          "session.concerns" => [],
          "session.curiosity" => [],
          "session.decompositions" => [],
          "session.new_intents" => [],
          "session.proposal_decisions" => [],
          "session.identity_insights" => []
        })
    end
  end

  defp handle_type("session.store_decompositions", ctx, adapters, _meta) do
    with_adapter(adapters, :store_decompositions, fn store ->
      decompositions = Context.get(ctx, "session.decompositions", [])
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        store.(decompositions, agent_id)
        ok(%{"session.decompositions_stored" => true})
      catch
        kind, reason -> fail("store_decompositions: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.process_proposal_decisions", ctx, adapters, _meta) do
    with_adapter(adapters, :process_proposal_decisions, fn process ->
      decisions = Context.get(ctx, "session.proposal_decisions", [])
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        process.(decisions, agent_id)
        ok(%{"session.proposals_processed" => true})
      catch
        kind, reason -> fail("process_proposal_decisions: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.consolidate", ctx, adapters, _meta) do
    with_adapter(adapters, :consolidate, fn consolidate ->
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        result = consolidate.(agent_id)

        updates =
          case result do
            %{kg: kg, identity: identity} ->
              %{
                "session.consolidated" => true,
                "session.consolidation_kg" => format_consolidation_result(kg),
                "session.consolidation_identity" => format_consolidation_result(identity)
              }

            _ ->
              %{"session.consolidated" => true}
          end

        ok(updates)
      catch
        kind, reason -> fail("consolidate: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.update_working_memory", ctx, adapters, _meta) do
    with_adapter(adapters, :update_working_memory, fn update_wm ->
      agent_id = Context.get(ctx, "session.agent_id")
      concerns = Context.get(ctx, "session.concerns", [])
      curiosity = Context.get(ctx, "session.curiosity", [])

      try do
        update_wm.(agent_id, concerns, curiosity)
        ok(%{"session.wm_updated" => true})
      catch
        kind, reason -> fail("update_working_memory: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.route_actions", ctx, adapters, meta) do
    {node, _graph, _opts} = meta
    intent_source = Map.get(node.attrs, "intent_source")
    agent_id = Context.get(ctx, "session.agent_id")

    case intent_source do
      "intent_store" ->
        with_adapter(adapters, :route_intents, fn route ->
          try do
            route.(agent_id)
            ok(%{"session.intents_routed" => true})
          catch
            kind, reason -> fail("route_intents: #{inspect({kind, reason})}")
          end
        end)

      _ ->
        with_adapter(adapters, :route_actions, fn route ->
          actions = Context.get(ctx, "session.actions", [])

          try do
            route.(actions, agent_id)
          catch
            kind, reason -> fail("route_actions: #{inspect({kind, reason})}")
          end
        end)

        # Process identity insights (if adapter provided)
        with_adapter(adapters, :apply_identity_insights, fn apply_fn ->
          insights = Context.get(ctx, "session.identity_insights", [])

          try do
            apply_fn.(insights, agent_id)
          catch
            kind, reason -> fail("apply_identity_insights: #{inspect({kind, reason})}")
          end
        end)

        ok(%{"session.actions_routed" => true})
    end
  end

  defp handle_type("session.store_identity", ctx, adapters, _meta) do
    with_adapter(adapters, :apply_identity_insights, fn apply_fn ->
      insights = Context.get(ctx, "session.identity_insights", [])
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        apply_fn.(insights, agent_id)
        ok(%{"session.identity_stored" => true})
      catch
        kind, reason -> fail("store_identity: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.execute_actions", ctx, adapters, _meta) do
    actions = Context.get(ctx, "session.actions", [])

    if actions == [] do
      ok(%{"session.has_action_results" => "false", "session.percepts" => []})
    else
      with_adapter(adapters, :execute_actions, fn execute ->
        agent_id = Context.get(ctx, "session.agent_id")
        tool_turn = Context.get(ctx, "session.tool_turn", 0)

        try do
          case execute.(actions, agent_id) do
            {:ok, percepts} ->
              Logger.info(
                "[SessionHandler] execute_actions: #{length(actions)} actions, #{length(percepts)} percepts"
              )

              ok(%{
                "session.has_action_results" => "true",
                "session.percepts" => percepts,
                "session.tool_turn" => tool_turn + 1
              })

            {:error, reason} ->
              fail("execute_actions: #{inspect(reason)}")
          end
        catch
          kind, reason -> fail("execute_actions: #{inspect({kind, reason})}")
        end
      end)
    end
  end

  defp handle_type("session.llm_tool_followup", ctx, adapters, _meta) do
    with_adapter(adapters, :llm_call, fn llm_call ->
      percepts = Context.get(ctx, "session.percepts", [])
      messages = Context.get(ctx, "session.messages", [])
      mode = Context.get(ctx, "session.cognitive_mode", "reflection")
      agent_id = Context.get(ctx, "session.agent_id")
      call_opts = %{mode: mode, agent_id: agent_id}

      # Format percepts as a user message and append to conversation
      percept_msg = format_percepts(percepts)

      followup_messages =
        messages ++ [%{"role" => "user", "content" => percept_msg}]

      Logger.info("[SessionHandler] llm_tool_followup: sending #{length(percepts)} percepts")

      try do
        result = llm_call.(followup_messages, mode, call_opts)

        case result do
          {:ok, %{content: content}} ->
            updated_messages =
              followup_messages ++ [%{"role" => "assistant", "content" => content}]

            ok(%{
              "llm.content" => content,
              "session.messages" => updated_messages
            })

          {:error, reason} ->
            Logger.warning("[SessionHandler] llm_tool_followup failed: #{inspect(reason)}")
            fail("llm_tool_followup: #{inspect(reason)}")

          other ->
            Logger.warning("[SessionHandler] llm_tool_followup unexpected: #{inspect(other)}")
            fail("llm_tool_followup: unexpected result")
        end
      catch
        kind, reason ->
          Logger.warning("[SessionHandler] llm_tool_followup crashed: #{inspect({kind, reason})}")
          fail("llm_tool_followup: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.update_goals", ctx, adapters, _meta) do
    with_adapter(adapters, :update_goals, fn update ->
      goal_updates = Context.get(ctx, "session.goal_updates", [])
      new_goals = Context.get(ctx, "session.new_goals", [])
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        update.(goal_updates, new_goals, agent_id)
        ok(%{"session.goals_updated" => true})
      catch
        kind, reason -> fail("update_goals: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type(unknown, _ctx, _adapters, _meta) do
    fail("unknown session node type: #{unknown}")
  end

  # --- Helpers ---

  defp safe_recall(label, context_key, recall_fn) do
    try do
      case recall_fn.() do
        {:ok, data} -> ok(%{context_key => data})
        {:error, reason} -> fail("#{label}: #{inspect(reason)}")
        data when is_list(data) or is_map(data) -> ok(%{context_key => data})
        other -> ok(%{context_key => other})
      end
    catch
      kind, reason -> fail("#{label}: #{inspect({kind, reason})}")
    end
  end

  # Extracts a list from parsed JSON, filtering items that don't pass validation.
  # Returns [] if the field is missing or not a list.
  defp validated_list(parsed, key, validator) do
    case Map.get(parsed, key) do
      items when is_list(items) -> Enum.filter(items, validator)
      _ -> []
    end
  end

  defp valid_action?(%{"type" => type}) when is_binary(type), do: true
  defp valid_action?(_), do: false

  defp valid_memory_note?(note) when is_binary(note), do: true
  defp valid_memory_note?(%{"text" => text}) when is_binary(text), do: true
  defp valid_memory_note?(_), do: false

  defp valid_proposal_decision?(%{"proposal_id" => id, "decision" => d})
       when is_binary(id) and d in ["accept", "reject", "defer"],
       do: true

  defp valid_proposal_decision?(_), do: false

  defp format_consolidation_result({:ok, metrics}) when is_map(metrics), do: metrics
  defp format_consolidation_result({:ok, other}), do: %{result: inspect(other)}
  defp format_consolidation_result({:error, reason}), do: %{error: inspect(reason)}
  defp format_consolidation_result(other), do: %{result: inspect(other)}

  # Build heartbeat context from engine context values.
  # This gives the LLM the volatile state it needs: goals, working memory,
  # knowledge graph, intents, proposals, recent thinking, and response format.
  defp build_heartbeat_context(ctx, mode) do
    goals = Context.get(ctx, "session.goals", [])
    wm = Context.get(ctx, "session.working_memory", %{})
    kg = Context.get(ctx, "session.knowledge_graph", [])
    proposals = Context.get(ctx, "session.pending_proposals", [])
    intents = Context.get(ctx, "session.active_intents", [])
    thoughts = Context.get(ctx, "session.recent_thinking", [])
    turn_count = Context.get(ctx, "session.turn_count", 0)

    recent_percepts = Context.get(ctx, "session.recent_percepts", [])

    goals_section = format_goals(goals)
    wm_section = format_working_memory(wm)
    kg_section = format_knowledge_graph(kg)
    proposals_section = format_proposals(proposals)
    intents_section = format_intents(intents)
    thinking_section = format_recent_thinking(thoughts)
    percepts_section = format_recent_percepts(recent_percepts)
    mode_instructions = mode_instructions(mode)

    """
    ## Heartbeat Cycle (turn #{turn_count})

    #{mode_instructions}

    #{goals_section}

    #{intents_section}

    #{wm_section}

    #{kg_section}

    #{thinking_section}

    #{proposals_section}

    #{percepts_section}

    Respond with valid JSON containing these fields:
    - "cognitive_mode": your current mode (string)
    - "memory_notes": list of strings — observations worth remembering
    - "goal_updates": list of {id, progress, status} for existing goals
    - "new_goals": list of {description, priority} for goals you want to create
    - "actions": list of {type, params} for actions to take
    - "decompositions": list of {goal_id, intentions: [{action, description}]}
    - "concerns": list of current concerns (strings)
    - "curiosity": list of things you're curious about (strings)
    - "identity_insights": list of {category, content, confidence} self-discoveries
    - "proposal_decisions": list of {proposal_id, decision} where decision is accept/reject/defer
    """
  end

  defp format_goals([]), do: "## Goals\nNo active goals."

  defp format_goals(goals) do
    items =
      goals
      |> Enum.map_join("\n", fn goal ->
        id = goal["id"] || Map.get(goal, :id, "?")
        desc = goal["description"] || Map.get(goal, :description, "")
        progress = goal["progress"] || Map.get(goal, :progress, 0)
        "- [#{id}] #{desc} (progress: #{progress})"
      end)

    "## Goals\n#{items}"
  end

  defp format_working_memory(wm) when map_size(wm) == 0, do: ""

  defp format_working_memory(wm) do
    parts =
      wm
      |> Enum.map_join("\n", fn {k, v} -> "- #{k}: #{inspect(v)}" end)

    "## Working Memory\n#{parts}"
  end

  defp format_knowledge_graph([]), do: ""

  defp format_knowledge_graph(nodes) do
    items =
      Enum.map_join(nodes, "\n", fn node ->
        type = node["type"] || ""
        content = node["content"] || ""
        confidence = node["confidence"] || 0.5
        "- [#{type}] #{content} (confidence: #{confidence})"
      end)

    "## Knowledge Graph (top #{length(nodes)} nodes)\n#{items}"
  end

  defp format_proposals([]), do: ""

  defp format_proposals(proposals) do
    items =
      Enum.map_join(proposals, "\n", fn p ->
        id = p["id"] || ""
        type = p["type"] || ""
        content = p["content"] || ""
        "- [#{id}] (#{type}) #{content}"
      end)

    "## Pending Proposals\nReview and decide (accept/reject/defer):\n#{items}"
  end

  defp format_intents([]), do: ""

  defp format_intents(intents) do
    items =
      Enum.map_join(intents, "\n", fn i ->
        id = i["id"] || ""
        action = i["action"] || ""
        desc = i["description"] || ""
        goal_id = i["goal_id"] || ""
        status = i["status"] || ""
        "- [#{id}] #{action}: #{desc} (goal: #{goal_id}, status: #{status})"
      end)

    "## Active Intents\n#{items}"
  end

  defp format_recent_thinking([]), do: ""

  defp format_recent_thinking(thoughts) do
    items =
      Enum.map_join(thoughts, "\n", fn t ->
        text = t["text"] || ""
        marker = if t["significant"], do: " ★", else: ""
        "- #{text}#{marker}"
      end)

    "## Recent Thinking\n#{items}"
  end

  defp format_recent_percepts([]), do: ""

  defp format_recent_percepts(percepts) do
    items =
      Enum.map_join(percepts, "\n", fn p ->
        action_type =
          get_in_map(p, [:data, :action_type]) || get_in_map(p, ["data", "action_type"]) || "?"

        outcome = Map.get(p, :outcome) || Map.get(p, "outcome", "?")
        "- #{action_type}: #{outcome}"
      end)

    "## Recent Action Results (from previous heartbeats)\n#{items}"
  end

  defp mode_instructions("goal_pursuit") do
    """
    Mode: GOAL PURSUIT
    You have active goals with pending intentions. Focus on making concrete progress
    toward the highest priority goal. Choose ONE action from the "actions" array that
    advances a goal. Populate the "actions" field with at least one action — for example,
    use file_read to examine source code, or shell_execute to run diagnostics.
    Do not just think — act. Report progress via goal_updates.
    """
  end

  defp mode_instructions("plan_execution") do
    """
    Mode: PLAN EXECUTION
    Decompose your goals into concrete intentions (action steps).
    Each intention should be a single, executable action.
    If you can already identify a concrete action to take (e.g. file_read to
    examine a file), include it in the "actions" array alongside your decompositions.
    """
  end

  defp mode_instructions("consolidation") do
    """
    Mode: CONSOLIDATION
    Review and organize your memory. Decay stale entries, prune redundancies.
    Reflect on identity insights. No new actions — maintenance only.
    """
  end

  defp mode_instructions(_reflection) do
    """
    Mode: REFLECTION
    Reflect on recent activity. What have you learned? What patterns emerge?
    Generate memory notes and identity insights.
    """
  end

  defp format_percepts([]), do: "No action results."

  defp format_percepts(percepts) do
    items =
      percepts
      |> Enum.map_join("\n\n", fn p ->
        action_type =
          get_in_map(p, [:data, :action_type]) || get_in_map(p, ["data", "action_type"]) ||
            "unknown"

        outcome = Map.get(p, :outcome) || Map.get(p, "outcome", "unknown")

        case to_string(outcome) do
          "success" ->
            result = get_in_map(p, [:data, :result]) || get_in_map(p, ["data", "result"]) || ""
            result_str = truncate_for_prompt(inspect(result))
            "### Action: #{action_type}\nStatus: SUCCESS\nResult:\n```\n#{result_str}\n```"

          "blocked" ->
            reason = Map.get(p, :error) || Map.get(p, "error", "unauthorized")
            "### Action: #{action_type}\nStatus: BLOCKED\nReason: #{reason}"

          _failure ->
            error = Map.get(p, :error) || Map.get(p, "error", "unknown error")
            "### Action: #{action_type}\nStatus: FAILED\nError: #{inspect(error)}"
        end
      end)

    """
    ## Action Results

    #{items}

    Continue working toward your goal. Use the "actions" array for more actions, or return empty actions if done.
    """
  end

  defp get_in_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value when rest == [] -> value
      value when is_map(value) -> get_in_map(value, rest)
      _ -> nil
    end
  end

  defp get_in_map(_, _), do: nil

  defp truncate_for_prompt(text) when is_binary(text) and byte_size(text) > 4000 do
    String.slice(text, 0, 3997) <> "..."
  end

  defp truncate_for_prompt(text), do: text

  defp truncate_tool_result(result) when is_binary(result) and byte_size(result) > 500 do
    String.slice(result, 0, 497) <> "..."
  end

  defp truncate_tool_result(result) when is_binary(result), do: result
  defp truncate_tool_result(result), do: inspect(result, limit: 50, printable_limit: 500)

  # Inject timestamps into message content for LLM temporal awareness.
  # Prepends "[HH:MM:SS] " to content for messages that carry a timestamp field,
  # then strips the timestamp key so LLM adapters don't choke on unknown fields.
  defp inject_timestamps(messages) do
    Enum.map(messages, fn msg ->
      case msg do
        %{"timestamp" => ts, "content" => content}
        when is_binary(ts) and is_binary(content) and content != "" ->
          time_str = format_message_timestamp(ts)
          %{"role" => msg["role"], "content" => "[#{time_str}] #{content}"}

        %{"timestamp" => _} ->
          Map.delete(msg, "timestamp")

        _ ->
          msg
      end
    end)
  end

  defp format_message_timestamp(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ""
    end
  end

  defp with_adapter(adapters, key, fun) do
    case Map.get(adapters, key) do
      nil -> ok(%{})
      adapter when is_function(adapter) -> fun.(adapter)
    end
  end

  defp ok(updates), do: %Outcome{status: :success, context_updates: updates}

  defp fail(reason), do: %Outcome{status: :fail, failure_reason: reason, context_updates: %{}}

  @doc """
  Returns the idempotency class for a specific session node type.
  The handler-level `idempotency/0` returns `:side_effecting` as a
  conservative default; use this for per-node checkpoint decisions.
  """
  @spec idempotency_for(String.t()) :: Handler.idempotency_class()
  def idempotency_for(type) when type in @side_effecting, do: :side_effecting
  def idempotency_for(_type), do: :read_only
end
