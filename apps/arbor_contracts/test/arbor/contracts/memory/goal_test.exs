defmodule Arbor.Contracts.Memory.GoalTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Memory.Goal

  describe "new/2" do
    test "creates a goal with required fields" do
      goal = Goal.new("Fix the bug")

      assert goal.description == "Fix the bug"
      assert goal.type == :achieve
      assert goal.status == :active
      assert goal.priority == 50
      assert goal.progress == 0.0
      assert String.starts_with?(goal.id, "goal_")
      assert %DateTime{} = goal.created_at
    end

    test "accepts optional fields" do
      goal =
        Goal.new("Learn Elixir",
          type: :learn,
          priority: 80,
          parent_id: "goal_parent",
          metadata: %{tags: ["education"]}
        )

      assert goal.type == :learn
      assert goal.priority == 80
      assert goal.parent_id == "goal_parent"
      assert goal.metadata == %{tags: ["education"]}
    end

    test "accepts custom id" do
      goal = Goal.new("Custom", id: "goal_custom123")
      assert goal.id == "goal_custom123"
    end
  end

  describe "achieve/1" do
    test "marks goal as achieved with timestamp" do
      goal = Goal.new("Complete task")
      achieved = Goal.achieve(goal)

      assert achieved.status == :achieved
      assert achieved.progress == 1.0
      assert %DateTime{} = achieved.achieved_at
    end
  end

  describe "abandon/2" do
    test "marks goal as abandoned" do
      goal = Goal.new("Abandoned task")
      abandoned = Goal.abandon(goal)

      assert abandoned.status == :abandoned
    end

    test "stores abandon reason in metadata" do
      goal = Goal.new("Abandoned task")
      abandoned = Goal.abandon(goal, "No longer relevant")

      assert abandoned.status == :abandoned
      assert abandoned.metadata.abandon_reason == "No longer relevant"
    end
  end

  describe "update_progress/2" do
    test "updates progress within bounds" do
      goal = Goal.new("In progress")
      updated = Goal.update_progress(goal, 0.5)

      assert updated.progress == 0.5
    end

    test "allows 0.0 progress" do
      goal = Goal.new("Starting")
      updated = Goal.update_progress(goal, 0.0)

      assert updated.progress == 0.0
    end

    test "allows 1.0 progress" do
      goal = Goal.new("Complete")
      updated = Goal.update_progress(goal, 1.0)

      assert updated.progress == 1.0
    end
  end

  describe "goal types" do
    test "supports all goal types" do
      for type <- [:achieve, :maintain, :explore, :learn, :avoid] do
        goal = Goal.new("Test", type: type)
        assert goal.type == type
      end
    end
  end

  describe "Jason encoding" do
    test "encodes goal to JSON" do
      goal = Goal.new("Test goal", type: :explore, priority: 75)
      json = Jason.encode!(goal)
      decoded = Jason.decode!(json)

      assert decoded["description"] == "Test goal"
      assert decoded["type"] == "explore"
      assert decoded["priority"] == 75
      assert decoded["status"] == "active"
      assert is_binary(decoded["created_at"])
    end

    test "encodes nil achieved_at as null" do
      goal = Goal.new("Pending")
      json = Jason.encode!(goal)
      decoded = Jason.decode!(json)

      assert decoded["achieved_at"] == nil
    end

    test "encodes achieved_at datetime" do
      goal = Goal.new("Done") |> Goal.achieve()
      json = Jason.encode!(goal)
      decoded = Jason.decode!(json)

      assert is_binary(decoded["achieved_at"])
    end
  end
end
