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

  test "generic chat fallback is unchanged" do
    result = TaskArtifacts.normalize("hello")
    assert result.result_type == :chat
    assert result.payload.text == "hello"
  end
end
