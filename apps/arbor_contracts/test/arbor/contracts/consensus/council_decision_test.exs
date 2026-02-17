defmodule Arbor.Contracts.Consensus.CouncilDecisionTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.{CouncilDecision, Evaluation, Proposal}

  defp make_proposal(opts \\ %{}) do
    attrs =
      Map.merge(
        %{
          proposer: "agent_1",
          topic: :code_modification,
          description: "Test proposal",
          target_layer: 4
        },
        opts
      )

    {:ok, p} = Proposal.new(attrs)
    p
  end

  defp make_sealed_evaluation(vote, perspective) do
    {:ok, e} =
      Evaluation.new(%{
        proposal_id: "prop_123",
        evaluator_id: "eval_#{perspective}",
        perspective: perspective,
        vote: vote,
        reasoning: "Reasoning for #{vote}",
        confidence: 0.8,
        risk_score: 0.2,
        benefit_score: 0.7,
        concerns: if(vote == :reject, do: ["risk found"], else: [])
      })

    Evaluation.seal(e)
  end

  describe "from_evaluations/3" do
    test "creates approved decision when quorum met" do
      proposal = make_proposal()

      evals =
        for p <- [:security, :stability, :capability, :adversarial, :resource] do
          make_sealed_evaluation(:approve, p)
        end

      assert {:ok, %CouncilDecision{} = d} = CouncilDecision.from_evaluations(proposal, evals)
      assert d.decision == :approved
      assert d.quorum_met == true
      assert d.approve_count == 5
      assert d.reject_count == 0
      assert String.starts_with?(d.id, "decision_")
    end

    test "creates rejected decision when reject quorum met" do
      proposal = make_proposal()

      evals =
        for p <- [:security, :stability, :capability, :adversarial, :resource] do
          make_sealed_evaluation(:reject, p)
        end

      assert {:ok, %CouncilDecision{} = d} = CouncilDecision.from_evaluations(proposal, evals)
      assert d.decision == :rejected
      assert d.reject_count == 5
    end

    test "creates deadlock when no quorum" do
      proposal = make_proposal()

      evals = [
        make_sealed_evaluation(:approve, :security),
        make_sealed_evaluation(:approve, :stability),
        make_sealed_evaluation(:reject, :capability),
        make_sealed_evaluation(:reject, :adversarial),
        make_sealed_evaluation(:abstain, :resource)
      ]

      assert {:ok, %CouncilDecision{} = d} = CouncilDecision.from_evaluations(proposal, evals)
      assert d.decision == :deadlock
      assert d.approve_count == 2
      assert d.reject_count == 2
      assert d.abstain_count == 1
    end

    test "rejects unsealed evaluations" do
      proposal = make_proposal()
      {:ok, unsealed} = Evaluation.new(%{
        proposal_id: "prop_123",
        evaluator_id: "eval_1",
        perspective: :security,
        vote: :approve,
        reasoning: "good"
      })

      assert {:error, {:unsealed_evaluations, _}} =
               CouncilDecision.from_evaluations(proposal, [unsealed])
    end

    test "computes averages correctly" do
      proposal = make_proposal()
      evals = [make_sealed_evaluation(:approve, :security)]

      {:ok, d} = CouncilDecision.from_evaluations(proposal, evals, quorum: 1)
      assert d.average_confidence == 0.8
      assert d.average_risk == 0.2
      assert d.average_benefit == 0.7
    end

    test "aggregates concerns" do
      proposal = make_proposal()

      evals = [
        make_sealed_evaluation(:reject, :security),
        make_sealed_evaluation(:reject, :stability)
      ]

      {:ok, d} = CouncilDecision.from_evaluations(proposal, evals, quorum: 1)
      # Both reject evals have "risk found" concern
      assert is_list(d.primary_concerns)
    end

    test "handles empty evaluations" do
      proposal = make_proposal()
      # Empty list of evals -> all sealed (vacuously)
      {:ok, d} = CouncilDecision.from_evaluations(proposal, [])
      assert d.decision == :deadlock
      assert d.approve_count == 0
    end

    test "respects advisory mode" do
      proposal = make_proposal(%{mode: :advisory})
      evals = [make_sealed_evaluation(:approve, :security)]

      {:ok, d} = CouncilDecision.from_evaluations(proposal, evals)
      assert d.mode == :advisory
    end

    test "allows quorum override via opts" do
      proposal = make_proposal()
      evals = [make_sealed_evaluation(:approve, :security)]

      {:ok, d} = CouncilDecision.from_evaluations(proposal, evals, quorum: 1)
      assert d.decision == :approved
      assert d.required_quorum == 1
    end
  end

  describe "query functions" do
    setup do
      proposal = make_proposal()

      evals = [
        make_sealed_evaluation(:approve, :security),
        make_sealed_evaluation(:reject, :stability),
        make_sealed_evaluation(:approve, :capability)
      ]

      {:ok, d} = CouncilDecision.from_evaluations(proposal, evals, quorum: 2)
      %{decision: d}
    end

    test "final?/1", %{decision: d} do
      assert CouncilDecision.final?(d) == true
    end

    test "final?/1 false for deadlock" do
      proposal = make_proposal()
      evals = [make_sealed_evaluation(:abstain, :security)]
      {:ok, d} = CouncilDecision.from_evaluations(proposal, evals, quorum: 5)
      assert CouncilDecision.final?(d) == false
    end

    test "approved?/1", %{decision: d} do
      assert CouncilDecision.approved?(d) == true
    end

    test "advisory?/1 false for decision mode", %{decision: d} do
      assert CouncilDecision.advisory?(d) == false
    end

    test "summary/1", %{decision: d} do
      s = CouncilDecision.summary(d)
      assert s.decision == :approved
      assert s.votes.approve == 2
      assert s.votes.reject == 1
      assert is_float(s.confidence)
    end

    test "evaluations_by_vote/2", %{decision: d} do
      approvals = CouncilDecision.evaluations_by_vote(d, :approve)
      assert length(approvals) == 2
    end

    test "evaluations_by_perspective/2", %{decision: d} do
      sec = CouncilDecision.evaluations_by_perspective(d, :security)
      assert length(sec) == 1
    end
  end
end
