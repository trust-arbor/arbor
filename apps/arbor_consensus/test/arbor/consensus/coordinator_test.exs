defmodule Arbor.Consensus.CoordinatorTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.TestHelpers

  setup do
    # Start a test event store
    {_es_pid, es_name} = TestHelpers.start_test_event_store()
    # Start coordinator with test backend and short timeout
    {_pid, name} =
      TestHelpers.start_test_coordinator(
        evaluator_backend: TestHelpers.AlwaysApproveBackend,
        config: [evaluation_timeout_ms: 5_000]
      )

    %{coordinator: name, event_store: es_name}
  end

  describe "submit/2" do
    test "submits a proposal and returns its ID", %{coordinator: coord} do
      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            change_type: :code_modification,
            description: "Test change"
          },
          server: coord
        )

      assert is_binary(id)
      assert String.starts_with?(id, "prop_")
    end

    test "accepts a Proposal struct", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)
      assert id == proposal.id
    end

    test "rejects proposals that violate invariants", %{coordinator: coord} do
      proposal = TestHelpers.build_invariant_violating_proposal()
      result = Coordinator.submit(proposal, server: coord)
      assert {:error, {:violates_invariants, _}} = result
    end

    test "rejects duplicate proposals", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, _id} = Coordinator.submit(proposal, server: coord)

      # Same proposal again
      proposal2 = TestHelpers.build_proposal(%{
        change_type: proposal.change_type,
        target_module: proposal.target_module,
        description: proposal.description,
        code_diff: proposal.code_diff
      })
      result = Coordinator.submit(proposal2, server: coord)
      assert result == {:error, :duplicate_proposal}
    end

    test "respects capacity limits" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [max_concurrent_proposals: 1, evaluation_timeout_ms: 60_000]
        )

      # First should succeed
      {:ok, _} =
        Coordinator.submit(
          %{proposer: "a1", change_type: :code_modification, description: "first"},
          server: coord
        )

      # Second should fail (at capacity)
      result =
        Coordinator.submit(
          %{proposer: "a2", change_type: :test_change, description: "second"},
          server: coord
        )

      assert result == {:error, :at_capacity}
    end

    test "rejects when authorizer denies" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          authorizer: TestHelpers.DenyAllAuthorizer
        )

      result =
        Coordinator.submit(
          %{proposer: "a1", change_type: :code_modification, description: "denied"},
          server: coord
        )

      assert result == {:error, :unauthorized}
    end
  end

  describe "get_status/2" do
    test "returns status of existing proposal", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      {:ok, status} = Coordinator.get_status(id, coord)
      assert status in [:evaluating, :approved, :rejected, :deadlock]
    end

    test "returns not_found for unknown proposal", %{coordinator: coord} do
      assert {:error, :not_found} = Coordinator.get_status("nonexistent", coord)
    end
  end

  describe "get_decision/2" do
    test "returns decision after evaluation completes", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      # Wait for decision
      {:ok, _status} = TestHelpers.wait_for_decision(coord, id, 10_000)

      {:ok, decision} = Coordinator.get_decision(id, coord)
      assert decision.proposal_id == id
      assert decision.decision in [:approved, :rejected, :deadlock]
    end

    test "returns not_decided for still-evaluating proposal" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      # Immediately check — should not be decided yet
      assert {:error, :not_decided} = Coordinator.get_decision(id, coord)
    end

    test "returns not_found for unknown proposal", %{coordinator: coord} do
      assert {:error, :not_found} = Coordinator.get_decision("nonexistent", coord)
    end
  end

  describe "get_proposal/2" do
    test "returns proposal by ID", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      {:ok, retrieved} = Coordinator.get_proposal(id, coord)
      assert retrieved.id == id
      assert retrieved.proposer == proposal.proposer
    end

    test "returns not_found for unknown", %{coordinator: coord} do
      assert {:error, :not_found} = Coordinator.get_proposal("nope", coord)
    end
  end

  describe "list_pending/1" do
    test "lists pending proposals" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      Coordinator.submit(
        %{proposer: "a1", change_type: :code_modification, description: "p1"},
        server: coord
      )

      pending = Coordinator.list_pending(coord)
      assert length(pending) == 1
    end
  end

  describe "list_proposals/1" do
    test "lists all proposals", %{coordinator: coord} do
      Coordinator.submit(
        %{proposer: "a1", change_type: :code_modification, description: "proposal 1"},
        server: coord
      )

      Coordinator.submit(
        %{proposer: "a2", change_type: :test_change, description: "proposal 2"},
        server: coord
      )

      proposals = Coordinator.list_proposals(coord)
      assert length(proposals) == 2
    end
  end

  describe "cancel/2" do
    test "cancels a pending proposal" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{proposer: "a1", change_type: :code_modification, description: "to cancel"},
          server: coord
        )

      assert :ok = Coordinator.cancel(id, coord)
      {:ok, status} = Coordinator.get_status(id, coord)
      assert status == :vetoed
    end

    test "returns not_found for unknown proposal", %{coordinator: coord} do
      assert {:error, :not_found} = Coordinator.cancel("nope", coord)
    end
  end

  describe "force_approve/3" do
    test "force-approves a proposal" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{proposer: "a1", change_type: :code_modification, description: "force approve"},
          server: coord
        )

      assert :ok = Coordinator.force_approve(id, "admin_1", coord)
      {:ok, status} = Coordinator.get_status(id, coord)
      assert status == :approved
    end

    test "returns not_found for unknown", %{coordinator: coord} do
      assert {:error, :not_found} = Coordinator.force_approve("nope", "admin", coord)
    end
  end

  describe "force_reject/3" do
    test "force-rejects a proposal" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{proposer: "a1", change_type: :code_modification, description: "force reject"},
          server: coord
        )

      assert :ok = Coordinator.force_reject(id, "admin_1", coord)
      {:ok, status} = Coordinator.get_status(id, coord)
      assert status == :rejected
    end
  end

  describe "stats/1" do
    test "returns coordinator statistics", %{coordinator: coord} do
      stats = Coordinator.stats(coord)

      assert is_map(stats)
      assert Map.has_key?(stats, :total_proposals)
      assert Map.has_key?(stats, :total_decisions)
      assert Map.has_key?(stats, :active_councils)
      assert Map.has_key?(stats, :evaluator_backend)
      assert Map.has_key?(stats, :config)
    end

    test "tracks proposal counts", %{coordinator: coord} do
      Coordinator.submit(
        %{proposer: "a1", change_type: :code_modification, description: "stat test"},
        server: coord
      )

      Process.sleep(100)
      stats = Coordinator.stats(coord)
      assert stats.total_proposals >= 1
    end
  end

  describe "full lifecycle" do
    test "proposal goes through complete lifecycle with approval", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      # Wait for decision
      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status == :approved

      # Check decision
      {:ok, decision} = Coordinator.get_decision(id, coord)
      assert decision.decision == :approved
      assert decision.quorum_met == true
    end

    test "proposal gets rejected with rejecting backend" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysRejectBackend
        )

      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status == :rejected

      {:ok, decision} = Coordinator.get_decision(id, coord)
      assert decision.decision == :rejected
    end

    test "auto-executes approved proposal when configured" do
      Process.register(self(), :test_executor_receiver)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          executor: TestHelpers.TestExecutor,
          config: [auto_execute_approved: true, evaluation_timeout_ms: 5_000]
        )

      proposal = TestHelpers.build_proposal()
      {:ok, id} = Coordinator.submit(proposal, server: coord)

      {:ok, :approved} = TestHelpers.wait_for_decision(coord, id)

      # Should receive execution message
      assert_receive :executed, 5_000

      Process.unregister(:test_executor_receiver)
    end
  end

  describe "evaluator_backend override" do
    test "per-proposal backend override works" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysRejectBackend
        )

      # Default would reject, but we override with approve
      proposal = TestHelpers.build_proposal()

      {:ok, id} =
        Coordinator.submit(proposal,
          server: coord,
          evaluator_backend: TestHelpers.AlwaysApproveBackend
        )

      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status == :approved
    end
  end
end
