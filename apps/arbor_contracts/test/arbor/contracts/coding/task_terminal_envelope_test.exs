defmodule Arbor.Contracts.Coding.TaskTerminalEnvelopeTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{TaskOutcome, TaskTerminalEnvelope}

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
end
