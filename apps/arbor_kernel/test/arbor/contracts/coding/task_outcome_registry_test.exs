defmodule Arbor.Contracts.Coding.TaskOutcomeRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.{TaskOutcome, TaskOutcomeRegistry}

  @moduletag :fast

  test "preserves compatibility ordering and exposes exact status categories" do
    assert TaskOutcomeRegistry.terminal_statuses() == ~w(
             approval_denied
             change_committed
             declined
             human_review_required
             no_changes
             pr_created
             pr_failed
             review_failed
             review_unavailable
             review_rejected
             review_requires_rework
             rework_exhausted
             validation_capacity_exceeded
             validation_failed
             design_rework_exhausted
           )

    assert TaskOutcomeRegistry.coding_result_statuses() ==
             TaskOutcomeRegistry.terminal_statuses() ++ ["pipeline_error"]

    assert TaskOutcomeRegistry.pipeline_error_codes() == ~w(
             pipeline_error
             committed_change_materialization_failed
             council_review_failed
             draft_pr_failed
             review_tier_invalid_or_missing
             worker_provider_account_exhausted
             worker_provider_session_id_missing
             worker_recovery_continuity_invalid
             worker_recovery_reopen_failed
             worker_recovery_send_failed
             worker_recovery_summary_failed
             worker_send_recovery_exhausted
             worker_stale_close_failed
             worker_stop_reason_not_end_turn
             worker_turn_no_progress
             workspace_missing
             design_turn_modified_workspace
             design_response_invalid
             design_checkpoint_open_failed
             design_checkpoint_await_failed
             design_checkpoint_timeout
             design_checkpoint_outcome_invalid
             design_worker_phase_invalid
             design_checkpoint_rework_exhausted
           )
  end

  test "parity keeps legacy cancelled distinct from canonical outer task_cancelled" do
    assert TaskOutcomeRegistry.parity_terminal_statuses() == ~w(
             approval_denied
             cancelled
             change_committed
             declined
             human_review_required
             no_changes
             pr_created
             pr_failed
             review_failed
             review_unavailable
             review_rejected
             review_requires_rework
             rework_exhausted
             validation_capacity_exceeded
             validation_failed
             design_rework_exhausted
           )

    assert Enum.all?(
             TaskOutcomeRegistry.parity_terminal_statuses(),
             &TaskOutcomeRegistry.parity_terminal_status?/1
           )

    assert TaskOutcomeRegistry.parity_terminal_status?("cancelled")
    refute TaskOutcomeRegistry.terminal_status?("cancelled")
    assert TaskOutcomeRegistry.registered_code?("task_cancelled")
    refute TaskOutcomeRegistry.parity_terminal_status?("task_cancelled")
  end

  test "every registered code builds a valid TaskOutcome with its declared spec" do
    for code <- TaskOutcomeRegistry.registered_codes() do
      assert {:ok, spec} = TaskOutcomeRegistry.lookup(code)

      assert {:ok, outcome} =
               TaskOutcome.new(
                 Map.merge(
                   %{version: TaskOutcome.schema_version()},
                   spec
                 )
               )

      assert outcome.code == code
      assert outcome.disposition == spec.disposition
      assert outcome.phase == spec.phase
      assert outcome.origin == spec.origin
      assert outcome.retry == spec.retry
      assert TaskOutcomeRegistry.registered_code?(code)
    end
  end

  test "outer lifecycle and control codes have exact specs" do
    assert spec("coding_admission_failed") == {"failed", "preflight", "arbor", "none"}

    assert spec("coding_execution_state_drift") ==
             {"failed", "preflight", "arbor", "after_external_change"}

    assert spec("task_cancelled") == {"cancelled", "control", "operator", "none"}
    assert spec("task_owner_died") == {"failed", "control", "runtime", "new_session"}
    assert spec("task_runner_failed") == {"failed", "control", "runtime", "new_session"}

    assert spec("approval_owner_terminated") ==
             {"failed", "control", "runtime", "after_external_change"}

    assert spec("task_finalization_failed") ==
             {"failed", "cleanup", "runtime", "after_external_change"}
  end

  test "design pipeline codes have exact closed semantics" do
    expected = [
      {"design_turn_modified_workspace", {"failed", "design", "worker", "new_session"}},
      {"design_response_invalid", {"failed", "design", "worker", "same_session"}},
      {"design_checkpoint_open_failed", {"failed", "design", "arbor", "after_external_change"}},
      {"design_checkpoint_await_failed", {"failed", "design", "arbor", "after_external_change"}},
      {"design_checkpoint_timeout",
       {"requires_input", "design", "operator", "after_external_change"}},
      {"design_checkpoint_outcome_invalid", {"failed", "design", "runtime", "none"}},
      {"design_worker_phase_invalid", {"failed", "design", "runtime", "none"}},
      {"design_checkpoint_rework_exhausted", {"failed", "design", "runtime", "new_session"}}
    ]

    for {code, semantics} <- expected do
      assert TaskOutcomeRegistry.pipeline_error_code?(code)
      assert spec(code) == semantics
      assert {:ok, %TaskOutcome{phase: "design"}} = TaskOutcome.from_code(code)
    end

    assert spec("design_rework_exhausted") == {"failed", "design", "policy", "none"}
    assert TaskOutcomeRegistry.terminal_status?("design_rework_exhausted")
    assert TaskOutcomeRegistry.registered_code?("design_rework_exhausted")
    refute TaskOutcomeRegistry.pipeline_error_code?("design_rework_exhausted")
    refute TaskOutcomeRegistry.adoptable_terminal_status?("design_rework_exhausted")

    assert {:ok, %TaskOutcome{phase: "design", origin: "policy", retry: "none"}} =
             TaskOutcome.from_code("design_rework_exhausted")
  end

  test "adoptable terminal statuses are the exact closed post-terminal vocabulary" do
    assert TaskOutcomeRegistry.adoptable_terminal_statuses() ==
             ~w(change_committed human_review_required pr_created)

    assert Enum.all?(
             TaskOutcomeRegistry.adoptable_terminal_statuses(),
             fn status ->
               TaskOutcomeRegistry.adoptable_terminal_status?(status) and
                 TaskOutcomeRegistry.terminal_status?(status) and
                 TaskOutcomeRegistry.registered_code?(status)
             end
           )

    refute TaskOutcomeRegistry.adoptable_terminal_status?("validation_capacity_exceeded")
    refute TaskOutcomeRegistry.adoptable_terminal_status?("review_requires_rework")
    refute TaskOutcomeRegistry.adoptable_terminal_status?("no_changes")
    refute TaskOutcomeRegistry.adoptable_terminal_status?(nil)
    refute TaskOutcomeRegistry.adoptable_terminal_status?(:human_review_required)
    refute TaskOutcomeRegistry.adoptable_terminal_status?("unknown_code")
    refute TaskOutcomeRegistry.adoptable_terminal_status?("change_committed/extra")

    assert {:ok, spec} = TaskOutcomeRegistry.lookup("human_review_required")
    assert Map.keys(spec) |> Enum.sort() == [:code, :disposition, :origin, :phase, :retry]
    refute Map.has_key?(spec, :adoptable)
    refute Map.has_key?(spec, "adoptable")

    assert {:ok, outcome} = TaskOutcome.from_code("human_review_required")
    assert outcome.disposition == "requires_input"
    assert outcome.phase == "review"
    assert outcome.origin == "reviewer"
    assert outcome.retry == "none"
  end

  test "unknown status and code queries fail closed" do
    for unknown <- [nil, :change_committed, "unknown_code", "change_committed/extra"] do
      refute TaskOutcomeRegistry.terminal_status?(unknown)
      refute TaskOutcomeRegistry.adoptable_terminal_status?(unknown)
      refute TaskOutcomeRegistry.coding_result_status?(unknown)
      refute TaskOutcomeRegistry.pipeline_error_code?(unknown)
      refute TaskOutcomeRegistry.registered_code?(unknown)
      assert TaskOutcomeRegistry.lookup(unknown) == :error
    end
  end

  test "status consumers recognize exactly the intended values" do
    assert Enum.all?(
             TaskOutcomeRegistry.terminal_statuses(),
             &TaskOutcomeRegistry.terminal_status?/1
           )

    assert TaskOutcomeRegistry.coding_result_status?("pipeline_error")
    refute TaskOutcomeRegistry.coding_result_status?("worker_provider_account_exhausted")
    refute TaskOutcomeRegistry.terminal_status?("pipeline_error")

    assert TaskOutcomeRegistry.transcript_terminal_status?("success")
    assert TaskOutcomeRegistry.transcript_terminal_status?("cancelled")
    refute TaskOutcomeRegistry.transcript_terminal_status?("change_committed")
  end

  defp spec(code) do
    {:ok, value} = TaskOutcomeRegistry.lookup(code)
    {value.disposition, value.phase, value.origin, value.retry}
  end
end
