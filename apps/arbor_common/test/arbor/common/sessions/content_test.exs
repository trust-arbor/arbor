defmodule Arbor.Common.Sessions.ContentTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Common.Sessions.Content
  alias Arbor.Common.Sessions.Record

  describe "text/1" do
    test "returns the text field" do
      record = %Record{text: "Hello, world!"}
      assert Content.text(record) == "Hello, world!"
    end

    test "returns empty string when text is empty" do
      record = %Record{text: ""}
      assert Content.text(record) == ""
    end
  end

  describe "tool_uses/1" do
    test "extracts tool use items" do
      record = %Record{
        content: [
          %{type: :text, text: "I'll help"},
          %{type: :tool_use, tool_name: "Bash", tool_use_id: "123"},
          %{type: :tool_use, tool_name: "Read", tool_use_id: "456"}
        ]
      }

      tool_uses = Content.tool_uses(record)
      assert length(tool_uses) == 2
      assert Enum.all?(tool_uses, &(&1.type == :tool_use))
    end

    test "returns empty list when no tool uses" do
      record = %Record{content: [%{type: :text, text: "Hello"}]}
      assert Content.tool_uses(record) == []
    end
  end

  describe "tool_results/1" do
    test "extracts tool result items" do
      record = %Record{
        content: [
          %{type: :tool_result, tool_use_id: "123", tool_result: "success"},
          %{type: :text, text: "Done"}
        ]
      }

      results = Content.tool_results(record)
      assert length(results) == 1
      assert hd(results).tool_result == "success"
    end
  end

  describe "thinking/1" do
    test "extracts thinking blocks" do
      record = %Record{
        content: [
          %{type: :thinking, text: "Let me think..."},
          %{type: :text, text: "Here's my answer"}
        ]
      }

      thinking = Content.thinking(record)
      assert length(thinking) == 1
      assert hd(thinking).text == "Let me think..."
    end
  end

  describe "thinking_text/1" do
    test "joins thinking blocks with newlines" do
      record = %Record{
        content: [
          %{type: :thinking, text: "First thought"},
          %{type: :text, text: "Answer"},
          %{type: :thinking, text: "Second thought"}
        ]
      }

      assert Content.thinking_text(record) == "First thought\nSecond thought"
    end

    test "returns empty string when no thinking" do
      record = %Record{content: [%{type: :text, text: "Answer"}]}
      assert Content.thinking_text(record) == ""
    end
  end

  describe "has_tool_use?/1" do
    test "returns true when record has tool use" do
      record = %Record{content: [%{type: :tool_use, tool_name: "Bash"}]}
      assert Content.has_tool_use?(record)
    end

    test "returns false when record has no tool use" do
      record = %Record{content: [%{type: :text, text: "Hello"}]}
      refute Content.has_tool_use?(record)
    end
  end

  describe "has_thinking?/1" do
    test "returns true when record has thinking" do
      record = %Record{content: [%{type: :thinking, text: "Hmm..."}]}
      assert Content.has_thinking?(record)
    end

    test "returns false when record has no thinking" do
      record = %Record{content: [%{type: :text, text: "Hello"}]}
      refute Content.has_thinking?(record)
    end
  end

  describe "tools_used/1" do
    test "returns unique sorted tool names" do
      records = [
        %Record{content: [%{type: :tool_use, tool_name: "Bash"}]},
        %Record{content: [%{type: :tool_use, tool_name: "Read"}]},
        %Record{content: [%{type: :tool_use, tool_name: "Bash"}]},
        %Record{content: [%{type: :tool_use, tool_name: "Edit"}]}
      ]

      assert Content.tools_used(records) == ["Bash", "Edit", "Read"]
    end

    test "returns empty list when no tools used" do
      records = [%Record{content: [%{type: :text, text: "Hello"}]}]
      assert Content.tools_used(records) == []
    end
  end

  describe "conversation_pairs/1" do
    test "pairs user and assistant messages" do
      records = [
        %Record{type: :user, text: "Question 1"},
        %Record{type: :assistant, text: "Answer 1"},
        %Record{type: :user, text: "Question 2"},
        %Record{type: :assistant, text: "Answer 2"}
      ]

      pairs = Content.conversation_pairs(records)
      assert length(pairs) == 2

      {user1, assistant1} = hd(pairs)
      assert user1.text == "Question 1"
      assert assistant1.text == "Answer 1"
    end

    test "handles unpaired messages" do
      records = [
        %Record{type: :user, text: "Question"},
        %Record{type: :user, text: "Another question"}
      ]

      pairs = Content.conversation_pairs(records)
      assert pairs == []
    end

    test "filters out non-message records" do
      records = [
        %Record{type: :progress},
        %Record{type: :user, text: "Question"},
        %Record{type: :progress},
        %Record{type: :assistant, text: "Answer"}
      ]

      pairs = Content.conversation_pairs(records)
      assert length(pairs) == 1
    end
  end

  describe "messages/1" do
    test "filters to only message records" do
      records = [
        %Record{type: :user},
        %Record{type: :progress},
        %Record{type: :assistant},
        %Record{type: :summary}
      ]

      messages = Content.messages(records)
      assert length(messages) == 2
      assert Enum.all?(messages, &Record.message?/1)
    end
  end

  describe "user_messages/1" do
    test "filters to only user messages" do
      records = [
        %Record{type: :user},
        %Record{type: :assistant},
        %Record{type: :user}
      ]

      user_msgs = Content.user_messages(records)
      assert length(user_msgs) == 2
      assert Enum.all?(user_msgs, &Record.user?/1)
    end
  end

  describe "assistant_messages/1" do
    test "filters to only assistant messages" do
      records = [
        %Record{type: :user},
        %Record{type: :assistant},
        %Record{type: :assistant}
      ]

      assistant_msgs = Content.assistant_messages(records)
      assert length(assistant_msgs) == 2
      assert Enum.all?(assistant_msgs, &Record.assistant?/1)
    end
  end

  describe "token_count/1" do
    test "extracts token counts from usage" do
      record = %Record{
        usage: %{"input_tokens" => 100, "output_tokens" => 50}
      }

      counts = Content.token_count(record)
      assert counts.input == 100
      assert counts.output == 50
      assert counts.total == 150
    end

    test "returns nil when no usage" do
      record = %Record{usage: nil}
      assert Content.token_count(record) == nil
    end
  end

  describe "total_tokens/1" do
    test "sums token usage across records" do
      records = [
        %Record{usage: %{"input_tokens" => 100, "output_tokens" => 50}},
        %Record{usage: nil},
        %Record{usage: %{"input_tokens" => 200, "output_tokens" => 100}}
      ]

      totals = Content.total_tokens(records)
      assert totals.input == 300
      assert totals.output == 150
      assert totals.total == 450
    end

    test "returns zeros for empty list" do
      totals = Content.total_tokens([])
      assert totals == %{input: 0, output: 0, total: 0}
    end
  end

  describe "find_by_tool_use_id/2" do
    test "finds content item by tool_use_id" do
      record = %Record{
        content: [
          %{type: :tool_use, tool_use_id: "123", tool_name: "Bash"},
          %{type: :tool_use, tool_use_id: "456", tool_name: "Read"}
        ]
      }

      item = Content.find_by_tool_use_id(record, "456")
      assert item.tool_name == "Read"
    end

    test "returns nil when not found" do
      record = %Record{content: [%{type: :text, text: "Hello"}]}
      assert Content.find_by_tool_use_id(record, "nonexistent") == nil
    end
  end
end
