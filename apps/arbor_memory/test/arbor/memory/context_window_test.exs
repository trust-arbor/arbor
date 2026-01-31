defmodule Arbor.Memory.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Arbor.Memory.ContextWindow

  @moduletag :fast

  describe "new/2" do
    test "creates context window with defaults" do
      window = ContextWindow.new("agent_001")

      assert window.agent_id == "agent_001"
      assert window.entries == []
      assert window.max_tokens == 10_000
      assert window.summary_threshold == 0.7
      assert window.model_id == nil
    end

    test "accepts custom options" do
      window =
        ContextWindow.new("agent_001",
          max_tokens: 5000,
          summary_threshold: 0.8,
          model_id: "anthropic:claude-3-5-sonnet-20241022"
        )

      assert window.max_tokens == 5000
      assert window.summary_threshold == 0.8
      assert window.model_id == "anthropic:claude-3-5-sonnet-20241022"
    end
  end

  describe "add_entry/3" do
    test "adds message entry" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "Hello!")

      assert length(window.entries) == 1
      [{type, content, timestamp}] = window.entries
      assert type == :message
      assert content == "Hello!"
      assert %DateTime{} = timestamp
    end

    test "adds summary entry" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:summary, "Summary of earlier...")

      [{type, content, _}] = window.entries
      assert type == :summary
      assert content == "Summary of earlier..."
    end

    test "maintains chronological order" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "First")
        |> ContextWindow.add_entry(:message, "Second")

      contents = Enum.map(window.entries, fn {_, c, _} -> c end)
      assert contents == ["First", "Second"]
    end
  end

  describe "add_entries/2" do
    test "adds multiple entries at once" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entries([
          {:message, "One"},
          {:message, "Two"},
          {:message, "Three"}
        ])

      assert length(window.entries) == 3
    end
  end

  describe "entry_count/1" do
    test "returns number of entries" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "One")
        |> ContextWindow.add_entry(:message, "Two")

      assert ContextWindow.entry_count(window) == 2
    end
  end

  describe "token_usage/1" do
    test "estimates current token usage" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, String.duplicate("word ", 100))

      usage = ContextWindow.token_usage(window)
      assert usage > 0
    end
  end

  describe "should_summarize?/1" do
    test "returns false when under threshold" do
      window =
        ContextWindow.new("agent_001", max_tokens: 10_000)
        |> ContextWindow.add_entry(:message, "Short message")

      refute ContextWindow.should_summarize?(window)
    end

    test "returns true when over threshold" do
      # Create a window with very low max_tokens
      window =
        ContextWindow.new("agent_001", max_tokens: 10, summary_threshold: 0.5)
        |> ContextWindow.add_entry(:message, String.duplicate("word ", 50))

      assert ContextWindow.should_summarize?(window)
    end
  end

  describe "remaining_capacity/1" do
    test "returns remaining token capacity" do
      window =
        ContextWindow.new("agent_001", max_tokens: 1000)
        |> ContextWindow.add_entry(:message, "Short")

      capacity = ContextWindow.remaining_capacity(window)
      assert capacity > 0
      assert capacity < 1000
    end
  end

  describe "apply_summary/3" do
    test "replaces old entries with summary" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "Msg 1")
        |> ContextWindow.add_entry(:message, "Msg 2")
        |> ContextWindow.add_entry(:message, "Msg 3")
        |> ContextWindow.add_entry(:message, "Msg 4")
        |> ContextWindow.add_entry(:message, "Msg 5")

      summarized = ContextWindow.apply_summary(window, "Summary of messages 1-2", keep_recent: 3)

      # Should have summary + 3 recent = 4 entries
      assert length(summarized.entries) == 4

      # First should be summary
      [{type, content, _} | _] = summarized.entries
      assert type == :summary
      assert content == "Summary of messages 1-2"
    end

    test "keeps window unchanged if not enough entries" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "Only one")

      summarized = ContextWindow.apply_summary(window, "Summary", keep_recent: 3)

      assert window == summarized
    end
  end

  describe "entries_to_summarize/2" do
    test "returns older entries that would be summarized" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "Msg 1")
        |> ContextWindow.add_entry(:message, "Msg 2")
        |> ContextWindow.add_entry(:message, "Msg 3")
        |> ContextWindow.add_entry(:message, "Msg 4")

      to_summarize = ContextWindow.entries_to_summarize(window, keep_recent: 2)

      assert length(to_summarize) == 2
      contents = Enum.map(to_summarize, fn {_, c, _} -> c end)
      assert contents == ["Msg 1", "Msg 2"]
    end
  end

  describe "content_to_summarize/2" do
    test "returns concatenated text of older entries" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "First message")
        |> ContextWindow.add_entry(:message, "Second message")
        |> ContextWindow.add_entry(:message, "Third message")

      text = ContextWindow.content_to_summarize(window, keep_recent: 1)

      assert text =~ "First message"
      assert text =~ "Second message"
      refute text =~ "Third message"
    end
  end

  describe "to_prompt_text/1" do
    test "renders entries as text" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "User: Hello")
        |> ContextWindow.add_entry(:message, "Assistant: Hi there!")

      text = ContextWindow.to_prompt_text(window)

      assert text =~ "User: Hello"
      assert text =~ "Assistant: Hi there!"
    end

    test "prefixes summaries" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:summary, "Earlier conversation summary")
        |> ContextWindow.add_entry(:message, "New message")

      text = ContextWindow.to_prompt_text(window)

      assert text =~ "[Previous Context Summary]"
      assert text =~ "Earlier conversation summary"
    end
  end

  describe "to_entries_list/1" do
    test "returns entries as list of maps" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "Hello")

      entries = ContextWindow.to_entries_list(window)

      assert length(entries) == 1
      [entry] = entries
      assert entry.type == :message
      assert entry.content == "Hello"
      assert is_binary(entry.timestamp)
    end
  end

  describe "stats/1" do
    test "returns comprehensive stats" do
      window =
        ContextWindow.new("agent_001", max_tokens: 10_000)
        |> ContextWindow.add_entry(:summary, "Summary")
        |> ContextWindow.add_entry(:message, "Msg 1")
        |> ContextWindow.add_entry(:message, "Msg 2")

      stats = ContextWindow.stats(window)

      assert stats.agent_id == "agent_001"
      assert stats.entry_count == 3
      assert stats.message_count == 2
      assert stats.summary_count == 1
      assert stats.max_tokens == 10_000
      assert is_integer(stats.token_usage)
      assert is_float(stats.utilization)
      assert is_boolean(stats.should_summarize)
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips correctly" do
      original =
        ContextWindow.new("agent_001", max_tokens: 5000, summary_threshold: 0.8)
        |> ContextWindow.add_entry(:summary, "Summary")
        |> ContextWindow.add_entry(:message, "Message 1")
        |> ContextWindow.add_entry(:message, "Message 2")

      serialized = ContextWindow.serialize(original)
      deserialized = ContextWindow.deserialize(serialized)

      assert deserialized.agent_id == original.agent_id
      assert deserialized.max_tokens == original.max_tokens
      assert deserialized.summary_threshold == original.summary_threshold
      assert length(deserialized.entries) == length(original.entries)

      # Check entry types preserved
      types = Enum.map(deserialized.entries, fn {t, _, _} -> t end)
      assert types == [:summary, :message, :message]
    end

    test "serialize produces JSON-safe map" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "Test")

      serialized = ContextWindow.serialize(window)

      assert is_map(serialized)
      assert Map.has_key?(serialized, "agent_id")
      assert Map.has_key?(serialized, "entries")
    end
  end

  describe "clear/1" do
    test "clears all entries" do
      window =
        ContextWindow.new("agent_001")
        |> ContextWindow.add_entry(:message, "One")
        |> ContextWindow.add_entry(:message, "Two")
        |> ContextWindow.clear()

      assert window.entries == []
    end
  end
end
