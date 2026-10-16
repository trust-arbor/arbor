defmodule Arbor.Actions.ConfirmationTrackerFixture do
  @moduledoc false

  # arbor_trust starts with start_children: false in tests. ReviewedValidation
  # and ReviewedCommit used to start_supervised! the named ConfirmationTracker
  # from setup_all. ExUnit stops that child when the owning module ends, so the
  # next async:false module hit :approval_evidence_unavailable on a live
  # InteractionRouter answer. Keep one suite-owned tracker.
  #
  # Child-app runs also cannot load Arbor.Agent.ApprovalEvidence (L7, not an
  # actions dep). Install the Comms/Consensus-backed test provider only when
  # the configured module is missing so production still fail-closes.
  def ensure! do
    ensure_tracker!()
    ensure_evidence_provider!()
  end

  defp ensure_tracker! do
    case Process.whereis(Arbor.Trust.ConfirmationTracker) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_trust)
        {:ok, _} = Arbor.Trust.ConfirmationTracker.start_link(test_isolated_owner: true)
        :ok
    end
  end

  defp ensure_evidence_provider! do
    provider = Application.get_env(:arbor_trust, :approval_evidence_provider)

    if usable_provider?(provider) do
      :ok
    else
      Application.put_env(
        :arbor_trust,
        :approval_evidence_provider,
        Arbor.Actions.TestApprovalEvidence
      )
    end
  end

  defp usable_provider?(provider) do
    is_atom(provider) and not is_nil(provider) and Code.ensure_loaded?(provider) and
      function_exported?(provider, :answered_approval, 2)
  end
end
