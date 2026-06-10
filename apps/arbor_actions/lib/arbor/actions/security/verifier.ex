defmodule Arbor.Actions.Security.Verifier do
  @moduledoc """
  Pure logic for the Security Sentinel's adversarial **verify-finding** stage.

  Before a finding is acted on, N independent LLM skeptics each try to *refute*
  it (the adversarial-refutation pattern: default to "refuted" when uncertain, so
  only findings that survive scrutiny are confirmed). This module is the
  deterministic brain around those LLM calls:

    * `needs_verification?/1` — selective gate. High-precision deterministic L0
      findings (confidence ≥ threshold) skip verification; low-confidence and
      LLM-discovered (L1/L2) findings get verified. Keeps LLM cost proportional.
    * `aggregate_verdict/1` — turns the skeptics' raw outputs into a verdict
      (majority-refute ⇒ `:refuted`), with a confidence = fraction confirming.
    * `apply_verdict/2` — **advisory**: annotates the finding with the verdict,
      reasoning, and an adjusted confidence. Does NOT change status — a human (or
      the future auto-action gate) decides. Auto-suppression is a later phase.

  The LLM skepticism itself lives in `verify-finding.dot` (compute nodes); this
  module is invoked by the `AggregateVerdict` action that the pipeline ends with.
  """

  alias Arbor.Contracts.Security.Finding

  @verify_below_confidence 0.7
  @always_verify_layers ["L1", "L2"]

  @type verdict :: %{
          verdict: :confirmed | :refuted,
          refuted: non_neg_integer(),
          total: non_neg_integer(),
          confidence: float(),
          dissent: [String.t()]
        }

  @doc "Whether a finding should go through adversarial verification."
  @spec needs_verification?(Finding.t()) :: boolean()
  def needs_verification?(%Finding{} = finding) do
    layer = finding.detector[:layer] || finding.detector["layer"]
    score = get_in_either(finding.confidence, :score) || 0.5

    layer in @always_verify_layers or score < @verify_below_confidence
  end

  @doc """
  Aggregates skeptic outputs (raw LLM texts) into a verdict. Each skeptic is
  asked to end with `VERDICT: REFUTED` or `VERDICT: CONFIRMED`; an ambiguous
  output counts as a refutation (conservative — the finding must earn "confirmed").
  """
  @spec aggregate_verdict([String.t()]) :: verdict()
  def aggregate_verdict(skeptic_outputs) when is_list(skeptic_outputs) do
    parsed = Enum.map(skeptic_outputs, &parse_skeptic/1)
    total = length(parsed)
    refuted = Enum.count(parsed, fn {r, _reason} -> r end)

    verdict = if total > 0 and refuted * 2 > total, do: :refuted, else: :confirmed
    confidence = if total == 0, do: 0.0, else: Float.round((total - refuted) / total, 2)

    dissent =
      parsed
      |> Enum.filter(fn {r, _} -> r end)
      |> Enum.map(fn {_, reason} -> reason end)
      |> Enum.reject(&(&1 == ""))

    %{verdict: verdict, refuted: refuted, total: total, confidence: confidence, dissent: dissent}
  end

  @doc """
  Advisory application: records the verdict on the finding (confidence adjusted to
  the skeptics' confirm-fraction, verdict + dissent stored in metadata). Status is
  left untouched.
  """
  @spec apply_verdict(Finding.t(), verdict()) :: Finding.t()
  def apply_verdict(%Finding{} = finding, %{} = verdict) do
    rationale =
      "adversarial verify: #{verdict.refuted}/#{verdict.total} skeptics refuted (#{verdict.verdict})"

    %{
      finding
      | confidence: %{score: verdict.confidence, rationale: rationale},
        metadata: Map.put(finding.metadata, :verification, verdict)
    }
  end

  # ---------------------------------------------------------------------------

  defp parse_skeptic(text) when is_binary(text) do
    cond do
      Regex.match?(~r/VERDICT:\s*REFUTED/i, text) -> {true, reason(text)}
      Regex.match?(~r/VERDICT:\s*CONFIRMED/i, text) -> {false, ""}
      # No clear verdict — be skeptical: count as refuted, flag the ambiguity.
      true -> {true, "ambiguous skeptic output (no VERDICT line) — counted as refuted"}
    end
  end

  defp parse_skeptic(_), do: {true, "non-text skeptic output — counted as refuted"}

  # Grab a short reason after the verdict line, if present.
  defp reason(text) do
    case Regex.run(~r/VERDICT:\s*REFUTED\s*[-:–]?\s*(.+)/i, text) do
      [_, rest] -> rest |> String.split("\n") |> List.first() |> String.slice(0, 200)
      _ -> ""
    end
  end

  defp get_in_either(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_in_either(_, _), do: nil
end
