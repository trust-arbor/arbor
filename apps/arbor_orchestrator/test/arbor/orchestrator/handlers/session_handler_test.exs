defmodule Arbor.Orchestrator.Handlers.SessionHandlerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.SessionHandler

  @graph %Graph{id: "test", nodes: %{}, edges: [], attrs: %{}}

  defp node(type, attrs \\ %{}), do: %Node{id: "n_#{type}", attrs: Map.put(attrs, "type", type)}

  defp run(type, context_values \\ %{}, adapters \\ %{}, attrs \\ %{}) do
    SessionHandler.execute(
      node(type, attrs),
      Context.new(context_values),
      @graph,
      session_adapters: adapters
    )
  end

  # --- classify ---

  describe "session.classify" do
    test "classifies plain text as query" do
      outcome = run("session.classify", %{"session.input" => "hello"})
      assert outcome.status == :success
      assert outcome.context_updates["session.input_type"] == "query"
    end

    test "classifies slash-prefixed as command" do
      outcome = run("session.classify", %{"session.input" => "/help"})
      assert outcome.context_updates["session.input_type"] == "command"
    end

    test "classifies tool_result map" do
      outcome = run("session.classify", %{"session.input" => %{"tool_result" => "ok"}})
      assert outcome.context_updates["session.input_type"] == "tool_result"
    end

    test "classifies blocked" do
      outcome = run("session.classify", %{"session.blocked" => true, "session.input" => "x"})
      assert outcome.context_updates["session.input_type"] == "blocked"
    end
  end

  # --- memory_recall ---

  describe "session.memory_recall" do
    test "calls adapter and sets recalled_memories" do
      adapters = %{memory_recall: fn _id, _q -> {:ok, ["mem1", "mem2"]} end}
      ctx = %{"session.agent_id" => "a1", "session.input" => "tell me"}
      outcome = run("session.memory_recall", ctx, adapters)

      assert outcome.status == :success
      assert outcome.context_updates["session.recalled_memories"] == ["mem1", "mem2"]
    end

    test "handles bare list return" do
      adapters = %{memory_recall: fn _, _ -> ["bare"] end}
      outcome = run("session.memory_recall", %{"session.agent_id" => "a1"}, adapters)

      assert outcome.context_updates["session.recalled_memories"] == ["bare"]
    end

    test "degrades gracefully when adapter missing" do
      outcome = run("session.memory_recall", %{"session.agent_id" => "a1"}, %{})
      assert outcome.status == :success
      assert outcome.context_updates == %{}
    end

    test "fails on adapter error" do
      adapters = %{memory_recall: fn _, _ -> {:error, :timeout} end}
      outcome = run("session.memory_recall", %{"session.agent_id" => "a1"}, adapters)
      assert outcome.status == :fail
    end
  end

  # --- mode_select ---

  describe "session.mode_select" do
    test "selects goal_pursuit when goals exist" do
      outcome = run("session.mode_select", %{"session.goals" => [%{id: "g1"}]})
      assert outcome.context_updates["session.cognitive_mode"] == "goal_pursuit"
    end

    test "selects consolidation every 5th turn" do
      outcome = run("session.mode_select", %{"session.turn_count" => 10, "session.goals" => []})
      assert outcome.context_updates["session.cognitive_mode"] == "consolidation"
    end

    test "selects reflection by default" do
      outcome = run("session.mode_select", %{"session.turn_count" => 1})
      assert outcome.context_updates["session.cognitive_mode"] == "reflection"
    end
  end

  # --- llm_call ---

  describe "session.llm_call" do
    test "handles text response" do
      adapters = %{llm_call: fn _, _, _ -> {:ok, %{content: "hello world"}} end}
      outcome = run("session.llm_call", %{}, adapters)

      assert outcome.context_updates["llm.response_type"] == "text"
      assert outcome.context_updates["llm.content"] == "hello world"
    end

    test "handles tool_call response" do
      calls = [%{name: "search", args: %{q: "test"}}]
      adapters = %{llm_call: fn _, _, _ -> {:ok, %{tool_calls: calls}} end}
      outcome = run("session.llm_call", %{}, adapters)

      assert outcome.context_updates["llm.response_type"] == "tool_call"
      assert outcome.context_updates["llm.tool_calls"] == calls
    end

    test "fails on error" do
      adapters = %{llm_call: fn _, _, _ -> {:error, :rate_limited} end}
      outcome = run("session.llm_call", %{}, adapters)
      assert outcome.status == :fail
    end

    test "degrades when adapter missing" do
      outcome = run("session.llm_call")
      assert outcome.status == :success
      assert outcome.context_updates == %{}
    end
  end

  # --- tool_dispatch ---

  describe "session.tool_dispatch" do
    test "dispatches tools and appends to messages" do
      adapters = %{tool_dispatch: fn _, _ -> {:ok, ["result1", "result2"]} end}

      ctx = %{
        "llm.tool_calls" => [%{name: "read"}],
        "session.agent_id" => "a1",
        "session.messages" => [%{"role" => "user", "content" => "hi"}]
      }

      outcome = run("session.tool_dispatch", ctx, adapters)
      assert outcome.status == :success
      assert outcome.context_updates["session.tool_results"] == ["result1", "result2"]
      assert length(outcome.context_updates["session.messages"]) == 3
    end

    test "fails on error" do
      adapters = %{tool_dispatch: fn _, _ -> {:error, :sandbox_denied} end}
      outcome = run("session.tool_dispatch", %{"session.agent_id" => "a1"}, adapters)
      assert outcome.status == :fail
    end
  end

  # --- memory_update ---

  describe "session.memory_update" do
    test "calls adapter with turn data" do
      test_pid = self()

      adapters = %{
        memory_update: fn id, data ->
          send(test_pid, {:updated, id, data})
          :ok
        end
      }

      ctx = %{"session.agent_id" => "a1", "session.turn_data" => %{input: "x"}}

      outcome = run("session.memory_update", ctx, adapters)
      assert outcome.status == :success
      assert_received {:updated, "a1", %{input: "x"}}
    end
  end

  # --- checkpoint ---

  describe "session.checkpoint" do
    test "calls adapter with session snapshot" do
      test_pid = self()

      adapters = %{
        checkpoint: fn sid, tc, _snap ->
          send(test_pid, {:cp, sid, tc})
          :ok
        end
      }

      ctx = %{"session.id" => "s1", "session.turn_count" => 3}

      outcome = run("session.checkpoint", ctx, adapters)
      assert outcome.status == :success
      assert_received {:cp, "s1", 3}
    end
  end

  # --- format ---

  describe "session.format" do
    test "extracts llm.content into response" do
      outcome = run("session.format", %{"llm.content" => "formatted answer"})
      assert outcome.context_updates["session.response"] == "formatted answer"
    end

    test "defaults to empty string" do
      outcome = run("session.format")
      assert outcome.context_updates["session.response"] == ""
    end
  end

  # --- process_results ---

  describe "session.process_results" do
    test "parses JSON heartbeat response" do
      json =
        Jason.encode!(%{
          "actions" => [%{"type" => "search"}],
          "goal_updates" => [%{"id" => "g1", "progress" => 0.5}],
          "new_goals" => [%{"description" => "learn"}],
          "memory_notes" => ["note1"]
        })

      outcome = run("session.process_results", %{"llm.content" => json})
      assert outcome.status == :success
      assert length(outcome.context_updates["session.actions"]) == 1
      assert length(outcome.context_updates["session.new_goals"]) == 1
    end

    test "returns empty arrays on invalid JSON" do
      outcome = run("session.process_results", %{"llm.content" => "not json"})
      assert outcome.status == :success
      assert outcome.context_updates["session.actions"] == []
    end
  end

  # --- route_actions ---

  describe "session.route_actions" do
    test "calls adapter with actions" do
      test_pid = self()
      adapters = %{route_actions: fn actions, id -> send(test_pid, {:routed, actions, id}) end}
      ctx = %{"session.actions" => [%{type: "search"}], "session.agent_id" => "a1"}

      outcome = run("session.route_actions", ctx, adapters)
      assert outcome.status == :success
      assert_received {:routed, [%{type: "search"}], "a1"}
    end
  end

  # --- update_goals ---

  describe "session.update_goals" do
    test "calls adapter with goals" do
      test_pid = self()

      adapters = %{
        update_goals: fn updates, new, id -> send(test_pid, {:goals, updates, new, id}) end
      }

      ctx = %{
        "session.goal_updates" => [%{id: "g1"}],
        "session.new_goals" => [],
        "session.agent_id" => "a1"
      }

      outcome = run("session.update_goals", ctx, adapters)
      assert outcome.status == :success
      assert_received {:goals, [%{id: "g1"}], [], "a1"}
    end
  end

  # --- background_checks ---

  describe "session.background_checks" do
    test "calls adapter" do
      test_pid = self()
      adapters = %{background_checks: fn id -> send(test_pid, {:bg, id}) end}
      outcome = run("session.background_checks", %{"session.agent_id" => "a1"}, adapters)

      assert outcome.status == :success
      assert_received {:bg, "a1"}
    end
  end

  # --- unknown type ---

  describe "unknown type" do
    test "fails with descriptive error" do
      outcome = run("session.unknown")
      assert outcome.status == :fail
      assert outcome.failure_reason =~ "unknown session node type"
    end
  end

  # --- idempotency ---

  describe "idempotency" do
    test "handler default is side_effecting" do
      assert SessionHandler.idempotency() == :side_effecting
    end

    test "per-type classification" do
      assert SessionHandler.idempotency_for("session.llm_call") == :side_effecting
      assert SessionHandler.idempotency_for("session.tool_dispatch") == :side_effecting
      assert SessionHandler.idempotency_for("session.classify") == :read_only
      assert SessionHandler.idempotency_for("session.format") == :read_only
      assert SessionHandler.idempotency_for("session.mode_select") == :read_only
    end
  end

  # --- registry integration ---

  describe "registry integration" do
    test "can register and resolve session handler" do
      alias Arbor.Orchestrator.Handlers.Registry

      Registry.register("session.classify", SessionHandler)
      node = %Node{id: "n1", attrs: %{"type" => "session.classify"}}
      assert Registry.resolve(node) == SessionHandler

      Registry.unregister("session.classify")
    end
  end
end
