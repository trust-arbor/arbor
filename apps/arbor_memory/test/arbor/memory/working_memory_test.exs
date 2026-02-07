defmodule Arbor.Memory.WorkingMemoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.WorkingMemory

  @moduletag :fast

  # ============================================================================
  # Construction
  # ============================================================================

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
      assert wm.version == 2
      assert wm.name == nil
      assert wm.current_human == nil
      assert wm.max_tokens == nil
      assert wm.model == nil
      assert wm.thought_count == 0
      assert %DateTime{} = wm.started_at
    end

    test "accepts custom engagement level" do
      wm = WorkingMemory.new("agent_001", engagement_level: 0.8)
      assert wm.engagement_level == 0.8
    end

    test "accepts name option" do
      wm = WorkingMemory.new("agent_001", name: "Atlas")
      assert wm.name == "Atlas"
    end

    test "accepts max_tokens and model options" do
      wm = WorkingMemory.new("agent_001", max_tokens: 5000, model: "anthropic:claude-sonnet-4-5-20250929")
      assert wm.max_tokens == 5000
      assert wm.model == "anthropic:claude-sonnet-4-5-20250929"
    end
  end

  # ============================================================================
  # Thought Management — String Input
  # ============================================================================

  describe "add_thought/3 with strings" do
    test "wraps string in structured map" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("First thought")

      assert length(wm.recent_thoughts) == 1
      thought = hd(wm.recent_thoughts)
      assert thought.content == "First thought"
      assert %DateTime{} = thought.timestamp
      assert is_integer(thought.cached_tokens)
      assert thought.cached_tokens > 0
    end

    test "prepends thought (newest first)" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("First thought")
        |> WorkingMemory.add_thought("Second thought")

      contents = Enum.map(wm.recent_thoughts, & &1.content)
      assert contents == ["Second thought", "First thought"]
    end

    test "bounds thoughts by max_thoughts option" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("One", max_thoughts: 2)
        |> WorkingMemory.add_thought("Two", max_thoughts: 2)
        |> WorkingMemory.add_thought("Three", max_thoughts: 2)

      assert length(wm.recent_thoughts) == 2
      contents = Enum.map(wm.recent_thoughts, & &1.content)
      assert contents == ["Three", "Two"]
    end

    test "increments thought_count" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("One")
        |> WorkingMemory.add_thought("Two")

      assert wm.thought_count == 2
    end
  end

  # ============================================================================
  # Thought Management — Map Input
  # ============================================================================

  describe "add_thought/3 with maps" do
    test "accepts structured thought map" do
      ts = DateTime.utc_now()
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought(%{content: "Map thought", timestamp: ts, cached_tokens: 42})

      thought = hd(wm.recent_thoughts)
      assert thought.content == "Map thought"
      assert thought.timestamp == ts
      assert thought.cached_tokens == 42
    end

    test "fills in defaults for partial map" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought(%{content: "Partial map"})

      thought = hd(wm.recent_thoughts)
      assert thought.content == "Partial map"
      assert %DateTime{} = thought.timestamp
      assert is_integer(thought.cached_tokens)
    end
  end

  # ============================================================================
  # Token-Based Thought Trimming
  # ============================================================================

  describe "add_thought/3 with token budget" do
    test "trims by token count when max_tokens is set" do
      # Each thought ~250 chars = ~63 tokens; budget of 100 tokens allows ~1-2
      wm = WorkingMemory.new("agent_001", max_tokens: 100)

      wm =
        wm
        |> WorkingMemory.add_thought(String.duplicate("a", 250))
        |> WorkingMemory.add_thought(String.duplicate("b", 250))
        |> WorkingMemory.add_thought(String.duplicate("c", 250))

      # Should have trimmed some thoughts to fit budget
      assert length(wm.recent_thoughts) < 3
    end
  end

  describe "thought_tokens/1" do
    test "returns total token count" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought("Hello world")
        |> WorkingMemory.add_thought("Another thought here")

      tokens = WorkingMemory.thought_tokens(wm)
      assert is_integer(tokens)
      assert tokens > 0
    end
  end

  # ============================================================================
  # Goal Management — String Input
  # ============================================================================

  describe "set_goals/3 with strings" do
    test "wraps strings in goal maps" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Goal 1", "Goal 2"])

      assert length(wm.active_goals) == 2
      descriptions = Enum.map(wm.active_goals, & &1.description)
      assert descriptions == ["Goal 1", "Goal 2"]
    end

    test "replaces existing goals" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Old goal"])
        |> WorkingMemory.set_goals(["New goal"])

      assert length(wm.active_goals) == 1
      assert hd(wm.active_goals).description == "New goal"
    end

    test "bounds goals by max_goals option" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["A", "B", "C"], max_goals: 2)

      assert length(wm.active_goals) == 2
    end
  end

  describe "add_goal/3 with strings" do
    test "wraps string in goal map with unique id" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal("Goal 1")
        |> WorkingMemory.add_goal("Goal 2")

      assert length(wm.active_goals) == 2
      ids = Enum.map(wm.active_goals, & &1.id)
      assert Enum.uniq(ids) == ids  # all unique
      assert Enum.all?(wm.active_goals, &(&1.type == :general))
      assert Enum.all?(wm.active_goals, &(&1.priority == :normal))
      assert Enum.all?(wm.active_goals, &(&1.progress == 0))
    end
  end

  # ============================================================================
  # Goal Management — Map Input
  # ============================================================================

  describe "add_goal/3 with maps" do
    test "accepts structured goal map" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{
          id: "goal_001",
          description: "Explain GenServer",
          type: :task,
          priority: :high,
          progress: 25
        })

      goal = hd(wm.active_goals)
      assert goal.id == "goal_001"
      assert goal.description == "Explain GenServer"
      assert goal.type == :task
      assert goal.priority == :high
      assert goal.progress == 25
    end

    test "replaces goal with same id" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Original"})
        |> WorkingMemory.add_goal(%{id: "g1", description: "Updated"})

      assert length(wm.active_goals) == 1
      assert hd(wm.active_goals).description == "Updated"
    end
  end

  describe "complete_goal/2" do
    test "removes goal by description" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["A", "B", "C"])
        |> WorkingMemory.complete_goal("B")

      descriptions = Enum.map(wm.active_goals, & &1.description)
      assert "B" not in descriptions
      assert length(wm.active_goals) == 2
    end

    test "removes goal by id" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Task A"})
        |> WorkingMemory.add_goal(%{id: "g2", description: "Task B"})
        |> WorkingMemory.complete_goal("g1")

      assert length(wm.active_goals) == 1
      assert hd(wm.active_goals).id == "g2"
    end
  end

  describe "remove_goal/2" do
    test "removes goal by id" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Task"})
        |> WorkingMemory.remove_goal("g1")

      assert wm.active_goals == []
    end
  end

  describe "update_goal_progress/3" do
    test "updates progress on a specific goal" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Task", progress: 0})
        |> WorkingMemory.update_goal_progress("g1", 75)

      goal = hd(wm.active_goals)
      assert goal.progress == 75
    end

    test "clamps progress to 0-100" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Task"})

      wm_over = WorkingMemory.update_goal_progress(wm, "g1", 150)
      assert hd(wm_over.active_goals).progress == 100

      wm_under = WorkingMemory.update_goal_progress(wm, "g1", -10)
      assert hd(wm_under.active_goals).progress == 0
    end
  end

  # ============================================================================
  # Identity and Relationship
  # ============================================================================

  describe "set_name/2" do
    test "sets agent name" do
      wm = WorkingMemory.new("agent_001") |> WorkingMemory.set_name("Atlas")
      assert wm.name == "Atlas"
    end
  end

  describe "set_current_human/2" do
    test "sets current human" do
      wm = WorkingMemory.new("agent_001") |> WorkingMemory.set_current_human("Hysun")
      assert wm.current_human == "Hysun"
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

  # ============================================================================
  # Concerns and Curiosity
  # ============================================================================

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

  # ============================================================================
  # Engagement Level
  # ============================================================================

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

  # ============================================================================
  # Consolidation and Lifecycle
  # ============================================================================

  describe "mark_consolidated/1" do
    test "sets last_consolidated_at timestamp" do
      wm = WorkingMemory.new("agent_001") |> WorkingMemory.mark_consolidated()
      assert %DateTime{} = wm.last_consolidated_at
    end
  end

  describe "uptime/1" do
    test "returns seconds since creation" do
      wm = WorkingMemory.new("agent_001")
      assert WorkingMemory.uptime(wm) >= 0
    end

    test "returns 0 when started_at is nil" do
      wm = %WorkingMemory{agent_id: "test", started_at: nil}
      assert WorkingMemory.uptime(wm) == 0
    end
  end

  describe "rebuild_from_long_term/1" do
    test "returns error when signals not available" do
      wm = WorkingMemory.new("agent_001")
      assert {:error, :signals_not_available} = WorkingMemory.rebuild_from_long_term(wm)
    end
  end

  # ============================================================================
  # Rendering
  # ============================================================================

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
    test "returns structured map with string content" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["Goal 1"])
        |> WorkingMemory.add_thought("Thought 1")

      context = WorkingMemory.to_prompt_context(wm)

      assert context.agent_id == "agent_001"
      # Goals and thoughts are extracted to plain strings in context
      assert context.active_goals == ["Goal 1"]
      assert context.recent_thoughts == ["Thought 1"]
      assert is_float(context.engagement_level)
    end
  end

  # ============================================================================
  # Serialization
  # ============================================================================

  describe "serialize/1 and deserialize/1" do
    test "round-trips correctly" do
      original =
        WorkingMemory.new("agent_001", name: "Atlas")
        |> WorkingMemory.set_current_human("Hysun")
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
      assert deserialized.name == original.name
      assert deserialized.current_human == original.current_human
      assert deserialized.relationship_context == original.relationship_context
      assert deserialized.concerns == original.concerns
      assert deserialized.curiosity == original.curiosity
      assert deserialized.engagement_level == original.engagement_level
      assert deserialized.version == original.version
      assert deserialized.thought_count == original.thought_count

      # Thoughts round-trip (content preserved)
      assert length(deserialized.recent_thoughts) == length(original.recent_thoughts)
      orig_contents = Enum.map(original.recent_thoughts, & &1.content)
      deser_contents = Enum.map(deserialized.recent_thoughts, & &1.content)
      assert deser_contents == orig_contents

      # Goals round-trip (descriptions preserved)
      assert length(deserialized.active_goals) == length(original.active_goals)
      orig_descs = Enum.map(original.active_goals, & &1.description)
      deser_descs = Enum.map(deserialized.active_goals, & &1.description)
      assert deser_descs == orig_descs
    end

    test "serialize produces JSON-safe map" do
      wm = WorkingMemory.new("agent_001")
      serialized = WorkingMemory.serialize(wm)

      assert is_map(serialized)
      assert Map.has_key?(serialized, "agent_id")
      assert Map.has_key?(serialized, "recent_thoughts")
      assert Map.has_key?(serialized, "name")
      assert Map.has_key?(serialized, "thought_count")
    end

    test "deserialize handles v1 plain string format" do
      v1_data = %{
        "agent_id" => "agent_001",
        "recent_thoughts" => ["plain thought"],
        "active_goals" => ["plain goal"],
        "relationship_context" => nil,
        "concerns" => [],
        "curiosity" => [],
        "engagement_level" => 0.5,
        "version" => 1
      }

      wm = WorkingMemory.deserialize(v1_data)
      assert wm.agent_id == "agent_001"
      assert length(wm.recent_thoughts) == 1
      assert hd(wm.recent_thoughts).content == "plain thought"
      assert length(wm.active_goals) == 1
      assert hd(wm.active_goals).description == "plain goal"
    end

    test "deserialize handles both string and atom keys" do
      atom_data = %{
        agent_id: "agent_001",
        recent_thoughts: [],
        active_goals: [],
        engagement_level: 0.5
      }

      wm = WorkingMemory.deserialize(atom_data)
      assert wm.agent_id == "agent_001"
    end
  end

  # ============================================================================
  # Token Budget
  # ============================================================================

  describe "trim_to_budget/2" do
    test "trims thoughts when over budget" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_thought(String.duplicate("a", 1000))
        |> WorkingMemory.add_thought(String.duplicate("b", 1000))
        |> WorkingMemory.add_thought(String.duplicate("c", 1000))

      trimmed = WorkingMemory.trim_to_budget(wm, budget: {:fixed, 100})

      assert length(trimmed.recent_thoughts) < length(wm.recent_thoughts)
    end
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  describe "stats/1" do
    test "returns comprehensive stats" do
      wm =
        WorkingMemory.new("agent_001", name: "Atlas")
        |> WorkingMemory.set_relationship_context("Context")
        |> WorkingMemory.set_goals(["A", "B"])
        |> WorkingMemory.add_thought("T1")
        |> WorkingMemory.add_concern("C1")
        |> WorkingMemory.add_curiosity("Q1")

      stats = WorkingMemory.stats(wm)

      assert stats.agent_id == "agent_001"
      assert stats.name == "Atlas"
      assert stats.thought_count == 1
      assert stats.recent_thought_count == 1
      assert stats.goal_count == 2
      assert stats.concern_count == 1
      assert stats.curiosity_count == 1
      assert stats.has_relationship_context == true
      assert is_integer(stats.estimated_tokens)
      assert is_integer(stats.thought_tokens)
      assert stats.version == 2
      assert is_integer(stats.uptime_seconds)
    end
  end

  # ============================================================================
  # Clear Thoughts
  # ============================================================================

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
