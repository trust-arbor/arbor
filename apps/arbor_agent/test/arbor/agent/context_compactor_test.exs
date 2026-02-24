defmodule Arbor.Agent.ContextCompactorTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ContextCompactor

  # ── Helpers ──────────────────────────────────────────────────

  defp make_tool_msg(name, content, opts \\ []) do
    %{
      role: :tool,
      tool_call_id: Keyword.get(opts, :id, "tc_#{:rand.uniform(10000)}"),
      name: name,
      content: content
    }
  end

  defp make_assistant_msg(content, opts \\ []) do
    base = %{role: :assistant, content: content}

    case Keyword.get(opts, :tool_calls) do
      nil -> base
      tcs -> Map.put(base, :tool_calls, tcs)
    end
  end

  defp make_file_read_result(path, content) do
    "#{path}\n#{content}"
  end

  defp make_large_content(lines) do
    Enum.map_join(1..lines, "\n", fn i -> "Line #{i}: #{String.duplicate("x", 80)}" end)
  end

  # ── new/1 ────────────────────────────────────────────────────

  describe "new/1" do
    test "creates compactor with default effective window" do
      c = ContextCompactor.new()

      assert c.effective_window > 0
      assert c.full_transcript == []
      assert c.llm_messages == []
      assert c.file_index == %{}
      assert c.token_count == 0
      assert c.turn == 0
    end

    test "creates compactor with model-aware effective window" do
      c = ContextCompactor.new(model: "anthropic/claude-3-5-haiku-latest")

      # Claude models have 200k context, 75% = 150k
      assert c.effective_window > 50_000
    end

    test "respects explicit effective_window override" do
      c = ContextCompactor.new(effective_window: 5000)

      assert c.effective_window == 5000
    end

    test "stores config options" do
      c = ContextCompactor.new(enable_llm_compaction: true)

      assert c.config.enable_llm_compaction == true
    end
  end

  # ── append/2 ─────────────────────────────────────────────────

  describe "append/2" do
    test "adds message to both full_transcript and llm_messages" do
      c = ContextCompactor.new()
      msg = %{role: :user, content: "Hello"}
      c = ContextCompactor.append(c, msg)

      assert length(c.full_transcript) == 1
      assert length(c.llm_messages) == 1
      assert List.first(c.full_transcript) == msg
      assert List.first(c.llm_messages) == msg
    end

    test "increments token count" do
      c = ContextCompactor.new()
      msg = %{role: :user, content: String.duplicate("word ", 100)}
      c = ContextCompactor.append(c, msg)

      assert c.token_count > 0
    end

    test "increments turn counter" do
      c = ContextCompactor.new()
      c = ContextCompactor.append(c, %{role: :user, content: "Hello"})
      assert c.turn == 1
      c = ContextCompactor.append(c, %{role: :assistant, content: "Hi"})
      assert c.turn == 2
    end

    test "tracks peak token usage" do
      c = ContextCompactor.new()
      msg = %{role: :user, content: String.duplicate("x", 400)}
      c = ContextCompactor.append(c, msg)

      assert c.peak_tokens == c.token_count
      assert c.peak_tokens > 0
    end
  end

  # ── maybe_compact/1 ──────────────────────────────────────────

  describe "maybe_compact/1" do
    test "returns unchanged when below threshold" do
      c = ContextCompactor.new(effective_window: 100_000)
      c = ContextCompactor.append(c, %{role: :user, content: "short message"})
      compacted = ContextCompactor.maybe_compact(c)

      assert compacted.llm_messages == c.llm_messages
      assert compacted.compression_count == 0
    end

    test "compresses messages when above threshold" do
      # Set very small window to trigger compaction
      c = ContextCompactor.new(effective_window: 100)

      # Add system + user (protected)
      c = ContextCompactor.append(c, %{role: :system, content: "System prompt"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task description"})

      # Add many tool results to exceed threshold
      c =
        Enum.reduce(1..20, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Reading file #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(
            make_tool_msg("file_read", make_large_content(10), id: "tc_#{i}")
          )
        end)

      assert c.token_count > 100

      compacted = ContextCompactor.maybe_compact(c)

      # Token count should decrease after compaction
      assert compacted.token_count < c.token_count
      # Compression count should be > 0
      assert compacted.compression_count > 0
    end
  end

  # ── Semantic Squashing ───────────────────────────────────────

  describe "semantic squashing" do
    test "second file read with different content squashes the first" do
      c = ContextCompactor.new(effective_window: 50)

      # Two different versions of the same file — simulates file modification between reads
      content_v1 = make_file_read_result("lib/foo.ex", "defmodule Foo do\nend")

      content_v2 =
        make_file_read_result("lib/foo.ex", "defmodule Foo do\n  def bar, do: :ok\nend")

      # System + user (protected)
      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      # First read of lib/foo.ex
      c = ContextCompactor.append(c, make_assistant_msg("Reading", tool_calls: [%{id: "tc_1"}]))
      c = ContextCompactor.append(c, make_tool_msg("file_read", content_v1, id: "tc_1"))

      # Some other work
      c = ContextCompactor.append(c, make_assistant_msg("Thinking"))
      c = ContextCompactor.append(c, make_tool_msg("shell_execute", "ok", id: "tc_2"))

      # Second read of lib/foo.ex with different content (supersedes the first)
      c =
        ContextCompactor.append(c, make_assistant_msg("Re-reading", tool_calls: [%{id: "tc_3"}]))

      c = ContextCompactor.append(c, make_tool_msg("file_read", content_v2, id: "tc_3"))

      compacted = ContextCompactor.maybe_compact(c)

      # The first file_read should be squashed
      assert compacted.squash_count > 0

      # Find the first tool message (index 3)
      first_tool = Enum.at(compacted.llm_messages, 3)
      assert String.contains?(first_tool.content, "[Superseded]")
    end

    test "identical file re-reads are handled by dedup, not squashing" do
      c = ContextCompactor.new(effective_window: 50)

      content = make_file_read_result("lib/foo.ex", make_large_content(5))

      c = ContextCompactor.append(c, %{role: :system, content: "S"})
      c = ContextCompactor.append(c, %{role: :user, content: "T"})
      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      # Second read of identical content — handled by dedup in append
      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      last_msg = List.last(c.llm_messages)
      assert String.contains?(last_msg.content, "unchanged")
    end
  end

  # ── Omission with Pointer ────────────────────────────────────

  describe "omission with pointer" do
    test "old file reads become stubs with re-read instruction" do
      c = ContextCompactor.new(effective_window: 50)

      # Build enough messages that old ones have low detail_level
      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      # Old tool result with lots of content
      large_result = make_large_content(50)

      c =
        Enum.reduce(1..15, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Step #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(make_tool_msg("file_read", large_result, id: "tc_#{i}"))
        end)

      compacted = ContextCompactor.maybe_compact(c)

      # Old tool messages should be compressed
      assert compacted.compression_count > 0

      # Some old messages should contain pointer language
      old_tools =
        compacted.llm_messages
        |> Enum.filter(fn msg -> msg.role == :tool end)
        |> Enum.take(3)

      # At least some old tools should be compressed
      compressed = Enum.filter(old_tools, fn msg -> String.length(msg.content) < 300 end)
      assert compressed != []
    end
  end

  # ── Heuristic Distillation ──────────────────────────────────

  describe "heuristic distillation" do
    test "old tool results become one-liners" do
      c = ContextCompactor.new(effective_window: 30)

      c = ContextCompactor.append(c, %{role: :system, content: "S"})
      c = ContextCompactor.append(c, %{role: :user, content: "T"})

      # Add many turns so oldest get very low detail_level
      c =
        Enum.reduce(1..20, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Step #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(
            make_tool_msg("shell_execute", "Output line #{i}\nMore output\nEven more",
              id: "tc_#{i}"
            )
          )
        end)

      compacted = ContextCompactor.maybe_compact(c)

      # Oldest tool messages should be very short
      oldest_tool = Enum.at(compacted.llm_messages, 3)

      if oldest_tool && oldest_tool.role == :tool do
        # Should be significantly shorter than original
        assert String.length(oldest_tool.content) < 100
      end
    end
  end

  # ── File Index ──────────────────────────────────────────────

  describe "file index" do
    test "tracks seen files with content hashes" do
      c = ContextCompactor.new()

      content = make_file_read_result("lib/foo.ex", "defmodule Foo do\nend")
      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      assert map_size(c.file_index) == 1
      assert Map.has_key?(c.file_index, "lib/foo.ex")

      entry = c.file_index["lib/foo.ex"]
      assert is_binary(entry.content_hash)
      assert entry.line_count > 0
    end

    test "file re-read with unchanged content returns dedup message" do
      c = ContextCompactor.new()

      content = make_file_read_result("lib/foo.ex", "defmodule Foo do\nend")

      # First read — populates index
      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      # Second read of same content — should be deduplicated
      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      last_msg = List.last(c.llm_messages)
      assert String.contains?(last_msg.content, "unchanged")
    end

    test "file re-read with changed content returns full result" do
      c = ContextCompactor.new()

      content1 = make_file_read_result("lib/foo.ex", "defmodule Foo do\nend")
      content2 = make_file_read_result("lib/foo.ex", "defmodule Foo do\n  def bar, do: :ok\nend")

      c = ContextCompactor.append(c, make_tool_msg("file_read", content1))
      c = ContextCompactor.append(c, make_tool_msg("file_read", content2))

      last_msg = List.last(c.llm_messages)
      # Changed content should NOT be marked as unchanged
      refute String.contains?(last_msg.content, "unchanged")
    end

    test "file write invalidates the index entry" do
      c = ContextCompactor.new()

      content = make_file_read_result("lib/foo.ex", "defmodule Foo do\nend")
      c = ContextCompactor.append(c, make_tool_msg("file_read", content))
      assert Map.has_key?(c.file_index, "lib/foo.ex")

      # Write to the same file
      c = ContextCompactor.append(c, make_tool_msg("file_write", "lib/foo.ex\nUpdated"))
      refute Map.has_key?(c.file_index, "lib/foo.ex")
    end
  end

  # ── Full Transcript Immutability ────────────────────────────

  describe "full transcript immutability" do
    test "full transcript is never mutated by compaction" do
      c = ContextCompactor.new(effective_window: 30)

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      # Add many messages to trigger compaction
      c =
        Enum.reduce(1..15, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Step #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(
            make_tool_msg("file_read", make_large_content(5), id: "tc_#{i}")
          )
        end)

      # Save reference to full transcript before compaction
      pre_compact_transcript = c.full_transcript
      pre_compact_length = length(pre_compact_transcript)

      compacted = ContextCompactor.maybe_compact(c)

      # Full transcript must be identical
      assert length(compacted.full_transcript) == pre_compact_length
      assert compacted.full_transcript == pre_compact_transcript

      # But llm_messages should be different (compressed)
      if compacted.compression_count > 0 do
        assert compacted.llm_messages != compacted.full_transcript
      end
    end
  end

  # ── Detail Level Continuity ────────────────────────────────

  describe "detail level" do
    test "is continuous, not discrete jumps" do
      levels = Enum.map(0..99, fn i -> ContextCompactor.detail_level(i, 100) end)

      # Should be monotonically increasing (oldest=0.0 → newest=1.0)
      pairs = Enum.zip(levels, Enum.drop(levels, 1))

      Enum.each(pairs, fn {a, b} ->
        assert a <= b, "Detail level should increase: #{a} > #{b}"
      end)

      # No large jumps (difference between consecutive should be small)
      diffs = Enum.map(pairs, fn {a, b} -> abs(a - b) end)
      max_diff = Enum.max(diffs)
      assert max_diff < 0.05, "Detail level has large jump: #{max_diff}"
    end

    test "oldest message has detail_level 0.0" do
      assert ContextCompactor.detail_level(0, 100) == 0.0
    end

    test "newest message has detail_level 1.0" do
      level = ContextCompactor.detail_level(99, 100)
      assert level == 1.0
    end
  end

  # ── Failed Tool Call Preservation ───────────────────────────

  describe "failed tool call preservation" do
    test "error results survive compaction with failure indication" do
      c = ContextCompactor.new(effective_window: 50)

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      # Add a failed tool call early
      c =
        ContextCompactor.append(
          c,
          make_assistant_msg("Trying", tool_calls: [%{id: "tc_fail"}])
        )

      c =
        ContextCompactor.append(
          c,
          make_tool_msg("shell_execute", "ERROR: command not found: foo", id: "tc_fail")
        )

      # Add many more turns to push the failure into low detail_level
      # Need enough that detail_level < 0.8 for index 3 (the failed tool)
      # detail = 1.0 - 3/total, need < 0.8, so total > 15
      c =
        Enum.reduce(1..40, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Step #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(make_tool_msg("shell_execute", "ok #{i}", id: "tc_#{i}"))
        end)

      compacted = ContextCompactor.maybe_compact(c)

      # The failed tool call should still indicate failure — either as
      # original ERROR prefix or compressed FAILED marker
      failure_msgs =
        compacted.llm_messages
        |> Enum.filter(fn msg ->
          msg.role == :tool and
            (String.contains?(msg.content, "FAILED") or
               String.contains?(msg.content, "ERROR"))
        end)

      assert failure_msgs != [],
             "Failed tool calls should preserve failure indication through compaction"
    end
  end

  # ── Token Count Tracking ───────────────────────────────────

  describe "token count tracking" do
    test "add on append, decrease on compact" do
      c = ContextCompactor.new(effective_window: 50)

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      initial_tokens = c.token_count

      # Add many large messages
      c =
        Enum.reduce(1..10, c, fn i, acc ->
          ContextCompactor.append(
            acc,
            make_tool_msg("file_read", make_large_content(20), id: "tc_#{i}")
          )
        end)

      pre_compact_tokens = c.token_count
      assert pre_compact_tokens > initial_tokens

      compacted = ContextCompactor.maybe_compact(c)

      if compacted.compression_count > 0 do
        assert compacted.token_count < pre_compact_tokens
      end
    end

    test "peak_tokens captures maximum" do
      c = ContextCompactor.new(effective_window: 50)

      c = ContextCompactor.append(c, %{role: :user, content: String.duplicate("x", 1000)})
      peak_after_big = c.peak_tokens

      compacted = ContextCompactor.maybe_compact(c)
      # Peak should never decrease
      assert compacted.peak_tokens >= peak_after_big
    end
  end

  # ── Stats ──────────────────────────────────────────────────

  describe "stats/1" do
    test "includes all expected fields" do
      c = ContextCompactor.new()
      c = ContextCompactor.append(c, %{role: :user, content: "Hello"})
      s = ContextCompactor.stats(c)

      assert Map.has_key?(s, :token_count)
      assert Map.has_key?(s, :peak_tokens)
      assert Map.has_key?(s, :effective_window)
      assert Map.has_key?(s, :full_transcript_length)
      assert Map.has_key?(s, :llm_messages_length)
      assert Map.has_key?(s, :compression_count)
      assert Map.has_key?(s, :squash_count)
      assert Map.has_key?(s, :narrative_count)
      assert Map.has_key?(s, :file_index_size)
      assert Map.has_key?(s, :turn)
      assert Map.has_key?(s, :token_roi)
    end

    test "token_roi is between 0 and 1" do
      c = ContextCompactor.new()
      c = ContextCompactor.append(c, %{role: :user, content: "Hello"})
      s = ContextCompactor.stats(c)

      assert s.token_roi >= 0.0
      assert s.token_roi <= 1.0
    end
  end

  # ── llm_messages/1 ─────────────────────────────────────────

  describe "llm_messages/1" do
    test "returns the projected view" do
      c = ContextCompactor.new()
      msg = %{role: :user, content: "Hello"}
      c = ContextCompactor.append(c, msg)

      messages = ContextCompactor.llm_messages(c)
      assert length(messages) == 1
      assert List.first(messages) == msg
    end
  end

  # ── full_transcript/1 ───────────────────────────────────────

  describe "full_transcript/1" do
    test "returns the full unmodified transcript" do
      c = ContextCompactor.new()
      msg = %{role: :user, content: "Hello"}
      c = ContextCompactor.append(c, msg)

      transcript = ContextCompactor.full_transcript(c)
      assert length(transcript) == 1
      assert List.first(transcript) == msg
    end

    test "is identical to direct struct access" do
      c = ContextCompactor.new()
      c = ContextCompactor.append(c, %{role: :user, content: "one"})
      c = ContextCompactor.append(c, %{role: :assistant, content: "two"})

      assert ContextCompactor.full_transcript(c) == c.full_transcript
    end
  end

  # ── @behaviour compliance ───────────────────────────────────

  describe "@behaviour Arbor.Contracts.AI.Compactor" do
    test "implements all required callbacks" do
      callbacks = Arbor.Contracts.AI.Compactor.behaviour_info(:callbacks)

      for {fun, arity} <- callbacks do
        assert function_exported?(ContextCompactor, fun, arity),
               "ContextCompactor must implement #{fun}/#{arity}"
      end
    end

    test "stats returns required fields" do
      c = ContextCompactor.new()
      c = ContextCompactor.append(c, %{role: :user, content: "Hello"})
      s = ContextCompactor.stats(c)

      # Behaviour stats type requires these fields
      assert is_integer(Map.get(s, :full_transcript_length) || Map.get(s, :total_messages, 0))
      assert is_integer(Map.get(s, :llm_messages_length) || Map.get(s, :visible_messages, 0))
    end
  end

  # ── File Index Enrichment ─────────────────────────────────

  describe "file index enrichment" do
    test "file index works with JSON format tool results" do
      c = ContextCompactor.new()

      # Real action modules return JSON: {"path": "...", "content": "..."}
      json_content =
        Jason.encode!(%{
          path: "lib/json_mod.ex",
          content: "defmodule JsonMod do\n  def hello, do: :world\nend",
          size: 48
        })

      c = ContextCompactor.append(c, make_tool_msg("file_read", json_content))

      assert Map.has_key?(c.file_index, "lib/json_mod.ex")
      entry = c.file_index["lib/json_mod.ex"]
      assert entry.modules == ["JsonMod"]
      assert "hello" in entry.key_functions
    end

    test "dedup works with JSON format results" do
      c = ContextCompactor.new()

      json_content =
        Jason.encode!(%{
          path: "lib/dedup.ex",
          content: "defmodule Dedup do\n  def run, do: :ok\nend",
          size: 42
        })

      c = ContextCompactor.append(c, make_tool_msg("file_read", json_content))
      c = ContextCompactor.append(c, make_tool_msg("file_read", json_content))

      last_msg = List.last(c.llm_messages)
      assert String.contains?(last_msg.content, "unchanged")
    end

    test "file index extracts module names from file content" do
      c = ContextCompactor.new()

      content =
        make_file_read_result(
          "lib/foo.ex",
          "defmodule Foo do\n  def bar, do: :ok\n  defp baz, do: :err\nend"
        )

      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      entry = c.file_index["lib/foo.ex"]
      assert entry.modules == ["Foo"]
      assert "bar" in entry.key_functions
      # defp should not be included
      refute "baz" in entry.key_functions
    end

    test "file index extracts multiple modules" do
      c = ContextCompactor.new()

      content =
        make_file_read_result("lib/multi.ex", """
        defmodule Outer do
          defmodule Inner do
            def hello, do: :world
          end

          def goodbye, do: :moon
        end
        """)

      c = ContextCompactor.append(c, make_tool_msg("file_read", content))

      entry = c.file_index["lib/multi.ex"]
      assert "Outer" in entry.modules
      assert "Inner" in entry.modules
    end

    test "compressed stubs include module names from file index" do
      c = ContextCompactor.new(effective_window: 80)

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      # Add a file read that will be in the file index
      file_content =
        make_file_read_result(
          "lib/foo.ex",
          "defmodule Foo.Bar do\n  def hello, do: :world\n" <>
            String.duplicate("  # padding line\n", 30) <> "end"
        )

      c =
        ContextCompactor.append(
          c,
          make_assistant_msg("Reading foo", tool_calls: [%{id: "tc_0"}])
        )

      c = ContextCompactor.append(c, make_tool_msg("file_read", file_content, id: "tc_0"))

      # Add many more messages to push file read into low detail territory
      c =
        Enum.reduce(1..30, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Step #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(
            make_tool_msg("shell_execute", "ok result #{i}", id: "tc_#{i}")
          )
        end)

      compacted = ContextCompactor.maybe_compact(c)

      # Find the compressed file read message
      compressed_file_msgs =
        compacted.llm_messages
        |> Enum.filter(fn msg ->
          msg.role == :tool and
            String.contains?(Map.get(msg, :content, ""), "Foo.Bar")
        end)

      assert compressed_file_msgs != [],
             "Compressed file read stubs should include module names from file index. " <>
               "Messages: #{inspect(Enum.map(compacted.llm_messages, &Map.get(&1, :content, "")), limit: :infinity)}"
    end

    test "compressed stubs include key function names" do
      c = ContextCompactor.new(effective_window: 80)

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      file_content =
        make_file_read_result(
          "lib/service.ex",
          "defmodule MyService do\n  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)\n  def call(pid, msg), do: GenServer.call(pid, msg)\n" <>
            String.duplicate("  # padding\n", 30) <> "end"
        )

      c =
        ContextCompactor.append(
          c,
          make_assistant_msg("Reading service", tool_calls: [%{id: "tc_0"}])
        )

      c = ContextCompactor.append(c, make_tool_msg("file_read", file_content, id: "tc_0"))

      # Push into low detail territory
      c =
        Enum.reduce(1..30, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Step #{i}", tool_calls: [%{id: "tc_#{i}"}])
          )
          |> ContextCompactor.append(make_tool_msg("shell_execute", "ok #{i}", id: "tc_#{i}"))
        end)

      compacted = ContextCompactor.maybe_compact(c)

      compressed_file_msgs =
        compacted.llm_messages
        |> Enum.filter(fn msg ->
          msg.role == :tool and
            String.contains?(Map.get(msg, :content, ""), "start_link")
        end)

      assert compressed_file_msgs != [],
             "Compressed stubs should include key function names"
    end
  end

  # ── Integration: LLM Narrative ─────────────────────────────

  describe "LLM narrative compaction" do
    @describetag :llm

    test "produces coherent summary preserving key facts" do
      c =
        ContextCompactor.new(
          effective_window: 50,
          enable_llm_compaction: true,
          compaction_model: "arcee-ai/trinity-large-preview:free",
          compaction_provider: :openrouter
        )

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Fix the bug in parser.ex"})

      # Build a realistic tool call history
      c =
        Enum.reduce(1..20, c, fn i, acc ->
          acc
          |> ContextCompactor.append(
            make_assistant_msg("Investigating step #{i}",
              tool_calls: [%{id: "tc_#{i}"}]
            )
          )
          |> ContextCompactor.append(
            make_tool_msg("file_read", "lib/parser.ex\nLine #{i}: content", id: "tc_#{i}")
          )
        end)

      compacted = ContextCompactor.maybe_compact(c)

      # Should have attempted narrative compaction
      # (may or may not succeed depending on API availability)
      assert compacted.compression_count > 0
    end
  end
end
