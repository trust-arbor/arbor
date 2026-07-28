defmodule Arbor.Consensus.PendingApprovalSettlementTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Coding.PendingApprovalIdentity
  alias Arbor.Contracts.Coding.PendingApprovalResourceId
  alias Arbor.Contracts.Consensus.Proposal

  @moduletag :fast

  setup do
    {_es_pid, _es_name} = TestHelpers.start_test_event_store()

    # SlowBackend keeps proposals pending/evaluating so settlement can race free.
    {_pid, name} =
      TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.SlowBackend,
        config: [evaluation_timeout_ms: 60_000]
      )

    %{coordinator: name}
  end

  test "exact match settles by cancel/veto and removes from list_pending", %{coordinator: coord} do
    proposal = auth_request_proposal("prop_settle_ok")
    assert {:ok, "prop_settle_ok"} = submit_human_approval(coord, proposal)

    stored = fetch_proposal!(coord, "prop_settle_ok")
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(stored)
    fields = settle_fields(expected)

    assert {:ok, receipt} =
             Coordinator.compare_and_settle_pending_approval(fields, coord)

    assert receipt["outcome"] == "settled"
    assert receipt["resource_type"] == "pending_approval"
    assert receipt["active"] == false
    assert receipt["status"] == "removed"

    pending_ids = coord |> Coordinator.list_pending() |> Enum.map(& &1.id)
    refute "prop_settle_ok" in pending_ids

    stored = Enum.find(Coordinator.list_proposals(coord), &(&1.id == "prop_settle_ok"))
    assert stored.status == :vetoed
  end

  test "replay after settle returns already_absent without mutation", %{coordinator: coord} do
    proposal = auth_request_proposal("prop_settle_replay")
    assert {:ok, "prop_settle_replay"} = submit_human_approval(coord, proposal)
    stored = fetch_proposal!(coord, "prop_settle_replay")
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(stored)
    fields = settle_fields(expected)

    assert {:ok, first} = Coordinator.compare_and_settle_pending_approval(fields, coord)
    assert first["outcome"] == "settled"

    assert {:ok, second} = Coordinator.compare_and_settle_pending_approval(fields, coord)
    assert second["outcome"] == "already_absent"
    assert second["active"] == false
    refute Map.has_key?(second, "status")
  end

  test "absent proposal returns already_absent", %{coordinator: coord} do
    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", "prop_missing")

    fields = %{
      "resource_id" => resource_id,
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => "prop_missing",
        "source" => "consensus",
        "task_id" => nil,
        "agent_id" => "agent_x",
        "principal_id" => "agent_x",
        "approver_id" => nil,
        "resource_uri" => nil,
        "action" => "authorization_request",
        "status" => "pending",
        "created_at" => nil
      }
    }

    assert {:ok, receipt} = Coordinator.compare_and_settle_pending_approval(fields, coord)
    assert receipt["outcome"] == "already_absent"
  end

  test "security regression: stale identity cannot mutate pending proposal", %{coordinator: coord} do
    proposal = auth_request_proposal("prop_stale_id")
    assert {:ok, "prop_stale_id"} = submit_human_approval(coord, proposal)
    stored = fetch_proposal!(coord, "prop_stale_id")
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(stored)

    stale = Map.put(expected, "task_id", "task_other")
    fields = settle_fields(stale)

    assert {:error, {:reconciliation_identity_conflict, conflict}} =
             Coordinator.compare_and_settle_pending_approval(fields, coord)

    assert conflict["resource_id"] == expected["resource_id"]
    assert conflict["current_identity"]["task_id"] == expected["task_id"]

    pending_ids = coord |> Coordinator.list_pending() |> Enum.map(& &1.id)
    assert "prop_stale_id" in pending_ids
  end

  test "security regression: duplicate outer keys cannot settle a pending proposal", %{
    coordinator: coord
  } do
    proposal = auth_request_proposal("prop_duplicate_outer")
    assert {:ok, _} = Coordinator.submit(proposal, server: coord)
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(proposal)

    duplicate_keys =
      expected
      |> settle_fields()
      |> Map.put(:resource_id, expected["resource_id"])

    assert {:error, :invalid_reconciliation_settle_fields} =
             Coordinator.compare_and_settle_pending_approval(duplicate_keys, coord)

    assert Enum.any?(Coordinator.list_pending(coord), &(&1.id == "prop_duplicate_outer"))
  end

  test "security regression: non-authorization topic is rejected without mutation", %{
    coordinator: coord
  } do
    proposal =
      TestHelpers.build_proposal(%{
        id: "prop_code_topic",
        topic: :code_modification,
        proposer: "agent_x",
        description: "not an approval"
      })

    assert {:ok, _} = submit_human_approval(coord, proposal)
    stored = fetch_proposal!(coord, "prop_code_topic")

    {:ok, resource_id} = PendingApprovalResourceId.resource_id("consensus", "prop_code_topic")

    fields = %{
      "resource_id" => resource_id,
      "expected_identity" => %{
        "resource_type" => "pending_approval",
        "resource_id" => resource_id,
        "approval_id" => "prop_code_topic",
        "source" => "consensus",
        "task_id" => nil,
        "agent_id" => "agent_x",
        "principal_id" => "agent_x",
        "approver_id" => nil,
        "resource_uri" => nil,
        "action" => "code_modification",
        "status" => "pending",
        "created_at" => DateTime.to_iso8601(stored.created_at)
      }
    }

    assert {:error, :not_authorization_request} =
             Coordinator.compare_and_settle_pending_approval(fields, coord)

    stored_after = fetch_proposal!(coord, "prop_code_topic")
    assert stored_after.status == :pending
  end

  test "malformed settle fields are rejected", %{coordinator: coord} do
    assert {:error, :invalid_reconciliation_settle_fields} =
             Coordinator.compare_and_settle_pending_approval(%{"resource_id" => "x"}, coord)

    assert {:error, :invalid_reconciliation_settle_fields} =
             Coordinator.compare_and_settle_pending_approval("nope", coord)
  end

  test "ordinary cancel remains available", %{coordinator: coord} do
    proposal = auth_request_proposal("prop_ordinary_cancel")
    assert {:ok, _} = submit_human_approval(coord, proposal)
    assert :ok = Coordinator.cancel("prop_ordinary_cancel", coord)

    stored = Enum.find(Coordinator.list_proposals(coord), &(&1.id == "prop_ordinary_cancel"))
    assert stored.status == :vetoed
  end

  test "security regression: reconciliation cancellation is terminal for waiters and late council results" do
    register_executor_receiver()

    {_pid, coord} =
      TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.SlowBackend,
        executor: TestHelpers.TestExecutor,
        config: [auto_execute_approved: true, evaluation_timeout_ms: 60_000]
      )

    proposal = auth_request_proposal("prop_terminal_settle")
    assert {:ok, proposal.id} == Coordinator.submit(proposal, server: coord)
    stored = fetch_proposal!(coord, proposal.id)
    assert stored.status == :evaluating
    {:ok, expected} = PendingApprovalIdentity.from_consensus_proposal(stored)

    waiter =
      Task.async(fn ->
        Coordinator.await(proposal.id, server: coord, timeout: 2_000)
      end)

    assert_eventually(fn ->
      proposal.id in Map.keys(:sys.get_state(coord).waiters)
    end)

    assert {:ok, %{"outcome" => "settled"}} =
             Coordinator.compare_and_settle_pending_approval(settle_fields(expected), coord)

    assert {:error, :cancelled} = Task.await(waiter, 2_000)
    assert {:error, :cancelled} = Coordinator.await(proposal.id, server: coord, timeout: 50)

    evaluations = TestHelpers.build_approving_evaluations(proposal.id)
    send(coord, {make_ref(), {:council_result, proposal.id, {:ok, evaluations}}})
    _state_barrier = :sys.get_state(coord)

    assert {:ok, :vetoed} = Coordinator.get_status(proposal.id, coord)
    refute Enum.any?(Coordinator.list_decisions(coord), &(&1.proposal_id == proposal.id))
    refute_receive :executed, 100
  end

  test "security regression: ordinary cancel rejects late council failure and releases waiters",
       %{
         coordinator: coord
       } do
    proposal = auth_request_proposal("prop_terminal_ordinary_cancel")
    assert {:ok, proposal.id} == Coordinator.submit(proposal, server: coord)

    waiter =
      Task.async(fn ->
        Coordinator.await(proposal.id, server: coord, timeout: 2_000)
      end)

    assert_eventually(fn ->
      proposal.id in Map.keys(:sys.get_state(coord).waiters)
    end)

    assert :ok = Coordinator.cancel(proposal.id, coord)
    assert {:error, :cancelled} = Task.await(waiter, 2_000)

    send(coord, {make_ref(), {:council_result, proposal.id, {:error, :late_failure}}})
    state = :sys.get_state(coord)

    assert state.proposals[proposal.id].status == :vetoed
    refute Map.has_key?(state.pending_evaluations, proposal.id)
    assert {:error, :already_decided} = Coordinator.cancel(proposal.id, coord)
  end

  test "deadlock regression: council failure releases existing waiters", %{coordinator: coord} do
    assert_deadlock_releases_waiter(coord, {:error, :council_failed})
  end

  test "deadlock regression: decision rendering failure releases existing waiters", %{
    coordinator: coord
  } do
    assert_deadlock_releases_waiter(coord, :render_failure)
  end

  defp auth_request_proposal(id) do
    {:ok, proposal} =
      Proposal.new(%{
        id: id,
        proposer: "agent_x",
        topic: :authorization_request,
        description: "approve shell",
        target_layer: 1,
        metadata: %{
          principal_id: "agent_x",
          resource_uri: "arbor://shell/exec",
          action: "execute",
          task_id: "task_settle_1"
        },
        context: %{}
      })

    proposal
  end

  defp submit_human_approval(coord, proposal) do
    Coordinator.submit(proposal, server: coord, human_approval: true)
  end

  defp settle_fields(expected) do
    %{
      "resource_id" => expected["resource_id"],
      "expected_identity" => expected
    }
  end

  defp fetch_proposal!(coord, id) do
    Enum.find(Coordinator.list_proposals(coord), &(&1.id == id)) ||
      flunk("proposal #{id} not found")
  end

  defp register_executor_receiver do
    Process.register(self(), :test_executor_receiver)

    on_exit(fn ->
      if Process.whereis(:test_executor_receiver) == self() do
        Process.unregister(:test_executor_receiver)
      end
    end)
  end

  defp assert_deadlock_releases_waiter(coord, council_result) do
    proposal_id = "prop_deadlock_waiter_#{System.unique_integer([:positive])}"
    proposal = auth_request_proposal(proposal_id)
    assert {:ok, ^proposal_id} = Coordinator.submit(proposal, server: coord)
    council_task = :sys.get_state(coord).active_councils[proposal_id]

    waiter =
      Task.async(fn ->
        Coordinator.await(proposal_id, server: coord, timeout: 2_000)
      end)

    assert_eventually(fn ->
      proposal_id in Map.keys(:sys.get_state(coord).waiters)
    end)

    council_result =
      case council_result do
        :render_failure ->
          evaluation =
            TestHelpers.build_evaluation(%{proposal_id: proposal_id})
            |> Map.put(:sealed, false)

          {:ok, [evaluation]}

        result ->
          result
      end

    send(coord, {make_ref(), {:council_result, proposal_id, council_result}})
    _state_barrier = :sys.get_state(coord)

    assert {:error, :deadlock} = Task.await(waiter, 2_000)
    assert {:ok, :deadlock} = Coordinator.get_status(proposal_id, coord)

    if match?(%Task{}, council_task), do: Process.exit(council_task.pid, :kill)
  end

  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
    end
  end
end
