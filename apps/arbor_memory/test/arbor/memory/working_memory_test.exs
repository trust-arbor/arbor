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
      assert wm.version == 3
      assert wm.name == nil
      assert wm.current_human == nil
      assert wm.current_conversation == nil
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
      wm =
        WorkingMemory.new("agent_001",
          max_tokens: 5000,
          model: "anthropic:claude-sonnet-4-5-20250929"
        )

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
      # all unique
      assert Enum.uniq(ids) == ids
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
    test "removes goal by description and records thought" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_goals(["A", "B", "C"])
        |> WorkingMemory.complete_goal("B")

      descriptions = Enum.map(wm.active_goals, & &1.description)
      assert "B" not in descriptions
      assert length(wm.active_goals) == 2

      # Audit trail: completion recorded as thought
      thought = hd(wm.recent_thoughts)
      assert thought.content == "Completed goal: B"
    end

    test "removes goal by id and records thought" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Task A"})
        |> WorkingMemory.add_goal(%{id: "g2", description: "Task B"})
        |> WorkingMemory.complete_goal("g1")

      assert length(wm.active_goals) == 1
      assert hd(wm.active_goals).id == "g2"

      # Audit trail
      thought = hd(wm.recent_thoughts)
      assert thought.content == "Completed goal: Task A"
    end

    test "no-op when goal not found" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.complete_goal("nonexistent")

      assert wm.active_goals == []
      assert wm.recent_thoughts == []
    end
  end

  describe "abandon_goal/2" do
    test "removes goal and records abandonment thought" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.add_goal(%{id: "g1", description: "Research topic"})
        |> WorkingMemory.abandon_goal("g1")

      assert wm.active_goals == []
      thought = hd(wm.recent_thoughts)
      assert thought.content == "Abandoned goal: Research topic"
    end

    test "no-op when goal not found" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.abandon_goal("nonexistent")

      assert wm.active_goals == []
      assert wm.recent_thoughts == []
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

  describe "set_relationship/3" do
    test "sets both current_human and relationship_context" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship("Hysun", %{role: "creator", trust: :high})

      assert wm.current_human == "Hysun"
      assert wm.relationship_context == %{role: "creator", trust: :high}
    end

    test "accepts string context" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_relationship("Hysun", "Primary collaborator")

      assert wm.current_human == "Hysun"
      assert wm.relationship_context == "Primary collaborator"
    end
  end

  describe "set_conversation/2" do
    test "sets conversation context" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_conversation(%{topic: "migration", turn: 5})

      assert wm.current_conversation == %{topic: "migration", turn: 5}
    end

    test "allows nil to clear conversation" do
      wm =
        WorkingMemory.new("agent_001")
        |> WorkingMemory.set_conversation(%{topic: "test"})
        |> WorkingMemory.set_conversation(nil)

      assert wm.current_conversation == nil
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
    test "gracefully returns unchanged wm when signals bus not running" do
      wm = WorkingMemory.new("agent_001", rebuild_from_signals: false)
      assert {:ok, rebuilt} = WorkingMemory.rebuild_from_long_term(wm)
      assert rebuilt.agent_id == wm.agent_id
      assert rebuilt.recent_thoughts == wm.recent_thoughts
    end
  end

  # ============================================================================
  # Rendering
  # ============================================================================

  describe "to_prompt_text/2" do
    test "formats working memory as text with identity" do
      wm =
        WorkingMemory.new("agent_001", name: "Atlas")
        |> WorkingMemory.set_relationship_context("Primary collaborator")
        |> WorkingMemory.set_goals(["Help with task"])
        |> WorkingMemory.add_thought("User seems interested")
        |> WorkingMemory.add_concern("Unclear requirements")
        |> WorkingMemory.add_curiosity("New technology")

      text = WorkingMemory.to_prompt_text(wm)

      assert text =~ "## Identity"
      assert text =~ "Name: Atlas"
      assert text =~ "Agent ID: agent_001"
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

    test "identity section without name shows only agent_id" do
      wm = WorkingMemory.new("agent_001")
      text = WorkingMemory.to_prompt_text(wm)

      assert text =~ "## Identity"
      assert text =~ "Agent ID: agent_001"
      refute text =~ "Name:"
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

    test "include_identity: false hides identity section" do
      wm = WorkingMemory.new("agent_001", name: "Atlas")
      text = WorkingMemory.to_prompt_text(wm, include_identity: false)

      refute text =~ "## Identity"
      refute text =~ "Agent ID:"
    end

    test "returns empty string when nothing to show and identity disabled" do
      wm = WorkingMemory.new("agent_001")
      text = WorkingMemory.to_prompt_text(wm, include_identity: false)

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
        |> WorkingMemory.set_conversation(%{"topic" => "migration", "turn" => 5})
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
      assert deserialized.current_conversation == original.current_conversation
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
      assert stats.version == 3
      assert is_integer(stats.uptime_seconds)
    end
  end

  # ============================================================================
  # Temporal Thought Formatting
  # ============================================================================

  describe "temporal thought formatting" do
    test "thoughts are grouped by time when temporal_grouping: true" do
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -86_400, :second)

      wm =
        WorkingMemory.new("agent_001", rebuild_from_signals: false)
        |> WorkingMemory.add_thought(%{
          content: "Today thought",
          timestamp: now,
          cached_tokens: 5
        })
        |> WorkingMemory.add_thought(%{
          content: "Yesterday thought",
          timestamp: yesterday,
          cached_tokens: 5
        })

      text = WorkingMemory.to_prompt_text(wm, temporal_grouping: true, include_identity: false)

      assert text =~ "### Today"
      assert text =~ "### Yesterday"
      assert text =~ "Today thought"
      assert text =~ "Yesterday thought"
    end

    test "thoughts shown as flat list when temporal_grouping: false" do
      wm =
        WorkingMemory.new("agent_001", rebuild_from_signals: false)
        |> WorkingMemory.add_thought("First thought")
        |> WorkingMemory.add_thought("Second thought")

      text = WorkingMemory.to_prompt_text(wm, temporal_grouping: false, include_identity: false)

      refute text =~ "### Today"
      assert text =~ "- Second thought"
      assert text =~ "- First thought"
    end

    test "thoughts with referenced_date show reference annotation" do
      now = DateTime.utc_now()
      ref = DateTime.add(now, -2 * 86_400, :second)

      wm =
        WorkingMemory.new("agent_001", rebuild_from_signals: false)
        |> WorkingMemory.add_thought(%{
          content: "Deploy happened two days ago",
          timestamp: now,
          cached_tokens: 10,
          referenced_date: ref
        })

      text = WorkingMemory.to_prompt_text(wm, temporal_grouping: true, include_identity: false)

      assert text =~ "refers to"
      assert text =~ "Deploy happened two days ago"
    end

    test "empty thoughts list produces no section" do
      wm = WorkingMemory.new("agent_001", rebuild_from_signals: false)
      text = WorkingMemory.to_prompt_text(wm, include_identity: false)

      refute text =~ "Recent Thoughts"
    end

    test "temporal grouping is the default behavior" do
      wm =
        WorkingMemory.new("agent_001", rebuild_from_signals: false)
        |> WorkingMemory.add_thought("A thought")

      text = WorkingMemory.to_prompt_text(wm, include_identity: false)

      # Default should include temporal headers
      assert text =~ "### Today"
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

  # ============================================================================
  # Signal Replay (apply_memory_event/2)
  # ============================================================================

  describe "apply_memory_event/2" do
    setup do
      {:ok, wm: WorkingMemory.new("event_test", rebuild_from_signals: false)}
    end

    test "applies identity event from data.type", %{wm: wm} do
      signal = %{type: :identity_change, data: %{type: :identity, name: "Atlas"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.name == "Atlas"
    end

    test "infers identity type from signal type", %{wm: wm} do
      signal = %{type: :identity_change, data: %{name: "Orion"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.name == "Orion"
    end

    test "applies thought event", %{wm: wm} do
      signal = %{type: :thought_recorded, data: %{thought_preview: "Deep thinking"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert length(result.recent_thoughts) == 1
      assert hd(result.recent_thoughts).content == "Deep thinking"
    end

    test "applies thought with data.type", %{wm: wm} do
      signal = %{type: nil, data: %{type: :thought, content: "Explicit thought"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert length(result.recent_thoughts) == 1
      assert hd(result.recent_thoughts).content == "Explicit thought"
    end

    test "applies goal added event", %{wm: wm} do
      goal = %{id: "g1", description: "Learn Elixir", type: :short_term, priority: :medium}
      signal = %{type: nil, data: %{type: :goal, event_type: :added, goal: goal}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert length(result.active_goals) == 1
      assert hd(result.active_goals).description == "Learn Elixir"
    end

    test "applies goal achieved event (removes goal)", %{wm: wm} do
      wm = WorkingMemory.set_goals(wm, [%{id: "g1", description: "Done"}])
      signal = %{type: nil, data: %{type: :goal, event_type: :achieved, goal: %{id: "g1"}}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.active_goals == []
    end

    test "applies relationship event", %{wm: wm} do
      signal = %{
        type: :relationship_changed,
        data: %{human_name: "Alice", context: "Collaborator"}
      }

      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.current_human == "Alice"
      assert result.relationship_context == "Collaborator"
    end

    test "applies engagement event", %{wm: wm} do
      signal = %{type: :engagement_changed, data: %{level: 0.9}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.engagement_level == 0.9
    end

    test "ignores non-numeric engagement", %{wm: wm} do
      signal = %{type: :engagement_changed, data: %{level: "high"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.engagement_level == 0.5
    end

    test "applies concern added event", %{wm: wm} do
      signal = %{type: :concern_added, data: %{concern: "Memory usage", action: :added}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert length(result.concerns) == 1
    end

    test "applies concern resolved event", %{wm: wm} do
      wm = WorkingMemory.add_concern(wm, "Memory usage")
      signal = %{type: :concern_resolved, data: %{concern: "Memory usage", action: :resolved}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.concerns == []
    end

    test "applies curiosity added event", %{wm: wm} do
      signal = %{type: :curiosity_added, data: %{item: "Quantum computing", action: :added}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert length(result.curiosity) == 1
    end

    test "applies curiosity satisfied event", %{wm: wm} do
      wm = WorkingMemory.add_curiosity(wm, "Quantum computing")

      signal = %{
        type: :curiosity_satisfied,
        data: %{item: "Quantum computing", action: :satisfied}
      }

      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.curiosity == []
    end

    test "applies conversation event", %{wm: wm} do
      conv = %{topic: "Elixir OTP", turn_count: 5}
      signal = %{type: :conversation_changed, data: %{conversation: conv}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.current_conversation == conv
    end

    test "ignores unknown event types", %{wm: wm} do
      signal = %{type: :unknown_signal, data: %{foo: "bar"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result == wm
    end

    test "handles signal without :type field (legacy format)", %{wm: wm} do
      signal = %{data: %{type: :identity, name: "Legacy"}}
      result = WorkingMemory.apply_memory_event(signal, wm)
      assert result.name == "Legacy"
    end

    test "handles completely invalid signal", %{wm: wm} do
      result = WorkingMemory.apply_memory_event(:garbage, wm)
      assert result == wm
    end
  end

  # ============================================================================
  # Rebuild Integration (new/2 with rebuild_from_signals)
  # ============================================================================

  describe "new/2 with rebuild_from_signals" do
    test "defaults to true and gracefully returns base when signals not running" do
      wm = WorkingMemory.new("rebuild_test")
      assert wm.agent_id == "rebuild_test"
      assert wm.recent_thoughts == []
    end

    test "can be explicitly disabled" do
      wm = WorkingMemory.new("no_rebuild", rebuild_from_signals: false)
      assert wm.agent_id == "no_rebuild"
    end
  end
end
