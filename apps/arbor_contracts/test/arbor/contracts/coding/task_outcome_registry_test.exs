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
             review_rejected
             review_requires_rework
             rework_exhausted
             validation_capacity_exceeded
             validation_failed
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
           )
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
    assert spec("task_cancelled") == {"cancelled", "control", "operator", "none"}
    assert spec("task_owner_died") == {"failed", "control", "runtime", "new_session"}
    assert spec("task_runner_failed") == {"failed", "control", "runtime", "new_session"}

    assert spec("approval_owner_terminated") ==
             {"failed", "control", "runtime", "after_external_change"}

    assert spec("task_finalization_failed") ==
             {"failed", "cleanup", "runtime", "after_external_change"}
  end

  test "unknown status and code queries fail closed" do
    for unknown <- [nil, :change_committed, "unknown_code", "change_committed/extra"] do
      refute TaskOutcomeRegistry.terminal_status?(unknown)
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
