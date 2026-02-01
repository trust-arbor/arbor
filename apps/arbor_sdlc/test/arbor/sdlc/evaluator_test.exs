defmodule Arbor.SDLC.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Consensus.Proposal
  alias Arbor.SDLC.Evaluator

  @moduletag :fast

  describe "supported_perspectives/0" do
    test "returns list of 7 SDLC perspectives" do
      perspectives = Evaluator.supported_perspectives()

      assert length(perspectives) == 7
      assert :scope in perspectives
      assert :feasibility in perspectives
      assert :priority in perspectives
      assert :architecture in perspectives
      assert :consistency in perspectives
      assert :adversarial in perspectives
      assert :random in perspectives
    end
  end

  describe "evaluate/3 with unsupported perspective" do
    test "returns abstain for unsupported perspective" do
      {:ok, proposal} = create_test_proposal()

      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} =
        Evaluator.evaluate(proposal, :unknown_perspective, ai_module: mock_ai)

      assert evaluation.vote == :abstain
      assert evaluation.reasoning =~ "Unsupported SDLC perspective"
    end
  end

  describe "evaluate/3 with mock AI" do
    setup do
      {:ok, proposal} = create_test_proposal()
      %{proposal: proposal}
    end

    test "evaluates scope perspective", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :scope, ai_module: mock_ai)

      assert evaluation.vote in [:approve, :reject, :abstain]
      assert is_binary(evaluation.reasoning)
      assert evaluation.perspective == :scope
      assert evaluation.proposal_id == proposal.id
      assert evaluation.sealed == true
    end

    test "evaluates feasibility perspective", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :feasibility, ai_module: mock_ai)

      assert evaluation.perspective == :feasibility
      assert evaluation.sealed == true
    end

    test "evaluates priority perspective", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :priority, ai_module: mock_ai)

      assert evaluation.perspective == :priority
    end

    test "evaluates architecture perspective", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :architecture, ai_module: mock_ai)

      assert evaluation.perspective == :architecture
    end

    test "evaluates consistency perspective", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :consistency, ai_module: mock_ai)

      assert evaluation.perspective == :consistency
    end

    test "evaluates adversarial perspective", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_reject_with_concerns()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :adversarial, ai_module: mock_ai)

      assert evaluation.perspective == :adversarial
      assert evaluation.vote == :reject
      assert evaluation.concerns != []
    end

    test "evaluates random perspective with higher temperature", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :random, ai_module: mock_ai)

      assert evaluation.perspective == :random
    end

    test "handles AI failure by abstaining", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.failure(:connection_error)

      {:ok, evaluation} = Evaluator.evaluate(proposal, :scope, ai_module: mock_ai)

      assert evaluation.vote == :abstain
      assert evaluation.reasoning =~ "LLM error"
    end

    test "handles AI timeout by abstaining", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.timeout()

      # Use a very short timeout
      {:ok, evaluation} = Evaluator.evaluate(proposal, :scope, ai_module: mock_ai, timeout: 10)

      assert evaluation.vote == :abstain
      assert evaluation.reasoning =~ "timeout"
    end
  end

  describe "evaluate/3 response parsing" do
    setup do
      {:ok, proposal} = create_test_proposal()
      %{proposal: proposal}
    end

    test "parses approve vote", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :scope, ai_module: mock_ai)

      assert evaluation.vote == :approve
    end

    test "parses reject vote with concerns", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.standard_reject_with_concerns()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :scope, ai_module: mock_ai)

      assert evaluation.vote == :reject
      assert evaluation.concerns != []
    end

    test "falls back to text detection for malformed JSON", %{proposal: proposal} do
      mock_ai = EvaluatorMockAI.malformed_json_approve()

      {:ok, evaluation} = Evaluator.evaluate(proposal, :scope, ai_module: mock_ai)

      # Should detect "approve" from text
      assert evaluation.vote == :approve
    end
  end

  # Helper to create a test proposal
  defp create_test_proposal do
    Proposal.new(%{
      proposer: "test_deliberator",
      change_type: :sdlc_decision,
      description: "Test SDLC decision for feature implementation",
      target_layer: 4,
      metadata: %{
        item: %{
          title: "Implement user authentication",
          summary: "Add login/logout functionality to the application",
          priority: :high,
          category: :feature,
          acceptance_criteria: [
            %{text: "Users can log in with email/password", completed: false},
            %{text: "Users can log out", completed: false}
          ]
        }
      }
    })
  end
end
