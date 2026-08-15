defmodule Arbor.Common.Sessions.ContentEdgeCasesTest do
  @moduledoc """
  Additional edge case tests for Content module to improve coverage.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Content
  alias Arbor.Common.Sessions.Record

  describe "thinking_text/1 edge cases" do
    test "handles thinking blocks with nil text" do
      record = %Record{
        content: [
          %{type: :thinking, text: "Valid thought"},
          %{type: :thinking, text: nil},
          %{type: :thinking, text: "Another thought"}
        ]
      }

      assert Content.thinking_text(record) == "Valid thought\nAnother thought"
    end

    test "returns empty string when content is empty" do
      record = %Record{content: []}
      assert Content.thinking_text(record) == ""
    end
  end

  describe "tools_used/1 edge cases" do
    test "handles tool_use items with nil tool_name" do
      records = [
        %Record{content: [%{type: :tool_use, tool_name: nil}]},
        %Record{content: [%{type: :tool_use, tool_name: "Bash"}]}
      ]

      assert Content.tools_used(records) == ["Bash"]
    end

    test "handles empty records list" do
      assert Content.tools_used([]) == []
    end
  end

  describe "conversation_pairs/1 edge cases" do
    test "handles list with only assistant messages (no pairs)" do
      records = [
        %Record{type: :assistant, text: "Answer 1"},
        %Record{type: :assistant, text: "Answer 2"}
      ]

      pairs = Content.conversation_pairs(records)
      assert pairs == []
    end

    test "handles single user message without assistant follow-up" do
      records = [
        %Record{type: :user, text: "Question"}
      ]

      pairs = Content.conversation_pairs(records)
      assert pairs == []
    end

    test "handles interleaved non-message records correctly" do
      records = [
        %Record{type: :user, text: "Q1"},
        %Record{type: :progress},
        %Record{type: :assistant, text: "A1"},
        %Record{type: :summary},
        %Record{type: :user, text: "Q2"},
        %Record{type: :assistant, text: "A2"}
      ]

      pairs = Content.conversation_pairs(records)
      assert length(pairs) == 2
    end

    test "handles empty list" do
      assert Content.conversation_pairs([]) == []
    end
  end

  describe "token_count/1 edge cases" do
    test "handles usage with missing token fields" do
      record = %Record{usage: %{}}

      counts = Content.token_count(record)
      assert counts.input == 0
      assert counts.output == 0
      assert counts.total == 0
    end

    test "handles usage with only input tokens" do
      record = %Record{usage: %{"input_tokens" => 500}}

      counts = Content.token_count(record)
      assert counts.input == 500
      assert counts.output == 0
      assert counts.total == 500
    end
  end

  describe "total_tokens/1 edge cases" do
    test "handles list of records all with nil usage" do
      records = [
        %Record{usage: nil},
        %Record{usage: nil}
      ]

      totals = Content.total_tokens(records)
      assert totals == %{input: 0, output: 0, total: 0}
    end
  end

  describe "messages/1 edge cases" do
    test "handles empty list" do
      assert Content.messages([]) == []
    end

    test "filters out all non-message types" do
      records = [
        %Record{type: :progress},
        %Record{type: :queue_operation},
        %Record{type: :summary},
        %Record{type: :file_history_snapshot},
        %Record{type: :unknown}
      ]

      assert Content.messages(records) == []
    end
  end

  describe "find_by_tool_use_id/2 edge cases" do
    test "handles empty content list" do
      record = %Record{content: []}
      assert Content.find_by_tool_use_id(record, "any-id") == nil
    end

    test "handles content items without tool_use_id key" do
      record = %Record{
        content: [
          %{type: :text, text: "Hello"},
          %{type: :thinking, text: "Hmm"}
        ]
      }

      assert Content.find_by_tool_use_id(record, "some-id") == nil
    end
  end
end
