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
    * `aggregate_verdict/1` — turns the skeptics' raw outputs into a
      `Arbor.Contracts.Judge.Verdict` (majority-refute ⇒ `recommendation: :reject`),
      with `overall_score` = the fraction of skeptics that confirmed. Adopting the
      shared Judge verdict contract keeps security verdicts uniform with the rest
      of the judge/council infrastructure (see the consolidate-llm-opinion-systems
      roadmap item) — security-specific bits live in `meta`.
    * `apply_verdict/2` — **advisory**: annotates the finding with the verdict +
      adjusted confidence. Does NOT change status — a human (or the future
      auto-action gate) decides. Auto-suppression is a later phase.

  The LLM skepticism itself lives in `verify-finding.dot` (compute nodes); this
  module is invoked by the `AggregateVerdict` action that the pipeline ends with.
  """

  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Contracts.Security.Finding

  @verify_below_confidence 0.7
  @always_verify_layers ["L1", "L2"]

  @doc "Whether a finding should go through adversarial verification."
  @spec needs_verification?(Finding.t()) :: boolean()
  def needs_verification?(%Finding{} = finding) do
    layer = finding.detector[:layer] || finding.detector["layer"]
    score = get_in_either(finding.confidence, :score) || 0.5

    layer in @always_verify_layers or score < @verify_below_confidence
  end

  @doc """
  Aggregates skeptic outputs (raw LLM texts) into a `Judge.Verdict`. Each skeptic
  is asked to end with `VERDICT: REFUTED` or `VERDICT: CONFIRMED`; an ambiguous
  output counts as a refutation (conservative — the finding must earn "confirmed").

  Mapping: `overall_score` = confirm-fraction; `recommendation` = `:reject` when
  the majority refute (the finding doesn't survive), else `:keep`; `mode` =
  `:verification`. `meta` carries `decision` (:confirmed | :refuted),
  `refuted`/`total` counts, and the `dissent` reasons.
  """
  @spec aggregate_verdict([String.t()]) :: Verdict.t()
  def aggregate_verdict(skeptic_outputs) when is_list(skeptic_outputs) do
    parsed = Enum.map(skeptic_outputs, &parse_skeptic/1)
    total = length(parsed)
    refuted = Enum.count(parsed, fn {r, _reason} -> r end)

    decision = if total > 0 and refuted * 2 > total, do: :refuted, else: :confirmed
    score = if total == 0, do: 0.0, else: Float.round((total - refuted) / total, 2)

    dissent =
      parsed
      |> Enum.filter(fn {r, _} -> r end)
      |> Enum.map(fn {_, reason} -> reason end)
      |> Enum.reject(&(&1 == ""))

    {:ok, verdict} =
      Verdict.new(%{
        overall_score: score,
        recommendation: if(decision == :refuted, do: :reject, else: :keep),
        mode: :verification,
        meta: %{
          source: "security.verify_finding",
          decision: decision,
          refuted: refuted,
          total: total,
          dissent: dissent
        }
      })

    verdict
  end

  @doc """
  Advisory application: records the verdict on the finding (confidence adjusted to
  the skeptics' confirm-fraction, the verdict stored in metadata). Status is left
  untouched.
  """
  @spec apply_verdict(Finding.t(), Verdict.t()) :: Finding.t()
  def apply_verdict(%Finding{} = finding, %Verdict{meta: m} = verdict) do
    rationale = "adversarial verify: #{m.refuted}/#{m.total} skeptics refuted (#{m.decision})"

    %{
      finding
      | confidence: %{score: verdict.overall_score, rationale: rationale},
        metadata: Map.put(finding.metadata, :verification, verdict)
    }
  end

  @doc """
  Flattens a verdict to the plain map the file-backed `FindingStore` annotation
  expects (keeps the store decoupled from the Judge contract).
  """
  @spec to_annotation(Verdict.t()) :: map()
  def to_annotation(%Verdict{meta: m} = verdict) do
    %{
      verdict: m.decision,
      refuted: m.refuted,
      total: m.total,
      confidence: verdict.overall_score,
      dissent: m.dissent
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
