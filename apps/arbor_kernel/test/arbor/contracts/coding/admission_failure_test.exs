defmodule Arbor.Contracts.Coding.AdmissionFailureTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{AdmissionFailure, Diagnostic, TaskOutcome}

  @moduletag :fast

  test "normalizes exact blocked preflight evidence" do
    attrs = valid_attrs()

    assert {:ok, failure} = AdmissionFailure.new(attrs)
    assert AdmissionFailure.to_map(failure) == attrs
    assert {:ok, ^attrs} = AdmissionFailure.normalize(attrs)
    assert AdmissionFailure.valid?(attrs)
    assert {:ok, _json} = Jason.encode(attrs)
  end

  test "rejects missing, extra, and noncanonical terminal fields" do
    attrs = valid_attrs()

    refute AdmissionFailure.valid?(Map.delete(attrs, "diagnostic"))
    refute AdmissionFailure.valid?(Map.put(attrs, "extra", true))
    refute AdmissionFailure.valid?(Map.put(attrs, "status", "validation_failed"))
  end

  test "rejects diagnostics that do not describe a blocked preflight gate" do
    attrs = valid_attrs()

    refute AdmissionFailure.valid?(put_in(attrs, ["diagnostic", "decision"], "passed"))
    refute AdmissionFailure.valid?(put_in(attrs, ["diagnostic", "phase"], "worker_turn"))
  end

  test "rejects any outcome other than the exact registered admission outcome" do
    attrs = valid_attrs()

    refute AdmissionFailure.valid?(put_in(attrs, ["outcome", "code"], "no_changes"))
    refute AdmissionFailure.valid?(put_in(attrs, ["outcome", "retry"], "new_session"))
    refute AdmissionFailure.valid?(put_in(attrs, ["outcome", "message"], "extra prose"))
  end

  defp valid_attrs do
    {:ok, diagnostic} =
      Diagnostic.new(%{
        version: Diagnostic.schema_version(),
        gate_id: "plan_schema",
        phase: "preflight",
        decision: "blocked",
        code: "checkpoint_policy_required",
        observed_at: "2026-07-27T20:00:00Z"
      })

    {:ok, outcome} = TaskOutcome.from_code("coding_admission_failed")

    %{
      "status" => "coding_admission_failed",
      "diagnostic" => Diagnostic.to_map(diagnostic),
      "outcome" => TaskOutcome.to_map(outcome)
    }
  end
end
