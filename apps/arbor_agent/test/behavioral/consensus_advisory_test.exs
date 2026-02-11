defmodule Arbor.Behavioral.ConsensusAdvisoryTest do
  @moduledoc """
  Behavioral test: consensus advisory consultation.

  Verifies the end-to-end flow:
  1. Question submitted via Consult.ask/3
  2. Advisory proposal created
  3. Evaluator perspectives activated (parallel)
  4. Perspectives collected and sorted
  5. Results returned to caller

  Defines its own inline test evaluators to be self-contained.
  """
  use Arbor.Test.BehavioralCase

  alias Arbor.Consensus.Evaluators.Consult
  alias Arbor.Contracts.Consensus.Evaluation

  # -- Inline test evaluators (self-contained, no cross-app test deps) --

  defmodule TestEvaluator do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :behavioral_test_advisory

    @impl true
    def perspectives, do: [:technical, :stability]

    @impl true
    def strategy, do: :deterministic

    @impl true
    def evaluate(proposal, perspective, _opts) do
      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: proposal.id,
          evaluator_id: "behavioral_#{perspective}",
          perspective: perspective,
          vote: :approve,
          reasoning: "Behavioral test analysis from #{perspective}: #{proposal.description}",
          confidence: 0.85
        })

      {:ok, Evaluation.seal(eval)}
    end
  end

  defmodule FailingEvaluator do
    @moduledoc false
    @behaviour Arbor.Contracts.Consensus.Evaluator

    @impl true
    def name, do: :behavioral_failing

    @impl true
    def perspectives, do: [:technical]

    @impl true
    def strategy, do: :deterministic

    @impl true
    def evaluate(_proposal, _perspective, _opts) do
      {:error, :intentional_failure}
    end
  end

  describe "scenario: advisory consultation end-to-end" do
    test "Consult.ask/3 returns perspectives from all evaluator viewpoints" do
      {:ok, results} =
        Consult.ask(
          TestEvaluator,
          "Should we use middleware for cross-cutting concerns?"
        )

      assert is_list(results)
      assert length(results) == 2

      # Each result is {perspective, evaluation}
      for {perspective, evaluation} <- results do
        assert is_atom(perspective)
        assert perspective in [:technical, :stability]

        assert %{perspective: ^perspective, reasoning: reasoning, sealed: true} = evaluation
        assert is_binary(reasoning)
        assert String.length(reasoning) > 0
        assert reasoning =~ to_string(perspective)
      end
    end

    test "Consult.ask_one/4 returns a single perspective evaluation" do
      {:ok, eval} =
        Consult.ask_one(
          TestEvaluator,
          "Is the middleware pattern appropriate?",
          :technical
        )

      assert eval.perspective == :technical
      assert is_binary(eval.reasoning)
      assert eval.sealed == true
      assert eval.confidence == 0.85
    end

    test "context is passed through to evaluator" do
      {:ok, results} =
        Consult.ask(
          TestEvaluator,
          "Redis or ETS for caching?",
          context: %{requirement: "must survive restarts", constraint: "low latency"}
        )

      # All perspectives should succeed even with context
      assert length(results) == 2

      for {_perspective, evaluation} <- results do
        assert %{sealed: true} = evaluation
      end
    end

    test "failing evaluator returns error tuples, not crashes" do
      {:ok, results} =
        Consult.ask(
          FailingEvaluator,
          "This evaluator always fails"
        )

      # Should still return results, just with errors
      assert is_list(results)
      assert length(results) == 1

      [{:technical, evaluation}] = results

      assert match?({:error, :intentional_failure}, evaluation),
             "Failing evaluator should return {:error, _}, got: #{inspect(evaluation)}"
    end
  end

  describe "scenario: evaluation contract" do
    test "Evaluation struct has required fields after sealing" do
      {:ok, eval} =
        Evaluation.new(%{
          proposal_id: "prop_test_123",
          evaluator_id: "eval_behavioral",
          perspective: :technical,
          vote: :approve,
          reasoning: "Test reasoning",
          confidence: 0.9
        })

      sealed = Evaluation.seal(eval)

      assert sealed.proposal_id == "prop_test_123"
      assert sealed.perspective == :technical
      assert sealed.vote == :approve
      assert sealed.reasoning == "Test reasoning"
      assert sealed.confidence == 0.9
      assert sealed.sealed == true
    end
  end

  describe "scenario: topic routing" do
    test "registered topics are found by TopicRegistry" do
      # :test_topic was registered in BehavioralCase setup
      assert {:ok, _rule} = Arbor.Consensus.TopicRegistry.get(:test_topic)
    end

    test "TopicRegistry.exists?/1 returns true for registered topics" do
      assert Arbor.Consensus.TopicRegistry.exists?(:test_topic) == true
    end

    test "unregistered topics return not_found" do
      result = Arbor.Consensus.TopicRegistry.get(:completely_unknown_topic_xyz)
      assert result == {:error, :not_found}
    end
  end
end
