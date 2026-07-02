defmodule Arbor.Contracts.Eval.OutcomeTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Eval.Outcome

  describe "new/1" do
    test "builds a valid outcome" do
      assert {:ok, o} = Outcome.new(%{evaluator: "x", score: 0.8, passed: true})
      assert o.confidence == 1.0
      assert o.concerns == []
      assert o.metadata == %{}
    end

    test "rejects out-of-range score" do
      assert {:error, {:out_of_range, :score, 1.5}} =
               Outcome.new(%{evaluator: "x", score: 1.5, passed: true})
    end

    test "rejects an invalid vote" do
      assert {:error, {:invalid_vote, :maybe}} =
               Outcome.new(%{evaluator: "x", score: 0.5, passed: false, vote: :maybe})
    end
  end

  describe "mappers" do
    test "from_grader_result maps score/passed/detail" do
      o = Outcome.from_grader_result(%{score: 1.0, passed: true, detail: "matched"}, "exact_match")
      assert o.evaluator == "exact_match"
      assert o.score == 1.0
      assert o.passed
      assert o.reasoning == "matched"
      assert o.confidence == 1.0
    end

    test "from_check_result: a failing check surfaces its detail as a concern" do
      check = %{check: {:credential_exposure}, passed: false, detail: "leaked sk_live_", severity: :hard}
      o = Outcome.from_check_result(check, "credential_exposure")
      refute o.passed
      assert o.score == 0.0
      assert o.concerns == ["leaked sk_live_"]
      assert o.metadata.severity == :hard
    end

    test "from_evaluation derives score from the vote" do
      o = Outcome.from_evaluation(%{perspective: :security, vote: :reject, reasoning: "unsafe", confidence: 0.9})
      assert o.evaluator == "security"
      assert o.vote == :reject
      assert o.score == 0.0
      refute o.passed
      assert o.confidence == 0.9
    end
  end

  describe "passed?/1" do
    test "false when vote is :reject even if passed flag is true" do
      {:ok, o} = Outcome.new(%{evaluator: "x", score: 1.0, passed: true, vote: :reject})
      refute Outcome.passed?(o)
    end

    test "true for a passed deterministic check" do
      {:ok, o} = Outcome.new(%{evaluator: "x", score: 1.0, passed: true})
      assert Outcome.passed?(o)
    end
  end
end
