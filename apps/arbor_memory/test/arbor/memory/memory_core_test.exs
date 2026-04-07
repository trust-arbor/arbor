defmodule Arbor.Memory.MemoryCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.MemoryCore

  # ===========================================================================
  # Construct
  # ===========================================================================

  describe "normalize_thought/1" do
    test "normalizes string to thought record" do
      thought = MemoryCore.normalize_thought("hello")
      assert thought.content == "hello"
      assert thought.cached_tokens > 0
      assert %DateTime{} = thought.timestamp
    end

    test "normalizes atom-keyed map" do
      thought = MemoryCore.normalize_thought(%{content: "hello", cached_tokens: 5})
      assert thought.content == "hello"
      assert thought.cached_tokens == 5
    end

    test "normalizes string-keyed map" do
      thought = MemoryCore.normalize_thought(%{"content" => "hello"})
      assert thought.content == "hello"
    end
  end

  describe "normalize_goal/1" do
    test "normalizes string to goal" do
      goal = MemoryCore.normalize_goal("Write tests")
      assert goal.description == "Write tests"
      assert goal.status == :active
      assert goal.progress == 0.0
      assert is_binary(goal.id)
    end

    test "normalizes map with defaults" do
      goal = MemoryCore.normalize_goal(%{description: "Ship it", type: :achieve})
      assert goal.description == "Ship it"
      assert goal.type == :achieve
      assert goal.priority == 50
    end
  end

  # ===========================================================================
  # Reduce — Thoughts & Concerns
  # ===========================================================================

  describe "add_thought/3" do
    test "adds thought to front" do
      thoughts = MemoryCore.add_thought([], "first")
      assert length(thoughts) == 1
      assert hd(thoughts).content == "first"

      thoughts = MemoryCore.add_thought(thoughts, "second")
      assert length(thoughts) == 2
      assert hd(thoughts).content == "second"
    end

    test "trims to max" do
      thoughts = Enum.reduce(1..25, [], fn i, acc ->
        MemoryCore.add_thought(acc, "thought #{i}", max_thoughts: 10)
      end)
      assert length(thoughts) == 10
    end
  end

  describe "add_concern/2" do
    test "adds new concern" do
      assert MemoryCore.add_concern([], "test") == ["test"]
    end

    test "deduplicates" do
      concerns = MemoryCore.add_concern(["test"], "test")
      assert concerns == ["test"]
    end
  end

  # ===========================================================================
  # Reduce — Goals
  # ===========================================================================

  describe "update_goal_progress/3" do
    test "updates progress" do
      goals = [%{id: "g1", progress: 0.0}]
      updated = MemoryCore.update_goal_progress(goals, "g1", 0.5)
      assert hd(updated).progress == 0.5
    end

    test "clamps to 0..1" do
      goals = [%{id: "g1", progress: 0.5}]
      assert hd(MemoryCore.update_goal_progress(goals, "g1", -1)).progress == 0.0
      assert hd(MemoryCore.update_goal_progress(goals, "g1", 2.0)).progress == 1.0
    end
  end

  describe "achieve_goal/2" do
    test "removes goal from active list" do
      goals = [%{id: "g1", status: :active, progress: 0.5}]
      remaining = MemoryCore.achieve_goal(goals, "g1")
      assert remaining == []
    end

    test "returns unchanged list for unknown goal" do
      assert MemoryCore.achieve_goal([], "nope") == []
    end

    test "is pipeable" do
      goals = [
        %{id: "g1", status: :active},
        %{id: "g2", status: :active},
        %{id: "g3", status: :active}
      ]

      remaining =
        goals
        |> MemoryCore.achieve_goal("g1")
        |> MemoryCore.abandon_goal("g2", "not needed")

      assert length(remaining) == 1
      assert hd(remaining).id == "g3"
    end
  end

  describe "abandon_goal/3" do
    test "removes goal from active list" do
      goals = [%{id: "g1", status: :active, notes: []}]
      remaining = MemoryCore.abandon_goal(goals, "g1", "not needed")
      assert remaining == []
    end
  end

  describe "fail_goal/3" do
    test "removes goal from active list" do
      goals = [%{id: "g1", status: :active, notes: []}]
      remaining = MemoryCore.fail_goal(goals, "g1", "timeout")
      assert remaining == []
    end
  end

  describe "find_goal/2 and transition_goal/3" do
    test "find_goal returns the matching goal" do
      goals = [%{id: "g1", status: :active}, %{id: "g2", status: :active}]
      assert MemoryCore.find_goal(goals, "g1").id == "g1"
      assert MemoryCore.find_goal(goals, "nope") == nil
    end

    test "transition_goal stamps :achieved with progress 1.0" do
      goal = %{id: "g1", status: :active, progress: 0.5}
      achieved = MemoryCore.transition_goal(goal, :achieved, nil)
      assert achieved.status == :achieved
      assert achieved.progress == 1.0
    end

    test "transition_goal stamps :abandoned with reason note" do
      goal = %{id: "g1", status: :active, notes: []}
      abandoned = MemoryCore.transition_goal(goal, :abandoned, "not needed")
      assert abandoned.status == :abandoned
      assert "not needed" in abandoned.notes
    end

    test "transition_goal stamps :failed with prefixed reason" do
      goal = %{id: "g1", status: :active, notes: []}
      failed = MemoryCore.transition_goal(goal, :failed, "timeout")
      assert failed.status == :failed
      assert Enum.any?(failed.notes, &String.contains?(&1, "Failed: timeout"))
    end

    test "transition_goal handles nil goal" do
      assert MemoryCore.transition_goal(nil, :achieved, nil) == nil
    end

    test "find + transition + achieve composes" do
      goals = [%{id: "g1", status: :active, progress: 0.5}]

      # Capture transitioned goal for side effects, then update list
      transitioned =
        goals
        |> MemoryCore.find_goal("g1")
        |> MemoryCore.transition_goal(:achieved, nil)

      remaining = MemoryCore.achieve_goal(goals, "g1")

      assert transitioned.status == :achieved
      assert remaining == []
    end
  end

  describe "sort_goals/1" do
    test "sorts by priority desc, then progress asc" do
      goals = [
        %{id: "low", priority: 10, progress: 0.5},
        %{id: "high", priority: 90, progress: 0.1},
        %{id: "mid", priority: 50, progress: 0.0}
      ]
      sorted = MemoryCore.sort_goals(goals)
      assert Enum.map(sorted, & &1.id) == ["high", "mid", "low"]
    end
  end

  describe "apply_goal_changes/2" do
    test "adds new goals" do
      existing = [%{id: "g1", description: "old", status: :active, progress: 0.5}]
      updates = [%{description: "new goal"}]
      result = MemoryCore.apply_goal_changes(existing, updates)
      assert length(result) == 2
    end

    test "updates existing by description match" do
      existing = [%{id: "g1", description: "Write tests", status: :active, progress: 0.3}]
      updates = [%{description: "Write tests", progress: 0.8}]
      result = MemoryCore.apply_goal_changes(existing, updates)
      assert length(result) == 1
      assert hd(result).progress == 0.8
    end
  end

  # ===========================================================================
  # Reduce — Intent Filtering
  # ===========================================================================

  describe "filter_by_type/2" do
    test "filters intents by type" do
      intents = [
        %{type: :think, content: "a"},
        %{type: :act, content: "b"},
        %{type: :think, content: "c"}
      ]
      assert length(MemoryCore.filter_by_type(intents, :think)) == 2
    end
  end

  describe "filter_by_goal/2" do
    test "filters intents by goal_id" do
      intents = [
        %{goal_id: "g1", content: "a"},
        %{goal_id: "g2", content: "b"},
        %{goal_id: "g1", content: "c"}
      ]
      assert length(MemoryCore.filter_by_goal(intents, "g1")) == 2
    end
  end

  # ===========================================================================
  # Convert
  # ===========================================================================

  describe "for_prompt/2" do
    test "formats working memory for LLM" do
      wm = %{
        recent_thoughts: [%{content: "thinking about CRC"}],
        active_goals: [%{description: "Ship v2", progress: 0.5, status: :active}],
        concerns: ["deadline approaching"],
        curiosity: ["how does Zenoh work?"]
      }

      text = MemoryCore.for_prompt(wm)
      assert String.contains?(text, "thinking about CRC")
      assert String.contains?(text, "Ship v2")
      assert String.contains?(text, "50")
      assert String.contains?(text, "deadline")
      assert String.contains?(text, "Zenoh")
    end

    test "handles empty memory" do
      text = MemoryCore.for_prompt(%{recent_thoughts: [], active_goals: [], concerns: [], curiosity: []})
      assert text == ""
    end
  end

  describe "for_dashboard/1" do
    test "formats for display from a plain map" do
      wm = %{
        agent_id: "agent_123",
        recent_thoughts: [%{content: "a"}, %{content: "b"}],
        active_goals: [%{id: "g1", description: "test", progress: 0.5, status: :active, priority: 80}],
        concerns: ["c1"],
        curiosity: ["q1"],
        engagement_level: 0.7
      }

      dashboard = MemoryCore.for_dashboard(wm)
      assert dashboard.thought_count == 2
      assert dashboard.goal_count == 1
      assert length(dashboard.active_goals) == 1
      assert hd(dashboard.active_goals).priority == 80
      assert dashboard.engagement_level == 0.7
    end

    test "formats for display from a WorkingMemory struct (regression)" do
      # Regression: previous version used `wm[:field]` (Access protocol) which
      # raises on structs that don't implement Access. WorkingMemory doesn't.
      # This test exercises the function with a real struct so we don't ship
      # the same bug twice. The crash signature was:
      #   UndefinedFunctionError: Arbor.Memory.WorkingMemory.fetch/2 is undefined
      wm = Arbor.Memory.WorkingMemory.new("agent_struct_test")

      wm =
        wm
        |> Arbor.Memory.WorkingMemory.add_thought("a thought")
        |> Arbor.Memory.WorkingMemory.add_concern("a concern")

      # Must not raise
      dashboard = MemoryCore.for_dashboard(wm)

      assert dashboard.agent_id == "agent_struct_test"
      assert dashboard.thought_count >= 1
      assert dashboard.concerns_count >= 1
      assert is_list(dashboard.active_goals)
    end
  end

  describe "for_persistence/1" do
    test "serializes to JSON-safe map" do
      wm = %{
        agent_id: "agent_123",
        recent_thoughts: [%{content: "test", timestamp: DateTime.utc_now()}],
        active_goals: [%{id: "g1", description: "d", status: :active}],
        concerns: ["c"],
        curiosity: ["q"],
        engagement_level: 0.5,
        thought_count: 1
      }

      persisted = MemoryCore.for_persistence(wm)
      assert persisted["agent_id"] == "agent_123"
      assert is_list(persisted["recent_thoughts"])
      assert is_list(persisted["active_goals"])
    end
  end

  describe "for_heartbeat/2" do
    test "formats condensed context" do
      wm = %{
        recent_thoughts: Enum.map(1..10, &%{content: "thought #{&1}"}),
        active_goals: [%{id: "g1", description: "d", progress: 0.5, status: :active}],
        concerns: Enum.map(1..5, &"concern #{&1}"),
        curiosity: Enum.map(1..5, &"q #{&1}")
      }

      hb = MemoryCore.for_heartbeat(wm, max_thoughts: 3)
      assert length(hb.recent_thoughts) == 3
      assert length(hb.concerns) == 3
      assert length(hb.curiosity) == 3
    end
  end

  describe "goal_summary/1" do
    test "summarizes goal stats" do
      goals = [
        %{status: :active, progress: 0.5},
        %{status: :active, progress: 0.8},
        %{status: :achieved, progress: 1.0},
        %{status: :failed, progress: 0.1}
      ]

      summary = MemoryCore.goal_summary(goals)
      assert summary.total == 4
      assert summary.active == 2
      assert summary.achieved == 1
      assert summary.failed == 1
      assert summary.avg_progress == 0.65
    end
  end

  # ===========================================================================
  # Pipeline
  # ===========================================================================

  describe "pipeline" do
    test "compose reduce → convert" do
      thoughts =
        []
        |> MemoryCore.add_thought("first thought")
        |> MemoryCore.add_thought("second thought")

      goals =
        [MemoryCore.normalize_goal("Ship v2")]
        |> MemoryCore.update_goal_progress(hd([MemoryCore.normalize_goal("Ship v2")]).id, 0.0)

      wm = %{
        recent_thoughts: thoughts,
        active_goals: goals,
        concerns: ["deadline"],
        curiosity: ["Zenoh"],
        agent_id: "test",
        engagement_level: 0.5
      }

      # Same wm → different Convert views
      prompt = MemoryCore.for_prompt(wm)
      assert String.contains?(prompt, "second thought")

      dashboard = MemoryCore.for_dashboard(wm)
      assert dashboard.thought_count == 2

      heartbeat = MemoryCore.for_heartbeat(wm, max_thoughts: 1)
      assert length(heartbeat.recent_thoughts) == 1

      summary = MemoryCore.goal_summary(goals)
      assert summary.active >= 0
    end
  end
end
