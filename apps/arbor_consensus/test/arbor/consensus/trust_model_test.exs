defmodule Arbor.Consensus.TrustModelTest do
  @moduledoc """
  Tests for the trust model enforcement.

  Verifies that:
  - Agents cannot specify which evaluators handle their proposals
  - Routing is opaque to callers
  - Evaluator selection is determined by topic, not proposer
  """

  use ExUnit.Case, async: true

  alias Arbor.Consensus.Coordinator
  alias Arbor.Consensus.TestHelpers

  @moduletag :fast

  describe "evaluator selection opacity" do
    setup do
      {_es_pid, _es_name} = TestHelpers.start_test_event_store()
      {_coord_pid, coord_name} = TestHelpers.start_test_coordinator()
      {:ok, coordinator: coord_name}
    end

    test "proposer cannot specify evaluator modules directly", %{coordinator: coord} do
      # Attempt to set evaluator_backend in proposal metadata (should be ignored)
      proposal =
        TestHelpers.build_proposal(%{
          metadata: %{
            evaluator_backend: SomeEvilEvaluator,
            preferred_evaluators: [:friendly_evaluator]
          }
        })

      {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)
      {:ok, _status} = TestHelpers.wait_for_decision(coord, proposal_id)

      {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

      # Decision should exist and use the coordinator's configured evaluator
      assert decision != nil
      assert decision.evaluations != []

      # The evaluations should NOT be from the proposed evaluator
      Enum.each(decision.evaluations, fn eval ->
        refute String.contains?(eval.evaluator_id, "SomeEvil")
        refute String.contains?(eval.evaluator_id, "friendly")
      end)
    end

    test "proposal topic determines evaluator routing, not proposer", %{coordinator: coord} do
      # Two different proposers submitting same topic should get same treatment
      proposal1 =
        TestHelpers.build_proposal(%{
          proposer: "agent_1",
          topic: :code_modification,
          description: "First agent's proposal"
        })

      proposal2 =
        TestHelpers.build_proposal(%{
          proposer: "agent_2",
          topic: :code_modification,
          description: "Second agent's proposal"
        })

      {:ok, id1} = Coordinator.submit(proposal1, server: coord)
      {:ok, id2} = Coordinator.submit(proposal2, server: coord)

      {:ok, _} = TestHelpers.wait_for_decision(coord, id1)
      {:ok, _} = TestHelpers.wait_for_decision(coord, id2)

      {:ok, decision1} = Coordinator.get_decision(id1, coord)
      {:ok, decision2} = Coordinator.get_decision(id2, coord)

      # Both should have evaluations from the same perspectives
      perspectives1 = Enum.map(decision1.evaluations, & &1.perspective) |> Enum.sort()
      perspectives2 = Enum.map(decision2.evaluations, & &1.perspective) |> Enum.sort()

      assert perspectives1 == perspectives2
    end

    test "evaluator_backend opt in submit affects routing but not proposal metadata", %{
      coordinator: coord
    } do
      proposal = TestHelpers.build_proposal()

      # The evaluator_backend option should be used by Coordinator, but not stored
      {:ok, proposal_id} =
        Coordinator.submit(proposal,
          server: coord,
          evaluator_backend: TestHelpers.AlwaysApproveBackend
        )

      {:ok, stored_proposal} = Coordinator.get_proposal(proposal_id, coord)

      # The proposal itself should not have the evaluator_backend stored
      refute Map.has_key?(stored_proposal.metadata, :evaluator_backend)
      refute Map.has_key?(stored_proposal.context, :evaluator_backend)
    end
  end

  describe "trust boundaries" do
    setup do
      {_es_pid, _es_name} = TestHelpers.start_test_event_store()
      {_coord_pid, coord_name} = TestHelpers.start_test_coordinator()
      {:ok, coordinator: coord_name}
    end

    test "proposal cannot influence its own quorum requirement", %{coordinator: coord} do
      # Attempt to set a low quorum in proposal metadata
      proposal =
        TestHelpers.build_proposal(%{
          topic: :governance_change,
          metadata: %{
            quorum: 1,
            required_quorum: 1,
            min_quorum: 1
          }
        })

      {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)
      {:ok, _status} = TestHelpers.wait_for_decision(coord, proposal_id)

      {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

      # Decision should use system quorum, not the proposed one
      # Governance changes require 6/7 quorum
      assert decision.required_quorum >= 5
    end

    test "proposal cannot bypass evaluator independence", %{coordinator: coord} do
      # Attempt to include pre-made evaluations
      fake_eval =
        TestHelpers.build_evaluation(%{
          vote: :approve,
          perspective: :security,
          reasoning: "Pre-approved by proposer"
        })

      proposal =
        TestHelpers.build_proposal(%{
          metadata: %{
            evaluations: [fake_eval],
            pre_approved: true
          }
        })

      {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)
      {:ok, _status} = TestHelpers.wait_for_decision(coord, proposal_id)

      {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

      # The fake evaluation should not be in the decision
      # All evaluations should be freshly generated
      Enum.each(decision.evaluations, fn eval ->
        refute eval.reasoning == "Pre-approved by proposer"
        assert eval.sealed == true
      end)
    end
  end

  describe "agent quota enforcement" do
    setup do
      # Set a low quota for testing
      prev_quota = Application.get_env(:arbor_consensus, :max_proposals_per_agent)
      prev_enabled = Application.get_env(:arbor_consensus, :proposal_quota_enabled)
      Application.put_env(:arbor_consensus, :max_proposals_per_agent, 2)
      Application.put_env(:arbor_consensus, :proposal_quota_enabled, true)

      {_es_pid, _es_name} = TestHelpers.start_test_event_store()

      # Use a slow evaluator so proposals stay pending
      {_coord_pid, coord_name} =
        TestHelpers.start_test_coordinator(evaluator_backend: TestHelpers.SlowBackend)

      on_exit(fn ->
        if prev_quota,
          do: Application.put_env(:arbor_consensus, :max_proposals_per_agent, prev_quota)

        if prev_enabled != nil,
          do: Application.put_env(:arbor_consensus, :proposal_quota_enabled, prev_enabled)
      end)

      {:ok, coordinator: coord_name}
    end

    @tag timeout: 10_000
    test "limits concurrent proposals per agent", %{coordinator: coord} do
      proposer = "quota_test_agent"

      # Submit proposals up to quota
      {:ok, _id1} =
        Coordinator.submit(
          TestHelpers.build_proposal(%{proposer: proposer, description: "First"}),
          server: coord
        )

      {:ok, _id2} =
        Coordinator.submit(
          TestHelpers.build_proposal(%{proposer: proposer, description: "Second"}),
          server: coord
        )

      # Third should fail
      result =
        Coordinator.submit(
          TestHelpers.build_proposal(%{proposer: proposer, description: "Third"}),
          server: coord
        )

      assert result == {:error, :agent_proposal_quota_exceeded}
    end
  end
end
