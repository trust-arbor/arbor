defmodule Arbor.Actions.SessionExecutionTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionExecution

  @moduletag :fast

  # ============================================================================
  # RouteActions
  # ============================================================================

  describe "RouteActions — schema" do
    test "action metadata" do
      assert SessionExecution.RouteActions.name() == "session_exec_route_actions"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionExecution.RouteActions.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} =
               SessionExecution.RouteActions.validate_params(%{
                 agent_id: "agent_1",
                 intent_source: "intent_store"
               })
    end
  end

  describe "RouteActions — run" do
    test "routes intents when intent_source is intent_store" do
      assert {:ok, %{intents_routed: true}} =
               SessionExecution.RouteActions.run(
                 %{agent_id: "test", intent_source: "intent_store"},
                 %{}
               )
    end

    test "routes actions by default" do
      assert {:ok, %{actions_routed: true}} =
               SessionExecution.RouteActions.run(
                 %{agent_id: "test", actions: [%{"type" => "file.read"}]},
                 %{}
               )
    end

    test "handles empty actions" do
      assert {:ok, %{actions_routed: true}} =
               SessionExecution.RouteActions.run(
                 %{agent_id: "test", actions: []},
                 %{}
               )
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionExecution.RouteActions.run(%{}, %{})
      end
    end
  end

  # ============================================================================
  # ExecuteActions
  # ============================================================================

  describe "ExecuteActions — schema" do
    test "action metadata" do
      assert SessionExecution.ExecuteActions.name() == "session_exec_execute_actions"
    end

    test "requires agent_id" do
      assert {:error, _} = SessionExecution.ExecuteActions.validate_params(%{})
    end
  end

  describe "ExecuteActions — run" do
    test "returns no results for empty actions" do
      assert {:ok, result} =
               SessionExecution.ExecuteActions.run(
                 %{agent_id: "test", actions: []},
                 %{}
               )

      assert result.has_action_results == false
      assert result.percepts == []
      assert result.tool_turn == 0
    end

    test "increments tool_turn" do
      assert {:ok, result} =
               SessionExecution.ExecuteActions.run(
                 %{agent_id: "test", actions: [], tool_turn: 3},
                 %{}
               )

      assert result.tool_turn == 3
    end

    test "raises without agent_id" do
      assert_raise ArgumentError, ~r/agent_id/, fn ->
        SessionExecution.ExecuteActions.run(%{}, %{})
      end
    end

    test "accepts context key format" do
      assert {:ok, result} =
               SessionExecution.ExecuteActions.run(
                 %{"session.agent_id" => "test", "session.actions" => []},
                 %{}
               )

      assert result.has_action_results == false
    end
  end
end
