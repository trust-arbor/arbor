defmodule Arbor.Agent.Eval.SecurityReview.ReportTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.Report

  defp scored do
    %{
      by_reviewer_strategy: [
        %{
          reviewer: "qwen3.6-27b",
          strategy: :a,
          items: 3,
          recall_any: 0.67,
          recall_mean: 0.5,
          cross_file_items: 2,
          cross_file_recall_any: 0.0,
          unmatched_total: 4,
          elapsed_ms_total: 12_300
        },
        %{
          reviewer: "qwen3.6-27b",
          strategy: :b_lite,
          items: 3,
          recall_any: 1.0,
          recall_mean: 1.0,
          cross_file_items: 2,
          cross_file_recall_any: 1.0,
          unmatched_total: 2,
          elapsed_ms_total: 9000
        }
      ],
      cells: [
        %{
          reviewer: "qwen3.6-27b",
          strategy: :a,
          item_id: "taint",
          cross_file: false,
          matched: true
        },
        %{
          reviewer: "qwen3.6-27b",
          strategy: :a,
          item_id: "uri",
          cross_file: true,
          matched: false
        },
        %{
          reviewer: "qwen3.6-27b",
          strategy: :b_lite,
          item_id: "uri",
          cross_file: true,
          matched: true
        }
      ]
    }
  end

  test "renders the recall table and per-item matrix" do
    md =
      Report.render(scored(), %{
        timestamp: "20260618T000000",
        corpus_dir: "corp",
        reviewers: ["qwen3.6-27b"],
        strategies: [:a, :b_lite],
        k: 1,
        item_count: 3,
        cross_file_count: 2
      })

    assert md =~ "# Security Sentinel L2-review eval"
    assert md =~ "Recall by reviewer × strategy"
    # the headline numbers render
    assert md =~ "0.67"
    assert md =~ "1.00"
    # cross-file column shows the discriminator (A 0.00 vs B-lite 1.00)
    assert md =~ "0.00 (2)"
    assert md =~ "1.00 (2)"
    # per-item matrix marks the cross-file item and a match
    assert md =~ "uri ⨯"
    assert md =~ "✓"
  end

  test "write/3 writes the markdown to disk" do
    path = Path.join(System.tmp_dir!(), "secreport_#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm_rf(path) end)

    assert ^path = Report.write(scored(), %{corpus_dir: "c"}, path)
    assert File.read!(path) =~ "Recall by reviewer"
  end
end
