defmodule Arbor.Actions.Security.VerifierTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Security.Verifier
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

  describe "aggregate_verdict/1" do
    test "all skeptics confirm → :confirmed, confidence 1.0" do
      v =
        Verifier.aggregate_verdict([
          "VERDICT: CONFIRMED",
          "VERDICT: CONFIRMED",
          "VERDICT: CONFIRMED"
        ])

      assert v.verdict == :confirmed
      assert v.confidence == 1.0
      assert v.refuted == 0
    end

    test "majority refute → :refuted with dissent reasons" do
      v =
        Verifier.aggregate_verdict([
          "VERDICT: REFUTED - the field is intentionally excluded",
          "VERDICT: REFUTED - mix.lock pins it",
          "VERDICT: CONFIRMED"
        ])

      assert v.verdict == :refuted
      assert v.refuted == 2
      assert v.total == 3
      assert v.confidence == 0.33
      assert length(v.dissent) == 2
      assert Enum.any?(v.dissent, &(&1 =~ "intentionally excluded"))
    end

    test "ambiguous output (no VERDICT line) counts as refuted" do
      v = Verifier.aggregate_verdict(["I'm not sure about this one.", "VERDICT: CONFIRMED"])
      assert v.refuted == 1
      assert v.verdict == :confirmed
    end

    test "empty skeptic set → confidence 0.0" do
      assert %{total: 0, confidence: +0.0} = Verifier.aggregate_verdict([])
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
      assert updated.confidence.score == v.confidence
      assert updated.confidence.rationale =~ "skeptics refuted"
      assert updated.metadata.verification == v
    end
  end
end
