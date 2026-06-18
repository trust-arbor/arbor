defmodule Arbor.Actions.Security.Precision do
  @moduledoc """
  The Security Sentinel's **precision floor** (E1.3 / G3) — pure decision logic,
  no I/O.

  After a synthesized candidate detector is swept over the umbrella (G2,
  `SweepCandidate`) it produces a set of *sibling* findings. The existing
  adversarial verifier (`verify-finding.dot`) then triages each sibling into a
  verdict — `:confirmed` (a real sibling, the payoff) or `:refuted` (a false
  positive the detector should be tightened against).

  This module turns those verdicts into the **admit / reject** decision:

      precision = confirmed / max(1, confirmed + refuted)

  A candidate is admitted to the suite (proposed for human review, never
  auto-merged) only when `precision >= threshold`. A noisier candidate is held
  back — flagged for human authoring instead of admitted — so the Sentinel does
  not ship a detector that cries wolf.

  ## The payoff vs. the noise

  A **confirmed** sibling is the whole point of synthesis: one fix → a detector →
  a real, previously-unreviewed instance of the same class caught. A **refuted**
  sibling is a false positive: the detector's predicate is too broad and matched
  something that does not actually violate the invariant. Refuted siblings are
  the signal that the detector should be *tightened* — and (in E1.4 / G4) each
  becomes a generated FP-regression test that pins the tightening in place. G4 is
  out of scope here; this module only computes whether the candidate is precise
  enough to admit at all.

  ## Threshold resolution

  `opts[:threshold]` wins; otherwise
  `Application.get_env(:arbor_actions, :sentinel_precision_floor, 0.5)`.
  """

  @default_floor 0.5

  @type verdict :: :confirmed | :refuted
  @type assessment :: %{
          precision: float(),
          admit?: boolean(),
          confirmed: non_neg_integer(),
          refuted: non_neg_integer(),
          reason: term()
        }

  @doc """
  Assess a candidate's precision from its swept siblings + their verdicts.

  `siblings` is the list of swept `Finding`s (used to derive the finding ids the
  verdicts key on). `verdicts` is a map `finding_id => :confirmed | :refuted`
  (the adversarial verifier's per-sibling decision). Siblings without a verdict
  are ignored (un-triaged → not yet counted for/against precision).

  Returns `%{precision, admit?, confirmed, refuted, reason}`:

    * `admit?: true`, `reason: :meets_precision_floor` — `precision >= threshold`,
      the candidate is precise enough to propose (human still approves the PR).
    * `admit?: false`, `reason: {:below_precision_floor, precision, threshold}` —
      too noisy; hold back and flag for human authoring instead.
    * `admit?: false`, `reason: :no_triaged_siblings` — nothing was triaged
      (no confirmed and no refuted), so there is no evidence the detector finds
      real siblings. Withheld (fail-closed): an un-evidenced detector is not
      admitted automatically.

  Precision uses `max(1, confirmed + refuted)` as the denominator so an empty
  triage set yields `0.0` rather than a divide-by-zero.
  """
  @spec assess([map()], %{optional(String.t()) => verdict()}, keyword()) :: assessment()
  def assess(siblings, verdicts, opts \\ [])
      when is_list(siblings) and is_map(verdicts) and is_list(opts) do
    threshold = resolve_threshold(opts)

    sibling_ids = MapSet.new(siblings, &finding_id/1)

    relevant =
      verdicts
      |> Enum.filter(fn {id, _v} -> MapSet.member?(sibling_ids, id) end)
      |> Enum.map(fn {_id, v} -> v end)

    confirmed = Enum.count(relevant, &(&1 == :confirmed))
    refuted = Enum.count(relevant, &(&1 == :refuted))
    triaged = confirmed + refuted

    precision = Float.round(confirmed / max(1, triaged), 4)

    {admit?, reason} = decide(precision, threshold, triaged)

    %{
      precision: precision,
      admit?: admit?,
      confirmed: confirmed,
      refuted: refuted,
      reason: reason
    }
  end

  @doc "The resolved precision floor (opts override, else app env, else default)."
  @spec resolve_threshold(keyword()) :: float()
  def resolve_threshold(opts \\ []) do
    case opts[:threshold] do
      t when is_number(t) -> t
      _ -> Application.get_env(:arbor_actions, :sentinel_precision_floor, @default_floor)
    end
  end

  # No sibling was triaged → no evidence the detector finds real siblings.
  # Fail closed: not admitted automatically.
  defp decide(_precision, _threshold, 0), do: {false, :no_triaged_siblings}

  defp decide(precision, threshold, _triaged) when precision >= threshold,
    do: {true, :meets_precision_floor}

  defp decide(precision, threshold, _triaged),
    do: {false, {:below_precision_floor, precision, threshold}}

  # A sibling can be a Finding struct or a plain map (the swept result is a
  # Finding, but keep the core decoupled from the struct so it stays pure +
  # easy to unit-test).
  defp finding_id(%{id: id}), do: id
  defp finding_id(%{"id" => id}), do: id
  defp finding_id(_), do: nil
end
