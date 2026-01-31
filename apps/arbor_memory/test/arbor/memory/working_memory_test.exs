defmodule Arbor.Memory.WorkingMemoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.WorkingMemory

  @moduletag :fast

  describe "new/2" do
    test "creates working memory with defaults" do
      wm = WorkingMemory.new("agent_001")

      assert wm.agent_id == "agent_001"
      assert wm.recent_thoughts == []
      assert wm.active_goals == []
      assert wm.relationship_context == nil
      assert wm.concerns == []
      assert wm.curiosity == []
      assert wm.engagement_level == 0.5
      assert wm.version == 1
    end

    test "accepts custom engagement level" do
      wm = WorkingMemory.new("agent_001", engagement_level: 0.8)

      assert wm.engagement_level == 0.8
    end
  end

  describe "add_thought/3" do
    test "prepends thought to list" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("First thought")
        |> WorkingMemory.add_thought("Second thought")

      assert wm.recent_thoughts == ["Second thought", "First thought"]
    end

    test "bounds thoughts by max_thoughts option" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("One", max_thoughts: 2)
        |> WorkingMemory.add_thought("Two", max_thoughts: 2)
        |> WorkingMemory.add_thought("Three", max_thoughts: 2)

      assert length(wm.recent_thoughts) == 2
      assert wm.recent_thoughts == ["Three", "Two"]
    end
  end

  describe "set_goals/3" do
    test "sets active goals" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Goal 1", "Goal 2"])

      assert wm.active_goals == ["Goal 1", "Goal 2"]
    end

    test "replaces existing goals" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Old goal"])
        |> WorkingMemory.set_goals(["New goal"])

      assert wm.active_goals == ["New goal"]
    end

    test "bounds goals by max_goals option" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["A", "B", "C"], max_goals: 2)

      assert wm.active_goals == ["A", "B"]
    end
  end

  describe "add_goal/3" do
    test "adds goal and deduplicates" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal("Goal 1")
        |> WorkingMemory.add_goal("Goal 2")
        |> WorkingMemory.add_goal("Goal 1")

      assert wm.active_goals == ["Goal 1", "Goal 2"]
    end
  end

  describe "complete_goal/2" do
    test "removes completed goal" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["A", "B", "C"])
        |> WorkingMemory.complete_goal("B")

      assert wm.active_goals == ["A", "C"]
    end
  end

  describe "set_relationship_context/2" do
    test "sets relationship context" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship_context("Close collaborator")

      assert wm.relationship_context == "Close collaborator"
    end

    test "allows nil to clear context" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship_context("Context")
        |> WorkingMemory.set_relationship_context(nil)

      assert wm.relationship_context == nil
    end
  end

  describe "concerns" do
    test "add_concern/3 adds and deduplicates" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_concern("Concern 1")
        |> WorkingMemory.add_concern("Concern 2")
        |> WorkingMemory.add_concern("Concern 1")

      assert wm.concerns == ["Concern 1", "Concern 2"]
    end

    test "resolve_concern/2 removes concern" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_concern("A")
        |> WorkingMemory.add_concern("B")
        |> WorkingMemory.resolve_concern("A")

      assert wm.concerns == ["B"]
    end
  end

  describe "curiosity" do
    test "add_curiosity/3 adds and deduplicates" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_curiosity("Item 1")
        |> WorkingMemory.add_curiosity("Item 2")
        |> WorkingMemory.add_curiosity("Item 1")

      assert wm.curiosity == ["Item 1", "Item 2"]
    end

    test "satisfy_curiosity/2 removes item" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_curiosity("A")
        |> WorkingMemory.add_curiosity("B")
        |> WorkingMemory.satisfy_curiosity("A")

      assert wm.curiosity == ["B"]
    end
  end

  describe "engagement_level" do
    test "set_engagement_level/2 clamps to valid range" do
      wm = WorkingMemory.new("agent_001")

      wm_high = WorkingMemory.set_engagement_level(wm, 1.5)
      assert wm_high.engagement_level == 1.0

      wm_low = WorkingMemory.set_engagement_level(wm, -0.5)
      assert wm_low.engagement_level == 0.0
    end

    test "adjust_engagement/2 adjusts and clamps" do
      wm = WorkingMemory.new("agent_001", engagement_level: 0.5)

      wm_up = WorkingMemory.adjust_engagement(wm, 0.3)
      assert wm_up.engagement_level == 0.8

      wm_down = WorkingMemory.adjust_engagement(wm, -0.3)
      assert wm_down.engagement_level == 0.2
    end
  end

  describe "to_prompt_text/2" do
    test "formats working memory as text" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship_context("Primary collaborator")
        |> WorkingMemory.set_goals(["Help with task"])
        |> WorkingMemory.add_thought("User seems interested")
        |> WorkingMemory.add_concern("Unclear requirements")
        |> WorkingMemory.add_curiosity("New technology")

      text = WorkingMemory.to_prompt_text(wm)

      assert text =~ "Relationship Context"
      assert text =~ "Primary collaborator"
      assert text =~ "Active Goals"
      assert text =~ "Help with task"
      assert text =~ "Recent Thoughts"
      assert text =~ "User seems interested"
      assert text =~ "Current Concerns"
      assert text =~ "Unclear requirements"
      assert text =~ "Things I'm Curious About"
      assert text =~ "New technology"
    end

    test "respects include options" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Goal"])
        |> WorkingMemory.add_thought("Thought")

      text = WorkingMemory.to_prompt_text(wm, include_thoughts: false)

      assert text =~ "Active Goals"
      refute text =~ "Recent Thoughts"
    end

    test "returns empty string when nothing to show" do
      wm = WorkingMemory.new("agent_001")
      text = WorkingMemory.to_prompt_text(wm)

      assert text == ""
    end
  end

  describe "to_prompt_context/2" do
    test "returns structured map" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Goal 1"])
        |> WorkingMemory.add_thought("Thought 1")

      context = WorkingMemory.to_prompt_context(wm)

      assert context.agent_id == "agent_001"
      assert context.active_goals == ["Goal 1"]
      assert context.recent_thoughts == ["Thought 1"]
      assert is_float(context.engagement_level)
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips correctly" do
      original =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship_context("Context")
        |> WorkingMemory.set_goals(["Goal 1", "Goal 2"])
        |> WorkingMemory.add_thought("Thought 1")
        |> WorkingMemory.add_thought("Thought 2")
        |> WorkingMemory.add_concern("Concern")
        |> WorkingMemory.add_curiosity("Curiosity")
        |> WorkingMemory.set_engagement_level(0.7)

      serialized = WorkingMemory.serialize(original)
      deserialized = WorkingMemory.deserialize(serialized)

      assert deserialized.agent_id == original.agent_id
      assert deserialized.recent_thoughts == original.recent_thoughts
      assert deserialized.active_goals == original.active_goals
      assert deserialized.relationship_context == original.relationship_context
      assert deserialized.concerns == original.concerns
      assert deserialized.curiosity == original.curiosity
      assert deserialized.engagement_level == original.engagement_level
      assert deserialized.version == original.version
    end

    test "serialize produces JSON-safe map" do
      wm = WorkingMemory.new("agent_001")
      serialized = WorkingMemory.serialize(wm)

      # All keys should be strings
      assert is_map(serialized)
      assert Map.has_key?(serialized, "agent_id")
      assert Map.has_key?(serialized, "recent_thoughts")
    end

    test "deserialize handles both string and atom keys" do
      atom_data = %{
        agent_id: "agent_001",
        recent_thoughts: ["thought"],
        active_goals: [],
        relationship_context: nil,
        concerns: [],
        curiosity: [],
        engagement_level: 0.5,
        version: 1
      }

      wm = WorkingMemory.deserialize(atom_data)
      assert wm.agent_id == "agent_001"
      assert wm.recent_thoughts == ["thought"]
    end
  end

  describe "trim_to_budget/2" do
    test "trims thoughts when over budget" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought(String.duplicate("a", 1000))
        |> WorkingMemory.add_thought(String.duplicate("b", 1000))
        |> WorkingMemory.add_thought(String.duplicate("c", 1000))

      # Very small budget to force trimming
      trimmed = WorkingMemory.trim_to_budget(wm, budget: {:fixed, 100})

      assert length(trimmed.recent_thoughts) < length(wm.recent_thoughts)
    end
  end

  describe "stats/1" do
    test "returns comprehensive stats" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship_context("Context")
        |> WorkingMemory.set_goals(["A", "B"])
        |> WorkingMemory.add_thought("T1")
        |> WorkingMemory.add_concern("C1")
        |> WorkingMemory.add_curiosity("Q1")

      stats = WorkingMemory.stats(wm)

      assert stats.agent_id == "agent_001"
      assert stats.thought_count == 1
      assert stats.goal_count == 2
      assert stats.concern_count == 1
      assert stats.curiosity_count == 1
      assert stats.has_relationship_context == true
      assert is_integer(stats.estimated_tokens)
      assert stats.version == 1
    end
  end

  describe "clear_thoughts/1" do
    test "clears all thoughts" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("One")
        |> WorkingMemory.add_thought("Two")
        |> WorkingMemory.clear_thoughts()

      assert wm.recent_thoughts == []
    end
  end
end
