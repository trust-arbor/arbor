defmodule Arbor.Contracts.Consensus.EvaluationTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.Evaluation

  @valid_attrs %{
    proposal_id: "prop_123",
    evaluator_id: "eval_456",
    perspective: :security,
    vote: :approve,
    reasoning: "Looks safe and well-structured"
  }

  describe "new/1" do
    test "creates evaluation with valid attributes" do
      assert {:ok, %Evaluation{} = e} = Evaluation.new(@valid_attrs)
      assert e.proposal_id == "prop_123"
      assert e.evaluator_id == "eval_456"
      assert e.perspective == :security
      assert e.vote == :approve
      assert e.reasoning == "Looks safe and well-structured"
      assert String.starts_with?(e.id, "eval_")
    end

    test "sets defaults" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      assert e.confidence == 0.5
      assert e.concerns == []
      assert e.recommendations == []
      assert e.risk_score == 0.0
      assert e.benefit_score == 0.0
      assert e.sealed == false
      assert e.seal_hash == nil
      assert %DateTime{} = e.created_at
    end

    test "accepts all optional fields" do
      {:ok, e} =
        Evaluation.new(
          Map.merge(@valid_attrs, %{
            confidence: 0.9,
            concerns: ["perf risk"],
            recommendations: ["add benchmark"],
            risk_score: 0.3,
            benefit_score: 0.8
          })
        )

      assert e.confidence == 0.9
      assert e.concerns == ["perf risk"]
      assert e.recommendations == ["add benchmark"]
      assert e.risk_score == 0.3
      assert e.benefit_score == 0.8
    end

    test "errors on missing required fields" do
      for field <- [:proposal_id, :evaluator_id, :perspective, :vote, :reasoning] do
        attrs = Map.delete(@valid_attrs, field)
        assert {:error, {:missing_required_field, ^field}} = Evaluation.new(attrs)
      end
    end
  end

  describe "seal/1" do
    test "seals an evaluation" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      sealed = Evaluation.seal(e)
      assert sealed.sealed == true
      assert is_binary(sealed.seal_hash)
      assert String.length(sealed.seal_hash) == 64
    end

    test "is idempotent" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      sealed = Evaluation.seal(e)
      sealed_again = Evaluation.seal(sealed)
      assert sealed == sealed_again
    end
  end

  describe "verify_seal/1" do
    test "verifies valid seal" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      sealed = Evaluation.seal(e)
      assert :ok = Evaluation.verify_seal(sealed)
    end

    test "detects tampered evaluation" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      sealed = Evaluation.seal(e)
      tampered = %{sealed | vote: :reject}
      assert {:error, :invalid_seal} = Evaluation.verify_seal(tampered)
    end

    test "errors on unsealed evaluation" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      assert {:error, :not_sealed} = Evaluation.verify_seal(e)
    end
  end

  describe "positive?/1 and negative?/1" do
    test "approve is positive" do
      {:ok, e} = Evaluation.new(@valid_attrs)
      assert Evaluation.positive?(e) == true
      assert Evaluation.negative?(e) == false
    end

    test "reject is negative" do
      {:ok, e} = Evaluation.new(%{@valid_attrs | vote: :reject})
      assert Evaluation.positive?(e) == false
      assert Evaluation.negative?(e) == true
    end

    test "abstain is neither" do
      {:ok, e} = Evaluation.new(%{@valid_attrs | vote: :abstain})
      assert Evaluation.positive?(e) == false
      assert Evaluation.negative?(e) == false
    end
  end

  describe "summary/1" do
    test "returns summary map" do
      {:ok, e} =
        Evaluation.new(
          Map.merge(@valid_attrs, %{
            confidence: 0.8,
            risk_score: 0.2,
            benefit_score: 0.7,
            concerns: ["concern1", "concern2"]
          })
        )

      summary = Evaluation.summary(e)
      assert summary.perspective == :security
      assert summary.vote == :approve
      assert summary.confidence == 0.8
      assert summary.risk == 0.2
      assert summary.benefit == 0.7
      assert summary.concern_count == 2
    end
  end
end
