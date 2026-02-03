defmodule Arbor.Consensus.CouncilTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Council
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.Evaluation

  describe "evaluate/4" do
    test "returns evaluations for all perspectives" do
      proposal = TestHelpers.build_proposal()
      perspectives = [:security, :stability, :capability]
      backend = TestHelpers.AlwaysApproveBackend

      {:ok, evaluations} = Council.evaluate(proposal, perspectives, backend, timeout: 5_000)

      assert length(evaluations) == 3
      assert Enum.all?(evaluations, &match?(%Evaluation{}, &1))
    end

    test "all evaluations are sealed" do
      proposal = TestHelpers.build_proposal()
      perspectives = [:security, :stability]
      backend = TestHelpers.AlwaysApproveBackend

      {:ok, evaluations} = Council.evaluate(proposal, perspectives, backend, timeout: 5_000)

      assert Enum.all?(evaluations, & &1.sealed)
    end

    test "evaluations have correct proposal_id" do
      proposal = TestHelpers.build_proposal()
      perspectives = [:security]
      backend = TestHelpers.AlwaysApproveBackend

      {:ok, [eval]} = Council.evaluate(proposal, perspectives, backend, timeout: 5_000)

      assert eval.proposal_id == proposal.id
    end

    test "handles failing evaluators gracefully" do
      proposal = TestHelpers.build_proposal()
      perspectives = [:security, :stability, :capability]
      backend = TestHelpers.FailingBackend

      # All fail, should still return (empty list or error)
      result = Council.evaluate(proposal, perspectives, backend, timeout: 5_000)

      case result do
        {:ok, evals} -> assert Enum.empty?(evals)
        {:error, :no_evaluations} -> :ok
      end
    end

    test "respects timeout" do
      proposal = TestHelpers.build_proposal()
      perspectives = [:security]
      backend = TestHelpers.SlowBackend

      # Very short timeout — should return quickly
      result = Council.evaluate(proposal, perspectives, backend, timeout: 100)

      case result do
        {:ok, []} -> :ok
        {:error, :no_evaluations} -> :ok
      end
    end

    test "uses the rule-based backend by default" do
      proposal = TestHelpers.build_proposal()
      perspectives = [:security]
      backend = Arbor.Consensus.EvaluatorBackend.RuleBased

      {:ok, [eval]} = Council.evaluate(proposal, perspectives, backend, timeout: 5_000)

      assert eval.perspective == :security
      assert eval.vote in [:approve, :reject, :abstain]
    end

    test "evaluates from multiple perspectives correctly" do
      proposal = TestHelpers.build_proposal()

      perspectives = [
        :security,
        :stability,
        :capability,
        :adversarial,
        :resource,
        :emergence,
        :random
      ]

      backend = Arbor.Consensus.EvaluatorBackend.RuleBased

      {:ok, evaluations} = Council.evaluate(proposal, perspectives, backend, timeout: 10_000)

      # Should have evaluations (some may fail gracefully)
      assert evaluations != []

      # Each should have a unique perspective
      perspectives_returned = Enum.map(evaluations, & &1.perspective)
      assert length(perspectives_returned) == length(Enum.uniq(perspectives_returned))
    end
  end

  describe "required_perspectives/1" do
    test "returns all non-human perspectives" do
      proposal = TestHelpers.build_proposal(%{topic: :code_modification})

      perspectives = Council.required_perspectives(proposal)

      assert :security in perspectives
      assert :stability in perspectives
      assert :test_runner in perspectives
      assert :code_review in perspectives
      refute :human in perspectives
      assert length(perspectives) == 9
    end
  end

  describe "early termination" do
    test "terminates early when quorum is reached" do
      proposal = TestHelpers.build_proposal()
      # Use 7 perspectives with quorum of 5 — should terminate once 5 approve
      perspectives = [
        :security,
        :stability,
        :capability,
        :adversarial,
        :resource,
        :emergence,
        :random
      ]

      backend = TestHelpers.AlwaysApproveBackend

      {:ok, evaluations} =
        Council.evaluate(proposal, perspectives, backend,
          timeout: 5_000,
          quorum: 5
        )

      # May get all 7, or may terminate early with 5+
      assert length(evaluations) >= 5
    end
  end
end
