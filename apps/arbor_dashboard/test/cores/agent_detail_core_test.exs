defmodule Arbor.Dashboard.Cores.AgentDetailCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.AgentDetailCore

  @moduletag :fast

  # ── show_executor/1 ──────────────────────────────────────────────────

  describe "show_executor/1" do
    test "returns nil when no executor" do
      assert AgentDetailCore.show_executor(nil) == nil
    end

    test "shapes a running executor with stats" do
      executor = %{
        status: :running,
        stats: %{intents_received: 42, intents_executed: 39, intents_blocked: 3}
      }

      result = AgentDetailCore.show_executor(executor)

      assert result.status == :running
      assert result.status_label == "running"
      assert result.status_color == :green
      assert result.intents_received == 42
      assert result.intents_executed == 39
      assert result.intents_blocked == 3
    end

    test "tolerates missing stats with zero defaults" do
      result = AgentDetailCore.show_executor(%{status: :paused})
      assert result.status_color == :purple
      assert result.intents_received == 0
      assert result.intents_executed == 0
      assert result.intents_blocked == 0
    end
  end

  # ── show_reasoning/1 ─────────────────────────────────────────────────

  describe "show_reasoning/1" do
    test "returns nil when no reasoning loop" do
      assert AgentDetailCore.show_reasoning(nil) == nil
    end

    test "shapes a reasoning state with mode/status/iteration" do
      reasoning = %{mode: :reflective, status: :thinking, iteration: 7}
      result = AgentDetailCore.show_reasoning(reasoning)

      assert result.mode == :reflective
      assert result.mode_label == "reflective"
      assert result.status == :thinking
      assert result.status_color == :blue
      assert result.iteration == 7
    end

    test "tolerates missing fields" do
      result = AgentDetailCore.show_reasoning(%{})
      assert result.mode_label == "—"
      assert result.status_label == "—"
      assert result.iteration == 0
    end
  end

  # ── show_goals/1 ─────────────────────────────────────────────────────

  describe "show_goals/1" do
    test "returns empty list for nil or empty input" do
      assert AgentDetailCore.show_goals(nil) == []
      assert AgentDetailCore.show_goals([]) == []
    end

    test "shapes each goal with icon, label, type, priority" do
      goals = [
        %{id: "g1", type: :achieve, description: "Ship the refactor", priority: 80, progress: 0.5},
        %{id: "g2", type: :maintain, description: "Tests stay green", priority: 100}
      ]

      result = AgentDetailCore.show_goals(goals)

      [first, second] = result
      assert first.id == "g1"
      assert first.icon == "🎯"
      assert first.label == "Ship the refactor"
      assert first.type == :achieve
      assert first.priority == 80
      assert first.progress == 0.5

      assert second.icon == "🔄"
      assert second.label == "Tests stay green"
    end

    test "falls back to type as label when description is empty" do
      result = AgentDetailCore.show_goals([%{type: :achieve}])
      assert hd(result).label == "achieve"
    end

    test "uses fallback icon for unknown goal types" do
      result = AgentDetailCore.show_goals([%{type: :weird, description: "x"}])
      assert hd(result).icon == "⭐"
    end
  end

  # ── show_thinking/1 ──────────────────────────────────────────────────

  describe "show_thinking/2" do
    test "returns empty list for nil or empty input" do
      assert AgentDetailCore.show_thinking(nil) == []
      assert AgentDetailCore.show_thinking([]) == []
    end

    test "limits to 5 most recent blocks by default" do
      blocks =
        Enum.map(1..10, fn n ->
          %{text: "thought #{n}", significant: false, created_at: ~U[2026-04-07 12:00:00Z]}
        end)

      result = AgentDetailCore.show_thinking(blocks)
      assert length(result) == 5
      assert hd(result).text == "thought 1"
    end

    test "respects custom :limit option" do
      blocks = Enum.map(1..10, fn n -> %{text: "t#{n}"} end)
      result = AgentDetailCore.show_thinking(blocks, limit: 3)
      assert length(result) == 3
    end

    test "truncates long text" do
      long_text = String.duplicate("a", 500)
      result = AgentDetailCore.show_thinking([%{text: long_text}], truncate: 50)
      assert String.length(hd(result).text) <= 53
    end

    test "shapes each block with significance + relative time" do
      blocks = [
        %{
          text: "I should refactor this",
          significant: true,
          created_at: ~U[2026-04-07 12:00:00Z]
        }
      ]

      [block] = AgentDetailCore.show_thinking(blocks)
      assert block.significant == true
      assert block.text == "I should refactor this"
      assert is_binary(block.time_relative)
    end

    test "handles nil/empty text gracefully" do
      result = AgentDetailCore.show_thinking([%{}])
      assert hd(result).text == ""
      assert hd(result).significant == false
    end
  end

  # ── show_drilldown/1 ─────────────────────────────────────────────────

  describe "show_drilldown/1" do
    test "shapes all four sections in one call" do
      detail = %{
        executor: %{status: :running, stats: %{}},
        reasoning: %{mode: :idle, status: :idle, iteration: 0},
        goals: [%{type: :achieve, description: "test"}],
        thinking: [%{text: "x"}]
      }

      result = AgentDetailCore.show_drilldown(detail)

      assert result.executor.status == :running
      assert result.reasoning.mode == :idle
      assert length(result.goals) == 1
      assert length(result.thinking) == 1
    end

    test "tolerates missing sections" do
      result = AgentDetailCore.show_drilldown(%{})
      assert result.executor == nil
      assert result.reasoning == nil
      assert result.goals == []
      assert result.thinking == []
    end
  end

  # ── Pure Helpers ─────────────────────────────────────────────────────

  describe "executor_status_color/1" do
    test "maps known statuses" do
      assert AgentDetailCore.executor_status_color(:running) == :green
      assert AgentDetailCore.executor_status_color(:paused) == :purple
      assert AgentDetailCore.executor_status_color(:stopped) == :gray
    end

    test "unknown statuses default to gray" do
      assert AgentDetailCore.executor_status_color(:weird) == :gray
      assert AgentDetailCore.executor_status_color(nil) == :gray
    end
  end

  describe "reasoning_status_color/1" do
    test "maps known statuses" do
      assert AgentDetailCore.reasoning_status_color(:thinking) == :blue
      assert AgentDetailCore.reasoning_status_color(:idle) == :gray
      assert AgentDetailCore.reasoning_status_color(:awaiting_percept) == :purple
    end
  end

  describe "goal_icon/1" do
    test "returns icon by goal type" do
      assert AgentDetailCore.goal_icon(%{type: :maintain}) == "🔄"
      assert AgentDetailCore.goal_icon(%{type: :achieve}) == "🎯"
      assert AgentDetailCore.goal_icon(%{}) == "⭐"
    end
  end

  describe "goal_label/1" do
    test "prefers description" do
      assert AgentDetailCore.goal_label(%{description: "x", type: :achieve}) == "x"
    end

    test "falls back to type when description is empty or missing" do
      assert AgentDetailCore.goal_label(%{description: "", type: :achieve}) == "achieve"
      assert AgentDetailCore.goal_label(%{type: :maintain}) == "maintain"
    end

    test "falls back to 'goal' when nothing usable" do
      assert AgentDetailCore.goal_label(%{}) == "goal"
    end
  end
end
