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

  describe "new/2 with new fields" do
    test "accepts deadline, success_criteria, notes, assigned_by" do
      deadline = DateTime.add(DateTime.utc_now(), 3600, :second)

      goal =
        Goal.new("Ship feature",
          deadline: deadline,
          success_criteria: "All tests pass",
          notes: ["Started planning"],
          assigned_by: :user
        )

      assert goal.deadline == deadline
      assert goal.success_criteria == "All tests pass"
      assert goal.notes == ["Started planning"]
      assert goal.assigned_by == :user
    end

    test "defaults new fields to nil/empty" do
      goal = Goal.new("Simple goal")

      assert goal.deadline == nil
      assert goal.success_criteria == nil
      assert goal.notes == []
      assert goal.assigned_by == nil
    end
  end

  describe "fail/2" do
    test "marks goal as failed" do
      goal = Goal.new("Risky task")
      failed = Goal.fail(goal)

      assert failed.status == :failed
    end

    test "prepends reason to notes" do
      goal = Goal.new("Risky task", notes: ["existing note"])
      failed = Goal.fail(goal, "Timeout exceeded")

      assert failed.status == :failed
      assert hd(failed.notes) == "Failed: Timeout exceeded"
      assert length(failed.notes) == 2
    end

    test "preserves notes when no reason given" do
      goal = Goal.new("Risky task", notes: ["note1"])
      failed = Goal.fail(goal)

      assert failed.notes == ["note1"]
    end
  end

  describe "add_note/2" do
    test "prepends note to notes list" do
      goal = Goal.new("Task")
      goal = Goal.add_note(goal, "First note")
      goal = Goal.add_note(goal, "Second note")

      assert goal.notes == ["Second note", "First note"]
    end
  end

  describe "overdue?/1" do
    test "returns false when no deadline" do
      goal = Goal.new("No deadline")
      refute Goal.overdue?(goal)
    end

    test "returns true when past deadline" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      goal = Goal.new("Late", deadline: past)
      assert Goal.overdue?(goal)
    end

    test "returns false when before deadline" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      goal = Goal.new("On time", deadline: future)
      refute Goal.overdue?(goal)
    end
  end

  describe "urgency/1" do
    test "base urgency is priority/100 with no deadline" do
      goal = Goal.new("Task", priority: 80)
      assert Goal.urgency(goal) == 0.8
    end

    test "overdue deadline doubles urgency" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      goal = Goal.new("Late task", priority: 50, deadline: past)
      assert Goal.urgency(goal) == 1.0
    end

    test "deadline within 1 hour has 1.8x factor" do
      soon = DateTime.add(DateTime.utc_now(), 1800, :second)
      goal = Goal.new("Urgent", priority: 100, deadline: soon)
      assert Goal.urgency(goal) == 1.8
    end

    test "deadline within 24 hours has 1.5x factor" do
      tomorrow = DateTime.add(DateTime.utc_now(), 12 * 3600, :second)
      goal = Goal.new("Soon", priority: 100, deadline: tomorrow)
      assert Goal.urgency(goal) == 1.5
    end

    test "deadline within 7 days has 1.2x factor" do
      next_week = DateTime.add(DateTime.utc_now(), 3 * 24 * 3600, :second)
      goal = Goal.new("This week", priority: 100, deadline: next_week)
      assert Goal.urgency(goal) == 1.2
    end

    test "far deadline has 1.0x factor" do
      far_future = DateTime.add(DateTime.utc_now(), 30 * 24 * 3600, :second)
      goal = Goal.new("Later", priority: 60, deadline: far_future)
      assert Goal.urgency(goal) == 0.6
    end
  end

  describe "to_prompt_format/1" do
    test "formats basic goal" do
      goal = Goal.new("Fix auth", priority: 80, progress: 0.65)
      text = Goal.to_prompt_format(goal)

      assert String.contains?(text, "[P80]")
      assert String.contains?(text, "Fix auth")
      assert String.contains?(text, "[65%]")
    end

    test "includes deadline when set" do
      deadline = ~U[2026-03-01 12:00:00Z]
      goal = Goal.new("Ship it", priority: 90, deadline: deadline)
      text = Goal.to_prompt_format(goal)

      assert String.contains?(text, "(deadline: 2026-03-01T12:00:00Z)")
    end

    test "includes success criteria when set" do
      goal = Goal.new("Deploy", success_criteria: "Zero downtime")
      text = Goal.to_prompt_format(goal)

      assert String.contains?(text, "Success when: Zero downtime")
    end

    test "omits deadline and criteria when nil" do
      goal = Goal.new("Simple")
      text = Goal.to_prompt_format(goal)

      refute String.contains?(text, "deadline")
      refute String.contains?(text, "Success when")
    end
  end

  describe "terminal?/1" do
    test "achieved is terminal" do
      goal = Goal.new("Done") |> Goal.achieve()
      assert Goal.terminal?(goal)
    end

    test "failed is terminal" do
      goal = Goal.new("Failed") |> Goal.fail("error")
      assert Goal.terminal?(goal)
    end

    test "abandoned is terminal" do
      goal = Goal.new("Abandoned") |> Goal.abandon()
      assert Goal.terminal?(goal)
    end

    test "active is not terminal" do
      goal = Goal.new("Active")
      refute Goal.terminal?(goal)
    end

    test "blocked is not terminal" do
      goal = Goal.new("Blocked", status: :blocked)
      refute Goal.terminal?(goal)
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

    test "encodes deadline datetime" do
      deadline = ~U[2026-03-15 10:00:00Z]
      goal = Goal.new("Deadline goal", deadline: deadline)
      json = Jason.encode!(goal)
      decoded = Jason.decode!(json)

      assert decoded["deadline"] == "2026-03-15T10:00:00Z"
    end

    test "encodes nil deadline as null" do
      goal = Goal.new("No deadline")
      json = Jason.encode!(goal)
      decoded = Jason.decode!(json)

      assert decoded["deadline"] == nil
    end

    test "encodes notes and success_criteria" do
      goal = Goal.new("Rich goal",
        notes: ["note1", "note2"],
        success_criteria: "Tests pass"
      )
      json = Jason.encode!(goal)
      decoded = Jason.decode!(json)

      assert decoded["notes"] == ["note1", "note2"]
      assert decoded["success_criteria"] == "Tests pass"
    end
  end
end
