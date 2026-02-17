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
    * `:route_actions`     — `fn actions, agent_id -> :ok`
    * `:route_intents`     — `fn agent_id -> :ok`
    * `:update_goals`      — `fn goal_updates, new_goals, agent_id -> :ok`
    * `:background_checks` — `fn agent_id -> results`

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
                     session.checkpoint session.route_actions session.update_goals)

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
          "session.actions" => Map.get(parsed, "actions", []),
          "session.goal_updates" => Map.get(parsed, "goal_updates", []),
          "session.new_goals" => Map.get(parsed, "new_goals", []),
          "session.memory_notes" => Map.get(parsed, "memory_notes", []),
          "session.decompositions" => Map.get(parsed, "decompositions", []),
          "session.new_intents" => Map.get(parsed, "new_intents", []),
          "session.proposal_decisions" => Map.get(parsed, "proposal_decisions", [])
        })

      _ ->
        ok(%{
          "session.actions" => [],
          "session.goal_updates" => [],
          "session.new_goals" => [],
          "session.memory_notes" => [],
          "session.decompositions" => [],
          "session.new_intents" => [],
          "session.proposal_decisions" => []
        })
    end
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
            ok(%{"session.actions_routed" => true})
          catch
            kind, reason -> fail("route_actions: #{inspect({kind, reason})}")
          end
        end)
    end
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
