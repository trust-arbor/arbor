defmodule Arbor.Consensus.Evaluators.ConsultTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Evaluators.Consult
  alias Arbor.Consensus.TestHelpers.{FailingAdvisoryEvaluator, TestAdvisoryEvaluator}

  @moduletag :fast

  describe "ask/3" do
    test "consults all perspectives and returns sorted results" do
      {:ok, results} = Consult.ask(TestAdvisoryEvaluator, "How should we design the router?")

      assert length(results) == 2

      # Sorted by perspective
      [{p1, eval1}, {p2, eval2}] = results
      assert p1 == :brainstorming
      assert p2 == :design_review

      assert eval1.perspective == :brainstorming
      assert eval1.reasoning =~ "brainstorming"
      assert eval1.reasoning =~ "How should we design the router?"

      assert eval2.perspective == :design_review
      assert eval2.reasoning =~ "design_review"
    end

    test "passes context to the proposal" do
      {:ok, results} =
        Consult.ask(TestAdvisoryEvaluator, "ETS or Redis?",
          context: %{requirement: "persistence"}
        )

      assert length(results) == 2
      # All evaluations succeed (test evaluator ignores context but proposal has it)
      Enum.each(results, fn {_perspective, eval} ->
        assert eval.sealed == true
      end)
    end

    test "handles evaluator errors in results" do
      {:ok, results} = Consult.ask(FailingAdvisoryEvaluator, "This will fail")

      assert [{:brainstorming, {:error, :intentional_failure}}] = results
    end
  end

  describe "ask_one/4" do
    test "consults a single perspective" do
      {:ok, eval} =
        Consult.ask_one(TestAdvisoryEvaluator, "What about the API design?", :design_review)

      assert eval.perspective == :design_review
      assert eval.reasoning =~ "design_review"
      assert eval.reasoning =~ "What about the API design?"
      assert eval.sealed == true
    end

    test "passes context through" do
      {:ok, eval} =
        Consult.ask_one(
          TestAdvisoryEvaluator,
          "Should we cache?",
          :brainstorming,
          context: %{current: "no caching"}
        )

      assert eval.perspective == :brainstorming
    end

    test "returns error from failing evaluator" do
      assert {:error, :intentional_failure} =
               Consult.ask_one(FailingAdvisoryEvaluator, "Will fail", :brainstorming)
    end
  end
end
