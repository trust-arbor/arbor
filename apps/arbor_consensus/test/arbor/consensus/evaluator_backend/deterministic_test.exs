defmodule Arbor.Consensus.EvaluatorBackend.DeterministicTest do
  use ExUnit.Case, async: false

  alias Arbor.Consensus.Config
  alias Arbor.Consensus.EvaluatorBackend.Deterministic
  alias Arbor.Contracts.Consensus.Evaluation
  alias Arbor.Contracts.Consensus.Proposal

  # Use the arbor project itself for testing (6 levels up from test file)
  # apps/arbor_consensus/test/arbor/consensus/evaluator_backend/ → arbor/
  @project_path Path.expand("../../../../../..", __DIR__)

  setup do
    # Create a minimal proposal for testing
    {:ok, proposal} =
      Proposal.new(%{
        proposer: "test_agent",
        change_type: :code_modification,
        description: "Test proposal for deterministic evaluation",
        metadata: %{
          project_path: @project_path
        }
      })

    {:ok, proposal: proposal}
  end

  describe "supported_perspectives/0" do
    test "returns all supported perspectives" do
      perspectives = Deterministic.supported_perspectives()

      assert :mix_test in perspectives
      assert :mix_credo in perspectives
      assert :mix_compile in perspectives
      assert :mix_format_check in perspectives
      assert :mix_dialyzer in perspectives
    end
  end

  describe "evaluate/3 with :mix_compile" do
    @tag :slow
    test "approves when compilation succeeds", %{proposal: proposal} do
      # mix compile should pass on our project
      # Use :basic sandbox to allow mix subprocesses
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile, timeout: 60_000, sandbox: :basic)

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_compile
      assert evaluation.sealed == true
      assert evaluation.vote == :approve
      assert evaluation.confidence > 0.5
      assert String.contains?(evaluation.reasoning, "passed")
    end
  end

  describe "evaluate/3 with :mix_format_check" do
    @tag :slow
    test "returns evaluation for format check", %{proposal: proposal} do
      # This may pass or fail depending on current formatting state
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_format_check, timeout: 60_000, sandbox: :basic)

      assert %Evaluation{} = evaluation
      assert evaluation.perspective == :mix_format_check
      assert evaluation.sealed == true
      assert evaluation.vote in [:approve, :reject]
    end
  end

  describe "evaluate/3 without project_path" do
    test "abstains when project_path is missing" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Proposal without project path",
          metadata: %{}
        })

      {:ok, evaluation} = Deterministic.evaluate(proposal, :mix_test)

      assert evaluation.vote == :abstain
      assert String.contains?(evaluation.reasoning, "no project_path")
      assert "Missing project_path in proposal metadata" in evaluation.concerns
    end
  end

  describe "evaluate/3 with unsupported perspective" do
    test "abstains for unsupported perspective", %{proposal: proposal} do
      {:ok, evaluation} = Deterministic.evaluate(proposal, :unknown_perspective)

      assert evaluation.vote == :abstain
      assert String.contains?(evaluation.reasoning, "Unsupported perspective")
      assert evaluation.confidence == 0.0
    end
  end

  describe "evaluate/3 with invalid project path" do
    test "rejects when project path doesn't exist" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Proposal with bad path",
          metadata: %{
            project_path: "/nonexistent/path/to/project"
          }
        })

      {:ok, evaluation} = Deterministic.evaluate(proposal, :mix_compile, timeout: 5_000)

      # Should fail because the path doesn't exist
      assert evaluation.vote == :reject
    end
  end

  describe "evaluate/3 with custom options" do
    test "respects custom evaluator_id", %{proposal: proposal} do
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          evaluator_id: "custom_eval_123",
          timeout: 30_000
        )

      assert evaluation.evaluator_id == "custom_eval_123"
    end

    test "respects project_path from options over metadata" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "test_agent",
          change_type: :code_modification,
          description: "Proposal with metadata path",
          metadata: %{
            project_path: "/bad/path"
          }
        })

      # Override with valid path
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile,
          project_path: @project_path,
          timeout: 60_000,
          sandbox: :basic
        )

      # Should succeed because we used the good path from options
      assert evaluation.vote == :approve
    end
  end

  describe "evaluation result structure" do
    @tag :slow
    test "produces sealed evaluation with all required fields", %{proposal: proposal} do
      {:ok, evaluation} =
        Deterministic.evaluate(proposal, :mix_compile, timeout: 60_000, sandbox: :basic)

      # Check all required Evaluation fields
      assert is_binary(evaluation.id)
      assert evaluation.proposal_id == proposal.id
      assert is_binary(evaluation.evaluator_id)
      assert evaluation.perspective == :mix_compile
      assert evaluation.vote in [:approve, :reject, :abstain]
      assert is_binary(evaluation.reasoning)
      assert is_float(evaluation.confidence)
      assert is_list(evaluation.concerns)
      assert is_list(evaluation.recommendations)
      assert is_float(evaluation.risk_score)
      assert is_float(evaluation.benefit_score)
      assert evaluation.sealed == true
      assert is_binary(evaluation.seal_hash)
    end
  end

  describe "config integration" do
    test "uses config for default timeout" do
      # Default should be 60_000
      assert Config.deterministic_evaluator_timeout() == 60_000
    end

    test "uses config for default sandbox" do
      # Default should be :strict
      assert Config.deterministic_evaluator_sandbox() == :strict
    end

    test "uses config for default cwd" do
      # Default should be nil
      assert Config.deterministic_evaluator_default_cwd() == nil
    end
  end
end
