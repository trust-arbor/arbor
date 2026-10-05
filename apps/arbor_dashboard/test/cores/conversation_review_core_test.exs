defmodule Arbor.Dashboard.ConversationReviewCoreTest do
  use ExUnit.Case, async: true
  alias Arbor.Dashboard.ConversationReviewCore, as: Core
  @moduletag :fast
  @scope {"human_one", "agent_one", "eng_one"}
  @prompt %{
    "command_id" => "command",
    "request_id" => "request",
    "operation_id" => "operation",
    "revision" => 1,
    "protected" => true,
    "actionable" => true,
    "status" => "pending"
  }
  @input %{
    command_id: "command",
    request_id: "request",
    operation_id: "operation",
    revision: 1,
    decision: "rework",
    note: "Retain 東京 🌲"
  }

  test "unchanged exact pending identity retains user review across observations" do
    current = Core.sync(Core.new(), @scope, [@prompt], true)
    assert {:ok, edited} = Core.edit(current, @input)
    again = Core.sync(edited, @scope, [@prompt], true)
    assert Core.show(again, @prompt) == %{decision: "rework", note: "Retain 東京 🌲"}
  end

  test "security regression: scope and every exact prompt selector fences private review retention" do
    current = Core.sync(Core.new(), @scope, [@prompt], true)
    {:ok, edited} = Core.edit(current, @input)

    for scope <- [
          {"human_two", "agent_one", "eng_one"},
          {"human_one", "agent_two", "eng_one"},
          {"human_one", "agent_one", "eng_two"}
        ] do
      assert Core.show(Core.sync(edited, scope, [@prompt], true), @prompt) == %{
               decision: "",
               note: ""
             }
    end

    for {field, value} <- [
          {"command_id", "next_command"},
          {"request_id", "next_request"},
          {"operation_id", "next_operation"},
          {"revision", 2}
        ] do
      next = Map.put(@prompt, field, value)
      replaced = Core.sync(edited, @scope, [next], true)
      assert Core.show(replaced, next) == %{decision: "", note: ""}
      assert {:error, :invalid_review_draft} = Core.edit(replaced, @input)
    end

    assert Core.sync(edited, @scope, [@prompt], false) == Core.new()
    assert Core.sync(edited, @scope, [], true).drafts == %{}

    assert Core.sync(edited, @scope, [Map.put(@prompt, "status", "responded")], true).drafts ==
             %{}
  end

  test "closed current membership and UTF-8 byte bounds reject malformed local edits" do
    current = Core.sync(Core.new(), @scope, [@prompt], true)

    for rejected <- [
          Map.put(@input, :decision, "auto"),
          Map.put(@input, :note, <<255>>),
          Map.put(@input, :note, String.duplicate("x", 4097)),
          Map.put(@input, :session_token, "forged"),
          Map.put(@input, :revision, 2)
        ] do
      assert {:error, :invalid_review_draft} = Core.edit(current, rejected)
      assert Core.show(current, @prompt) == %{decision: "", note: ""}
    end

    assert {:ok, _} = Core.edit(current, Map.put(@input, :note, String.duplicate("x", 4096)))
    assert Core.sync(current, @scope, List.duplicate(@prompt, 51), true) == Core.new()
    assert Core.sync(current, @scope, [nil, "not a prompt"], true).drafts == %{}
  end
end
