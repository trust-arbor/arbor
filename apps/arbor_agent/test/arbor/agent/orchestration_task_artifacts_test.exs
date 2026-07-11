defmodule Arbor.Agent.Orchestration.TaskArtifactsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Orchestration.TaskArtifacts

  test "normalizes change_committed coding results" do
    raw = %{
      status: "change_committed",
      branch: "agent/change",
      commit: "abc123",
      worktree_path: "/tmp/ws",
      validation: [%{command: "mix test", passed: true}],
      review_recommendation: :keep
    }

    result = TaskArtifacts.normalize(raw)
    assert result.result_type == :coding_change
    assert result.payload.branch == "agent/change"
    assert result.payload.report.status == "change_committed"
    assert result.payload.verdict.recommendation == :keep
  end

  test "accepts rework_exhausted as a coding status" do
    raw = %{
      "status" => "rework_exhausted",
      "canonical_status" => "rework_exhausted",
      "branch" => "agent/change",
      "worktree_path" => "/tmp/ws",
      "review" => %{"tier_decision" => "rework"}
    }

    result = TaskArtifacts.normalize(raw)
    assert result.result_type == :coding_change
    assert result.payload.report.status == "rework_exhausted"
    assert result.payload.report.canonical_status == "rework_exhausted"
  end

  test "carries bounded approval_request_id and approval_note through stable report" do
    raw = %{
      "status" => "approval_denied",
      "worktree_path" => "/tmp/ws",
      "branch" => "agent/change",
      "approval_request_id" => "irq_deadbeefcafebabe",
      "approval_note" => "please no"
    }

    result = TaskArtifacts.normalize(raw)
    assert result.result_type == :coding_change
    assert result.payload.report.status == "approval_denied"
    assert result.payload.report.approval_request_id == "irq_deadbeefcafebabe"
    assert result.payload.report.approval_note == "please no"
  end

  test "drops invalid approval_request_id and control-bearing notes from report" do
    raw = %{
      "status" => "approval_denied",
      "worktree_path" => "/tmp/ws",
      "branch" => "agent/change",
      "approval_request_id" => "irq has spaces",
      "approval_note" => "bad\x00note"
    }

    result = TaskArtifacts.normalize(raw)
    assert result.result_type == :coding_change
    refute Map.has_key?(result.payload.report, :approval_request_id)
    refute Map.has_key?(result.payload.report, :approval_note)
  end

  test "accepts review_requires_rework compatibility status with canonical_status" do
    raw = %{
      "status" => "review_requires_rework",
      "canonical_status" => "rework_exhausted",
      "branch" => "agent/change",
      "commit" => "deadbeef",
      "worktree_path" => "/tmp/ws",
      "review" => %{"recommendation" => "revise"}
    }

    result = TaskArtifacts.normalize(raw)
    assert result.result_type == :coding_change
    assert result.payload.report.status == "review_requires_rework"
    assert result.payload.report.canonical_status == "rework_exhausted"
    assert result.raw["canonical_status"] == "rework_exhausted"
  end

  test "existing declined and validation_failed variants still normalize" do
    for status <- ~w(declined validation_failed no_changes pr_failed review_rejected) do
      raw = %{
        status: status,
        worktree_path: "/tmp/ws",
        branch: "b"
      }

      result = TaskArtifacts.normalize(raw)
      assert result.result_type == :coding_change
      assert result.payload.report.status == status
    end
  end

  test "promotes a valid coding artifact descriptor without changing it" do
    artifacts = coding_artifacts()

    raw = %{status: "validation_failed", artifacts: artifacts}

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    assert result.payload.artifacts === artifacts
    assert result.payload.report.artifacts === artifacts
    assert result.raw === raw
  end

  test "accepts a valid descriptor under string-key result fields" do
    artifacts = coding_artifacts()

    raw = %{"status" => "no_changes", "artifacts" => artifacts}

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    assert result.payload.artifacts === artifacts
    assert result.payload.report.artifacts === artifacts
    assert result.raw === raw
  end

  test "security regression: arbitrary artifacts cannot classify a declined result as coding" do
    raw = %{
      "status" => "declined",
      "artifacts" => %{"invoice_path" => "/tmp/invoice.pdf"}
    }

    assert TaskArtifacts.normalize(raw) == %{
             result_type: :value,
             payload: %{value: raw},
             raw: raw
           }
  end

  test "malformed coding descriptors cannot bootstrap coding classification" do
    for artifacts <- [
          Map.delete(coding_artifacts(), "compile_manifest_path"),
          coding_artifacts(%{"graph_hash" => String.duplicate("A", 64)}),
          coding_artifacts(%{"extra" => "not part of the exact descriptor"})
        ] do
      raw = %{"status" => "no_changes", "artifacts" => artifacts}

      assert TaskArtifacts.normalize(raw) == %{
               result_type: :value,
               payload: %{value: raw},
               raw: raw
             }
    end
  end

  test "malformed artifacts are not promoted when other coding evidence exists" do
    artifacts = %{"invoice_path" => "/tmp/invoice.pdf"}
    raw = %{status: "declined", branch: "agent/change", artifacts: artifacts}

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    refute Map.has_key?(result.payload, :artifacts)
    refute Map.has_key?(result.payload.report, :artifacts)
    assert result.raw === raw
  end

  test "promotes valid atom- and string-keyed metrics into payload and report" do
    cases = [
      %{
        status: "change_committed",
        branch: "agent/atom-metrics",
        metrics: %{
          execution_path: "pipeline",
          wall_clock_ms: 12,
          usage: %{input_tokens: 34}
        }
      },
      %{
        "status" => "change_committed",
        "branch" => "agent/string-metrics",
        "metrics" => %{
          "execution_path" => "pipeline",
          "wall_clock_ms" => 12,
          "usage" => %{"input_tokens" => 34}
        }
      }
    ]

    for raw <- cases do
      metrics = Map.get(raw, :metrics, Map.get(raw, "metrics"))
      result = TaskArtifacts.normalize(raw)

      assert result.result_type == :coding_change
      assert result.payload.metrics === metrics
      assert result.payload.report.metrics === metrics
      assert result.raw === raw
    end
  end

  test "malformed metrics are omitted from an otherwise coding result" do
    malformed_metrics = [
      %URI{scheme: "https", host: "example.com"},
      %{1 => "non-string-or-atom key"},
      %{"worker" => self()},
      %{"callback" => fn -> :ok end},
      %{"nested" => [%{"valid" => true}, {:runtime, :tuple}]},
      %{"status" => :not_json}
    ]

    for metrics <- malformed_metrics do
      raw = %{
        status: "change_committed",
        branch: "agent/change",
        worktree_path: "/tmp/ws",
        metrics: metrics
      }

      result = TaskArtifacts.normalize(raw)

      assert result.result_type == :coding_change
      refute Map.has_key?(result.payload, :metrics)
      refute Map.has_key?(result.payload.report, :metrics)
      assert result.raw === raw
    end
  end

  test "metrics do not classify an otherwise generic result as coding" do
    raw = %{
      "status" => "change_committed",
      "metrics" => %{
        "execution_path" => "pipeline",
        "wall_clock_ms" => 12
      }
    }

    assert TaskArtifacts.normalize(raw) == %{
             result_type: :value,
             payload: %{value: raw},
             raw: raw
           }
  end

  test "artifact-like data does not change generic result fallbacks" do
    raw = %{
      "status" => "running",
      "artifacts" => %{"plan" => %{"path" => "/tmp/task/coding-plan.json"}}
    }

    assert TaskArtifacts.normalize(raw) == %{
             result_type: :value,
             payload: %{value: raw},
             raw: raw
           }
  end

  test "generic chat fallback is unchanged" do
    result = TaskArtifacts.normalize("hello")
    assert result.result_type == :chat
    assert result.payload.text == "hello"
  end

  defp coding_artifacts(overrides \\ %{}) do
    Map.merge(
      %{
        "coding_plan_path" => "/tmp/task/coding-plan.json",
        "coding_pipeline_path" => "/tmp/task/coding-pipeline.dot",
        "compile_manifest_path" => "/tmp/task/coding-compile-manifest.json",
        "compiler_version" => "coding-plan-1",
        "graph_hash" => String.duplicate("a", 64)
      },
      overrides
    )
  end
end
