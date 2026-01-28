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

  # ===========================================================================
  # Phase 7: Per-agent proposal quota enforcement
  # ===========================================================================

  describe "submit/2 per-agent quota enforcement" do
    setup do
      original_max = Application.get_env(:arbor_consensus, :max_proposals_per_agent)
      original_enabled = Application.get_env(:arbor_consensus, :proposal_quota_enabled)

      on_exit(fn ->
        restore_config(:max_proposals_per_agent, original_max)
        restore_config(:proposal_quota_enabled, original_enabled)
      end)

      :ok
    end

    test "succeeds within per-agent proposal limit" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 3)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      agent_id = "agent_quota_test_#{:erlang.unique_integer([:positive])}"

      for i <- 1..3 do
        {:ok, _} =
          Coordinator.submit(
            %{proposer: agent_id, change_type: :code_modification, description: "p#{i}"},
            server: coord
          )
      end

      # All 3 should succeed
      stats = Coordinator.stats(coord)
      assert stats.total_proposals == 3
    end

    test "fails when per-agent limit exceeded" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 2)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      agent_id = "agent_quota_fail_#{:erlang.unique_integer([:positive])}"

      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :code_modification, description: "p1"},
          server: coord
        )

      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :test_change, description: "p2"},
          server: coord
        )

      # 3rd should fail
      result =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :documentation_change, description: "p3"},
          server: coord
        )

      assert result == {:error, :agent_proposal_quota_exceeded}
    end

    test "decision reached frees quota space" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 1)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      agent_id = "agent_quota_free_#{:erlang.unique_integer([:positive])}"

      {:ok, id1} =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :code_modification, description: "first"},
          server: coord
        )

      # Wait for decision
      {:ok, :approved} = TestHelpers.wait_for_decision(coord, id1)

      # Now should be able to submit another
      {:ok, _id2} =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :test_change, description: "second"},
          server: coord
        )
    end

    test "cancel frees quota space" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 1)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      agent_id = "agent_quota_cancel_#{:erlang.unique_integer([:positive])}"

      {:ok, id1} =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :code_modification, description: "cancel me"},
          server: coord
        )

      # At limit
      result =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :test_change, description: "blocked"},
          server: coord
        )

      assert result == {:error, :agent_proposal_quota_exceeded}

      # Cancel the first
      :ok = Coordinator.cancel(id1, coord)

      # Now should succeed
      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent_id, change_type: :test_change, description: "after cancel"},
          server: coord
        )
    end

    test "multiple agents can each have max proposals" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 2)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000, max_concurrent_proposals: 10]
        )

      agent1 = "multi_agent_1_#{:erlang.unique_integer([:positive])}"
      agent2 = "multi_agent_2_#{:erlang.unique_integer([:positive])}"

      # Agent 1: 2 proposals
      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent1, change_type: :code_modification, description: "a1p1"},
          server: coord
        )

      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent1, change_type: :test_change, description: "a1p2"},
          server: coord
        )

      # Agent 2: 2 proposals
      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent2, change_type: :code_modification, description: "a2p1"},
          server: coord
        )

      {:ok, _} =
        Coordinator.submit(
          %{proposer: agent2, change_type: :test_change, description: "a2p2"},
          server: coord
        )

      # Agent 1 at limit
      result =
        Coordinator.submit(
          %{proposer: agent1, change_type: :documentation_change, description: "a1p3"},
          server: coord
        )

      assert result == {:error, :agent_proposal_quota_exceeded}

      # Agent 2 also at limit
      result =
        Coordinator.submit(
          %{proposer: agent2, change_type: :documentation_change, description: "a2p3"},
          server: coord
        )

      assert result == {:error, :agent_proposal_quota_exceeded}
    end

    test "quota disabled allows unlimited proposals" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 1)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, false)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000, max_concurrent_proposals: 10]
        )

      agent_id = "agent_no_quota_#{:erlang.unique_integer([:positive])}"

      # Should be able to submit more than the limit
      for i <- 1..5 do
        {:ok, _} =
          Coordinator.submit(
            %{proposer: agent_id, change_type: :code_modification, description: "p#{i}"},
            server: coord
          )
      end
    end
  end

  describe "stats/1 quota information" do
    test "includes quota stats", %{coordinator: coord} do
      stats = Coordinator.stats(coord)

      assert Map.has_key?(stats, :max_proposals_per_agent)
      assert Map.has_key?(stats, :agents_with_proposals)
      assert Map.has_key?(stats, :proposal_quota_enabled)

      assert is_integer(stats.max_proposals_per_agent)
      assert is_integer(stats.agents_with_proposals)
      assert is_boolean(stats.proposal_quota_enabled)
    end
  end

  defp restore_config(key, nil), do: Application.delete_env(:arbor_consensus, key)
  defp restore_config(key, value), do: Application.put_env(:arbor_consensus, key, value)
end
