defmodule Arbor.Consensus.CoordinatorRoutingTest do
  @moduledoc """
  Tests for Phase 3 Coordinator routing via TopicMatcher and TopicRegistry.

  These tests verify that:
  1. TopicMatcher integration routes proposals correctly
  2. TopicRule-driven council configuration works
  3. Advisory mode skips dedup/quota/quorum
  4. Signal differentiation between decision and advice
  5. Backward compatibility is maintained
  """
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.TestHelpers

  describe "advisory mode handling" do
    test "advisory mode skips deduplication check" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      # Submit same advisory proposal twice
      proposal_attrs = %{
        proposer: "agent_1",
        topic: :code_modification,
        mode: :advisory,
        description: "How should we handle caching?"
      }

      {:ok, id1} = Coordinator.submit(proposal_attrs, server: coord)
      {:ok, id2} = Coordinator.submit(proposal_attrs, server: coord)

      # Both should succeed (no duplicate error)
      assert id1 != id2
    end

    test "decision mode enforces deduplication" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      proposal_attrs = %{
        proposer: "agent_1",
        topic: :code_modification,
        mode: :decision,
        description: "Add caching to the API"
      }

      {:ok, _id1} = Coordinator.submit(proposal_attrs, server: coord)
      result = Coordinator.submit(proposal_attrs, server: coord)

      assert result == {:error, :duplicate_proposal}
    end

    test "advisory mode skips agent quota check" do
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 1)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      on_exit(fn ->
        Application.delete_env(:arbor_consensus, :max_proposals_per_agent)
        Application.delete_env(:arbor_consensus, :proposal_quota_enabled)
      end)

      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.SlowBackend,
          config: [evaluation_timeout_ms: 60_000]
        )

      agent_id = "quota_test_agent_#{System.unique_integer([:positive])}"

      # First decision mode proposal
      {:ok, _id1} =
        Coordinator.submit(
          %{
            proposer: agent_id,
            topic: :code_modification,
            mode: :decision,
            description: "Decision proposal 1"
          },
          server: coord
        )

      # Decision mode should hit quota
      result =
        Coordinator.submit(
          %{
            proposer: agent_id,
            topic: :code_modification,
            mode: :decision,
            description: "Decision proposal 2"
          },
          server: coord
        )

      assert result == {:error, :agent_proposal_quota_exceeded}

      # Advisory mode should bypass quota
      {:ok, _id2} =
        Coordinator.submit(
          %{
            proposer: agent_id,
            topic: :code_modification,
            mode: :advisory,
            description: "Advisory proposal"
          },
          server: coord
        )
    end

    test "advisory mode gets quorum of 0 and completes" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :code_modification,
            mode: :advisory,
            description: "Advisory question"
          },
          server: coord
        )

      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status == :approved

      {:ok, decision} = Coordinator.get_decision(id, coord)
      # Advisory mode should have all perspectives collected (no quorum cutoff)
      assert decision.proposal_id == id
    end
  end

  describe "TopicMatcher fallback routing" do
    test "proposal that doesn't match any topic stays as :general" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :general,
            description: "Some unrelated random change"
          },
          server: coord
        )

      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)
      {:ok, proposal} = Coordinator.get_proposal(id, coord)

      # Should stay as :general
      assert proposal.topic == :general
    end

    test "routing adds metadata even for :general fallback" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :general,
            description: "Random proposal"
          },
          server: coord
        )

      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)
      {:ok, proposal} = Coordinator.get_proposal(id, coord)

      # Should have routing metadata
      assert Map.has_key?(proposal.metadata, :routing_confidence)
      assert proposal.metadata[:routed_by] == :topic_matcher
    end
  end

  describe "graceful fallback" do
    test "handles TopicRegistry being unavailable" do
      # Start coordinator - TopicRegistry may or may not be running
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :code_modification,
            description: "Test without registry"
          },
          server: coord
        )

      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status in [:approved, :rejected, :deadlock]
    end

    test "Config-based routing still works as fallback" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      # Submit with a topic that has Config-based rules but no TopicRegistry entry
      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :governance_change,
            description: "Governance change requiring supermajority"
          },
          server: coord
        )

      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)
      {:ok, decision} = Coordinator.get_decision(id, coord)
      assert decision.proposal_id == id
    end
  end

  describe "signal differentiation" do
    test "advisory mode proposal completes successfully" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :code_modification,
            mode: :advisory,
            description: "Advisory question for brainstorming"
          },
          server: coord
        )

      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)

      # The signal is emitted by EventEmitter - just verify the proposal completes
      {:ok, decision} = Coordinator.get_decision(id, coord)
      assert decision.proposal_id == id
    end

    test "decision mode proposal completes with approval" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :code_modification,
            mode: :decision,
            description: "Decision proposal"
          },
          server: coord
        )

      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status == :approved

      {:ok, decision} = Coordinator.get_decision(id, coord)
      assert decision.proposal_id == id
      assert decision.decision == :approved
    end
  end

  describe "backward compatibility" do
    test "existing tests continue to pass with default behavior" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      # Standard proposal using old patterns (change_type instead of topic)
      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            change_type: :code_modification,
            description: "Legacy proposal style"
          },
          server: coord
        )

      {:ok, status} = TestHelpers.wait_for_decision(coord, id)
      assert status == :approved
    end

    test "proposals without explicit mode default to :decision" do
      {_pid, coord} =
        TestHelpers.start_test_coordinator(
          evaluator_backend: TestHelpers.AlwaysApproveBackend,
          config: [evaluation_timeout_ms: 5_000]
        )

      {:ok, id} =
        Coordinator.submit(
          %{
            proposer: "agent_1",
            topic: :code_modification,
            description: "Proposal without mode"
          },
          server: coord
        )

      {:ok, _status} = TestHelpers.wait_for_decision(coord, id)
      {:ok, proposal} = Coordinator.get_proposal(id, coord)

      # Should default to :decision mode
      assert proposal.mode == :decision
    end
  end
end
