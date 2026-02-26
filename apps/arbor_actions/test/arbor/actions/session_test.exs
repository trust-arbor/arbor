defmodule Arbor.Actions.SessionTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Session

  @moduletag :fast

  # ============================================================================
  # Classify
  # ============================================================================

  describe "Classify — schema" do
    test "action metadata" do
      assert Session.Classify.name() == "session_classify"
    end

    test "accepts empty params" do
      assert {:ok, _} = Session.Classify.validate_params(%{})
    end
  end

  describe "Classify — run" do
    test "classifies regular text as query" do
      assert {:ok, %{input_type: "query"}} = Session.Classify.run(%{input: "hello"}, %{})
    end

    test "classifies slash-prefixed as command" do
      assert {:ok, %{input_type: "command"}} = Session.Classify.run(%{input: "/help"}, %{})
    end

    test "classifies blocked session" do
      assert {:ok, %{input_type: "blocked"}} = Session.Classify.run(%{blocked: true}, %{})
    end

    test "defaults to query with no input" do
      assert {:ok, %{input_type: "query"}} = Session.Classify.run(%{}, %{})
    end

    test "accepts context key format" do
      assert {:ok, %{input_type: "command"}} =
               Session.Classify.run(%{"session.input" => "/status"}, %{})
    end
  end

  # ============================================================================
  # ModeSelect
  # ============================================================================

  describe "ModeSelect — schema" do
    test "action metadata" do
      assert Session.ModeSelect.name() == "session_mode_select"
    end

    test "accepts empty params" do
      assert {:ok, _} = Session.ModeSelect.validate_params(%{})
    end
  end

  describe "ModeSelect — run" do
    test "user_waiting → conversation" do
      assert {:ok, %{cognitive_mode: "conversation"}} =
               Session.ModeSelect.run(%{user_waiting: true, goals: [%{id: "g1"}]}, %{})
    end

    test "consolidation floor at turn multiples of 5" do
      assert {:ok, %{cognitive_mode: "consolidation"}} =
               Session.ModeSelect.run(%{turn_count: 5}, %{})
    end

    test "goals with no intents → plan_execution" do
      assert {:ok, %{cognitive_mode: "plan_execution"}} =
               Session.ModeSelect.run(%{goals: [%{id: "g1"}], active_intents: []}, %{})
    end

    test "goals with intents → goal_pursuit" do
      assert {:ok, %{cognitive_mode: "goal_pursuit"}} =
               Session.ModeSelect.run(
                 %{goals: [%{id: "g1"}], active_intents: [%{id: "i1"}]},
                 %{}
               )
    end

    test "no goals → reflection" do
      assert {:ok, %{cognitive_mode: "reflection"}} =
               Session.ModeSelect.run(%{}, %{})
    end

    test "accepts string turn_count" do
      assert {:ok, %{cognitive_mode: "consolidation"}} =
               Session.ModeSelect.run(%{turn_count: "10"}, %{})
    end

    test "accepts context key format" do
      assert {:ok, %{cognitive_mode: "reflection"}} =
               Session.ModeSelect.run(%{"session.goals" => []}, %{})
    end
  end

  # ============================================================================
  # ProcessResults
  # ============================================================================

  describe "ProcessResults — schema" do
    test "action metadata" do
      assert Session.ProcessResults.name() == "session_process_results"
    end

    test "accepts empty params" do
      assert {:ok, _} = Session.ProcessResults.validate_params(%{})
    end
  end

  describe "ProcessResults — run" do
    test "parses valid JSON with all fields" do
      json =
        Jason.encode!(%{
          "actions" => [%{"type" => "file.read", "params" => %{}}],
          "goal_updates" => [%{"id" => "g1", "progress" => 0.5}],
          "new_goals" => [%{"description" => "test"}],
          "memory_notes" => ["note1"],
          "concerns" => ["c1"],
          "curiosity" => ["q1"],
          "decompositions" => [%{"goal_id" => "g1"}],
          "new_intents" => [%{"action" => "read"}],
          "proposal_decisions" => [%{"proposal_id" => "p1", "decision" => "accept"}],
          "identity_insights" => [%{"category" => "trait", "content" => "curious"}]
        })

      assert {:ok, result} = Session.ProcessResults.run(%{raw_content: json}, %{})
      assert length(result.actions) == 1
      assert length(result.goal_updates) == 1
      assert length(result.new_goals) == 1
      assert length(result.memory_notes) == 1
      assert length(result.concerns) == 1
      assert length(result.curiosity) == 1
      assert length(result.decompositions) == 1
      assert length(result.new_intents) == 1
      assert length(result.proposal_decisions) == 1
      assert length(result.identity_insights) == 1
    end

    test "filters invalid actions" do
      json = Jason.encode!(%{"actions" => [%{"no_type" => true}, %{"type" => "valid"}]})
      assert {:ok, result} = Session.ProcessResults.run(%{raw_content: json}, %{})
      assert length(result.actions) == 1
    end

    test "filters invalid proposal decisions" do
      json =
        Jason.encode!(%{
          "proposal_decisions" => [
            %{"proposal_id" => "p1", "decision" => "accept"},
            %{"proposal_id" => "p2", "decision" => "invalid"},
            %{"missing" => "id"}
          ]
        })

      assert {:ok, result} = Session.ProcessResults.run(%{raw_content: json}, %{})
      assert length(result.proposal_decisions) == 1
    end

    test "accepts memory_notes as strings or maps" do
      json =
        Jason.encode!(%{
          "memory_notes" => ["plain string", %{"text" => "map note"}, %{"bad" => true}]
        })

      assert {:ok, result} = Session.ProcessResults.run(%{raw_content: json}, %{})
      assert length(result.memory_notes) == 2
    end

    test "returns empty arrays for non-JSON" do
      assert {:ok, result} = Session.ProcessResults.run(%{raw_content: "not json"}, %{})
      assert result.actions == []
      assert result.goal_updates == []
    end

    test "returns empty arrays for empty input" do
      assert {:ok, result} = Session.ProcessResults.run(%{}, %{})
      assert result.actions == []
    end

    test "accepts context key format" do
      json = Jason.encode!(%{"concerns" => ["test"]})

      assert {:ok, result} = Session.ProcessResults.run(%{"llm.content" => json}, %{})
      assert result.concerns == ["test"]
    end
  end
end
