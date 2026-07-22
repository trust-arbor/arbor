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

  test "projects a bounded provider session id through successful coding payload and report" do
    raw = %{
      "status" => "change_committed",
      "branch" => "agent/change",
      "worktree_path" => "/tmp/ws",
      "worker_provider_session_id" => "provider-session-1"
    }

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    assert result.payload.worker_provider_session_id == "provider-session-1"
    assert result.payload.report.worker_provider_session_id == "provider-session-1"
    assert result.raw === raw
  end

  test "projects a bounded provider session id through pipeline-error coding payload and report" do
    raw = %{
      "status" => "pipeline_error",
      "error" => "acquire failed",
      "worker_provider_session_id" => "provider-session-failure-1"
    }

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    assert result.payload.worker_provider_session_id == "provider-session-failure-1"
    assert result.payload.report.status == "pipeline_error"
    assert result.payload.report.worker_provider_session_id == "provider-session-failure-1"
    assert result.raw === raw
  end

  test "omits invalid provider session ids while preserving raw coding results" do
    for provider_session_id <- [
          nil,
          42,
          "",
          "bad\x00session",
          <<255>>,
          String.duplicate("a", 201)
        ] do
      raw = %{
        "status" => "change_committed",
        "branch" => "agent/change",
        "worktree_path" => "/tmp/ws",
        "worker_provider_session_id" => provider_session_id
      }

      result = TaskArtifacts.normalize(raw)

      assert result.result_type == :coding_change
      refute Map.has_key?(result.payload, :worker_provider_session_id)
      refute Map.has_key?(result.payload.report, :worker_provider_session_id)
      assert result.raw === raw
    end
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

  test "existing terminal variants including capacity still normalize" do
    for status <- ~w(
           declined validation_failed validation_capacity_exceeded no_changes pr_failed
           review_rejected
         ) do
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

  test "promotes optional bounded acp_transcript descriptor only" do
    transcript = %{
      "path" => "/tmp/task/acp-transcript.json",
      "sha256" => String.duplicate("b", 64),
      "byte_size" => 128,
      "turns_retained" => 2,
      "turns_seen" => 2,
      "turns_omitted" => 0,
      "turns_truncated" => false,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => "task-1"
    }

    artifacts = coding_artifacts(%{"acp_transcript" => transcript})
    raw = %{status: "change_committed", branch: "agent/x", artifacts: artifacts}

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    assert result.payload.artifacts["acp_transcript"] === transcript
    refute Map.has_key?(result.payload.artifacts["acp_transcript"], "turns")
  end

  test "promotes and canonicalizes a valid task evidence descriptor" do
    task_evidence = %{
      path: "/tmp/task/task-evidence.json",
      sha256: String.duplicate("d", 64),
      byte_size: 96,
      schema_version: 1,
      task_id: "task-1"
    }

    artifacts = coding_artifacts(%{"task_evidence" => task_evidence})
    raw = %{status: "change_committed", branch: "agent/x", artifacts: artifacts}

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change

    assert result.payload.artifacts["task_evidence"] == %{
             "path" => "/tmp/task/task-evidence.json",
             "sha256" => String.duplicate("d", 64),
             "byte_size" => 96,
             "schema_version" => 1,
             "task_id" => "task-1"
           }

    assert result.payload.report.artifacts["task_evidence"] ==
             result.payload.artifacts["task_evidence"]
  end

  test "security regression: rejects inline, unknown, and malformed task evidence" do
    valid = %{
      "path" => "/tmp/task/task-evidence.json",
      "sha256" => String.duplicate("e", 64),
      "byte_size" => 96,
      "schema_version" => 1,
      "task_id" => "task-1"
    }

    for bad <- [
          Map.put(valid, "content", "inline evidence"),
          Map.put(valid, "authority", "execute"),
          Map.put(valid, "sha256", "not-a-digest"),
          Map.delete(valid, "task_id")
        ] do
      raw = %{
        "status" => "no_changes",
        "artifacts" => coding_artifacts(%{"task_evidence" => bad})
      }

      assert TaskArtifacts.normalize(raw) == %{
               result_type: :value,
               payload: %{value: raw},
               raw: raw
             }
    end
  end

  test "security regression: rejects inline unknown and malformed acp transcript descriptors" do
    valid = %{
      "path" => "/tmp/t.json",
      "sha256" => String.duplicate("c", 64),
      "byte_size" => 1,
      "turns_retained" => 1,
      "turns_seen" => 1,
      "turns_omitted" => 0,
      "turns_truncated" => false,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => "task-1"
    }

    for bad <- [
          coding_artifacts(%{"acp_transcript" => Map.put(valid, "turns", [])}),
          coding_artifacts(%{"acp_transcript" => Map.put(valid, "authority", "no")}),
          coding_artifacts(%{"acp_transcript" => Map.put(valid, "sha256", "not-a-digest")}),
          coding_artifacts(%{"acp_transcript" => Map.put(valid, "turns_omitted", 4)}),
          coding_artifacts(%{"acp_transcript" => Map.delete(valid, "task_id")})
        ] do
      raw = %{"status" => "no_changes", "artifacts" => bad}

      assert TaskArtifacts.normalize(raw) == %{
               result_type: :value,
               payload: %{value: raw},
               raw: raw
             }
    end
  end

  test "promotes only the canonical workspace release descriptor" do
    artifacts =
      coding_artifacts(%{
        "workspace_release" => %{
          workspace_release_status: :retained,
          workspace_expires_at: "2026-07-16T12:00:00+00:00"
        }
      })

    raw = %{"status" => "change_committed", "artifacts" => artifacts}
    result = TaskArtifacts.normalize(raw)

    assert result.payload.artifacts["workspace_release"] == %{
             "workspace_release_status" => "retained",
             "workspace_expires_at" => "2026-07-16T12:00:00Z"
           }

    removed =
      coding_artifacts(%{
        "workspace_release" => %{"workspace_release_status" => "removed"}
      })

    removed_result =
      TaskArtifacts.normalize(%{"status" => "no_changes", "artifacts" => removed})

    assert removed_result.payload.artifacts["workspace_release"] == %{
             "workspace_release_status" => "removed"
           }
  end

  test "promotes canonical branch lifecycle evidence and rejects disagreement" do
    lifecycle = %{
      "branch_status" => "pending",
      "cleanup_status" => "retrying",
      "cleanup_retry_count" => 1,
      "cleanup_retry_limit" => 3,
      "cleanup_failure_category" => "worktree_remove_failed",
      "discard_phase" => "worktree"
    }

    matching = %{
      "status" => "no_changes",
      "artifacts" => coding_artifacts(%{"branch_lifecycle" => lifecycle})
    }

    matching_result = TaskArtifacts.normalize(matching)

    assert matching_result.payload.branch_lifecycle == lifecycle
    assert matching_result.payload.artifacts["branch_lifecycle"] == lifecycle

    top_level_only = %{
      "status" => "no_changes",
      "branch_lifecycle" => lifecycle
    }

    assert TaskArtifacts.normalize(top_level_only) == %{
             result_type: :value,
             payload: %{value: top_level_only},
             raw: top_level_only
           }

    mismatch = %{
      "status" => "no_changes",
      "branch_lifecycle" => %{"branch_status" => "retired", "cleanup_status" => "complete"},
      "artifacts" => coding_artifacts(%{"branch_lifecycle" => lifecycle})
    }

    assert TaskArtifacts.normalize(mismatch) == %{
             result_type: :value,
             payload: %{value: mismatch},
             raw: mismatch
           }

    bad = Map.put(lifecycle, "workspace_id", "authority")

    malformed_candidate = %{
      "status" => "no_changes",
      "branch" => "agent/change",
      "artifacts" => coding_artifacts(%{"branch_lifecycle" => bad})
    }

    assert TaskArtifacts.normalize(malformed_candidate) == %{
             result_type: :value,
             payload: %{value: malformed_candidate},
             raw: malformed_candidate
           }

    assert TaskArtifacts.normalize(%{
             "status" => "no_changes",
             "artifacts" => coding_artifacts(%{"branch_lifecycle" => bad})
           }) == %{
             result_type: :value,
             payload: %{
               value: %{
                 "status" => "no_changes",
                 "artifacts" => coding_artifacts(%{"branch_lifecycle" => bad})
               }
             },
             raw: %{
               "status" => "no_changes",
               "artifacts" => coding_artifacts(%{"branch_lifecycle" => bad})
             }
           }
  end

  test "security regression: rejects hostile workspace release descriptors" do
    valid = %{"workspace_release_status" => "retained"}

    for bad <- [
          Map.put(valid, "workspace_id", "workspace_authority"),
          Map.put(valid, "workspace_expires_at", String.duplicate("2", 65)),
          Map.put(valid, "workspace_expires_at", "not-iso8601"),
          Map.put(valid, "workspace_expires_at", Integer.pow(10, 100)),
          %{
            "workspace_release_status" => "removed",
            "workspace_expires_at" => "2026-07-16T12:00:00Z"
          },
          Map.put(valid, :workspace_release_status, :retained)
        ] do
      raw = %{
        "status" => "no_changes",
        "artifacts" => coding_artifacts(%{"workspace_release" => bad})
      }

      assert TaskArtifacts.normalize(raw) == %{
               result_type: :value,
               payload: %{value: raw},
               raw: raw
             }
    end
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
