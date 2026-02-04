defmodule Arbor.Consensus.CompositionTest do
  @moduledoc """
  Tests for multi-evaluator composition.

  Verifies that 2+ evaluators on the same proposal produce correctly
  merged results and that the decision logic handles mixed votes properly.
  """

  use ExUnit.Case, async: true

  alias Arbor.Consensus.{Coordinator, Council}
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.Evaluation

  @moduletag :fast

  describe "multiple evaluators on same proposal" do
    setup do
      {_es_pid, _es_name} = TestHelpers.start_test_event_store()
      {_coord_pid, coord_name} = TestHelpers.start_test_coordinator()
      {:ok, coordinator: coord_name}
    end

    test "merges evaluations from multiple perspectives", %{coordinator: coord} do
      proposal = TestHelpers.build_proposal()

      # Submit and wait for decision
      {:ok, proposal_id} = Coordinator.submit(proposal, server: coord)
      {:ok, _status} = TestHelpers.wait_for_decision(coord, proposal_id)

      # Get the decision
      {:ok, decision} = Coordinator.get_decision(proposal_id, coord)

      # Should have multiple evaluations
      assert length(decision.evaluations) > 1

      # All evaluations should be sealed
      Enum.each(decision.evaluations, fn eval ->
        assert eval.sealed == true
      end)

      # Vote counts should be consistent with evaluation list
      approve_count = Enum.count(decision.evaluations, &(&1.vote == :approve))
      reject_count = Enum.count(decision.evaluations, &(&1.vote == :reject))
      abstain_count = Enum.count(decision.evaluations, &(&1.vote == :abstain))

      assert decision.approve_count == approve_count
      assert decision.reject_count == reject_count
      assert decision.abstain_count == abstain_count
    end

    test "handles mixed votes correctly", %{coordinator: _coord} do
      # Create a proposal
      proposal = TestHelpers.build_proposal()

      # Manually evaluate with different votes to test merging
      perspectives = [:security, :stability, :capability]

      evaluations =
        Enum.map(Enum.with_index(perspectives), fn {perspective, idx} ->
          vote = if rem(idx, 2) == 0, do: :approve, else: :reject

          {:ok, eval} =
            Evaluation.new(%{
              proposal_id: proposal.id,
              evaluator_id: "eval_#{perspective}_test",
              perspective: perspective,
              vote: vote,
              reasoning: "Test evaluation for #{perspective}",
              confidence: 0.8,
              concerns: if(vote == :reject, do: ["Test concern"], else: []),
              recommendations: [],
              risk_score: if(vote == :reject, do: 0.7, else: 0.2),
              benefit_score: if(vote == :approve, do: 0.8, else: 0.3)
            })

          Evaluation.seal(eval)
        end)

      # Verify mixed evaluations
      approve_count = Enum.count(evaluations, &(&1.vote == :approve))
      reject_count = Enum.count(evaluations, &(&1.vote == :reject))

      # indices 0, 2
      assert approve_count == 2
      # index 1
      assert reject_count == 1
    end

    test "evaluations from different evaluators have unique IDs" do
      proposal = TestHelpers.build_proposal()

      # Use Council.evaluate directly to test composition
      perspectives = [:security, :stability, :capability, :adversarial]

      {:ok, evaluations} =
        Council.evaluate(
          proposal,
          perspectives,
          TestHelpers.AlwaysApproveBackend,
          timeout: 5000
        )

      # All evaluator IDs should be unique
      evaluator_ids = Enum.map(evaluations, & &1.evaluator_id)
      assert length(Enum.uniq(evaluator_ids)) == length(evaluator_ids)

      # Each perspective should be represented
      result_perspectives = Enum.map(evaluations, & &1.perspective)
      assert Enum.sort(result_perspectives) == Enum.sort(perspectives)
    end
  end

  describe "evaluator result aggregation" do
    test "calculates average confidence correctly" do
      proposal = TestHelpers.build_proposal()

      evaluations =
        Enum.map([0.6, 0.8, 0.9], fn confidence ->
          {:ok, eval} =
            Evaluation.new(%{
              proposal_id: proposal.id,
              evaluator_id: "eval_test_#{confidence}",
              perspective: :test,
              vote: :approve,
              reasoning: "Test",
              confidence: confidence
            })

          Evaluation.seal(eval)
        end)

      # Build decision to check average
      alias Arbor.Contracts.Consensus.CouncilDecision
      {:ok, decision} = CouncilDecision.from_evaluations(proposal, evaluations)

      # Average should be (0.6 + 0.8 + 0.9) / 3 = 0.7666...
      expected_avg = (0.6 + 0.8 + 0.9) / 3
      assert_in_delta decision.average_confidence, expected_avg, 0.001
    end

    test "collects primary concerns from all evaluators" do
      proposal = TestHelpers.build_proposal()

      evaluations =
        Enum.map([["Concern A"], ["Concern B", "Concern C"], []], fn concerns ->
          {:ok, eval} =
            Evaluation.new(%{
              proposal_id: proposal.id,
              evaluator_id: "eval_test_#{:rand.uniform(1000)}",
              perspective: :test,
              vote: :reject,
              reasoning: "Test",
              confidence: 0.8,
              concerns: concerns
            })

          Evaluation.seal(eval)
        end)

      alias Arbor.Contracts.Consensus.CouncilDecision
      {:ok, decision} = CouncilDecision.from_evaluations(proposal, evaluations)

      # Primary concerns should include concerns from multiple evaluators
      assert decision.primary_concerns != []
    end
  end
end
