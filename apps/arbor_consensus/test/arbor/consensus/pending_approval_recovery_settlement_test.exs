defmodule Arbor.Consensus.PendingApprovalRecoverySettlementTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Coding.PendingApprovalResourceId

  @moduletag :fast

  defmodule FailingEventLog do
    def read_stream(_stream_id, _opts), do: {:error, :backend_unavailable}
    def append(_stream_id, events, _opts), do: {:ok, List.wrap(events)}
  end

  setup do
    original_event_log = Application.fetch_env(:arbor_consensus, :event_log)
    original_emit_recovery = Application.fetch_env(:arbor_consensus, :emit_recovery_events)

    Application.put_env(:arbor_consensus, :event_log, {FailingEventLog, []})
    Application.put_env(:arbor_consensus, :emit_recovery_events, false)

    on_exit(fn ->
      restore_env(:event_log, original_event_log)
      restore_env(:emit_recovery_events, original_emit_recovery)
    end)

    :ok
  end

  test "security regression: failed recovery cannot prove a pending approval is absent" do
    {_pid, coord} = TestHelpers.start_test_coordinator()
    approval_id = "prop_unavailable_after_recovery_failure"
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", approval_id)

    fields = %{
      "resource_id" => resource_id,
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => approval_id,
        "source" => "consensus",
        "task_id" => "task_recovery_failure",
        "agent_id" => "agent_recovery_failure",
        "principal_id" => "agent_recovery_failure",
        "approver_id" => nil,
        "resource_uri" => "arbor://shell/exec",
        "action" => "execute",
        "status" => "pending",
        "created_at" => nil
      }
    }

    assert {:error, :current_identity_unavailable} =
             Coordinator.compare_and_settle_pending_approval(fields, coord)

    assert Coordinator.list_proposals(coord) == []
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_consensus, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_consensus, key)
end

defmodule Arbor.Consensus.PendingApprovalDurableSettlementTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Coding.PendingApprovalIdentity
  alias Arbor.Contracts.Consensus.Proposal
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast

  defmodule AppendFailingEventLog do
    def read_stream(_stream_id, _opts), do: {:error, :stream_not_found}
    def append(_stream_id, _events, _opts), do: {:error, :backend_unavailable}
  end

  setup do
    original_event_log = Application.fetch_env(:arbor_consensus, :event_log)
    original_strategy = Application.fetch_env(:arbor_consensus, :event_persistence_strategy)
    original_emit_recovery = Application.fetch_env(:arbor_consensus, :emit_recovery_events)

    on_exit(fn ->
      restore_env(:event_log, original_event_log)
      restore_env(:event_persistence_strategy, original_strategy)
      restore_env(:emit_recovery_events, original_emit_recovery)
    end)

    :ok
  end

  test "security regression: settled approval remains vetoed after coordinator restart" do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table = :"pending_settlement_events_#{System.unique_integer([:positive])}"
    {:ok, _pid} = ETS.start_link(name: table)

    Application.put_env(:arbor_consensus, :event_log, {ETS, name: table})
    Application.put_env(:arbor_consensus, :event_persistence_strategy, :with_event_log)
    Application.put_env(:arbor_consensus, :emit_recovery_events, false)

    {_pid, first} = TestHelpers.start_test_coordinator()
    proposal = approval_proposal("prop_durable_settlement")

    assert {:ok, proposal.id} ==
             Coordinator.submit(proposal, server: first, human_approval: true)

    stored = Enum.find(Coordinator.list_proposals(first), &(&1.id == proposal.id))
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(stored)

    assert {:ok, %{"outcome" => "settled"}} =
             Coordinator.compare_and_settle_pending_approval(settle_fields(expected), first)

    GenServer.stop(first)
    {_pid, recovered} = TestHelpers.start_test_coordinator()

    assert {:ok, :vetoed} = Coordinator.get_status(proposal.id, recovered)
    refute Enum.any?(Coordinator.list_pending(recovered), &(&1.id == proposal.id))

    assert {:ok, %{"outcome" => "already_absent"}} =
             Coordinator.compare_and_settle_pending_approval(settle_fields(expected), recovered)
  end

  test "security regression: failed cancellation append cannot publish settlement" do
    Application.put_env(:arbor_consensus, :event_log, {AppendFailingEventLog, []})
    Application.put_env(:arbor_consensus, :event_persistence_strategy, :with_event_log)
    Application.put_env(:arbor_consensus, :emit_recovery_events, false)

    {_pid, coord} = TestHelpers.start_test_coordinator()
    proposal = approval_proposal("prop_failed_cancel_append")

    assert {:ok, proposal.id} ==
             Coordinator.submit(proposal, server: coord, human_approval: true)

    stored = Enum.find(Coordinator.list_proposals(coord), &(&1.id == proposal.id))
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(stored)

    assert {:error, :reconciliation_persistence_unavailable} =
             Coordinator.compare_and_settle_pending_approval(settle_fields(expected), coord)

    assert {:ok, :pending} = Coordinator.get_status(proposal.id, coord)
    assert {:error, :persistence_unavailable} = Coordinator.cancel(proposal.id, coord)
    assert {:ok, :pending} = Coordinator.get_status(proposal.id, coord)
  end

  defp approval_proposal(id) do
    {:ok, proposal} =
      Proposal.new(%{
        id: id,
        proposer: "agent_durable_settlement",
        topic: :authorization_request,
        description: "durable settlement",
        target_layer: 1,
        metadata: %{
          principal_id: "agent_durable_settlement",
          resource_uri: "arbor://shell/exec",
          action: "execute",
          task_id: "task_durable_settlement"
        },
        context: %{}
      })

    proposal
  end

  defp settle_fields(expected) do
    %{
      "resource_id" => expected["resource_id"],
      "expected_identity" => expected
    }
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_consensus, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_consensus, key)
end
