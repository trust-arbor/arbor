defmodule Arbor.Agent.Orchestration.TaskArtifactsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Orchestration.TaskArtifacts
  alias Arbor.Contracts.Coding.TaskOutcomeRegistry

  test "recognizes exactly the closed coding result status set" do
    for status <- TaskOutcomeRegistry.coding_result_statuses() do
      result =
        TaskArtifacts.normalize(%{
          "status" => status,
          "branch" => "agent/change",
          "worktree_path" => "/tmp/ws"
        })

      assert result.result_type == :coding_change
      assert result.payload.report.status == status
    end

    unknown = TaskArtifacts.normalize(%{"status" => "unknown_status", "branch" => "agent/change"})
    assert unknown.result_type == :value
  end

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

  test "projects the exact canonical outcome into payload and report" do
    outcome = task_outcome()

    raw = %{
      "status" => "change_committed",
      "branch" => "agent/change",
      "worktree_path" => "/tmp/ws",
      "outcome" => outcome
    }

    result = TaskArtifacts.normalize(raw)

    assert result.result_type == :coding_change
    assert result.payload.outcome === outcome
    assert result.payload.report.outcome === outcome
    assert result.raw === raw
    assert TaskArtifacts.extract_outcome(result) == {:ok, outcome}
  end

  test "malformed or noncanonical outcomes fail closed from coding promotion" do
    outcome = task_outcome()

    for malformed <- [
          Map.put(outcome, "diagnostic_refs", []),
          Map.put(outcome, :code, outcome["code"]),
          Map.put(outcome, "code", 42)
        ] do
      raw = %{
        "status" => "change_committed",
        "branch" => "agent/change",
        "worktree_path" => "/tmp/ws",
        "outcome" => malformed
      }

      assert TaskArtifacts.normalize(raw) == %{
               result_type: :value,
               payload: %{value: raw},
               raw: raw
             }

      assert TaskArtifacts.extract_outcome(raw) == :error
    end
  end

  test "legacy coding results and prose do not infer an outcome" do
    legacy = %{
      "status" => "change_committed",
      "branch" => "agent/change",
      "worktree_path" => "/tmp/ws"
    }

    legacy_result = TaskArtifacts.normalize(legacy)
    assert legacy_result.result_type == :coding_change
    refute Map.has_key?(legacy_result.payload, :outcome)
    refute Map.has_key?(legacy_result.payload.report, :outcome)

    prose = Map.put(legacy, "response_text", "The outcome was succeeded and the change is done.")
    prose_result = TaskArtifacts.normalize(prose)
    assert prose_result.result_type == :coding_change
    refute Map.has_key?(prose_result.payload, :outcome)
    assert TaskArtifacts.extract_outcome(prose) == :error
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

  defp task_outcome do
    %{
      "version" => 1,
      "disposition" => "succeeded",
      "code" => "implemented",
      "phase" => "worker_turn",
      "origin" => "worker",
      "retry" => "none",
      "message" => "completed"
    }
  end

  describe "blocking findings" do
    defp review_raw(findings) do
      %{
        "status" => "human_review_required",
        "branch" => "b",
        "review" => %{
          "verdict" => %{"decision" => "rejected"},
          "finding_ledger" => %{"findings" => findings}
        }
      }
    end

    test "carries consolidated_findings next to the ledger on the task payload" do
      raw =
        review_raw(%{
          "aaa" => %{
            "id" => "aaa",
            "state" => "open",
            "blocks_merge" => true,
            "severity" => "blocking",
            "owner" => "security"
          }
        })
        |> put_in(["review", "consolidated_findings"], [
          %{
            "issue_key" => "issue-1",
            "owners" => ["security", "correctness"],
            "severity" => "blocking",
            "blocks_merge" => true,
            "title" => "Max rounds off-by-one",
            "required_actions" => [String.duplicate("a", 1_500), String.duplicate("a", 1_500)],
            "anchor" => %{"path" => "lib/rounds.ex", "line" => 42}
          }
        ])

      assert [finding] = get_in(TaskArtifacts.normalize(raw), [:payload, :consolidated_findings])
      assert finding.issue_key == "issue-1"
      assert finding.owners == ["correctness", "security"]
      assert finding.required_actions == [String.duplicate("a", 1_000)]
      assert finding.title == "Max rounds off-by-one"
    end

    test "surfaces blocking findings from the result, not just their hashed ids" do
      # Regression: the actionable output of a rejected review used to be
      # reachable only by reading the temp evidence JSON off disk and matching
      # blocking_ids hashes against finding_ledger.findings.
      raw =
        review_raw(%{
          "aaa" => %{
            "id" => "aaa",
            "state" => "open",
            "blocks_merge" => true,
            "severity" => "blocking",
            "owner" => "security",
            "title" => "Confused deputy",
            "evidence" => "signs for a caller-named principal",
            "required_action" => "bind to an authenticated caller",
            "anchor" => %{"path" => "lib/x.ex", "line" => 155}
          },
          "bbb" => %{"id" => "bbb", "blocks_merge" => false, "severity" => "nit"}
        })

      assert [finding] = get_in(TaskArtifacts.normalize(raw), [:payload, :blocking_findings])
      assert finding.id == "aaa"
      assert finding.title == "Confused deputy"
      assert finding.required_action == "bind to an authenticated caller"
      assert finding.anchor == %{path: "lib/x.ex", line: 155}
    end

    test "omits the key entirely when nothing blocks" do
      raw = review_raw(%{"bbb" => %{"id" => "bbb", "blocks_merge" => false}})
      refute Map.has_key?(TaskArtifacts.normalize(raw).payload, :blocking_findings)
    end

    test "bounds how many findings and how much text it will echo" do
      many =
        for i <- 1..40, into: %{} do
          {"f#{i}",
           %{
             "id" => "f#{i}",
             "state" => "open",
             "blocks_merge" => true,
             "evidence" => String.duplicate("x", 5_000)
           }}
        end

      findings = get_in(TaskArtifacts.normalize(review_raw(many)), [:payload, :blocking_findings])
      assert length(findings) == 16
      assert Enum.all?(findings, &(byte_size(&1.evidence) == 2_048))
    end

    test "omits fixed and otherwise inactive findings while retaining active merge blockers" do
      raw =
        review_raw(%{
          "open" => %{
            "id" => "open",
            "owner" => "aaa",
            "state" => "open",
            "blocks_merge" => true,
            "title" => "live open"
          },
          "new_regression" => %{
            "id" => "new_regression",
            "owner" => "bbb",
            "state" => "new_regression",
            "blocks_merge" => true,
            "title" => "live regression"
          },
          "arch" => %{
            "id" => "arch",
            "owner" => "ccc",
            "state" => "architectural_blocker",
            "severity" => "blocking",
            "title" => "live architectural"
          },
          "fixed" => %{
            "id" => "fixed",
            "owner" => "ddd",
            "state" => "fixed",
            "blocks_merge" => true,
            "severity" => "blocking",
            "title" => "already fixed"
          },
          "resolved" => %{
            "id" => "resolved",
            "owner" => "eee",
            "state" => "resolved",
            "blocks_merge" => true,
            "title" => "already resolved"
          },
          "oos" => %{
            "id" => "oos",
            "owner" => "fff",
            "state" => "out_of_scope",
            "blocks_merge" => true,
            "title" => "out of scope"
          },
          "nit" => %{
            "id" => "nit",
            "owner" => "ggg",
            "state" => "open",
            "blocks_merge" => false,
            "severity" => "nit",
            "title" => "open nit"
          }
        })

      findings = get_in(TaskArtifacts.normalize(raw), [:payload, :blocking_findings])
      assert Enum.map(findings, & &1.id) == ["open", "new_regression", "arch"]
      refute Enum.any?(findings, &(&1.id in ["fixed", "resolved", "oos", "nit"]))
    end

    test "surfaces an active architectural blocker with nit severity and false blocks_merge" do
      raw =
        review_raw(%{
          "arch" => %{
            "id" => "arch",
            "state" => "architectural_blocker",
            "severity" => "nit",
            "blocks_merge" => false,
            "title" => "grain mismatch"
          },
          "nit" => %{
            "id" => "nit",
            "state" => "open",
            "severity" => "nit",
            "blocks_merge" => false,
            "title" => "open nit"
          }
        })

      assert [finding] = get_in(TaskArtifacts.normalize(raw), [:payload, :blocking_findings])
      assert finding.id == "arch"
      assert finding.state == "architectural_blocker"
      assert finding.severity == "nit"
    end

    test "hostile finding scalars and anchors do not crash projection" do
      raw =
        review_raw(%{
          "good" => %{
            "id" => "good",
            "owner" => "security",
            "state" => "open",
            "blocks_merge" => true,
            "title" => "real",
            "anchor" => %{"path" => "lib/ok.ex", "line" => 1}
          },
          "hostile" => %{
            "id" => %{"nested" => true},
            "owner" => [1, 2, 3],
            "state" => "open",
            "blocks_merge" => true,
            "title" => %{"x" => 1},
            "evidence" => %{"y" => 2},
            "required_action" => %{"z" => 3},
            "anchor" => %{"path" => %{}, "line" => [10]}
          }
        })

      findings = get_in(TaskArtifacts.normalize(raw), [:payload, :blocking_findings])
      assert length(findings) == 2
      assert {:ok, _} = Jason.encode(findings)

      good = Enum.find(findings, &(&1[:id] == "good"))
      assert good.title == "real"
      assert good.anchor == %{path: "lib/ok.ex", line: 1}

      hostile = Enum.find(findings, &(not Map.has_key?(&1, :id)))
      refute Map.has_key?(hostile, :title)
      refute Map.has_key?(hostile, :owner)
      refute Map.has_key?(hostile, :evidence)
      refute Map.has_key?(hostile, :required_action)
      refute Map.has_key?(hostile, :anchor)
      assert hostile.state == "open"
    end

    test "bounds finding text on UTF-8 codepoint boundaries" do
      mixed = String.duplicate("a", 2047) <> "é"

      [mixed_finding] =
        get_in(
          TaskArtifacts.normalize(
            review_raw(%{
              "aaa" => %{
                "id" => "aaa",
                "state" => "open",
                "blocks_merge" => true,
                "evidence" => mixed
              }
            })
          ),
          [:payload, :blocking_findings]
        )

      assert String.valid?(mixed_finding.evidence)
      assert byte_size(mixed_finding.evidence) == 2047
      refute String.ends_with?(mixed_finding.evidence, "é")

      accents = String.duplicate("é", 2000)

      [accent_finding] =
        get_in(
          TaskArtifacts.normalize(
            review_raw(%{
              "bbb" => %{
                "id" => "bbb",
                "state" => "open",
                "blocks_merge" => true,
                "evidence" => accents
              }
            })
          ),
          [:payload, :blocking_findings]
        )

      assert String.valid?(accent_finding.evidence)
      assert byte_size(accent_finding.evidence) == 2048
      assert rem(byte_size(accent_finding.evidence), 2) == 0
    end

    test "invalid UTF-8 finding scalars are omitted without crashing" do
      raw =
        review_raw(%{
          "bad" => %{
            "id" => "bad",
            "state" => "open",
            "blocks_merge" => true,
            "title" => <<0xFF, 0xFE>>,
            "evidence" => "ok" <> <<0x80>>
          },
          "sort-bad" => %{
            "id" => <<0xFF>>,
            "owner" => <<0x80>>,
            "state" => "open",
            "blocks_merge" => true,
            "title" => "still here"
          },
          "good" => %{
            "id" => "good",
            "state" => "open",
            "blocks_merge" => true,
            "title" => "valid sibling"
          }
        })

      findings = get_in(TaskArtifacts.normalize(raw), [:payload, :blocking_findings])

      bad = Enum.find(findings, &(&1[:id] == "bad"))
      refute Map.has_key?(bad, :title)
      refute Map.has_key?(bad, :evidence)

      good = Enum.find(findings, &(&1[:id] == "good"))
      assert good.title == "valid sibling"

      sort_bad = Enum.find(findings, &(&1[:title] == "still here"))
      refute Map.has_key?(sort_bad, :id)
      refute Map.has_key?(sort_bad, :owner)
    end
  end
end
