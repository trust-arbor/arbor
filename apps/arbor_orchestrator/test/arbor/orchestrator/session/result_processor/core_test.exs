defmodule Arbor.Orchestrator.Session.ResultProcessor.CoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Session.ResultProcessor.Core

  describe "apply_goal_changes/3" do
    test "merges updates by id, leaves others, appends new goals" do
      existing = [%{"id" => "g1", "status" => "active"}, %{"id" => "g2", "status" => "active"}]
      updates = [%{"id" => "g1", "status" => "done"}]
      new = [%{"id" => "g3"}]

      result = Core.apply_goal_changes(existing, updates, new)

      assert result == [
               %{"id" => "g1", "status" => "done"},
               %{"id" => "g2", "status" => "active"},
               %{"id" => "g3"}
             ]
    end

    test "wraps a non-list new_goals value" do
      assert Core.apply_goal_changes([], [], %{"id" => "solo"}) == [%{"id" => "solo"}]
    end
  end

  describe "generate_heartbeat_proposals/3" do
    test "empty result context produces no proposals" do
      assert Core.generate_heartbeat_proposals("agent_1", %{cognitive_mode: :goal_pursuit}, %{}) ==
               []
    end

    test "composes proposals across goal, decomposition, and identity sources" do
      state = %{cognitive_mode: :goal_pursuit}

      ctx = %{
        "session.new_goals" => [%{"description" => "ship the thing"}],
        "session.decompositions" => [%{"description" => "step one"}],
        "session.identity_insights" => ["I value precision"]
      }

      proposals = Core.generate_heartbeat_proposals("agent_1", state, ctx)
      types = Enum.map(proposals, & &1.type)

      assert :goal in types
      assert :intent in types
      assert :identity in types
    end
  end

  describe "maybe_add_cognitive_mode_proposal/3" do
    test "proposes a switch when the result mode differs from current state" do
      state = %{cognitive_mode: :goal_pursuit}
      ctx = %{"session.cognitive_mode" => "reflection"}

      assert [%{type: :cognitive_mode, content: "Switch to reflection mode", metadata: meta}] =
               Core.maybe_add_cognitive_mode_proposal([], state, ctx)

      assert meta == %{from: "goal_pursuit", to: "reflection"}
    end

    test "no proposal when the mode matches current state" do
      state = %{cognitive_mode: :reflection}
      ctx = %{"session.cognitive_mode" => "reflection"}

      assert Core.maybe_add_cognitive_mode_proposal([], state, ctx) == []
    end

    test "no proposal when no mode is present" do
      assert Core.maybe_add_cognitive_mode_proposal([], %{cognitive_mode: :idle}, %{}) == []
    end
  end

  describe "maybe_add_goal_proposals/2" do
    test "rejects goals with blank descriptions" do
      ctx = %{"session.new_goals" => [%{"description" => "  "}, %{"description" => "real goal"}]}

      assert [%{type: :goal, content: "real goal"}] =
               Core.maybe_add_goal_proposals([], ctx)
    end
  end

  describe "maybe_add_wm_proposals/2" do
    test "filters internal monologue from thoughts but keeps observations" do
      ctx = %{"session.memory_notes" => ["Should refactor later", "The build went green"]}

      assert [%{type: :thought, content: "The build went green"}] =
               Core.maybe_add_wm_proposals([], ctx)
    end

    test "caps total observations at 5 (most-important-first)" do
      notes = for i <- 1..8, do: "observation #{i}"
      ctx = %{"session.memory_notes" => notes}

      assert length(Core.maybe_add_wm_proposals([], ctx)) == 5
    end

    test "concerns and curiosities are not monologue-filtered" do
      ctx = %{
        "session.concerns" => ["Should I be worried"],
        "session.curiosity" => ["Should I explore this"]
      }

      proposals = Core.maybe_add_wm_proposals([], ctx)
      assert Enum.map(proposals, & &1.type) |> Enum.sort() == [:concern, :curiosity]
    end
  end

  describe "internal_monologue?/1" do
    test "true for intention-prefixed content" do
      assert Core.internal_monologue?(%{content: "Need to fix the parser"})
      assert Core.internal_monologue?(%{content: "I should write tests"})
    end

    test "false for observations" do
      refute Core.internal_monologue?(%{content: "The parser handles nested edges"})
    end
  end

  describe "extract_note_with_metadata/1" do
    test "bare string → no metadata" do
      assert Core.extract_note_with_metadata("a note") == {"a note", %{}}
    end

    test "map with text + referenced_date → carries the date" do
      note = %{"text" => "dated note", "referenced_date" => "2026-05-27"}

      assert Core.extract_note_with_metadata(note) ==
               {"dated note", %{referenced_date: "2026-05-27"}}
    end

    test "map with text but no date → empty metadata" do
      assert Core.extract_note_with_metadata(%{"text" => "plain"}) == {"plain", %{}}
    end

    test "anything else → inspected, no metadata" do
      assert Core.extract_note_with_metadata(%{weird: true}) == {inspect(%{weird: true}), %{}}
    end
  end
end
