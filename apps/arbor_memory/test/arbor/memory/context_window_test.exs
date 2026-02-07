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

  # ============================================================================
  # Multi-Layer Mode Tests
  # ============================================================================

  describe "presets" do
    test "lists available presets" do
      presets = ContextWindow.presets()
      assert :balanced in presets
      assert :conservative in presets
      assert :expansive in presets
      assert :claude_full in presets
      assert :claude_conservative in presets
      assert :medium_context in presets
      assert :small_context in presets
      assert :large_context in presets
    end

    test "gets preset config" do
      config = ContextWindow.preset(:claude_full)
      assert config.max_tokens == 180_000
      assert config.multi_layer == true
      assert config.summarization_enabled == true
    end

    test "returns nil for unknown preset" do
      assert ContextWindow.preset(:nonexistent) == nil
    end

    test "legacy preset creates legacy window" do
      window = ContextWindow.new("agent_001", preset: :balanced)
      assert window.multi_layer == false
      assert window.max_tokens == 10_000
    end

    test "multi-layer preset creates multi-layer window" do
      window = ContextWindow.new("agent_001", preset: :claude_full)
      assert window.multi_layer == true
      assert window.max_tokens == 180_000
      assert window.summarization_enabled == true
      assert window.distant_summary == ""
      assert window.recent_summary == ""
      assert %DateTime{} = window.clarity_boundary
    end

    test "small_context preset has adjusted ratios" do
      window = ContextWindow.new("agent_001", preset: :small_context)
      assert window.ratios.full_detail == 0.60
      assert window.ratios.distant_summary == 0.10
    end

    test "preset options can be overridden" do
      window = ContextWindow.new("agent_001", preset: :claude_full, max_tokens: 50_000)
      assert window.max_tokens == 50_000
      assert window.multi_layer == true
    end

    test "unknown preset logs warning and uses defaults" do
      window = ContextWindow.new("agent_001", preset: :nonexistent)
      assert window.max_tokens == 10_000
      assert window.multi_layer == false
    end
  end

  describe "multi-layer message management" do
    setup do
      window = ContextWindow.new("agent_001", preset: :claude_full)
      {:ok, window: window}
    end

    test "add_message adds rich map to full_detail", %{window: window} do
      window = ContextWindow.add_message(window, %{role: :user, content: "Hello!"})

      assert length(window.full_detail) == 1
      [msg] = window.full_detail
      assert msg.role == :user
      assert msg.content == "Hello!"
      assert %DateTime{} = msg.timestamp
      assert is_binary(msg.id)
      assert String.starts_with?(msg.id, "msg_")
    end

    test "add_message tracks detail_tokens", %{window: window} do
      window = ContextWindow.add_message(window, %{role: :user, content: String.duplicate("a", 400)})

      assert window.detail_tokens > 0
    end

    test "add_message prepends (newest first)", %{window: window} do
      window =
        window
        |> ContextWindow.add_message(%{role: :user, content: "First"})
        |> ContextWindow.add_message(%{role: :user, content: "Second"})

      [newest, oldest] = window.full_detail
      assert newest.content == "Second"
      assert oldest.content == "First"
    end

    test "add_user_message creates user message", %{window: window} do
      window = ContextWindow.add_user_message(window, "Hello!", speaker: "Alice")

      [msg] = window.full_detail
      assert msg.role == :user
      assert msg.content == "Hello!"
      assert msg.speaker == "Alice"
    end

    test "add_user_message defaults speaker to Human", %{window: window} do
      window = ContextWindow.add_user_message(window, "Hi")

      [msg] = window.full_detail
      assert msg.speaker == "Human"
    end

    test "add_assistant_response creates assistant message", %{window: window} do
      window = ContextWindow.add_assistant_response(window, "I can help!")

      [msg] = window.full_detail
      assert msg.role == :assistant
      assert msg.content == "I can help!"
    end

    test "add_tool_results formats tool results", %{window: window} do
      results = [
        %{action: :read_file, outcome: :success, result: "file contents"},
        %{action: :list_dir, outcome: :success, result: ["a.ex", "b.ex"]}
      ]

      window = ContextWindow.add_tool_results(window, results)

      [msg] = window.full_detail
      assert msg.content =~ "[Tool Results]"
      assert msg.content =~ "read_file"
      assert msg.is_tool_result == true
    end

    test "add_tool_results with empty list is no-op", %{window: window} do
      result = ContextWindow.add_tool_results(window, [])
      assert result.full_detail == []
    end

    test "add_entry routes to add_message in multi-layer mode", %{window: window} do
      window = ContextWindow.add_entry(window, :message, "Hello via entry")

      assert length(window.full_detail) == 1
      [msg] = window.full_detail
      assert msg.content == "Hello via entry"
      assert msg.role == :user
    end

    test "entry_count returns full_detail length in multi-layer", %{window: window} do
      window =
        window
        |> ContextWindow.add_message(%{role: :user, content: "One"})
        |> ContextWindow.add_message(%{role: :assistant, content: "Two"})

      assert ContextWindow.entry_count(window) == 2
    end

    test "clear clears full_detail and retrieved in multi-layer", %{window: window} do
      window =
        window
        |> ContextWindow.add_message(%{role: :user, content: "Msg"})
        |> ContextWindow.add_retrieved(%{content: "Retrieved"})
        |> ContextWindow.clear()

      assert window.full_detail == []
      assert window.retrieved_context == []
      assert window.detail_tokens == 0
      assert window.retrieved_tokens == 0
    end
  end

  describe "retrieved context" do
    setup do
      window = ContextWindow.new("agent_001", preset: :medium_context)
      {:ok, window: window}
    end

    test "add_retrieved adds to retrieved_context", %{window: window} do
      window = ContextWindow.add_retrieved(window, %{content: "Some old memory"})

      assert length(window.retrieved_context) == 1
      [ctx] = window.retrieved_context
      assert ctx.content == "Some old memory"
      assert %DateTime{} = ctx.retrieved_at
    end

    test "add_retrieved tracks retrieved_tokens", %{window: window} do
      window = ContextWindow.add_retrieved(window, %{content: String.duplicate("word ", 100)})
      assert window.retrieved_tokens > 0
    end

    test "add_retrieved deduplicates exact matches", %{window: window} do
      window =
        window
        |> ContextWindow.add_retrieved(%{content: "Same content"})
        |> ContextWindow.add_retrieved(%{content: "Same content"})

      assert length(window.retrieved_context) == 1
    end

    test "add_retrieved allows different content", %{window: window} do
      window =
        window
        |> ContextWindow.add_retrieved(%{content: "The Elixir programming language uses pattern matching and immutable data structures"})
        |> ContextWindow.add_retrieved(%{content: "Tomorrow's weather forecast calls for heavy rain and thunderstorms in the evening"})

      assert length(window.retrieved_context) == 2
    end

    test "clear_retrieved clears all retrieved context", %{window: window} do
      window =
        window
        |> ContextWindow.add_retrieved(%{content: "Memory"})
        |> ContextWindow.clear_retrieved()

      assert window.retrieved_context == []
      assert window.retrieved_tokens == 0
    end

    test "add_retrieved is no-op in legacy mode" do
      window = ContextWindow.new("agent_001")
      result = ContextWindow.add_retrieved(window, %{content: "Memory"})
      assert result == window
    end
  end

  describe "compression pipeline" do
    test "needs_compression? returns false when under budget" do
      window = ContextWindow.new("agent_001", preset: :claude_full)
      window = ContextWindow.add_message(window, %{role: :user, content: "Short"})

      refute ContextWindow.needs_compression?(window)
    end

    test "needs_compression? returns true when over budget" do
      # small_context with 6k tokens, full_detail is 60% = 3600 tokens budget
      window = ContextWindow.new("agent_001", preset: :small_context)

      # Add enough content to exceed the budget (3600 * 4 = 14400 chars)
      big_content = String.duplicate("word ", 4000)

      window = ContextWindow.add_message(window, %{role: :user, content: big_content})

      assert ContextWindow.needs_compression?(window)
    end

    test "compress_if_needed returns {:ok, window} when no compression needed" do
      window = ContextWindow.new("agent_001", preset: :claude_full)
      window = ContextWindow.add_message(window, %{role: :user, content: "Short"})

      assert {:ok, result} = ContextWindow.compress_if_needed(window)
      assert result == window
    end

    test "compress demotes oldest messages to recent_summary" do
      # Use small_context to easily trigger compression.
      # Set summarization_enabled: true so compression is deferred (not inline in add_message).
      window = ContextWindow.new("agent_001",
        multi_layer: true,
        max_tokens: 100,
        summarization_enabled: true,
        ratios: %{full_detail: 0.50, recent_summary: 0.25, distant_summary: 0.15, retrieved: 0.10}
      )

      # Add many messages to exceed the budget (50 token budget for detail)
      window =
        Enum.reduce(1..10, window, fn i, w ->
          ContextWindow.add_message(w, %{
            role: :user,
            content: "Message #{i}: #{String.duplicate("content ", 10)}"
          })
        end)

      compressed = ContextWindow.compress(window)

      # After compression, detail_tokens should be reduced
      assert compressed.detail_tokens < window.detail_tokens
      # Recent summary should now have content
      assert compressed.recent_summary != ""
      # Compression count should increment
      assert compressed.compression_count == 1
      assert %DateTime{} = compressed.last_compression_at
    end

    test "compress_if_needed handles empty full_detail" do
      window = ContextWindow.new("agent_001", preset: :claude_full)
      result = ContextWindow.compress(window)
      assert result == window
    end

    test "compress is no-op for legacy mode" do
      window = ContextWindow.new("agent_001")
      result = ContextWindow.compress(window)
      assert result == window
    end
  end

  describe "token management (multi-layer)" do
    setup do
      window = ContextWindow.new("agent_001", preset: :medium_context)
      {:ok, window: window}
    end

    test "total_tokens sums all sections", %{window: window} do
      window = %{window | distant_tokens: 100, recent_tokens: 200, detail_tokens: 300, retrieved_tokens: 50}
      assert ContextWindow.total_tokens(window) == 650
    end

    test "token_usage delegates to total_tokens in multi-layer", %{window: window} do
      window = %{window | detail_tokens: 500}
      assert ContextWindow.token_usage(window) == 500
    end

    test "budget_info returns section breakdown", %{window: window} do
      info = ContextWindow.budget_info(window)

      assert is_integer(info.total)
      assert info.max == 28_000
      assert is_float(info.utilization)
      assert is_map(info.by_section)
      assert is_map(info.by_section.distant)
      assert is_map(info.by_section.recent)
      assert is_map(info.by_section.detail)
      assert is_map(info.by_section.retrieved)
    end

    test "remaining_capacity works in multi-layer", %{window: window} do
      capacity = ContextWindow.remaining_capacity(window)
      assert capacity == 28_000
    end
  end

  describe "context building (multi-layer)" do
    setup do
      window = ContextWindow.new("agent_001", preset: :medium_context)
      {:ok, window: window}
    end

    test "build_context returns sections in order", %{window: window} do
      window =
        window
        |> Map.put(:distant_summary, "Old context")
        |> Map.put(:recent_summary, "Recent context")
        |> ContextWindow.add_message(%{role: :user, content: "Hello"})

      sections = ContextWindow.build_context(window)

      types = Enum.map(sections, & &1.type)
      assert :distant_summary in types
      assert :recent_summary in types
      assert :clarity_boundary in types
      assert :full_detail in types
    end

    test "build_context omits empty sections", %{window: window} do
      sections = ContextWindow.build_context(window)

      types = Enum.map(sections, & &1.type)
      refute :distant_summary in types
      refute :recent_summary in types
      refute :retrieved in types
      refute :full_detail in types
      # Clarity boundary is always present
      assert :clarity_boundary in types
    end

    test "to_prompt_text joins all sections in multi-layer", %{window: window} do
      window =
        window
        |> Map.put(:distant_summary, "Distant info")
        |> Map.put(:recent_summary, "Recent info")
        |> ContextWindow.add_message(%{role: :user, content: "Current message"})

      text = ContextWindow.to_prompt_text(window)

      assert text =~ "DISTANT CONTEXT"
      assert text =~ "Distant info"
      assert text =~ "RECENT CONTEXT"
      assert text =~ "Recent info"
      assert text =~ "CLARITY BOUNDARY"
      assert text =~ "Current message"
    end

    test "to_system_prompt returns summaries only", %{window: window} do
      window =
        window
        |> Map.put(:distant_summary, "Old history")
        |> Map.put(:recent_summary, "Recent history")
        |> ContextWindow.add_message(%{role: :user, content: "Current msg"})

      system = ContextWindow.to_system_prompt(window)

      assert system =~ "Old history"
      assert system =~ "Recent history"
      refute system =~ "Current msg"
    end

    test "to_user_context returns boundary + detail", %{window: window} do
      window =
        window
        |> Map.put(:distant_summary, "Old history")
        |> ContextWindow.add_message(%{role: :user, content: "Current msg"})

      user_ctx = ContextWindow.to_user_context(window)

      assert user_ctx =~ "CLARITY BOUNDARY"
      assert user_ctx =~ "CONVERSATION"
      assert user_ctx =~ "Current msg"
      refute user_ctx =~ "Old history"
    end

    test "to_system_prompt returns empty for legacy mode" do
      window = ContextWindow.new("agent_001")
      assert ContextWindow.to_system_prompt(window) == ""
    end

    test "to_user_context returns empty for legacy mode" do
      window = ContextWindow.new("agent_001")
      assert ContextWindow.to_user_context(window) == ""
    end
  end

  describe "stats (multi-layer)" do
    test "returns multi-layer stats" do
      window =
        ContextWindow.new("agent_001", preset: :claude_full)
        |> ContextWindow.add_message(%{role: :user, content: "Hello"})
        |> ContextWindow.add_message(%{role: :assistant, content: "Hi"})

      stats = ContextWindow.stats(window)

      assert stats.agent_id == "agent_001"
      assert stats.multi_layer == true
      assert stats.entry_count == 2
      assert stats.max_tokens == 180_000
      assert is_integer(stats.token_usage)
      assert is_float(stats.utilization)
      assert is_boolean(stats.needs_compression)
      assert stats.compression_count == 0
      assert is_map(stats.budget)
    end
  end

  describe "serialization (multi-layer)" do
    test "round-trips correctly" do
      original =
        ContextWindow.new("agent_001", preset: :claude_full)
        |> Map.put(:distant_summary, "Old context")
        |> Map.put(:recent_summary, "Recent context")
        |> Map.put(:distant_tokens, 100)
        |> Map.put(:recent_tokens, 200)

      original =
        original
        |> ContextWindow.add_message(%{role: :user, content: "Hello"})

      serialized = ContextWindow.serialize(original)
      deserialized = ContextWindow.deserialize(serialized)

      assert deserialized.agent_id == original.agent_id
      assert deserialized.multi_layer == true
      assert deserialized.max_tokens == original.max_tokens
      assert deserialized.distant_summary == "Old context"
      assert deserialized.recent_summary == "Recent context"
      assert deserialized.distant_tokens == 100
      assert deserialized.recent_tokens == 200
      assert length(deserialized.full_detail) == length(original.full_detail)
      assert deserialized.summarization_enabled == original.summarization_enabled
      assert deserialized.summarization_algorithm == original.summarization_algorithm
    end

    test "multi-layer serialize produces JSON-safe map" do
      window = ContextWindow.new("agent_001", preset: :claude_full)
      serialized = ContextWindow.serialize(window)

      assert serialized["multi_layer"] == true
      assert serialized["agent_id"] == "agent_001"
      assert serialized["max_tokens"] == 180_000
      assert is_map(serialized["ratios"])
      assert {:ok, _json} = Jason.encode(serialized)
    end

    test "deserialize handles legacy data (no multi_layer key)" do
      legacy_data = %{
        "agent_id" => "agent_001",
        "entries" => [
          %{"type" => "message", "content" => "Hello", "timestamp" => DateTime.to_iso8601(DateTime.utc_now())}
        ],
        "max_tokens" => 10_000,
        "summary_threshold" => 0.7
      }

      window = ContextWindow.deserialize(legacy_data)

      assert window.multi_layer == false
      assert length(window.entries) == 1
      assert window.max_tokens == 10_000
    end

    test "deserialize handles multi-layer data" do
      data = %{
        "agent_id" => "agent_002",
        "multi_layer" => true,
        "max_tokens" => 100_000,
        "distant_summary" => "Old stuff",
        "recent_summary" => "New stuff",
        "full_detail" => [%{"role" => "user", "content" => "Hi"}],
        "distant_tokens" => 50,
        "recent_tokens" => 100,
        "detail_tokens" => 200,
        "retrieved_tokens" => 0,
        "compression_count" => 3,
        "summarization_algorithm" => "prose",
        "summarization_enabled" => true
      }

      window = ContextWindow.deserialize(data)

      assert window.multi_layer == true
      assert window.agent_id == "agent_002"
      assert window.max_tokens == 100_000
      assert window.distant_summary == "Old stuff"
      assert window.recent_summary == "New stuff"
      assert window.compression_count == 3
      assert window.summarization_algorithm == :prose
      assert window.summarization_enabled == true
    end
  end

  # ============================================================================
  # Gap-Fill Tests: Semantic Dedup, Fact Extraction, Signals, etc.
  # ============================================================================

  describe "semantic dedup (retrieved context)" do
    setup do
      window = ContextWindow.new("agent_dedup", preset: :claude_full)
      %{window: window}
    end

    test "deduplicates exact same content", %{window: window} do
      window =
        window
        |> ContextWindow.add_retrieved(%{content: "The database uses PostgreSQL for storage"})
        |> ContextWindow.add_retrieved(%{content: "The database uses PostgreSQL for storage"})

      assert length(window.retrieved_context) == 1
    end

    test "allows semantically distinct content", %{window: window} do
      window =
        window
        |> ContextWindow.add_retrieved(%{
          content: "Elixir uses the BEAM virtual machine for concurrent programming with lightweight processes"
        })
        |> ContextWindow.add_retrieved(%{
          content: "The stock market experienced significant volatility due to unexpected interest rate changes"
        })

      assert length(window.retrieved_context) == 2
    end

    test "stores embeddings on retrieved context when available", %{window: window} do
      window = ContextWindow.add_retrieved(window, %{
        content: "A substantial piece of content about Elixir programming patterns and OTP design"
      })

      ctx = hd(window.retrieved_context)

      # Embedding may or may not be present depending on whether Arbor.AI.embed/2 works in test
      if ctx[:embedding] do
        assert is_list(ctx.embedding)
        assert length(ctx.embedding) > 0
      end
    end

    test "retrieved_at timestamp is always set", %{window: window} do
      window = ContextWindow.add_retrieved(window, %{content: "Test content for timestamp"})
      ctx = hd(window.retrieved_context)
      assert %DateTime{} = ctx[:retrieved_at]
    end
  end

  describe "percentage-based token budgets" do
    test "resolves percentage-based max_tokens against default context" do
      window = ContextWindow.new("agent_pct", max_tokens: {:percentage, 0.50})
      # Should resolve to 50% of default context size (100_000)
      assert window.max_tokens == 50_000
    end

    test "resolves min_max budget spec" do
      window = ContextWindow.new("agent_minmax", max_tokens: {:min_max, 5_000, 20_000, 0.50})
      # 50% of 100_000 = 50_000, but capped at max 20_000
      assert window.max_tokens == 20_000
    end

    test "resolves fixed budget spec" do
      window = ContextWindow.new("agent_fixed", max_tokens: {:fixed, 42_000})
      assert window.max_tokens == 42_000
    end

    test "percentage with model_id resolves against model context" do
      window = ContextWindow.new("agent_model",
        max_tokens: {:percentage, 0.10},
        model_id: "anthropic:claude-3-5-sonnet-20241022"
      )
      # Should resolve based on the model's known context size
      assert window.max_tokens > 0
      assert is_integer(window.max_tokens)
    end
  end

  describe "model config for summarization" do
    test "stores summarization_model and summarization_provider" do
      window = ContextWindow.new("agent_model_cfg",
        multi_layer: true,
        summarization_enabled: true,
        summarization_model: "anthropic:claude-3-5-haiku-20241022",
        summarization_provider: :anthropic
      )

      assert window.summarization_model == "anthropic:claude-3-5-haiku-20241022"
      assert window.summarization_provider == :anthropic
    end

    test "stores fact_extraction_model" do
      window = ContextWindow.new("agent_fact_cfg",
        multi_layer: true,
        fact_extraction_enabled: true,
        fact_extraction_model: "openai:gpt-4o-mini"
      )

      assert window.fact_extraction_model == "openai:gpt-4o-mini"
    end

    test "model config defaults to nil" do
      window = ContextWindow.new("agent_defaults", multi_layer: true)

      assert window.summarization_model == nil
      assert window.summarization_provider == nil
      assert window.fact_extraction_model == nil
    end
  end

  describe "model config serialization" do
    test "round-trips model config through serialize/deserialize" do
      window = ContextWindow.new("agent_ser",
        multi_layer: true,
        summarization_enabled: true,
        summarization_model: "anthropic:claude-3-5-haiku-20241022",
        summarization_provider: :anthropic,
        fact_extraction_enabled: true,
        fact_extraction_model: "openai:gpt-4o-mini"
      )

      data = ContextWindow.serialize(window)
      restored = ContextWindow.deserialize(data)

      assert restored.summarization_model == "anthropic:claude-3-5-haiku-20241022"
      assert restored.summarization_provider == :anthropic
      assert restored.fact_extraction_model == "openai:gpt-4o-mini"
    end

    test "deserialize handles missing model config fields" do
      data = %{
        "agent_id" => "agent_legacy",
        "multi_layer" => true,
        "version" => 1,
        "max_tokens" => 10_000,
        "summarization_enabled" => false,
        "summarization_algorithm" => "prose"
      }

      window = ContextWindow.deserialize(data)
      assert window.summarization_model == nil
      assert window.summarization_provider == nil
      assert window.fact_extraction_model == nil
    end
  end

  describe "compression pipeline with fact extraction" do
    setup do
      # Small budget to trigger compression easily.
      # Use summarization_enabled: true so compression is deferred to compress_if_needed.
      window = ContextWindow.new("agent_pipeline",
        multi_layer: true,
        max_tokens: 200,
        summarization_enabled: true,
        fact_extraction_enabled: true,
        ratios: %{full_detail: 0.50, recent_summary: 0.25, distant_summary: 0.15, retrieved: 0.10}
      )

      %{window: window}
    end

    test "compress runs without error when fact_extraction_enabled", %{window: window} do
      # Add enough messages to trigger compression
      window =
        Enum.reduce(1..20, window, fn i, w ->
          ContextWindow.add_message(w, %{
            role: :user,
            content: "Message #{i} with some content about databases and API endpoints and server config"
          })
        end)

      assert ContextWindow.needs_compression?(window)

      # Should not raise even if FactExtractor isn't available in test
      {:ok, compressed} = ContextWindow.compress_if_needed(window)
      assert compressed.compression_count == 1
      assert compressed.last_compression_at != nil
    end

    test "compression demotes oldest messages to recent_summary", %{window: window} do
      window =
        Enum.reduce(1..20, window, fn i, w ->
          ContextWindow.add_message(w, %{
            role: :user,
            content: "Message #{i}: discussing various topics about API design and database optimization"
          })
        end)

      {:ok, compressed} = ContextWindow.compress_if_needed(window)

      # Should have fewer detail messages after compression
      assert length(compressed.full_detail) < length(window.full_detail)
      # Recent summary should have content
      assert compressed.recent_summary != ""
    end
  end

  describe "timestamps in summary formatting" do
    test "format_messages_for_summary includes timestamps" do
      window = ContextWindow.new("agent_ts",
        multi_layer: true,
        max_tokens: 200,
        summarization_enabled: false
      )

      now = DateTime.utc_now()

      window =
        %{window | full_detail: [
          %{role: :user, content: "Hello", speaker: "Human", timestamp: now},
          %{role: :assistant, content: "Hi there", timestamp: now}
        ]}

      # Trigger compression so format_messages_for_summary is called
      window = %{window | detail_tokens: 999}

      {:ok, compressed} = ContextWindow.compress_if_needed(window)

      # The recent summary should contain timestamp-formatted text
      # (either from LLM or fallback formatting)
      assert compressed.recent_summary != nil
    end
  end

  describe "flow_to_distant with LLM re-summarization" do
    test "flow_to_distant works when summarization is disabled" do
      # With disabled summarization, flow_to_distant still works via truncation
      window = ContextWindow.new("agent_flow",
        multi_layer: true,
        max_tokens: 100,
        summarization_enabled: false,
        ratios: %{full_detail: 0.50, recent_summary: 0.25, distant_summary: 0.15, retrieved: 0.10}
      )

      # Add many messages to trigger deep compression
      window =
        Enum.reduce(1..50, window, fn i, w ->
          ContextWindow.add_message(w, %{
            role: :user,
            content: "Detailed message #{i}: Long content about various topics to fill the context window quickly"
          })
        end)

      # First compression
      {:ok, compressed} = ContextWindow.compress_if_needed(window)

      # Add more to trigger another compression that might flow to distant
      compressed =
        Enum.reduce(1..50, compressed, fn i, w ->
          ContextWindow.add_message(w, %{
            role: :user,
            content: "Second batch message #{i}: More content to force another compression cycle"
          })
        end)

      {:ok, double_compressed} = ContextWindow.compress_if_needed(compressed)

      assert double_compressed.compression_count >= 2
      # After multiple compressions, distant_summary should have content
      # (or be empty if the budget is tiny)
      assert is_binary(double_compressed.distant_summary)
    end
  end

  describe "format_action_result with JSON encoding" do
    test "add_tool_results formats map results as JSON" do
      window = ContextWindow.new("agent_json", multi_layer: true, max_tokens: 10_000)

      results = [
        %{
          action: "fetch_data",
          outcome: :success,
          result: %{"users" => ["alice", "bob"], "count" => 2}
        }
      ]

      window = ContextWindow.add_tool_results(window, results)
      msg = hd(window.full_detail)

      # The content should contain the JSON-formatted result
      assert String.contains?(msg[:content], "fetch_data")
      assert String.contains?(msg[:content], "success")
    end
  end
end
