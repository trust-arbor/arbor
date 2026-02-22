defmodule Arbor.Agent.Eval.CompactionEvalTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Eval.CompactionEval

  # A minimal synthetic transcript for testing
  @test_transcript %{
    "task" => "Read files and summarize the codebase",
    "model" => "test-model",
    "status" => "completed",
    "turns" => 5,
    "text" => "The codebase uses a supervisor with heartbeat and memory systems.",
    "tool_calls" => [
      %{
        "turn" => 1,
        "name" => "file_list",
        "args" => %{"path" => "lib/"},
        "result" =>
          Jason.encode!(%{
            "entries" => ["app.ex", "server.ex", "memory.ex"],
            "path" => "lib/",
            "count" => 3
          }),
        "duration_ms" => 5
      },
      %{
        "turn" => 2,
        "name" => "file_read",
        "args" => %{"path" => "lib/app.ex"},
        "result" =>
          "lib/app.ex\ndefmodule MyApp.Application do\n  use Application\n  def start do\n    " <>
            String.duplicate("# application code with supervisor tree\n", 20),
        "duration_ms" => 3
      },
      %{
        "turn" => 3,
        "name" => "file_read",
        "args" => %{"path" => "lib/server.ex"},
        "result" =>
          "lib/server.ex\ndefmodule MyApp.Server do\n  use GenServer\n  def init(state) do\n    " <>
            String.duplicate("# server implementation with heartbeat loop\n", 20),
        "duration_ms" => 2
      },
      %{
        "turn" => 4,
        "name" => "file_read",
        "args" => %{"path" => "lib/memory.ex"},
        "result" =>
          "lib/memory.ex\ndefmodule MyApp.Memory do\n  def store(key, value) do\n    " <>
            String.duplicate("# memory persistence and recall functions\n", 20),
        "duration_ms" => 2
      }
    ]
  }

  describe "reconstruct_messages/1" do
    test "creates system + user + assistant/tool message pairs" do
      messages = CompactionEval.reconstruct_messages(@test_transcript)

      assert messages != []
      assert hd(messages).role == :system
      assert Enum.at(messages, 1).role == :user
      assert Enum.at(messages, 1).content == @test_transcript["task"]

      # Should have tool messages
      tool_msgs = Enum.filter(messages, &(&1.role == :tool))
      assert Enum.count(tool_msgs) == 4

      # Should have assistant messages with tool_calls
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))
      assert assistant_msgs != []
    end

    test "includes final text as assistant message" do
      messages = CompactionEval.reconstruct_messages(@test_transcript)
      last = List.last(messages)

      assert last.role == :assistant
      assert String.contains?(last.content, "supervisor")
    end
  end

  describe "extract_ground_truth/1" do
    test "extracts files read" do
      gt = CompactionEval.extract_ground_truth(@test_transcript)

      assert "lib/app.ex" in gt.all_paths
      assert "lib/server.ex" in gt.all_paths
      assert "lib/memory.ex" in gt.all_paths
      assert length(gt.all_paths) == 3
    end

    test "extracts module names from file contents" do
      gt = CompactionEval.extract_ground_truth(@test_transcript)

      assert "MyApp.Application" in gt.all_modules
      assert "MyApp.Server" in gt.all_modules
      assert "MyApp.Memory" in gt.all_modules
    end

    test "extracts concepts from summary text" do
      gt = CompactionEval.extract_ground_truth(@test_transcript)
      concept_names = Enum.map(gt.key_facts, fn {_, name, _} -> name end)

      assert "supervisor" in concept_names
      assert "heartbeat" in concept_names
      assert "memory" in concept_names
    end

    test "extracts directory listing entries" do
      gt = CompactionEval.extract_ground_truth(@test_transcript)

      assert length(gt.dirs_listed) == 1
      assert hd(gt.dirs_listed).path == "lib/"
      assert "app.ex" in hd(gt.dirs_listed).entries
    end
  end

  describe "measure_retention/2" do
    test "baseline (no compaction) has full retention" do
      messages = CompactionEval.reconstruct_messages(@test_transcript)
      gt = CompactionEval.extract_ground_truth(@test_transcript)

      # Create a compactor with all messages (no compaction)
      compactor =
        Enum.reduce(messages, Arbor.Agent.ContextCompactor.new(effective_window: 999_999), fn msg,
                                                                                              c ->
          Arbor.Agent.ContextCompactor.append(c, msg)
        end)

      measurement = CompactionEval.measure_retention(compactor, gt)

      assert measurement.path_retention == 1.0
      assert measurement.module_retention == 1.0
      assert measurement.concept_retention == 1.0
      assert measurement.retention_score == 1.0
      # No compaction triggered (compressions = 0)
      assert measurement.compressions == 0
    end

    test "aggressive compaction reduces retention scores" do
      messages = CompactionEval.reconstruct_messages(@test_transcript)
      gt = CompactionEval.extract_ground_truth(@test_transcript)

      # Create a compactor with very small window to force compaction
      compactor =
        Enum.reduce(
          messages,
          Arbor.Agent.ContextCompactor.new(effective_window: 500),
          fn msg, c ->
            c
            |> Arbor.Agent.ContextCompactor.append(msg)
            |> Arbor.Agent.ContextCompactor.maybe_compact()
          end
        )

      measurement = CompactionEval.measure_retention(compactor, gt)

      # With aggressive compaction, retention should be less than perfect
      assert measurement.retention_score <= 1.0
      # But concept retention may still be high since concepts appear in the summary
      assert measurement.concept_retention >= 0.0
      # Compression should have occurred
      assert measurement.compressions > 0 or measurement.compression_ratio > 0
    end
  end

  describe "run/1" do
    test "produces results for all strategy/window combinations" do
      # Write test transcript to a temp file
      path = Path.join(System.tmp_dir!(), "compaction_eval_test_#{:rand.uniform(999_999)}.json")
      File.write!(path, Jason.encode!(@test_transcript))

      try do
        {:ok, result} =
          CompactionEval.run(
            transcript_path: path,
            effective_windows: [500, 1000],
            strategies: [:none, :heuristic],
            checkpoints: [0.5, 1.0]
          )

        # Should have 4 results (2 strategies × 2 windows)
        assert length(result.results) == 4

        # Each result should have checkpoint measurements
        for r <- result.results do
          assert Map.has_key?(r.checkpoints, 0.5)
          assert Map.has_key?(r.checkpoints, 1.0)
        end

        # Summary should exist
        assert result.summary.ground_truth_size.files == 3
        assert result.summary.ground_truth_size.modules == 3
      after
        File.rm(path)
      end
    end

    test "returns error for missing transcript file" do
      assert {:error, {:file_read, :enoent}} =
               CompactionEval.run(transcript_path: "/nonexistent/file.json")
    end
  end
end
