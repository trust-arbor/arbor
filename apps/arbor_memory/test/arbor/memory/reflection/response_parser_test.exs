defmodule Arbor.Memory.Reflection.ResponseParserTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Memory.Reflection.ResponseParser

  describe "parse_reflection_response/1" do
    test "parses valid JSON response" do
      json = ~s({"thinking": "I reflected.", "goal_updates": [{"goal_id": "g1", "new_progress": 0.5}]})
      assert {:ok, result} = ResponseParser.parse_reflection_response(json)
      assert result.thinking == "I reflected."
      assert length(result.goal_updates) == 1
      assert hd(result.goal_updates)["goal_id"] == "g1"
    end

    test "extracts JSON from markdown code fences" do
      response = """
      Here is my reflection:

      ```json
      {"thinking": "deep thought", "insights": [{"content": "pattern found", "importance": 0.8}]}
      ```
      """

      assert {:ok, result} = ResponseParser.parse_reflection_response(response)
      assert result.thinking == "deep thought"
      assert length(result.insights) == 1
    end

    test "extracts JSON from code fence without language tag" do
      response = """
      ```
      {"thinking": "no tag", "learnings": []}
      ```
      """

      assert {:ok, result} = ResponseParser.parse_reflection_response(response)
      assert result.thinking == "no tag"
    end

    test "returns empty response on malformed JSON" do
      assert {:ok, result} = ResponseParser.parse_reflection_response("not json at all")
      assert result == ResponseParser.empty_parsed_response()
    end

    test "returns empty response on partial JSON" do
      assert {:ok, result} = ResponseParser.parse_reflection_response("{\"thinking\": ")
      assert result == ResponseParser.empty_parsed_response()
    end

    test "normalizes missing fields to empty lists" do
      json = ~s({"thinking": "minimal"})
      assert {:ok, result} = ResponseParser.parse_reflection_response(json)
      assert result.goal_updates == []
      assert result.new_goals == []
      assert result.insights == []
      assert result.learnings == []
      assert result.knowledge_nodes == []
      assert result.knowledge_edges == []
      assert result.self_insight_suggestions == []
      assert result.relationships == []
    end

    test "preserves all fields when present" do
      json =
        Jason.encode!(%{
          "thinking" => "full response",
          "goal_updates" => [%{"goal_id" => "g1"}],
          "new_goals" => [%{"description" => "new"}],
          "insights" => [%{"content" => "x"}],
          "learnings" => [%{"content" => "y"}],
          "knowledge_nodes" => [%{"name" => "n"}],
          "knowledge_edges" => [%{"from" => "a", "to" => "b"}],
          "self_insight_suggestions" => [%{"content" => "z"}],
          "relationships" => [%{"entity" => "e"}]
        })

      assert {:ok, result} = ResponseParser.parse_reflection_response(json)
      assert result.thinking == "full response"
      assert length(result.goal_updates) == 1
      assert length(result.new_goals) == 1
      assert length(result.insights) == 1
      assert length(result.learnings) == 1
      assert length(result.knowledge_nodes) == 1
      assert length(result.knowledge_edges) == 1
      assert length(result.self_insight_suggestions) == 1
      assert length(result.relationships) == 1
    end
  end

  describe "empty_parsed_response/0" do
    test "returns map with all expected keys" do
      empty = ResponseParser.empty_parsed_response()
      assert is_map(empty)
      assert Map.has_key?(empty, :goal_updates)
      assert Map.has_key?(empty, :new_goals)
      assert Map.has_key?(empty, :insights)
      assert Map.has_key?(empty, :learnings)
      assert Map.has_key?(empty, :knowledge_nodes)
      assert Map.has_key?(empty, :knowledge_edges)
      assert Map.has_key?(empty, :self_insight_suggestions)
      assert Map.has_key?(empty, :relationships)
      assert Map.has_key?(empty, :thinking)
    end

    test "all list fields are empty" do
      empty = ResponseParser.empty_parsed_response()
      assert empty.goal_updates == []
      assert empty.new_goals == []
      assert empty.insights == []
      assert empty.learnings == []
    end

    test "thinking is nil" do
      assert ResponseParser.empty_parsed_response().thinking == nil
    end
  end
end
