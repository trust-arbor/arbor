defmodule Arbor.Contracts.Coding.TaskTerminalEnvelopeTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{ReadinessReport, TaskOutcome, TaskTerminalEnvelope}

  @moduletag :fast

  test "builds a closed JSON envelope from registry semantics" do
    assert {:ok, envelope} =
             TaskTerminalEnvelope.from_code(
               "task_cancelled",
               :cancelled,
               %{"kind" => "task_cancelled"},
               %{"disposition" => "succeeded", "message" => "cancelled by operator"}
             )

    assert envelope == %{
             "version" => 1,
             "terminal_state" => "cancelled",
             "outcome" => %{
               "version" => 1,
               "disposition" => "cancelled",
               "code" => "task_cancelled",
               "phase" => "control",
               "origin" => "operator",
               "retry" => "none",
               "message" => "cancelled by operator"
             },
             "evidence" => %{"kind" => "task_cancelled"}
           }

    assert {:ok, ^envelope} = TaskTerminalEnvelope.normalize(envelope)
    assert {:ok, _json} = Jason.encode(envelope)
  end

  test "preserves only exact registered outcomes" do
    {:ok, outcome} = TaskOutcome.from_code("worker_turn_no_progress")
    outcome = TaskOutcome.to_map(outcome)

    assert {:ok, envelope} =
             TaskTerminalEnvelope.preserve(
               outcome,
               "failed",
               %{"kind" => "pipeline_failure", "result" => %{"outcome" => outcome}}
             )

    assert envelope["outcome"] == outcome

    forged = Map.put(outcome, "retry", "none")

    assert {:error, {:invalid_task_outcome, :registry_semantics_mismatch}} =
             TaskTerminalEnvelope.preserve(
               forged,
               "failed",
               %{"kind" => "pipeline_failure", "result" => %{}}
             )
  end

  test "requires a bounded readiness report for execution state drift evidence" do
    report = readiness_report()
    evidence_ref = get_in(report, ["diagnostics", Access.at(0), "evidence_ref"])

    assert {:ok, envelope} =
             TaskTerminalEnvelope.from_code(
               "coding_execution_state_drift",
               "failed",
               %{"kind" => "coding_execution_state_drift", "result" => report},
               %{
                 "diagnostic_refs" => [evidence_ref],
                 "evidence_ref" => evidence_ref
               }
             )

    assert envelope["outcome"] == %{
             "version" => 1,
             "disposition" => "failed",
             "code" => "coding_execution_state_drift",
             "phase" => "preflight",
             "origin" => "arbor",
             "retry" => "after_external_change",
             "diagnostic_refs" => [evidence_ref],
             "evidence_ref" => evidence_ref
           }

    assert envelope["evidence"] == %{
             "kind" => "coding_execution_state_drift",
             "result" => report
           }

    assert {:ok, ^envelope} = TaskTerminalEnvelope.normalize(envelope)

    assert {:error, {:invalid_field, "evidence"}} =
             TaskTerminalEnvelope.from_code(
               "coding_execution_state_drift",
               "failed",
               %{"kind" => "coding_execution_state_drift"}
             )

    oversized_for_terminal_envelope =
      Map.put(report, "diagnostics", List.duplicate(hd(report["diagnostics"]), 12))

    assert {:ok, ^oversized_for_terminal_envelope} =
             ReadinessReport.normalize(oversized_for_terminal_envelope)

    assert {:error, {:invalid_field, "evidence"}} =
             TaskTerminalEnvelope.from_code(
               "coding_execution_state_drift",
               "failed",
               %{
                 "kind" => "coding_execution_state_drift",
                 "result" => oversized_for_terminal_envelope
               }
             )
  end

  test "finalization failure retains prior outcome and bounded evidence" do
    {:ok, outcome} = TaskOutcome.from_code("no_changes")
    outcome = TaskOutcome.to_map(outcome)
    large = String.duplicate("evidence", 2_000)

    assert {:ok, envelope} =
             TaskTerminalEnvelope.preserve(
               outcome,
               "done",
               %{
                 "kind" => "executor_result",
                 "result" => %{"outcome" => outcome, "response" => large}
               }
             )

    assert envelope["evidence"]["truncated"] == true
    assert byte_size(envelope["evidence"]["result"]["response"]) <= 512

    assert {:ok, failed} = TaskTerminalEnvelope.finalization_failed(envelope)
    assert failed["outcome"]["code"] == "task_finalization_failed"
    assert failed["prior_outcome"] == outcome
    assert failed["evidence"] == envelope["evidence"]
    assert byte_size(Jason.encode!(failed)) <= 65_536
  end

  test "rejects executable, authority-bearing, open, and deeply nested evidence" do
    {:ok, outcome} = TaskOutcome.from_code("no_changes")
    outcome = TaskOutcome.to_map(outcome)

    for result <- [
          self(),
          fn -> :ok end,
          URI,
          %URI{path: "/tmp"},
          %{"capabilities" => [%{"resource" => "arbor://shell"}]}
        ] do
      assert {:error, {:invalid_field, "evidence"}} =
               TaskTerminalEnvelope.preserve(
                 outcome,
                 "done",
                 %{"kind" => "executor_result", "result" => result}
               )
    end

    assert {:error, {:unknown_field, "extra"}} =
             TaskTerminalEnvelope.normalize(%{
               "version" => 1,
               "terminal_state" => "done",
               "outcome" => outcome,
               "evidence" => %{"kind" => "executor_result", "result" => %{}},
               "extra" => true
             })

    nested = Enum.reduce(1..20, "leaf", fn index, acc -> %{"level_#{index}" => acc} end)

    assert {:ok, bounded} =
             TaskTerminalEnvelope.preserve(
               outcome,
               "done",
               %{"kind" => "executor_result", "result" => nested}
             )

    assert bounded["evidence"]["truncated"] == true
  end

  defp readiness_report do
    {:ok, report} =
      ReadinessReport.new(%{
        version: ReadinessReport.schema_version(),
        status: "blocked",
        plan_digest: "sha256:state-drift-plan",
        observed_at: "2026-07-24T20:00:00Z",
        diagnostics: [
          %{
            version: 1,
            gate_id: "immutable_execution_boundary",
            phase: "preflight",
            decision: "blocked",
            code: "execution_binding_drift",
            observed_at: "2026-07-24T20:00:00Z",
            evidence_ref: "sha256:state-drift-evidence"
          }
        ]
      })

    ReadinessReport.to_map(report)
  end
end
