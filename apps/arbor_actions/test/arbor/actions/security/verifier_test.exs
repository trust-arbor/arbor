defmodule Arbor.Actions.Security.VerifierTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.Verifier
  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Contracts.Security.Finding

  defp finding(opts) do
    Finding.new(Keyword.merge([category: :other, title: "t"], opts))
  end

  describe "needs_verification?/1 (selective gate)" do
    test "skips a high-confidence deterministic L0 finding" do
      f = finding(detector: %{layer: "L0"}, confidence: %{score: 0.85})
      refute Verifier.needs_verification?(f)
    end

    test "verifies a low-confidence finding" do
      f = finding(detector: %{layer: "L0b"}, confidence: %{score: 0.6})
      assert Verifier.needs_verification?(f)
    end

    test "always verifies LLM-discovered (L1/L2) findings" do
      assert Verifier.needs_verification?(
               finding(detector: %{layer: "L1"}, confidence: %{score: 0.95})
             )

      assert Verifier.needs_verification?(
               finding(detector: %{layer: "L2"}, confidence: %{score: 0.99})
             )
    end
  end

  describe "aggregate_verdict/1 → Judge.Verdict" do
    test "all skeptics confirm → :keep, overall_score 1.0" do
      v =
        Verifier.aggregate_verdict([
          "VERDICT: CONFIRMED",
          "VERDICT: CONFIRMED",
          "VERDICT: CONFIRMED"
        ])

      assert %Verdict{} = v
      assert v.recommendation == :keep
      assert v.mode == :verification
      assert v.overall_score == 1.0
      assert v.meta.decision == :confirmed
      assert v.meta.refuted == 0
      assert Verdict.passed?(v)
    end

    test "majority refute → :reject with dissent in meta" do
      v =
        Verifier.aggregate_verdict([
          "VERDICT: REFUTED - the field is intentionally excluded",
          "VERDICT: REFUTED - mix.lock pins it",
          "VERDICT: CONFIRMED"
        ])

      assert v.recommendation == :reject
      assert v.meta.decision == :refuted
      assert v.meta.refuted == 2
      assert v.meta.total == 3
      assert v.overall_score == 0.33
      assert length(v.meta.dissent) == 2
      assert Enum.any?(v.meta.dissent, &(&1 =~ "intentionally excluded"))
      refute Verdict.passed?(v)
    end

    test "ambiguous output (no VERDICT line) counts as refuted" do
      v = Verifier.aggregate_verdict(["I'm not sure about this one.", "VERDICT: CONFIRMED"])
      assert v.meta.refuted == 1
      assert v.meta.decision == :confirmed
    end

    test "empty skeptic set → overall_score 0.0" do
      v = Verifier.aggregate_verdict([])
      assert v.meta.total == 0
      assert v.overall_score == +0.0
    end
  end

  describe "apply_verdict/2 (advisory)" do
    test "annotates confidence + metadata but leaves status untouched" do
      f = finding(detector: %{layer: "L0b"}, confidence: %{score: 0.7})

      v =
        Verifier.aggregate_verdict([
          "VERDICT: REFUTED - false alarm",
          "VERDICT: REFUTED",
          "VERDICT: CONFIRMED"
        ])

      updated = Verifier.apply_verdict(f, v)

      assert updated.status == f.status
      assert updated.confidence.score == v.overall_score
      assert updated.confidence.rationale =~ "skeptics refuted"
      assert updated.metadata.verification == v
    end
  end

  describe "to_annotation/1" do
    test "flattens the verdict to the store annotation map" do
      v =
        Verifier.aggregate_verdict([
          "VERDICT: REFUTED - x",
          "VERDICT: CONFIRMED",
          "VERDICT: CONFIRMED"
        ])

      a = Verifier.to_annotation(v)
      assert a.verdict == :confirmed
      assert a.refuted == 1
      assert a.total == 3
      assert a.confidence == v.overall_score
    end
  end
end
