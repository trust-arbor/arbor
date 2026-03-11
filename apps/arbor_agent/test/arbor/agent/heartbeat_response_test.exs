defmodule Arbor.Agent.HeartbeatResponseTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.HeartbeatResponse

  # Ensure atoms exist for safe_to_atom tests
  _ = :think
  _ = :reflect
  _ = :wait
  _ = :introspect
  _ = :consolidate
  _ = :memory_index
  _ = :check_health
  # For proposal decisions
  _ = :accept
  _ = :reject
  _ = :defer
  # For identity insights
  _ = :capability
  _ = :skill
  _ = :trait
  _ = :personality
  _ = :value

  describe "parse/1 with nil and empty" do
    test "nil returns empty response" do
      result = HeartbeatResponse.parse(nil)
      assert result.thinking == ""
      assert result.actions == []
      assert result.memory_notes == []
      assert result.concerns == []
      assert result.curiosity == []
      assert result.goal_updates == []
      assert result.new_goals == []
      assert result.proposal_decisions == []
      assert result.decompositions == []
      assert result.identity_insights == []
    end

    test "empty string returns empty response" do
      assert HeartbeatResponse.parse("") == HeartbeatResponse.empty_response()
    end
  end

  describe "parse/1 with valid JSON" do
    test "parses minimal valid JSON" do
      json = Jason.encode!(%{"thinking" => "hello world"})
      result = HeartbeatResponse.parse(json)
      assert result.thinking == "hello world"
      assert result.actions == []
    end

    test "parses full response with all fields" do
      json =
        Jason.encode!(%{
          "thinking" => "I should check things",
          "actions" => [%{"type" => "think", "params" => %{"topic" => "goals"}, "reasoning" => "need to plan"}],
          "memory_notes" => ["observation one"],
          "concerns" => ["risk A"],
          "curiosity" => ["what about X?"],
          "goal_updates" => [%{"goal_id" => "g1", "progress" => 0.5, "note" => "halfway"}],
          "new_goals" => [%{"description" => "learn Elixir", "priority" => "high", "success_criteria" => "pass test"}],
          "proposal_decisions" => [%{"proposal_id" => "p1", "decision" => "accept", "reason" => "looks good"}],
          "decompositions" => [],
          "identity_insights" => [%{"category" => "capability", "content" => "I can code", "confidence" => 0.9}]
        })

      result = HeartbeatResponse.parse(json)
      assert result.thinking == "I should check things"
      assert length(result.actions) == 1
      assert hd(result.actions).type == :think
      assert hd(result.actions).params == %{"topic" => "goals"}
      assert result.memory_notes == ["observation one"]
      assert result.concerns == ["risk A"]
      assert result.curiosity == ["what about X?"]
      assert length(result.goal_updates) == 1
      assert hd(result.goal_updates).progress == 0.5
      assert length(result.new_goals) == 1
      assert hd(result.new_goals).description == "learn Elixir"
      assert hd(result.new_goals).priority == :high
      assert length(result.proposal_decisions) == 1
      assert hd(result.proposal_decisions).decision == :accept
      assert length(result.identity_insights) == 1
      assert hd(result.identity_insights).category == :capability
    end
  end

  describe "parse/1 with markdown code blocks" do
    test "extracts JSON from ```json code block" do
      text = """
      ```json
      {"thinking": "from code block", "actions": []}
      ```
      """

      result = HeartbeatResponse.parse(text)
      assert result.thinking == "from code block"
    end

    test "extracts JSON from bare ``` code block" do
      text = """
      ```
      {"thinking": "bare block", "actions": []}
      ```
      """

      result = HeartbeatResponse.parse(text)
      assert result.thinking == "bare block"
    end
  end

  describe "parse/1 with non-JSON text" do
    test "treats plain text as thinking-only" do
      result = HeartbeatResponse.parse("I'm just thinking about things")
      assert result.thinking == "I'm just thinking about things"
      assert result.actions == []
      assert result.memory_notes == []
    end

    test "treats malformed JSON as thinking-only" do
      result = HeartbeatResponse.parse("{broken json here")
      assert result.thinking == "{broken json here"
      assert result.actions == []
    end
  end

  describe "parse/1 CRLF line endings" do
    test "handles CRLF in code blocks" do
      text = "```json\r\n{\"thinking\": \"crlf test\"}\r\n```"
      result = HeartbeatResponse.parse(text)
      assert result.thinking == "crlf test"
    end
  end

  describe "parse_actions" do
    test "parses action with type key" do
      json = Jason.encode!(%{"actions" => [%{"type" => "reflect", "params" => %{}, "reasoning" => "need reflection"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{type: :reflect, params: %{}, reasoning: "need reflection"}] = result.actions
    end

    test "parses action with action key instead of type" do
      json = Jason.encode!(%{"actions" => [%{"action" => "think", "params" => %{}}]})
      result = HeartbeatResponse.parse(json)
      assert [%{type: :think}] = result.actions
    end

    test "defaults params and reasoning when missing" do
      json = Jason.encode!(%{"actions" => [%{"type" => "think"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{type: :think, params: %{}, reasoning: ""}] = result.actions
    end

    test "rejects non-map actions" do
      json = Jason.encode!(%{"actions" => ["not a map", 42, nil]})
      result = HeartbeatResponse.parse(json)
      assert result.actions == []
    end

    test "returns empty list when actions is not a list" do
      json = Jason.encode!(%{"actions" => "not a list"})
      result = HeartbeatResponse.parse(json)
      assert result.actions == []
    end

    test "unknown action type becomes :unknown" do
      json = Jason.encode!(%{"actions" => [%{"type" => "totally_unknown_xyz_123"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{type: :unknown}] = result.actions
    end
  end

  describe "parse_memory_notes" do
    test "parses plain string notes" do
      json = Jason.encode!(%{"memory_notes" => ["note one", "note two"]})
      result = HeartbeatResponse.parse(json)
      assert result.memory_notes == ["note one", "note two"]
    end

    test "parses map notes with text and referenced_date" do
      json = Jason.encode!(%{"memory_notes" => [%{"text" => "deploy happened", "referenced_date" => "2026-02-20"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{"text" => "deploy happened", "referenced_date" => "2026-02-20"}] = result.memory_notes
    end

    test "normalizes map note without referenced_date to plain text" do
      json = Jason.encode!(%{"memory_notes" => [%{"text" => "just a note"}]})
      result = HeartbeatResponse.parse(json)
      assert result.memory_notes == ["just a note"]
    end

    test "filters out empty strings" do
      json = Jason.encode!(%{"memory_notes" => ["", "valid note", ""]})
      result = HeartbeatResponse.parse(json)
      assert result.memory_notes == ["valid note"]
    end

    test "filters out non-string non-map items" do
      json = Jason.encode!(%{"memory_notes" => [42, true, nil, "valid"]})
      result = HeartbeatResponse.parse(json)
      assert result.memory_notes == ["valid"]
    end

    test "returns empty list when not a list" do
      json = Jason.encode!(%{"memory_notes" => "not a list"})
      result = HeartbeatResponse.parse(json)
      assert result.memory_notes == []
    end
  end

  describe "parse_goal_updates" do
    test "parses valid goal update" do
      json = Jason.encode!(%{"goal_updates" => [%{"goal_id" => "g1", "progress" => 0.75, "note" => "good progress"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{goal_id: "g1", progress: 0.75, note: "good progress"}] = result.goal_updates
    end

    test "converts integer progress (0-100) to float" do
      json = Jason.encode!(%{"goal_updates" => [%{"goal_id" => "g1", "progress" => 50}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.goal_updates).progress == 0.5
    end

    test "returns nil progress for out-of-range values" do
      json = Jason.encode!(%{"goal_updates" => [%{"goal_id" => "g1", "progress" => 200}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.goal_updates).progress == nil
    end

    test "returns nil progress for string progress" do
      json = Jason.encode!(%{"goal_updates" => [%{"goal_id" => "g1", "progress" => "halfway"}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.goal_updates).progress == nil
    end

    test "defaults note to empty string" do
      json = Jason.encode!(%{"goal_updates" => [%{"goal_id" => "g1", "progress" => 0.5}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.goal_updates).note == ""
    end
  end

  describe "parse_new_goals" do
    test "parses valid new goal" do
      json = Jason.encode!(%{"new_goals" => [%{"description" => "learn OTP", "priority" => "high", "success_criteria" => "build GenServer"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{description: "learn OTP", priority: :high, success_criteria: "build GenServer"}] = result.new_goals
    end

    test "parses priority values" do
      for {input, expected} <- [{"high", :high}, {"medium", :medium}, {"low", :low}, {"unknown", :medium}, {nil, :medium}] do
        json = Jason.encode!(%{"new_goals" => [%{"description" => "test", "priority" => input}]})
        result = HeartbeatResponse.parse(json)
        assert hd(result.new_goals).priority == expected, "Expected #{inspect(expected)} for input #{inspect(input)}"
      end
    end

    test "rejects goals without description" do
      json = Jason.encode!(%{"new_goals" => [%{"priority" => "high"}]})
      result = HeartbeatResponse.parse(json)
      assert result.new_goals == []
    end

    test "rejects goals with empty description" do
      json = Jason.encode!(%{"new_goals" => [%{"description" => "   ", "priority" => "high"}]})
      result = HeartbeatResponse.parse(json)
      assert result.new_goals == []
    end

    test "limits to 3 goals" do
      goals = Enum.map(1..5, &%{"description" => "goal #{&1}", "priority" => "medium"})
      json = Jason.encode!(%{"new_goals" => goals})
      result = HeartbeatResponse.parse(json)
      assert length(result.new_goals) == 3
    end
  end

  describe "parse_proposal_decisions" do
    test "parses accept decision" do
      json = Jason.encode!(%{"proposal_decisions" => [%{"proposal_id" => "p1", "decision" => "accept", "reason" => "good idea"}]})
      result = HeartbeatResponse.parse(json)
      assert [%{proposal_id: "p1", decision: :accept, reason: "good idea"}] = result.proposal_decisions
    end

    test "parses reject and defer decisions" do
      json = Jason.encode!(%{"proposal_decisions" => [
        %{"proposal_id" => "p1", "decision" => "reject", "reason" => "bad"},
        %{"proposal_id" => "p2", "decision" => "defer", "reason" => "later"}
      ]})
      result = HeartbeatResponse.parse(json)
      assert length(result.proposal_decisions) == 2
      assert Enum.at(result.proposal_decisions, 0).decision == :reject
      assert Enum.at(result.proposal_decisions, 1).decision == :defer
    end

    test "rejects invalid decision values" do
      json = Jason.encode!(%{"proposal_decisions" => [%{"proposal_id" => "p1", "decision" => "maybe"}]})
      result = HeartbeatResponse.parse(json)
      assert result.proposal_decisions == []
    end

    test "defaults reason to empty string" do
      json = Jason.encode!(%{"proposal_decisions" => [%{"proposal_id" => "p1", "decision" => "accept"}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.proposal_decisions).reason == ""
    end
  end

  describe "parse_decompositions" do
    test "parses valid decomposition" do
      json = Jason.encode!(%{"decompositions" => [
        %{
          "goal_id" => "g1",
          "intentions" => [%{"action" => "think", "params" => %{}, "reasoning" => "plan first"}],
          "contingency" => "fallback plan"
        }
      ]})
      result = HeartbeatResponse.parse(json)
      assert [decomp] = result.decompositions
      assert decomp.goal_id == "g1"
      assert decomp.contingency == "fallback plan"
      assert length(decomp.intentions) == 1
      assert hd(decomp.intentions).action == :think
    end

    test "limits intentions to 3 per decomposition" do
      intentions = Enum.map(1..5, &%{"action" => "think", "params" => %{}, "reasoning" => "step #{&1}"})
      json = Jason.encode!(%{"decompositions" => [%{"goal_id" => "g1", "intentions" => intentions}]})
      result = HeartbeatResponse.parse(json)
      assert length(hd(result.decompositions).intentions) == 3
    end

    test "rejects decomposition without goal_id" do
      json = Jason.encode!(%{"decompositions" => [%{"intentions" => [%{"action" => "think"}]}]})
      result = HeartbeatResponse.parse(json)
      assert result.decompositions == []
    end

    test "rejects decomposition with empty intentions" do
      json = Jason.encode!(%{"decompositions" => [%{"goal_id" => "g1", "intentions" => []}]})
      result = HeartbeatResponse.parse(json)
      assert result.decompositions == []
    end

    test "rejects intentions without action" do
      json = Jason.encode!(%{"decompositions" => [%{"goal_id" => "g1", "intentions" => [%{"params" => %{}}]}]})
      result = HeartbeatResponse.parse(json)
      assert result.decompositions == []
    end

    test "parses intention with preconditions and success_criteria" do
      json = Jason.encode!(%{"decompositions" => [
        %{
          "goal_id" => "g1",
          "intentions" => [%{
            "action" => "reflect",
            "params" => %{},
            "reasoning" => "why",
            "preconditions" => "must have data",
            "success_criteria" => "insight gained"
          }]
        }
      ]})
      result = HeartbeatResponse.parse(json)
      intent = hd(hd(result.decompositions).intentions)
      assert intent.preconditions == "must have data"
      assert intent.success_criteria == "insight gained"
    end
  end

  describe "parse_identity_insights" do
    test "parses valid insight" do
      json = Jason.encode!(%{"identity_insights" => [%{"category" => "trait", "content" => "I am curious", "confidence" => 0.8}]})
      result = HeartbeatResponse.parse(json)
      assert [%{category: :trait, content: "I am curious", confidence: 0.8}] = result.identity_insights
    end

    test "defaults confidence to 0.5" do
      json = Jason.encode!(%{"identity_insights" => [%{"category" => "value", "content" => "I value honesty"}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.identity_insights).confidence == 0.5
    end

    test "converts integer confidence" do
      json = Jason.encode!(%{"identity_insights" => [%{"category" => "skill", "content" => "coding", "confidence" => 90}]})
      result = HeartbeatResponse.parse(json)
      assert hd(result.identity_insights).confidence == 0.9
    end

    test "rejects invalid categories" do
      json = Jason.encode!(%{"identity_insights" => [%{"category" => "invalid_cat", "content" => "something"}]})
      result = HeartbeatResponse.parse(json)
      assert result.identity_insights == []
    end

    test "rejects empty content" do
      json = Jason.encode!(%{"identity_insights" => [%{"category" => "trait", "content" => ""}]})
      result = HeartbeatResponse.parse(json)
      assert result.identity_insights == []
    end

    test "limits to 5 insights" do
      insights = Enum.map(1..8, &%{"category" => "trait", "content" => "insight #{&1}", "confidence" => 0.5})
      json = Jason.encode!(%{"identity_insights" => insights})
      result = HeartbeatResponse.parse(json)
      assert length(result.identity_insights) == 5
    end

    test "allows all valid categories" do
      for cat <- ~w(capability skill trait personality value) do
        json = Jason.encode!(%{"identity_insights" => [%{"category" => cat, "content" => "test #{cat}"}]})
        result = HeartbeatResponse.parse(json)
        assert length(result.identity_insights) == 1, "Category #{cat} should be accepted"
      end
    end
  end

  describe "parse_string_list (concerns and curiosity)" do
    test "parses concerns" do
      json = Jason.encode!(%{"concerns" => ["risk one", "risk two"]})
      result = HeartbeatResponse.parse(json)
      assert result.concerns == ["risk one", "risk two"]
    end

    test "parses curiosity" do
      json = Jason.encode!(%{"curiosity" => ["what if?", "how does X work?"]})
      result = HeartbeatResponse.parse(json)
      assert result.curiosity == ["what if?", "how does X work?"]
    end

    test "filters non-strings from concerns" do
      json = Jason.encode!(%{"concerns" => [42, "valid", nil, true]})
      result = HeartbeatResponse.parse(json)
      assert result.concerns == ["valid"]
    end

    test "filters empty strings" do
      json = Jason.encode!(%{"curiosity" => ["", "valid", ""]})
      result = HeartbeatResponse.parse(json)
      assert result.curiosity == ["valid"]
    end
  end

  describe "empty_response/0" do
    test "returns all expected keys" do
      resp = HeartbeatResponse.empty_response()
      assert Map.keys(resp) |> Enum.sort() ==
        [:actions, :concerns, :curiosity, :decompositions, :goal_updates,
         :identity_insights, :memory_notes, :new_goals, :proposal_decisions, :thinking]
    end
  end

  describe "known_action_types/0" do
    test "returns a list of atoms" do
      types = HeartbeatResponse.known_action_types()
      assert is_list(types)
      assert :think in types
      assert :reflect in types
      assert :consolidate in types
      assert Enum.all?(types, &is_atom/1)
    end
  end

  describe "parse/1 thinking field fallback" do
    test "falls back to full text when thinking key missing" do
      json = Jason.encode!(%{"actions" => []})
      result = HeartbeatResponse.parse(json)
      # When thinking key is missing, get_string falls back to the original text
      assert result.thinking == json
    end

    test "uses thinking field when present" do
      json = Jason.encode!(%{"thinking" => "my thoughts"})
      result = HeartbeatResponse.parse(json)
      assert result.thinking == "my thoughts"
    end
  end
end
