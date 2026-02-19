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

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @side_effecting ~w(session.llm_call session.tool_dispatch session.memory_update
                     session.checkpoint session.route_actions session.update_goals
                     session.store_decompositions session.process_proposal_decisions
                     session.consolidate session.update_working_memory
                     session.store_identity)

  # --- Behaviour callbacks ---

  @impl true
  def execute(node, context, graph, opts) do
    type = Map.get(node.attrs, "type", "session.classify")
    adapters = Keyword.get(opts, :session_adapters, %{})
    handle_type(type, context, adapters, {node, graph, opts})
  rescue
    e -> fail("#{Map.get(node.attrs, "type")}: #{Exception.message(e)}")
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
          try do
            case recall.(agent_id) do
              {:ok, goals} -> ok(%{"session.goals" => goals})
              {:error, reason} -> fail("recall_goals: #{inspect(reason)}")
              goals when is_list(goals) -> ok(%{"session.goals" => goals})
              other -> ok(%{"session.goals" => other})
            end
          catch
            kind, reason -> fail("recall_goals: #{inspect({kind, reason})}")
          end
        end)

      "intents" ->
        with_adapter(adapters, :recall_intents, fn recall ->
          try do
            case recall.(agent_id) do
              {:ok, intents} -> ok(%{"session.intents" => intents})
              {:error, reason} -> fail("recall_intents: #{inspect(reason)}")
              intents when is_list(intents) -> ok(%{"session.intents" => intents})
              other -> ok(%{"session.intents" => other})
            end
          catch
            kind, reason -> fail("recall_intents: #{inspect({kind, reason})}")
          end
        end)

      "beliefs" ->
        with_adapter(adapters, :recall_beliefs, fn recall ->
          try do
            case recall.(agent_id) do
              {:ok, beliefs} -> ok(%{"session.beliefs" => beliefs})
              {:error, reason} -> fail("recall_beliefs: #{inspect(reason)}")
              beliefs when is_map(beliefs) -> ok(%{"session.beliefs" => beliefs})
              other -> ok(%{"session.beliefs" => other})
            end
          catch
            kind, reason -> fail("recall_beliefs: #{inspect({kind, reason})}")
          end
        end)

      _ ->
        # default behavior - existing memory_recall
        with_adapter(adapters, :memory_recall, fn recall ->
          query = Context.get(ctx, "session.input", "")

          try do
            case recall.(agent_id, query) do
              {:ok, memories} -> ok(%{"session.recalled_memories" => memories})
              {:error, reason} -> fail("memory_recall: #{inspect(reason)}")
              memories when is_list(memories) -> ok(%{"session.recalled_memories" => memories})
              other -> ok(%{"session.recalled_memories" => other})
            end
          catch
            kind, reason -> fail("memory_recall: #{inspect({kind, reason})}")
          end
        end)
    end
  end

  defp handle_type("session.mode_select", ctx, _adapters, _meta) do
    goals = Context.get(ctx, "session.goals", [])
    intents = Context.get(ctx, "session.intents", [])
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

    ok(%{"session.cognitive_mode" => mode})
  end

  defp handle_type("session.llm_call", ctx, adapters, _meta) do
    with_adapter(adapters, :llm_call, fn llm_call ->
      messages = Context.get(ctx, "session.messages", [])
      mode = Context.get(ctx, "session.cognitive_mode", "reflection")
      call_opts = %{mode: mode, agent_id: Context.get(ctx, "session.agent_id")}

      try do
        case llm_call.(messages, mode, call_opts) do
          {:ok, %{tool_calls: calls}} when is_list(calls) and calls != [] ->
            ok(%{"llm.response_type" => "tool_call", "llm.tool_calls" => calls})

          {:ok, %{content: content}} ->
            ok(%{"llm.response_type" => "text", "llm.content" => content})

          {:error, reason} ->
            fail("llm_call: #{inspect(reason)}")
        end
      catch
        kind, reason -> fail("llm_call: #{inspect({kind, reason})}")
      end
    end)
  end

  defp handle_type("session.tool_dispatch", ctx, adapters, _meta) do
    with_adapter(adapters, :tool_dispatch, fn tool_dispatch ->
      tool_calls = Context.get(ctx, "llm.tool_calls", [])
      agent_id = Context.get(ctx, "session.agent_id")

      try do
        case tool_dispatch.(tool_calls, agent_id) do
          {:ok, results} ->
            messages = Context.get(ctx, "session.messages", [])
            updated = messages ++ Enum.map(results, &%{"role" => "tool", "content" => &1})
            ok(%{"session.tool_results" => results, "session.messages" => updated})

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
          "session.memory_notes" => validated_list(parsed, "memory_notes", &is_binary/1),
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

  defp valid_proposal_decision?(%{"proposal_id" => id, "decision" => d})
       when is_binary(id) and d in ["accept", "reject", "defer"],
       do: true

  defp valid_proposal_decision?(_), do: false

  defp format_consolidation_result({:ok, metrics}) when is_map(metrics), do: metrics
  defp format_consolidation_result({:ok, other}), do: %{result: inspect(other)}
  defp format_consolidation_result({:error, reason}), do: %{error: inspect(reason)}
  defp format_consolidation_result(other), do: %{result: inspect(other)}

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
