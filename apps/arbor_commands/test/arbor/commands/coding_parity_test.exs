defmodule Arbor.Commands.CodingParityTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Commands.CodingParity

  @tree_a String.duplicate("a", 40)
  @tree_b String.duplicate("b", 40)

  test "different volatile execution details preserve semantic parity" do
    assert {:ok, legacy} = CodingParity.project(legacy_result(), legacy_observations())
    assert {:ok, pipeline} = CodingParity.project(pipeline_result(), %{"tree_oid" => @tree_a})

    assert legacy["semantic"]["changed_files"] == [
             "apps/arbor_commands/lib/a.ex",
             "apps/arbor_commands/test/a_test.exs"
           ]

    assert legacy["semantic"] == pipeline["semantic"]

    assert legacy["semantic"]["cleanup"] == %{
             "completed" => true,
             "resources_cleaned" => true,
             "status" => "retained",
             "workspace_removed" => false,
             "workspace_retained" => true
           }

    assert legacy["semantic"]["cancellation"] == %{
             "cancelled" => false,
             "cleanup_completed" => true,
             "requested" => false,
             "status" => "not_requested",
             "worker_terminated" => false
           }

    assert legacy["semantic"]["approval"] == %{
             "count" => 0,
             "requested" => false,
             "required" => false,
             "resumed" => false,
             "status" => "not_required"
           }

    assert {:ok, comparison} = CodingParity.compare(legacy, pipeline)
    assert comparison["equivalent?"] == true
    assert comparison["differences"] == []

    refute inspect(comparison) =~ "legacy/task-123"
    refute inspect(comparison) =~ "pipeline/task-987"
    refute inspect(comparison) =~ "legacy-worker-id"
    refute inspect(comparison) =~ "pipeline-worker-id"
  end

  test "tree validation review and cleanup differences are sorted by field" do
    changed_pipeline =
      pipeline_result()
      |> put_in(["payload", "report", "validation"], [%{"passed" => false}])
      |> put_in(["payload", "report", "review", "recommendation"], "revise")
      |> put_in(["raw", "metrics", "workspace_release_status"], "removed")

    assert {:ok, legacy} = CodingParity.project(legacy_result(), legacy_observations())
    assert {:ok, pipeline} = CodingParity.project(changed_pipeline, %{"tree_oid" => @tree_b})
    assert {:ok, comparison} = CodingParity.compare(legacy, pipeline)

    assert comparison["equivalent?"] == false

    assert Enum.map(comparison["differences"], & &1["field"]) == [
             "cleanup",
             "review.recommendation",
             "tree_oid",
             "validation_outcome"
           ]

    assert Enum.find(comparison["differences"], &(&1["field"] == "tree_oid")) == %{
             "field" => "tree_oid",
             "left" => @tree_a,
             "right" => @tree_b
           }
  end

  test "pipeline artifact richness is reported without changing equivalence" do
    assert {:ok, legacy} = CodingParity.project(legacy_result(), legacy_observations())
    assert {:ok, pipeline} = CodingParity.project(pipeline_result(), %{"tree_oid" => @tree_a})
    assert {:ok, comparison} = CodingParity.compare(legacy, pipeline)

    assert comparison["equivalent?"] == true

    assert comparison["artifact_quality"] == %{
             "left" => %{
               "digest" => false,
               "dot" => false,
               "manifest" => false,
               "plan" => false
             },
             "right" => %{
               "digest" => true,
               "dot" => true,
               "manifest" => true,
               "plan" => true
             }
           }
  end

  test "projects bounded approval_request_id and approval_note into stable semantic" do
    result =
      legacy_result()
      |> put_in([:payload, :report, :status], "approval_denied")
      |> put_in([:payload, :report, :canonical_status], "approval_denied")
      |> put_in([:payload, :report, :approval_request_id], "irq_deadbeefcafebabe")
      |> put_in([:payload, :report, :approval_note], "please no")

    observations =
      Map.put(legacy_observations(), :approval, %{
        status: :denied,
        requested: true,
        required: true,
        resumed: false,
        count: 1
      })

    assert {:ok, projection} = CodingParity.project(result, observations)
    assert projection["semantic"]["terminal_status"] == "approval_denied"
    assert projection["semantic"]["approval_request_id"] == "irq_deadbeefcafebabe"
    assert projection["semantic"]["approval_note"] == "please no"
  end

  test "opaque approval_request_id and approval_note differences do not break parity" do
    left_result =
      legacy_result()
      |> put_in([:payload, :report, :approval_request_id], "irq_leftaaaaaaaaaaaa")
      |> put_in([:payload, :report, :approval_note], "left note")

    right_result =
      pipeline_result()
      |> put_in(["payload", "report", "approval_request_id"], "irq_rightbbbbbbbbbbb")
      |> put_in(["payload", "report", "approval_note"], "right note")

    left_obs =
      Map.put(legacy_observations(), :approval, %{
        status: :approved,
        requested: true,
        required: true,
        resumed: true,
        count: 1
      })

    right_obs = %{
      "tree_oid" => @tree_a,
      "approval" => %{
        "status" => "approved",
        "requested" => true,
        "required" => true,
        "resumed" => true,
        "count" => 1
      },
      "cancellation" => %{
        "cancelled" => false,
        "cleanup_completed" => true,
        "requested" => false,
        "status" => "not_requested",
        "worker_terminated" => false
      },
      "cleanup" => %{
        "completed" => true,
        "status" => "retained",
        "resources_cleaned" => true,
        "workspace_removed" => false,
        "workspace_retained" => true
      }
    }

    assert {:ok, left} = CodingParity.project(left_result, left_obs)
    assert {:ok, right} = CodingParity.project(right_result, right_obs)

    assert left["semantic"]["approval_request_id"] != right["semantic"]["approval_request_id"]
    assert left["semantic"]["approval_note"] != right["semantic"]["approval_note"]
    assert left["semantic"]["approval"] == right["semantic"]["approval"]

    assert {:ok, comparison} = CodingParity.compare(left, right)
    assert comparison["equivalent?"] == true
    assert comparison["differences"] == []

    refute Enum.any?(
             comparison["differences"],
             &(&1["field"] in ~w(approval_request_id approval_note))
           )
  end

  test "atom and string fixtures project identically and remain JSON clean" do
    unknown_key = "parity_fixture_key_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    atom_fixture = put_in(legacy_result(), [:payload, unknown_key], "ignored fixture metadata")

    assert {:ok, atom_projection} =
             CodingParity.project(atom_fixture, legacy_observations())

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert {:ok, string_projection} =
             CodingParity.project(pipeline_result(), %{"tree_oid" => @tree_a})

    assert atom_projection["semantic"] == string_projection["semantic"]
    assert {:ok, comparison} = CodingParity.compare(atom_projection, string_projection)

    assert {:ok, _json} = Jason.encode(atom_projection)
    assert {:ok, _json} = Jason.encode(string_projection)
    assert {:ok, _json} = Jason.encode(comparison)
  end

  test "changed files preserve valid Git path bytes including trailing spaces" do
    result =
      put_in(legacy_result(), [:payload, :files], ["apps/x/name..ex", "apps/x/name..ex "])

    assert {:ok, projection} = CodingParity.project(result, legacy_observations())

    assert projection["semantic"]["changed_files"] == [
             "apps/x/name..ex",
             "apps/x/name..ex "
           ]
  end

  test "malformed and non-coding inputs fail closed with explicit errors" do
    observations = legacy_observations()

    assert {:error, %{"reason" => "non_coding_result"}} =
             CodingParity.project(%{"status" => "ok"}, observations)

    assert {:error, %{"reason" => "unsupported_result_type"}} =
             CodingParity.project(
               %{"result_type" => "chat", "payload" => %{"text" => "hello"}},
               observations
             )

    assert {:error, %{"field" => "terminal_status", "reason" => "missing_field"}} =
             CodingParity.project(%{result_type: :coding_change, payload: %{}}, observations)

    malformed =
      put_in(legacy_result(), [:payload, :files], "apps/arbor_commands/lib/a.ex")

    assert {:error, %{"reason" => "invalid_changed_files"}} =
             CodingParity.project(malformed, observations)

    nul_path = put_in(legacy_result(), [:payload, :files], ["apps/x/bad\0name.ex"])

    assert {:error, %{"reason" => "invalid_changed_file"}} =
             CodingParity.project(nul_path, observations)

    assert {:error,
            %{
              "error" => "coding_parity_comparison_failed",
              "sides" => [%{"side" => "left"}, %{"side" => "right"}]
            }} = CodingParity.compare(%{}, %{})
  end

  defp legacy_result do
    %{
      result_type: :coding_change,
      payload: %{
        branch: "legacy/task-123",
        commit: String.duplicate("1", 40),
        files: [
          "apps/arbor_commands/test/a_test.exs",
          "apps/arbor_commands/lib/a.ex",
          "apps/arbor_commands/lib/a.ex"
        ],
        report: %{
          status: :change_committed,
          validation: [
            %{command: "./bin/mix test", duration_ms: 81, passed: true}
          ],
          review: %{
            approval_id: "legacy-review-approval-id",
            blast_radius: :low,
            human_required: false,
            recommendation: :keep,
            security_veto: false,
            tier_decision: :auto_proceed
          }
        }
      },
      raw: %{
        provider_usage_id: "legacy-provider-usage-id",
        session_id: "legacy-session-id",
        status: :change_committed,
        wall_clock_ms: 9_001,
        worker_session_id: "legacy-worker-id"
      }
    }
  end

  defp legacy_observations do
    %{
      approval: %{
        approval_id: "legacy-approval-id",
        count: 0,
        requested: false,
        required: false,
        resumed: false,
        status: :not_required,
        wall_clock_ms: 700
      },
      cancellation: %{
        cancelled: false,
        cleanup_completed: true,
        requested: false,
        status: :not_requested,
        worker_terminated: false,
        worker_session_id: "legacy-worker-id"
      },
      cleanup: %{
        completed: true,
        status: :retained,
        duration_ms: 12,
        resources_cleaned: true,
        workspace_removed: false,
        workspace_retained: true,
        workspace_id: "legacy-workspace-id"
      },
      tree_oid: String.upcase(@tree_a)
    }
  end

  defp pipeline_result do
    %{
      "result_type" => "coding_change",
      "payload" => %{
        "artifacts" => %{
          "coding_pipeline_path" => "/tmp/pipeline/coding-pipeline.dot",
          "coding_plan_path" => "/tmp/pipeline/coding-plan.json",
          "compile_manifest_path" => "/tmp/pipeline/compile-manifest.json",
          "compiler_version" => "coding-plan-1",
          "graph_hash" => String.duplicate("c", 64)
        },
        "branch" => "pipeline/task-987",
        "commit" => String.duplicate("2", 40),
        "files" => [
          "apps/arbor_commands/lib/a.ex",
          "apps/arbor_commands/test/a_test.exs"
        ],
        "report" => %{
          "canonical_status" => "change_committed",
          "status" => "change_committed",
          "validation" => [
            %{"node_duration_ms" => 3, "passed" => true}
          ],
          "review" => %{
            "approval_id" => "pipeline-review-approval-id",
            "blast_radius" => "low",
            "human_required" => false,
            "recommendation" => "keep",
            "security_veto" => false,
            "tier_decision" => "auto_proceed"
          }
        }
      },
      "raw" => %{
        "metrics" => %{
          "approval_required" => false,
          "approval_status" => "not_required",
          "cancelled" => false,
          "cleanup_completed" => true,
          "completed" => true,
          "cancellation_status" => "not_requested",
          "count" => 0,
          "node_durations_ms" => %{"validate" => 3},
          "requested" => false,
          "resources_cleaned" => true,
          "resumed" => false,
          "usage" => %{
            "provider_request_id" => "pipeline-provider-usage-id",
            "total_tokens" => 500
          },
          "wall_clock_ms" => 101,
          "worker_terminated" => false,
          "workspace_release_status" => "retained",
          "workspace_removed" => false,
          "workspace_retained" => true
        },
        "session_id" => "pipeline-session-id",
        "status" => "change_committed",
        "worker_session_id" => "pipeline-worker-id"
      }
    }
  end
end
