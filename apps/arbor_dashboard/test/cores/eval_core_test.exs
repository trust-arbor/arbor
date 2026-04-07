defmodule Arbor.Dashboard.Cores.EvalCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Dashboard.Cores.EvalCore

  @moduletag :fast

  defp sample_run do
    %{
      id: "run_001",
      status: "completed",
      domain: "coding",
      model: "claude-sonnet",
      duration_ms: 12_500,
      sample_count: 50,
      metrics: %{accuracy: 0.92, mean_score: 4.6},
      graders: ["correctness", "style"],
      scores: %{
        "correctness" => %{"score" => 0.92},
        "style" => 0.85
      },
      started_at: ~U[2026-04-07 12:00:00Z]
    }
  end

  # ── show_run/1 ───────────────────────────────────────────────────────

  describe "show_run/1" do
    test "shapes a run with all formatted fields" do
      result = EvalCore.show_run(sample_run())

      assert result.id == "run_001"
      assert result.status == "completed"
      assert result.status_color == :green
      assert result.domain == "coding"
      assert result.domain_color == :blue
      assert result.model == "claude-sonnet"
      assert result.duration_label == "12.5s"
      assert result.sample_count == 50
      assert result.sample_count_label == "50"
      assert result.accuracy_label == "92.0%"
      assert result.mean_score_label == "4.6"
      assert result.graders_label == "correctness, style"
      assert is_binary(result.scores_label)
      assert is_binary(result.time_relative)
    end

    test "tolerates missing fields" do
      result = EvalCore.show_run(%{})
      assert result.status_color == :gray
      assert result.domain_color == :gray
      assert result.duration_label == "--"
      assert result.sample_count == 0
      assert result.accuracy_label == "--"
      assert result.graders_label == "--"
    end

    test "supports string-keyed runs" do
      string_run = %{
        "id" => "run_002",
        "status" => "running",
        "domain" => "chat",
        "model" => "gpt-4"
      }

      result = EvalCore.show_run(string_run)
      assert result.id == "run_002"
      assert result.status == "running"
      assert result.status_color == :blue
      assert result.domain_color == :green
    end
  end

  describe "show_runs/1" do
    test "returns empty list for nil/empty input" do
      assert EvalCore.show_runs(nil) == []
      assert EvalCore.show_runs([]) == []
    end

    test "shapes a list of runs" do
      result = EvalCore.show_runs([sample_run()])
      assert length(result) == 1
      assert hd(result).id == "run_001"
    end
  end

  # ── compute_stats/1 ──────────────────────────────────────────────────

  describe "compute_stats/1" do
    test "default stats for nil/empty" do
      assert EvalCore.compute_stats(nil) == EvalCore.default_stats()
      assert EvalCore.compute_stats([]) == EvalCore.default_stats()
    end

    test "computes total, completed_pct, avg_accuracy, avg_duration" do
      runs = [
        %{status: "completed", metrics: %{accuracy: 0.9}, duration_ms: 1000},
        %{status: "completed", metrics: %{accuracy: 0.8}, duration_ms: 2000},
        %{status: "running", metrics: %{}, duration_ms: nil}
      ]

      stats = EvalCore.compute_stats(runs)

      assert stats.total == 3
      assert stats.completed_pct == "66.7%"
      # avg of 0.9 and 0.8 = 0.85 → "85.0%"
      assert stats.avg_accuracy == "85.0%"
      # avg of 1000 and 2000 = 1500ms → "1.5s"
      assert stats.avg_duration == "1.5s"
    end

    test "returns default values when no completed runs" do
      runs = [%{status: "running", duration_ms: nil}, %{status: "failed", duration_ms: nil}]
      stats = EvalCore.compute_stats(runs)

      assert stats.total == 2
      assert stats.completed_pct == "0.0%"
      assert stats.avg_accuracy == "--"
      assert stats.avg_duration == "--"
    end
  end

  # ── Field accessors ──────────────────────────────────────────────────

  describe "run_field/2" do
    test "reads atom-keyed fields" do
      assert EvalCore.run_field(%{status: "x"}, :status) == "x"
    end

    test "falls back to string keys" do
      assert EvalCore.run_field(%{"status" => "x"}, :status) == "x"
    end

    test "returns nil when both missing" do
      assert EvalCore.run_field(%{}, :status) == nil
    end
  end

  describe "get_accuracy/1" do
    test "reads atom or string-keyed accuracy" do
      assert EvalCore.get_accuracy(%{accuracy: 0.85}) == 0.85
      assert EvalCore.get_accuracy(%{"accuracy" => 0.7}) == 0.7
    end

    test "returns nil for missing accuracy or non-map" do
      assert EvalCore.get_accuracy(nil) == nil
      assert EvalCore.get_accuracy(%{}) == nil
      assert EvalCore.get_accuracy("garbage") == nil
    end
  end

  # ── Formatters ───────────────────────────────────────────────────────

  describe "format_pct/1" do
    test "formats numbers as percent with 1 decimal" do
      assert EvalCore.format_pct(0.92) == "92.0%"
      assert EvalCore.format_pct(0.857) == "85.7%"
    end

    test "handles nil and non-numbers" do
      assert EvalCore.format_pct(nil) == "--"
      assert EvalCore.format_pct("x") == "--"
    end
  end

  describe "format_accuracy/1" do
    test "formats accuracy from a metrics map" do
      assert EvalCore.format_accuracy(%{accuracy: 0.85}) == "85.0%"
    end

    test "handles missing accuracy gracefully" do
      assert EvalCore.format_accuracy(%{}) == "--"
      assert EvalCore.format_accuracy(nil) == "--"
    end
  end

  describe "format_mean_score/1" do
    test "rounds mean_score to 3 decimals" do
      assert EvalCore.format_mean_score(%{mean_score: 4.5678}) == "4.568"
    end

    test "handles missing or non-numeric" do
      assert EvalCore.format_mean_score(%{}) == "--"
      assert EvalCore.format_mean_score(nil) == "--"
    end
  end

  describe "format_sample_count/1" do
    test "formats integers as strings" do
      assert EvalCore.format_sample_count(42) == "42"
    end

    test "defaults nil and non-integers to '0'" do
      assert EvalCore.format_sample_count(nil) == "0"
      assert EvalCore.format_sample_count("garbage") == "0"
    end
  end

  describe "format_duration/1" do
    test "formats sub-second as Nms" do
      assert EvalCore.format_duration(500) == "500ms"
    end

    test "formats sub-minute as Ns with one decimal" do
      assert EvalCore.format_duration(12_500) == "12.5s"
    end

    test "formats minutes as 'Nm Ns'" do
      assert EvalCore.format_duration(125_000) == "2m 5s"
    end

    test "handles nil and zero" do
      assert EvalCore.format_duration(nil) == "--"
      assert EvalCore.format_duration(0) == "--"
    end
  end

  describe "format_graders/1" do
    test "joins grader names with commas" do
      assert EvalCore.format_graders(["a", "b", "c"]) == "a, b, c"
    end

    test "defaults nil and empty list" do
      assert EvalCore.format_graders(nil) == "--"
      assert EvalCore.format_graders([]) == "--"
    end
  end

  describe "format_scores/1" do
    test "formats nested score maps with grader names" do
      scores = %{
        "correctness" => %{"score" => 0.92},
        "style" => 0.85
      }

      result = EvalCore.format_scores(scores)
      assert String.contains?(result, "correctness: 0.92")
      assert String.contains?(result, "style: 0.85")
      assert String.contains?(result, " · ")
    end

    test "handles nil and empty map" do
      assert EvalCore.format_scores(nil) == ""
      assert EvalCore.format_scores(%{}) == ""
    end
  end

  describe "format_relative_time/1" do
    test "formats DateTime as 'Nm/Nh/Nd ago'" do
      now = DateTime.utc_now()
      one_min_ago = DateTime.add(now, -120, :second)
      assert EvalCore.format_relative_time(one_min_ago) =~ "m ago"

      one_hour_ago = DateTime.add(now, -3700, :second)
      assert EvalCore.format_relative_time(one_hour_ago) =~ "h ago"
    end

    test "returns 'just now' for sub-minute differences" do
      now = DateTime.utc_now()
      assert EvalCore.format_relative_time(now) == "just now"
    end

    test "handles ISO8601 strings" do
      result = EvalCore.format_relative_time("2026-04-07T12:00:00Z")
      assert is_binary(result)
    end

    test "handles nil and other input" do
      assert EvalCore.format_relative_time(nil) == ""
      assert EvalCore.format_relative_time(:weird) == ""
    end
  end

  # ── Colors ───────────────────────────────────────────────────────────

  describe "domain_color/1" do
    test "maps known domains" do
      assert EvalCore.domain_color("coding") == :blue
      assert EvalCore.domain_color("chat") == :green
      assert EvalCore.domain_color("heartbeat") == :purple
    end

    test "unknown defaults to gray" do
      assert EvalCore.domain_color("weird") == :gray
      assert EvalCore.domain_color(nil) == :gray
    end
  end

  describe "status_color/1" do
    test "maps known statuses" do
      assert EvalCore.status_color("completed") == :green
      assert EvalCore.status_color("running") == :blue
      assert EvalCore.status_color("failed") == :error
    end
  end

  describe "data_source_label/1 and data_source_color/1" do
    test "labels and colors" do
      assert EvalCore.data_source_label(:postgres) == "Postgres"
      assert EvalCore.data_source_label(:unavailable) == "Offline"
      assert EvalCore.data_source_color(:postgres) == :green
      assert EvalCore.data_source_color(:unavailable) == :error
    end
  end

  describe "tab_label/1" do
    test "maps known tabs" do
      assert EvalCore.tab_label("runs") == "Runs"
      assert EvalCore.tab_label("models") == "Models"
    end

    test "capitalizes unknowns" do
      assert EvalCore.tab_label("custom") == "Custom"
    end
  end

  describe "blank_to_nil/1" do
    test "empty string and nil become nil" do
      assert EvalCore.blank_to_nil("") == nil
      assert EvalCore.blank_to_nil(nil) == nil
    end

    test "non-blank strings pass through" do
      assert EvalCore.blank_to_nil("x") == "x"
    end
  end
end
