defmodule Arbor.Orchestrator.CodingPlan.ValidationCapacityTerminalTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff
  alias Arbor.Orchestrator.CodingPlan.ValidationCapacityTerminal

  @moduletag :fast

  @kernel_test "apps/arbor_kernel/test/arbor/contracts/admission_test.exs"

  test "admits contract_change capacity including an interrupted launched stage" do
    unstarted = wrap_capacity(unstarted_capacity_report())
    assert {:ok, normalized} = ValidationCapacityTerminal.normalize_result(unstarted, :terminal)
    assert :ok = ValidationCapacityTerminal.validate_consistency(normalized, :terminal)

    interrupted = wrap_capacity(interrupted_capacity_report())

    assert {:ok, normalized_interrupted} =
             ValidationCapacityTerminal.normalize_result(interrupted, :terminal)

    assert :ok =
             ValidationCapacityTerminal.validate_consistency(normalized_interrupted, :terminal)

    handoff =
      get_in(normalized_interrupted, ["validation", Access.at(0), "preflight", "capacity_handoff"])

    assert ValidationCapacityHandoff.valid?(handoff)
    assert handoff["interrupted_batch"]["index"] == 1
    assert handoff["interrupted_batch"]["total"] == 2

    interrupted = handoff["interrupted_batch"]

    assert interrupted["label"] ==
             "batch-1-of-2-n#{interrupted["count"]}-#{interrupted["inventory_sha256"]}"
  end

  test "admits contract_change containment on a validation_failed envelope" do
    result = wrap_failed(containment_report())
    assert {:ok, normalized} = ValidationCapacityTerminal.normalize_result(result, :terminal)
    assert :ok = ValidationCapacityTerminal.validate_consistency(normalized, :terminal)

    termination =
      get_in(normalized, ["validation", Access.at(0), "preflight", "termination"])

    assert termination["containment_failure"] == true
    assert map_size(termination) == 5
  end

  test "rejects mixed termination plus handoff and four-key smuggling" do
    mixed = wrap_capacity(mixed_capacity_report())

    assert {:error, {:invalid_terminal_result, :capacity_handoff}} =
             ValidationCapacityTerminal.normalize_result(mixed, :terminal)

    smuggled = wrap_failed(four_key_containment_report())

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.normalize_result(smuggled, :terminal)

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.validate_consistency(smuggled, :terminal)
  end

  test "default five-key containment is status-consistent and fail closed" do
    result = default_containment_result("validation_failed")
    assert {:ok, normalized} = ValidationCapacityTerminal.normalize_result(result, :terminal)
    assert :ok = ValidationCapacityTerminal.validate_consistency(normalized, :terminal)

    passed = default_containment_result("passed")

    assert {:error, {:invalid_terminal_result, :containment_status_mismatch}} =
             ValidationCapacityTerminal.normalize_result(passed, :terminal)

    assert {:error, {:invalid_terminal_result, :containment_status_mismatch}} =
             ValidationCapacityTerminal.validate_consistency(passed, :terminal)
  end

  test "rejects success status carrying valid-shaped contract_change containment" do
    result =
      wrap_failed(containment_report())
      |> Map.put("status", "passed")
      |> Map.put("canonical_status", "passed")

    assert {:error, {:invalid_terminal_result, :containment_status_mismatch}} =
             ValidationCapacityTerminal.normalize_result(result, :terminal)

    assert {:error, {:invalid_terminal_result, :containment_status_mismatch}} =
             ValidationCapacityTerminal.validate_consistency(result, :terminal)
  end

  test "rejects multi-entry containment" do
    report = containment_report()

    result = %{
      "status" => "validation_failed",
      "canonical_status" => "validation_failed",
      "validation" => [report, report]
    }

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.normalize_result(result, :terminal)

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.validate_consistency(result, :terminal)
  end

  test "rejects malformed extra on the other check" do
    report = containment_report()
    test_check = Map.put(report["test"], "termination", %{"timed_out" => true})
    result = wrap_failed(Map.put(report, "test", test_check))

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.normalize_result(result, :terminal)

    capacity = unstarted_capacity_report()
    test_extra = Map.put(capacity["test"], "termination", %{"killed" => true})
    mixed_other = wrap_capacity(Map.put(capacity, "test", test_extra))

    assert {:error, {:invalid_terminal_result, :capacity_handoff}} =
             ValidationCapacityTerminal.normalize_result(mixed_other, :terminal)
  end

  test "rejects dual mixed extras on one check" do
    mixed = wrap_failed(mixed_containment_and_handoff_report())

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.normalize_result(mixed, :terminal)
  end

  test "rejects wrong-stage capacity handoffs" do
    swapped = wrap_capacity(wrong_stage_capacity_report())

    assert {:error, {:invalid_terminal_result, :capacity_handoff}} =
             ValidationCapacityTerminal.normalize_result(swapped, :terminal)

    refute ValidationCapacityTerminal.contract_handoff_matches_stage?(
             :test,
             interrupted_capacity_report()["preflight"]["capacity_handoff"]
           )
  end

  test "rejects duplicate nested containment envelopes on a default report" do
    result = default_containment_result("validation_failed")
    [report] = result["validation"]

    nested =
      Map.put(report, "nested", %{"termination" => containment_termination()})

    result = Map.put(result, "validation", [nested])

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.normalize_result(result, :terminal)

    assert {:error, {:invalid_terminal_result, :containment_evidence_mismatch}} =
             ValidationCapacityTerminal.validate_consistency(result, :terminal)
  end

  test "security regression: ContractChange containment report passed=true is rejected on terminal and finalize" do
    for kind <- [:terminal, :finalize] do
      expected_tag = invalid_tag(kind)
      honest_preflight = wrap_failed(containment_report())

      assert {:ok, normalized} =
               ValidationCapacityTerminal.normalize_result(honest_preflight, kind)

      assert :ok = ValidationCapacityTerminal.validate_consistency(normalized, kind)

      honest_test = wrap_failed(test_owned_containment_report())

      assert {:ok, normalized_test} =
               ValidationCapacityTerminal.normalize_result(honest_test, kind)

      assert :ok = ValidationCapacityTerminal.validate_consistency(normalized_test, kind)

      report_passed = wrap_failed(Map.put(containment_report(), "passed", true))

      assert {:error, {^expected_tag, :containment_evidence_mismatch}} =
               ValidationCapacityTerminal.normalize_result(report_passed, kind)

      assert {:error, {^expected_tag, :containment_evidence_mismatch}} =
               ValidationCapacityTerminal.validate_consistency(report_passed, kind)

      skipped_exit = containment_report()
      skipped_exit = Map.put(skipped_exit, "test", Map.put(skipped_exit["test"], "exit_code", 0))

      assert {:error, {^expected_tag, :containment_evidence_mismatch}} =
               ValidationCapacityTerminal.normalize_result(wrap_failed(skipped_exit), kind)

      owning_passed = containment_report()

      owning_passed =
        Map.put(
          owning_passed,
          "preflight",
          Map.put(owning_passed["preflight"], "passed", true)
        )

      assert {:error, {^expected_tag, :containment_evidence_mismatch}} =
               ValidationCapacityTerminal.normalize_result(wrap_failed(owning_passed), kind)

      preflight_reason = test_owned_containment_report()

      preflight_reason =
        Map.put(
          preflight_reason,
          "preflight",
          Map.put(preflight_reason["preflight"], "reason", "preflight_failed")
        )

      assert {:error, {^expected_tag, :containment_evidence_mismatch}} =
               ValidationCapacityTerminal.normalize_result(wrap_failed(preflight_reason), kind)

      preflight_exit = test_owned_containment_report()

      preflight_exit =
        Map.put(
          preflight_exit,
          "preflight",
          Map.put(preflight_exit["preflight"], "exit_code", 1)
        )

      assert {:error, {^expected_tag, :containment_evidence_mismatch}} =
               ValidationCapacityTerminal.normalize_result(wrap_failed(preflight_exit), kind)
    end
  end

  test "security regression: malformed default Mix.Compile capacity stays capacity family" do
    failed_capacity = default_four_key_capacity_on_failed_status()

    assert {:error, {:invalid_terminal_result, :capacity_evidence_mismatch}} =
             ValidationCapacityTerminal.normalize_result(failed_capacity, :terminal)

    assert {:error, {:invalid_terminal_result, :capacity_evidence_mismatch}} =
             ValidationCapacityTerminal.validate_consistency(failed_capacity, :terminal)

    refute match?(
             {:error, {:invalid_terminal_result, :containment_evidence_mismatch}},
             ValidationCapacityTerminal.normalize_result(failed_capacity, :terminal)
           )

    honest = default_containment_result("validation_failed")
    assert {:ok, normalized} = ValidationCapacityTerminal.normalize_result(honest, :terminal)
    assert :ok = ValidationCapacityTerminal.validate_consistency(normalized, :terminal)
  end

  test "security regression: contradictory passed/status/reason/exit ContractChange capacity is rejected on terminal and finalize" do
    for kind <- [:terminal, :finalize] do
      expected_tag = invalid_tag(kind)
      honest_unstarted = wrap_capacity(unstarted_capacity_report())

      assert {:ok, normalized} =
               ValidationCapacityTerminal.normalize_result(honest_unstarted, kind)

      assert :ok = ValidationCapacityTerminal.validate_consistency(normalized, kind)

      honest_interrupted = wrap_capacity(interrupted_capacity_report())

      assert {:ok, normalized_interrupted} =
               ValidationCapacityTerminal.normalize_result(honest_interrupted, kind)

      assert :ok = ValidationCapacityTerminal.validate_consistency(normalized_interrupted, kind)

      report_passed =
        wrap_capacity(Map.put(unstarted_capacity_report(), "passed", true))

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.normalize_result(report_passed, kind)

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.validate_consistency(report_passed, kind)

      preflight_passed = unstarted_capacity_report()

      preflight_passed =
        Map.put(
          preflight_passed,
          "preflight",
          Map.put(preflight_passed["preflight"], "passed", true)
        )

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.normalize_result(wrap_capacity(preflight_passed), kind)

      test_passed = wrap_capacity(test_stage_capacity_report())
      test_passed = put_in(test_passed, ["validation", Access.at(0), "test", "passed"], true)

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.normalize_result(test_passed, kind)

      skipped_exit = unstarted_capacity_report()
      skipped_exit = Map.put(skipped_exit, "test", Map.put(skipped_exit["test"], "exit_code", 0))

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.normalize_result(wrap_capacity(skipped_exit), kind)

      completed_pass_reason = wrap_capacity(test_stage_capacity_report())

      completed_pass_reason =
        put_in(completed_pass_reason, ["validation", Access.at(0), "preflight"], %{
          "status" => "completed",
          "passed" => true,
          "exit_code" => 0,
          "reason" => "validation_capacity_exceeded",
          "stdout_excerpt" => "",
          "stderr_excerpt" => "",
          "stdout_truncated" => false,
          "stderr_truncated" => false,
          "stdout_sha256" => String.duplicate("a", 64),
          "stderr_sha256" => String.duplicate("b", 64)
        })

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.normalize_result(completed_pass_reason, kind)

      report_level_handoff =
        wrap_capacity(
          Map.put(
            unstarted_capacity_report(),
            "capacity_handoff",
            unstarted_capacity_report()["preflight"]["capacity_handoff"]
          )
        )

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.normalize_result(report_level_handoff, kind)

      assert {:error, {^expected_tag, :capacity_handoff}} =
               ValidationCapacityTerminal.validate_consistency(report_level_handoff, kind)
    end
  end

  test "rejects a valid three-batch structural handoff as a contract_change preflight" do
    handoff = three_batch_structural_handoff()
    refute ValidationCapacityTerminal.contract_handoff_matches_stage?(:preflight, handoff)
    refute ValidationCapacityTerminal.contract_handoff_matches_stage?(:test, handoff)

    report = unstarted_capacity_report()
    preflight = Map.put(report["preflight"], "capacity_handoff", handoff)
    result = wrap_capacity(Map.put(report, "preflight", preflight))

    assert {:error, {:invalid_terminal_result, :capacity_handoff}} =
             ValidationCapacityTerminal.normalize_result(result, :terminal)
  end

  defp invalid_tag(:terminal), do: :invalid_terminal_result
  defp invalid_tag(:finalize), do: :invalid_finalize_result

  defp test_stage_capacity_report do
    {:ok, check} =
      Core.capacity_check(:runtime, 10_000, %{
        completed: [preflight_batch()],
        unstarted: [tests_batch()]
      })

    %{
      "passed" => false,
      "reason" => "validation_capacity_exceeded",
      "preflight" => Core.completed_check(%{"passed" => true, "exit_code" => 0}),
      "test" => check
    }
  end

  defp wrap_capacity(report) do
    %{
      "status" => "validation_capacity_exceeded",
      "canonical_status" => "validation_capacity_exceeded",
      "validation" => [report]
    }
  end

  defp wrap_failed(report) do
    %{
      "status" => "validation_failed",
      "canonical_status" => "validation_failed",
      "validation" => [report]
    }
  end

  defp default_containment_result(status) do
    %{
      "status" => status,
      "canonical_status" => status,
      "validation" => [
        %{
          "reason" => "validation_containment_failure",
          "passed" => false,
          "exit_code" => 0,
          "termination" => containment_termination()
        }
      ]
    }
  end

  defp unstarted_capacity_report do
    {:ok, check} =
      Core.capacity_check(:structural, 10_000, %{
        completed: [],
        unstarted: [preflight_batch(), tests_batch()]
      })

    %{
      "passed" => false,
      "reason" => "validation_capacity_exceeded",
      "preflight" => check,
      "test" => Core.skipped_check("validation_capacity_exceeded")
    }
  end

  defp interrupted_capacity_report do
    {:ok, check} =
      Core.capacity_check(:runtime, 10_000, %{
        completed: [],
        interrupted: preflight_batch(),
        unstarted: [tests_batch()]
      })

    launched =
      check
      |> Map.put("exit_code", 0)
      |> Map.put("stdout_excerpt", "ok")

    %{
      "passed" => false,
      "reason" => "validation_capacity_exceeded",
      "preflight" => launched,
      "test" => Core.skipped_check("validation_capacity_exceeded")
    }
  end

  defp wrong_stage_capacity_report do
    {:ok, preflight_handoff} =
      Core.capacity_check(:runtime, 10_000, %{
        completed: [],
        interrupted: preflight_batch(),
        unstarted: [tests_batch()]
      })

    %{
      "passed" => false,
      "reason" => "validation_capacity_exceeded",
      "preflight" => Core.completed_check(%{"passed" => true, "exit_code" => 0}),
      "test" =>
        Map.put(
          Core.completed_check(%{"passed" => false, "exit_code" => 0},
            reason: "validation_capacity_exceeded"
          ),
          "capacity_handoff",
          preflight_handoff["capacity_handoff"]
        )
    }
  end

  defp test_owned_containment_report do
    check =
      Map.put(
        Core.completed_check(%{"passed" => false, "exit_code" => 0},
          reason: "validation_containment_failure"
        ),
        "termination",
        containment_termination()
      )

    %{
      "passed" => false,
      "reason" => "validation_containment_failure",
      "preflight" => Core.completed_check(%{"passed" => true, "exit_code" => 0}),
      "test" => check
    }
  end

  defp default_four_key_capacity_on_failed_status do
    %{
      "status" => "validation_failed",
      "canonical_status" => "validation_failed",
      "validation" => [
        %{
          "reason" => "validation_capacity_exceeded",
          "passed" => false,
          "exit_code" => 137,
          "termination" => %{
            "timed_out" => false,
            "killed" => true,
            "output_limit_exceeded" => false,
            "cancelled" => false
          }
        }
      ]
    }
  end

  defp containment_report do
    check =
      Map.put(
        Core.completed_check(%{"passed" => false, "exit_code" => 0},
          reason: "validation_containment_failure"
        ),
        "termination",
        containment_termination()
      )

    %{
      "passed" => false,
      "reason" => "validation_containment_failure",
      "preflight" => check,
      "test" => Core.skipped_check("validation_containment_failure")
    }
  end

  defp mixed_capacity_report do
    report = unstarted_capacity_report()
    preflight = Map.put(report["preflight"], "termination", containment_termination())
    Map.put(report, "preflight", preflight)
  end

  defp mixed_containment_and_handoff_report do
    report = containment_report()

    {:ok, check} =
      Core.capacity_check(:runtime, 10_000, %{
        completed: [],
        interrupted: preflight_batch(),
        unstarted: [tests_batch()]
      })

    Map.put(
      report,
      "preflight",
      Map.put(report["preflight"], "capacity_handoff", check["capacity_handoff"])
    )
  end

  defp four_key_containment_report do
    check =
      Map.put(
        Core.completed_check(%{"passed" => false, "exit_code" => 0},
          reason: "validation_containment_failure"
        ),
        "termination",
        %{
          "timed_out" => false,
          "killed" => true,
          "output_limit_exceeded" => false,
          "cancelled" => false
        }
      )

    %{
      "passed" => false,
      "reason" => "validation_containment_failure",
      "preflight" => check,
      "test" => Core.skipped_check("validation_containment_failure")
    }
  end

  defp containment_termination do
    %{
      "timed_out" => false,
      "killed" => true,
      "output_limit_exceeded" => false,
      "cancelled" => false,
      "containment_failure" => true
    }
  end

  defp three_batch_structural_handoff do
    inventory = String.duplicate("a", 64)

    batches =
      Enum.map(1..3, fn index ->
        %{
          "index" => index,
          "total" => 3,
          "count" => 1,
          "label" => "batch-#{index}-of-3-n1-#{inventory}",
          "inventory_sha256" => inventory
        }
      end)

    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(batches)

    {:ok, handoff} =
      ValidationCapacityHandoff.normalize(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => "structural",
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 10_000,
        "completed_batch_count" => 0,
        "completed_file_count" => 0,
        "unstarted_batch_count" => 3,
        "unstarted_file_count" => 3,
        "total_batch_count" => 3,
        "total_file_count" => 3,
        "ordered_plan_sha256" => digest,
        "interrupted_batch" => nil,
        "unstarted_batches" => batches
      })

    handoff
  end

  defp preflight_batch do
    Core.preflight_batch(Core.inventory_sha256(Core.preflight_argv()))
  end

  defp tests_batch do
    Core.tests_batch(1, Core.inventory_sha256([@kernel_test]))
  end
end
