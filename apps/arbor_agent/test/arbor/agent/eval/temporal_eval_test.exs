defmodule Arbor.Agent.Eval.TemporalEvalTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.{TemporalEval, TemporalTranscript}

  # ── format_temporal/3 ──────────────────────────────────────

  describe "format_temporal/3" do
    test "returns empty string for nil observation" do
      assert ContextCompactor.format_temporal(nil, nil, 0.5) == ""
    end

    test "returns empty string at detail >= 0.8" do
      dt = ~U[2026-02-22 21:40:00Z]
      assert ContextCompactor.format_temporal(dt, nil, 0.8) == ""
      assert ContextCompactor.format_temporal(dt, nil, 0.9) == ""
      assert ContextCompactor.format_temporal(dt, nil, 1.0) == ""
    end

    test "includes full datetime at detail 0.5-0.8" do
      dt = ~U[2026-02-22 21:40:00Z]
      result = ContextCompactor.format_temporal(dt, nil, 0.6)
      assert result =~ "[Feb 22 21:40]"
    end

    test "includes full datetime with referenced date at detail 0.5-0.8" do
      dt = ~U[2026-02-22 21:40:00Z]
      ref = "2026-02-15"
      result = ContextCompactor.format_temporal(dt, ref, 0.6)
      assert result =~ "[Feb 22 21:40]"
      assert result =~ "(ref: Feb 15)"
    end

    test "includes date-only at detail 0.2-0.5" do
      dt = ~U[2026-02-22 21:40:00Z]
      result = ContextCompactor.format_temporal(dt, nil, 0.3)
      assert result =~ "[Feb 22]"
      refute result =~ "21:40"
    end

    test "includes date-only with ref at detail 0.2-0.5" do
      dt = ~U[2026-02-22 21:40:00Z]
      ref = "2026-02-15"
      result = ContextCompactor.format_temporal(dt, ref, 0.3)
      assert result =~ "[Feb 22]"
      assert result =~ "(ref: Feb 15)"
    end

    test "includes date-only and omits ref at detail < 0.2" do
      dt = ~U[2026-02-22 21:40:00Z]
      ref = "2026-02-15"
      result = ContextCompactor.format_temporal(dt, ref, 0.1)
      assert result =~ "[Feb 22]"
      refute result =~ "(ref:"
    end

    test "handles Date struct as referenced_date" do
      dt = ~U[2026-02-22 21:40:00Z]
      ref = ~D[2026-02-15]
      result = ContextCompactor.format_temporal(dt, ref, 0.6)
      assert result =~ "(ref: Feb 15)"
    end

    test "handles invalid referenced_date gracefully" do
      dt = ~U[2026-02-22 21:40:00Z]
      result = ContextCompactor.format_temporal(dt, "not-a-date", 0.6)
      refute result =~ "(ref:"
    end
  end

  # ── extract_referenced_date/1 ──────────────────────────────

  describe "extract_referenced_date/1" do
    test "extracts from explicit message field" do
      msg = %{role: :tool, content: "some content", referenced_date: "2026-02-15"}
      assert ContextCompactor.extract_referenced_date(msg) == "2026-02-15"
    end

    test "extracts from JSON content" do
      content =
        Jason.encode!(%{"referenced_date" => "2026-02-15", "content" => "test"})

      msg = %{role: :tool, content: content}
      assert ContextCompactor.extract_referenced_date(msg) == "2026-02-15"
    end

    test "returns nil when no referenced date" do
      msg = %{role: :tool, content: "just regular content"}
      assert ContextCompactor.extract_referenced_date(msg) == nil
    end
  end

  # ── message_timestamps in append ──────────────────────────

  describe "message_timestamps population" do
    test "populates from explicit timestamp field" do
      c = ContextCompactor.new()
      ts = "2026-02-22T21:40:00Z"

      c = ContextCompactor.append(c, %{role: :tool, content: "test", timestamp: ts})

      assert map_size(c.message_timestamps) == 1
      assert Map.has_key?(c.message_timestamps, 1)
    end

    test "populates with DateTime.utc_now when no timestamp" do
      c = ContextCompactor.new()

      c = ContextCompactor.append(c, %{role: :tool, content: "test"})

      assert map_size(c.message_timestamps) == 1
      assert %DateTime{} = c.message_timestamps[1]
    end

    test "backwards compatible when empty" do
      # Construct compactor with empty message_timestamps and run compaction
      c = ContextCompactor.new(effective_window: 100)
      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      Enum.reduce(1..10, c, fn i, acc ->
        acc
        |> ContextCompactor.append(%{role: :assistant, content: "step #{i}"})
        |> ContextCompactor.append(%{
          role: :tool,
          name: "test",
          content: String.duplicate("data ", 100)
        })
        |> ContextCompactor.maybe_compact()
      end)

      # Should not crash
    end
  end

  # ── TemporalTranscript ────────────────────────────────────

  describe "TemporalTranscript.generate/0" do
    test "produces messages with all temporal labels" do
      transcript = TemporalTranscript.generate()
      tool_calls = transcript["tool_calls"]

      labels = Enum.map(tool_calls, & &1["temporal_label"]) |> Enum.uniq()

      assert "has_observation" in labels
      assert "has_both" in labels
      assert "has_neither" in labels
    end

    test "messages span multiple simulated days" do
      now = ~U[2026-02-24 12:00:00Z]
      transcript = TemporalTranscript.generate(now: now)
      tool_calls = transcript["tool_calls"]

      timestamps =
        tool_calls
        |> Enum.filter(& &1["timestamp"])
        |> Enum.map(fn tc ->
          {:ok, dt, _} = DateTime.from_iso8601(tc["timestamp"])
          DateTime.to_date(dt)
        end)
        |> Enum.uniq()

      # Should have messages from at least 3 different dates
      assert length(timestamps) >= 3
    end

    test "has required transcript fields" do
      transcript = TemporalTranscript.generate()

      assert is_binary(transcript["task"])
      assert is_binary(transcript["text"])
      assert is_list(transcript["tool_calls"])
      assert is_integer(transcript["turns"])
    end

    test "tool calls have sequential turn numbers" do
      transcript = TemporalTranscript.generate()
      turns = Enum.map(transcript["tool_calls"], & &1["turn"])

      assert turns == Enum.to_list(1..length(turns))
    end

    test "has_both messages have both timestamp and referenced_date" do
      transcript = TemporalTranscript.generate()

      both =
        Enum.filter(transcript["tool_calls"], &(&1["temporal_label"] == "has_both"))

      assert length(both) > 0

      for tc <- both do
        assert tc["timestamp"] != nil, "has_both message should have timestamp"
        assert tc["referenced_date"] != nil, "has_both message should have referenced_date"
      end
    end

    test "generates at least 25 messages" do
      transcript = TemporalTranscript.generate()
      assert length(transcript["tool_calls"]) >= 25
    end
  end

  # ── Compressed stubs contain temporal markers ──────────────

  describe "compressed stubs with temporal markers" do
    test "stubs contain observation markers after compaction" do
      c = ContextCompactor.new(effective_window: 200)

      ts = ~U[2026-02-20 14:30:00Z]

      c = ContextCompactor.append(c, %{role: :system, content: "System"})
      c = ContextCompactor.append(c, %{role: :user, content: "Task"})

      # Add several messages with timestamps to trigger compaction
      c =
        Enum.reduce(1..15, c, fn i, acc ->
          acc
          |> ContextCompactor.append(%{role: :assistant, content: "step #{i}"})
          |> ContextCompactor.append(%{
            role: :tool,
            name: "file_read",
            content: String.duplicate("line #{i}\n", 50),
            timestamp: DateTime.to_iso8601(DateTime.add(ts, i * 300, :second))
          })
          |> ContextCompactor.maybe_compact()
        end)

      # Check that some compressed messages have temporal markers
      compressed =
        c
        |> ContextCompactor.llm_messages()
        |> Enum.filter(fn msg ->
          content = Map.get(msg, :content, "")
          is_binary(content) and Regex.match?(~r/^\[(?:Feb) \d{1,2}/, content)
        end)

      assert length(compressed) > 0,
             "Expected some compressed stubs to have temporal markers"
    end
  end

  # ── TemporalEval ground truth ─────────────────────────────

  describe "extract_temporal_ground_truth/1" do
    test "extracts observation and referenced date counts" do
      transcript = TemporalTranscript.generate()
      gt = TemporalEval.extract_temporal_ground_truth(transcript)

      assert gt.total_with_observation > 0
      assert gt.total_with_referenced > 0
      assert gt.total_with_neither > 0
    end

    test "observation turns are non-empty" do
      transcript = TemporalTranscript.generate()
      gt = TemporalEval.extract_temporal_ground_truth(transcript)

      assert length(gt.observation_turns) > 0
      assert length(gt.referenced_date_turns) > 0
    end
  end
end
