defmodule Arbor.Memory.Reflection.GoalProcessorTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  # GoalProcessor delegates to GoalStore GenServer calls.
  # We test input validation and data flow through the public API.
  # Since GoalStore may not be running in isolated tests, we verify
  # that the functions handle errors gracefully.

  alias Arbor.Memory.Reflection.GoalProcessor

  describe "process_goal_updates/2" do
    test "handles empty goal updates list" do
      # Should not crash with empty list
      assert GoalProcessor.process_goal_updates("agent_1", []) == :ok
    end

    test "skips updates without goal_id" do
      updates = [%{"status" => "active", "note" => "no id"}]
      # Should not crash — nil goal_id is skipped
      assert GoalProcessor.process_goal_updates("agent_1", updates) == :ok
    end

    test "handles updates with nil goal_id" do
      updates = [%{"goal_id" => nil, "new_progress" => 0.5}]
      assert GoalProcessor.process_goal_updates("agent_1", updates) == :ok
    end

    test "does not crash on ArgumentError from invalid data" do
      # GoalStore may raise ArgumentError for invalid goal_id — rescued in process_single_goal_update
      updates = [%{"goal_id" => "nonexistent_goal", "new_progress" => 0.5}]
      # Should handle gracefully even if GoalStore is not running
      assert GoalProcessor.process_goal_updates("agent_1", updates) == :ok
    end

    test "processes multiple updates sequentially" do
      updates = [
        %{"goal_id" => "g1", "new_progress" => 0.3},
        %{"goal_id" => "g2", "status" => "achieved"},
        %{"goal_id" => "g3", "note" => "making progress"}
      ]

      # Should not crash processing multiple updates
      assert GoalProcessor.process_goal_updates("agent_1", updates) == :ok
    end
  end

  describe "process_new_goals/2" do
    test "handles empty new goals list" do
      assert GoalProcessor.process_new_goals("agent_1", []) == :ok
    end

    test "filters out goals without description" do
      goals = [
        %{"description" => nil, "priority" => "high"},
        %{"priority" => "low"}
      ]

      # Should not crash — invalid goals filtered out
      assert GoalProcessor.process_new_goals("agent_1", goals) == :ok
    end

    test "filters out goals with empty description" do
      goals = [%{"description" => "", "priority" => "medium"}]
      assert GoalProcessor.process_new_goals("agent_1", goals) == :ok
    end

    test "attempts to create goals with valid descriptions" do
      goals = [
        %{"description" => "Valid goal", "priority" => "high", "type" => "achieve"}
      ]

      # Will try GoalStore.add_goal — may fail if not running, but shouldn't crash
      GoalProcessor.process_new_goals("agent_1", goals)
    end
  end
end
