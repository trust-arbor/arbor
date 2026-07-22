defmodule Arbor.Orchestrator.CodingPlan.TaskTerminalArchiveCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.TaskTerminalEnvelope
  alias Arbor.Orchestrator.CodingPlan.TaskTerminalArchiveCore

  @moduletag :fast
  @task_id "task_terminal_core"

  test "builds deterministic exact archives for every TaskStore terminal kind" do
    terminals = [
      terminal!("no_changes", "done", %{
        "kind" => "executor_result",
        "result" => %{"task_id" => @task_id}
      }),
      terminal!("worker_turn_no_progress", "failed", %{
        "kind" => "pipeline_failure",
        "result" => %{"task_id" => @task_id}
      }),
      terminal!("task_cancelled", "cancelled", %{"kind" => "task_cancelled"}),
      terminal!("task_owner_died", "failed", %{"kind" => "task_owner_died"}),
      terminal!("approval_owner_terminated", "failed", %{
        "kind" => "approval_owner_terminated",
        "approval_id" => "approval-1"
      }),
      terminal!("task_runner_failed", "failed", %{"kind" => "task_runner_failed"}),
      terminal!("invalid_terminal_evidence", "failed", %{
        "kind" => "invalid_terminal_evidence"
      })
    ]

    Enum.each(terminals, fn envelope ->
      assert {:ok, first} = TaskTerminalArchiveCore.build(@task_id, envelope, [])
      assert {:ok, second} = TaskTerminalArchiveCore.build(@task_id, envelope, [])
      assert first === second
      assert Jason.decode!(first.encoded) === first.body

      assert first.body === %{
               "schema_version" => 1,
               "task_id" => @task_id,
               "terminal_envelope" => envelope,
               "controls" => []
             }

      assert first.descriptor_fields === %{
               "schema_version" => 1,
               "task_id" => @task_id,
               "sha256" => sha256(first.encoded),
               "byte_size" => byte_size(first.encoded),
               "terminal_state" => envelope["terminal_state"],
               "outcome_code" => envelope["outcome"]["code"]
             }
    end)
  end

  test "accepts both TaskStore legacy-finalizer failure envelope forms" do
    originals = [
      terminal!("no_changes", "done", %{
        "kind" => "executor_result",
        "result" => %{"task_id" => @task_id}
      }),
      terminal!("invalid_terminal_evidence", "failed", %{
        "kind" => "invalid_terminal_evidence"
      })
    ]

    Enum.each(originals, fn original ->
      assert {:ok, failed} = TaskTerminalEnvelope.finalization_failed(original)
      assert {:ok, archive} = TaskTerminalArchiveCore.build(@task_id, failed, [])
      assert archive.body["terminal_envelope"] === failed
      assert archive.descriptor_fields["outcome_code"] == "task_finalization_failed"
    end)

    cancelled = terminal!("task_cancelled", "cancelled", %{"kind" => "task_cancelled"})
    assert {:ok, invalid_failure} = TaskTerminalEnvelope.finalization_failed(cancelled)

    assert {:error, :invalid_task_terminal_semantics} =
             TaskTerminalArchiveCore.build(@task_id, invalid_failure, [])
  end

  test "pipeline failure preserves TaskStore registered outcomes across dispositions" do
    # TaskStore derives the outer failed state from the runner error tuple, but
    # deliberately preserves the exact registered outcome carried by detail.
    for code <- [
          "worker_turn_no_progress",
          "validation_capacity_exceeded",
          "review_rejected",
          "no_changes"
        ] do
      envelope =
        terminal!(code, "failed", %{
          "kind" => "pipeline_failure",
          "result" => %{"task_id" => @task_id, "status" => "pipeline_error"}
        })

      assert {:ok, archive} = TaskTerminalArchiveCore.build(@task_id, envelope, [])
      assert archive.body["terminal_envelope"] === envelope
    end
  end

  test "rejects malformed states, codes, kinds, and reserved lifecycle pairings" do
    successful =
      terminal!("no_changes", "done", %{
        "kind" => "executor_result",
        "result" => %{"task_id" => @task_id}
      })

    malformed_state = Map.put(successful, "terminal_state", "running")
    wrong_state = Map.put(successful, "terminal_state", "failed")
    unknown_code = put_in(successful, ["outcome", "code"], "not_registered")
    unknown_kind = put_in(successful, ["evidence", "kind"], "unknown_terminal")
    wrong_kind = put_in(successful, ["evidence", "kind"], "task_owner_died")

    for envelope <- [malformed_state, unknown_code, unknown_kind] do
      assert {:error, :invalid_task_terminal_envelope} =
               TaskTerminalArchiveCore.build(@task_id, envelope, [])
    end

    for envelope <- [wrong_state, wrong_kind] do
      assert {:error, :invalid_task_terminal_semantics} =
               TaskTerminalArchiveCore.build(@task_id, envelope, [])
    end

    lifecycle_as_pipeline =
      terminal!("task_owner_died", "failed", %{
        "kind" => "pipeline_failure",
        "result" => %{"task_id" => @task_id}
      })

    assert {:error, :invalid_task_terminal_semantics} =
             TaskTerminalArchiveCore.build(@task_id, lifecycle_as_pipeline, [])
  end

  test "rejects every recursively embedded task identity mismatch" do
    envelope =
      terminal!("no_changes", "done", %{
        "kind" => "executor_result",
        "result" => %{
          "task_id" => @task_id,
          "nested" => [%{"task_id" => "other-task"}]
        }
      })

    assert {:error, :task_terminal_task_id_mismatch} =
             TaskTerminalArchiveCore.build(@task_id, envelope, [])

    non_string_id = put_in(envelope, ["evidence", "result", "nested"], [%{"task_id" => 1}])

    assert {:error, :task_terminal_task_id_mismatch} =
             TaskTerminalArchiveCore.build(@task_id, non_string_id, [])
  end

  test "accepts only exact ordered task-bound controls in final terminal states" do
    envelope = successful_envelope()

    valid_controls = [
      control(%{"sequence" => 1, "control_id" => "delivered"}),
      control(%{
        "sequence" => 2,
        "control_id" => "unconfirmed",
        "status" => "delivery_unconfirmed",
        "delivered_at" => nil,
        "delivery_mode" => nil,
        "error" => "delivery unknown"
      }),
      control(%{
        "sequence" => 3,
        "control_id" => "unsupported",
        "status" => "unsupported",
        "delivered_at" => nil,
        "delivery_mode" => nil,
        "error" => "unsupported"
      })
    ]

    assert {:ok, archive} = TaskTerminalArchiveCore.build(@task_id, envelope, valid_controls)
    assert archive.body["controls"] === valid_controls

    queued =
      control(%{"status" => "queued", "delivered_at" => nil, "delivery_mode" => nil})

    assert {:ok, [^queued]} = TaskTerminalArchiveCore.validate_control_history(@task_id, [queued])

    assert {:error, {:invalid_terminal_control, :nonterminal_or_malformed}} =
             TaskTerminalArchiveCore.build(@task_id, envelope, [queued])

    invalid_control_sets = [
      [control(%{"task_id" => "other-task"})],
      [control(), control(%{"sequence" => 2})],
      [control(%{"sequence" => 2}), control(%{"sequence" => 1, "control_id" => "second"})],
      [Map.put(control(), "extra", true)],
      [Map.delete(control(), "error")],
      [control(%{"delivery_mode" => nil})],
      [
        control(%{
          "status" => "delivery_unconfirmed",
          "delivered_at" => "2026-07-22T17:00:01Z",
          "error" => "unknown"
        })
      ],
      [
        control(%{
          "status" => "unsupported",
          "delivered_at" => nil,
          "delivery_mode" => "native_tool_loop",
          "error" => "unsupported"
        })
      ]
    ]

    Enum.each(invalid_control_sets, fn controls ->
      assert {:error, {:invalid_terminal_control, _reason}} =
               TaskTerminalArchiveCore.build(@task_id, envelope, controls)
    end)
  end

  test "enforces cumulative archive node bounds after individual control validation" do
    controls =
      Enum.map(1..100, fn sequence ->
        control(%{"sequence" => sequence, "control_id" => "control-#{sequence}"})
      end)

    assert {:error, :task_terminal_bounds_exceeded} =
             TaskTerminalArchiveCore.build(@task_id, successful_envelope(), controls)

    assert {:error, {:invalid_terminal_controls, :too_many}} =
             TaskTerminalArchiveCore.build(
               @task_id,
               successful_envelope(),
               controls ++ [control(%{"sequence" => 101, "control_id" => "control-101"})]
             )
  end

  defp successful_envelope do
    terminal!("no_changes", "done", %{
      "kind" => "executor_result",
      "result" => %{"task_id" => @task_id}
    })
  end

  defp terminal!(code, state, evidence) do
    {:ok, envelope} = TaskTerminalEnvelope.from_code(code, state, evidence)
    envelope
  end

  defp control(overrides \\ %{}) do
    Map.merge(
      %{
        "control_id" => "control-1",
        "task_id" => @task_id,
        "sequence" => 1,
        "status" => "delivered",
        "sender_id" => "human-1",
        "message" => "continue",
        "queued_at" => "2026-07-22T17:00:00Z",
        "delivered_at" => "2026-07-22T17:00:01Z",
        "target_stage" => "worker",
        "delivery_mode" => "native_tool_loop",
        "error" => nil
      },
      overrides
    )
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
