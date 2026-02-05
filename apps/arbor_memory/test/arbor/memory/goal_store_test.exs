defmodule Arbor.Memory.GoalStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Memory.Goal
  alias Arbor.Memory.GoalStore

  @moduletag :fast

  setup do
    agent_id = "test_agent_#{System.unique_integer([:positive])}"
    on_exit(fn -> GoalStore.clear_goals(agent_id) end)
    %{agent_id: agent_id}
  end

  describe "add_goal/2" do
    test "adds a Goal struct", %{agent_id: agent_id} do
      goal = Goal.new("Fix the bug", type: :achieve, priority: 80)
      assert {:ok, ^goal} = GoalStore.add_goal(agent_id, goal)
    end

    test "adds a goal from description string", %{agent_id: agent_id} do
      assert {:ok, goal} = GoalStore.add_goal(agent_id, "Learn Elixir", type: :learn)
      assert goal.description == "Learn Elixir"
      assert goal.type == :learn
      assert goal.status == :active
    end
  end

  describe "get_goal/2" do
    test "retrieves a stored goal", %{agent_id: agent_id} do
      goal = Goal.new("Test goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      assert {:ok, retrieved} = GoalStore.get_goal(agent_id, goal.id)
      assert retrieved.id == goal.id
      assert retrieved.description == "Test goal"
    end

    test "returns error for missing goal", %{agent_id: agent_id} do
      assert {:error, :not_found} = GoalStore.get_goal(agent_id, "nonexistent")
    end

    test "goals are isolated per agent" do
      agent_a = "agent_a_#{System.unique_integer([:positive])}"
      agent_b = "agent_b_#{System.unique_integer([:positive])}"

      goal = Goal.new("Agent A goal")
      {:ok, _} = GoalStore.add_goal(agent_a, goal)

      assert {:ok, _} = GoalStore.get_goal(agent_a, goal.id)
      assert {:error, :not_found} = GoalStore.get_goal(agent_b, goal.id)

      GoalStore.clear_goals(agent_a)
      GoalStore.clear_goals(agent_b)
    end
  end

  describe "update_goal_progress/3" do
    test "updates progress value", %{agent_id: agent_id} do
      goal = Goal.new("In progress goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      assert {:ok, updated} = GoalStore.update_goal_progress(agent_id, goal.id, 0.5)
      assert updated.progress == 0.5
    end

    test "persists updated progress", %{agent_id: agent_id} do
      goal = Goal.new("Persistent progress")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      GoalStore.update_goal_progress(agent_id, goal.id, 0.7)
      assert {:ok, retrieved} = GoalStore.get_goal(agent_id, goal.id)
      assert retrieved.progress == 0.7
    end

    test "returns error for missing goal", %{agent_id: agent_id} do
      assert {:error, :not_found} = GoalStore.update_goal_progress(agent_id, "missing", 0.5)
    end
  end

  describe "achieve_goal/2" do
    test "marks goal as achieved with timestamp", %{agent_id: agent_id} do
      goal = Goal.new("Achievable goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      assert {:ok, achieved} = GoalStore.achieve_goal(agent_id, goal.id)
      assert achieved.status == :achieved
      assert achieved.progress == 1.0
      assert achieved.achieved_at != nil
    end

    test "returns error for missing goal", %{agent_id: agent_id} do
      assert {:error, :not_found} = GoalStore.achieve_goal(agent_id, "missing")
    end
  end

  describe "abandon_goal/3" do
    test "marks goal as abandoned", %{agent_id: agent_id} do
      goal = Goal.new("Abandonable goal")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      assert {:ok, abandoned} = GoalStore.abandon_goal(agent_id, goal.id)
      assert abandoned.status == :abandoned
    end

    test "stores abandon reason in metadata", %{agent_id: agent_id} do
      goal = Goal.new("Goal with reason")
      {:ok, _} = GoalStore.add_goal(agent_id, goal)

      assert {:ok, abandoned} = GoalStore.abandon_goal(agent_id, goal.id, "No longer relevant")
      assert abandoned.metadata[:abandon_reason] == "No longer relevant"
    end

    test "returns error for missing goal", %{agent_id: agent_id} do
      assert {:error, :not_found} = GoalStore.abandon_goal(agent_id, "missing")
    end
  end

  describe "get_active_goals/1" do
    test "returns only active goals sorted by priority", %{agent_id: agent_id} do
      {:ok, _} = GoalStore.add_goal(agent_id, "Low priority", priority: 10)
      {:ok, _} = GoalStore.add_goal(agent_id, "High priority", priority: 90)
      {:ok, _} = GoalStore.add_goal(agent_id, "Medium priority", priority: 50)

      # Add and achieve one
      {:ok, done} = GoalStore.add_goal(agent_id, "Done goal", priority: 100)
      GoalStore.achieve_goal(agent_id, done.id)

      active = GoalStore.get_active_goals(agent_id)
      assert length(active) == 3
      assert hd(active).priority == 90
      assert List.last(active).priority == 10
    end

    test "returns empty list when no goals", %{agent_id: agent_id} do
      assert GoalStore.get_active_goals(agent_id) == []
    end
  end

  describe "get_goal_tree/2" do
    test "builds parent-children hierarchy", %{agent_id: agent_id} do
      {:ok, parent} = GoalStore.add_goal(agent_id, "Parent goal")

      {:ok, _child1} =
        GoalStore.add_goal(agent_id, "Child 1", parent_id: parent.id)

      {:ok, _child2} =
        GoalStore.add_goal(agent_id, "Child 2", parent_id: parent.id)

      assert {:ok, tree} = GoalStore.get_goal_tree(agent_id, parent.id)
      assert tree.goal.id == parent.id
      assert length(tree.children) == 2

      child_descriptions = Enum.map(tree.children, & &1.goal.description)
      assert "Child 1" in child_descriptions
      assert "Child 2" in child_descriptions
    end

    test "handles nested hierarchy", %{agent_id: agent_id} do
      {:ok, root} = GoalStore.add_goal(agent_id, "Root")
      {:ok, child} = GoalStore.add_goal(agent_id, "Child", parent_id: root.id)
      {:ok, _grandchild} = GoalStore.add_goal(agent_id, "Grandchild", parent_id: child.id)

      assert {:ok, tree} = GoalStore.get_goal_tree(agent_id, root.id)
      assert length(tree.children) == 1
      assert length(hd(tree.children).children) == 1
      assert hd(hd(tree.children).children).goal.description == "Grandchild"
    end

    test "returns error for missing goal", %{agent_id: agent_id} do
      assert {:error, :not_found} = GoalStore.get_goal_tree(agent_id, "missing")
    end
  end

  describe "delete_goal/2" do
    test "removes a goal", %{agent_id: agent_id} do
      {:ok, goal} = GoalStore.add_goal(agent_id, "Deleteable")
      assert {:ok, _} = GoalStore.get_goal(agent_id, goal.id)

      assert :ok = GoalStore.delete_goal(agent_id, goal.id)
      assert {:error, :not_found} = GoalStore.get_goal(agent_id, goal.id)
    end
  end

  describe "clear_goals/1" do
    test "removes all goals for an agent", %{agent_id: agent_id} do
      {:ok, _} = GoalStore.add_goal(agent_id, "Goal 1")
      {:ok, _} = GoalStore.add_goal(agent_id, "Goal 2")

      assert :ok = GoalStore.clear_goals(agent_id)
      assert GoalStore.get_active_goals(agent_id) == []
    end
  end
end
