defmodule Arbor.Actions.Security.DetectorSynthesisLoop do
  @moduledoc """
  In-process orchestration of the Security Sentinel's detector-synthesis loop —
  the **E1.4** assembly stage. Chains the E1.1–E1.3 stages into a single,
  human-reviewable `DetectorProposal` (DATA only — **no repo writes, no git**).

  ## The chain

      SynthesizeDetector.run  →  candidate (G1-validated module source + spec)
        │
        ▼
      SweepCandidate.run      →  siblings (umbrella-wide hits, seed excluded)
        │
        ▼
      Precision.assess        →  admit? / precision  (G3 floor)
        │  admit?
        ▼
      split siblings into confirmed / refuted by `verdicts`
        │
        ▼
      DetectorTestTemplate.generate  →  G4 FP-regression test source
        │
        ▼
      assemble %DetectorProposal{}    (target_path, registration_edits — DATA)

  If the candidate does not meet the precision floor (or nothing was triaged),
  NO proposal is produced — the loop returns `{:flagged, reason}` so the finding
  is held back for human authoring instead.

  ## `verdicts` is a parameter (testability)

  `verdicts` is a map `finding_id => :confirmed | :refuted` — the adversarial
  verifier's per-sibling decision. It is passed in as a PARAMETER so the loop is
  unit-testable without the LLM/verifier in the loop. **In production it is
  supplied by the verify-pending adversarial triage** (`verify-finding.dot` →
  `AggregateVerdict`, the only point a finding is confirmed-real): each swept
  sibling is fanned out through that pipeline and its `verdict.meta.decision`
  becomes the map value here.

  ## Output

    * `{:ok, %DetectorProposal{}}` — admitted; a full reviewable proposal as data
    * `{:flagged, reason}` — held back (e.g. `{:below_precision_floor, p, t}` or
      `:no_triaged_siblings`); propose nothing
    * `{:error, reason}` — a stage failed (synthesis/G1, sweep, or assembly)

  ## Side-effect freedom

  The loop drives `SweepCandidate` with `record: false` (no `FindingStore`
  writes, no signals) and assembles the proposal in memory. It writes no files
  and performs no git operations — materialization is deferred and human-gated.
  """

  alias Arbor.Actions.Security.{
    DetectorProposal,
    DetectorSpec,
    DetectorTestTemplate,
    Precision,
    SweepCandidate,
    SynthesizeDetector
  }

  alias Arbor.Contracts.Security.Finding

  @type verdict :: :confirmed | :refuted

  @doc """
  Run the full synthesis loop for a confirmed `finding`, returning a reviewable
  `DetectorProposal` (admit) or `{:flagged, reason}` (held back).

  ## Arguments

    * `finding` — the confirmed seed `Finding` (struct or map). Its `category`
      selects the shape and (for S1 known categories) the deterministic spec.
    * `verdicts` — `%{finding_id => :confirmed | :refuted}` (see moduledoc). A
      sibling without a verdict is un-triaged and ignored by the precision gate.

  ## Options

    * `:spec` — a pre-built `DetectorSpec` (struct/map/JSON string) forwarded to
      `SynthesizeDetector` (the LLM-synthesis node's output). REQUIRED for S3
      categories (they have no deterministic template).
    * `:root` — the directory `SweepCandidate` sweeps (default `"apps"`; tests
      pass a fixture dir).
    * `:threshold` — the precision floor override (else app env / 0.5).
    * `:git_sha` — provenance recorded on swept siblings.
  """
  @spec propose(map() | struct(), %{optional(String.t()) => verdict()}, keyword()) ::
          {:ok, DetectorProposal.t()} | {:flagged, term()} | {:error, term()}
  def propose(finding, verdicts \\ %{}, opts \\ [])
      when is_map(verdicts) and is_list(opts) do
    root = opts[:root] || "apps"

    with {:ok, candidate} <- synthesize(finding, opts),
         {:ok, sweep} <- sweep(candidate, finding, root, opts[:git_sha]),
         siblings = sweep.siblings,
         assessment = Precision.assess(siblings, verdicts, threshold_opts(opts)),
         :ok <- gate(assessment) do
      {:ok, build_proposal(candidate, siblings, verdicts, assessment)}
    end
  end

  # ---------------------------------------------------------------------------
  # Stages
  # ---------------------------------------------------------------------------

  defp synthesize(finding, opts) do
    params = %{finding: finding, spec: opts[:spec]}

    case SynthesizeDetector.run(params, %{}) do
      {:ok, candidate} -> {:ok, candidate}
      {:error, reason} -> {:error, {:synthesis_failed, reason}}
    end
  end

  defp sweep(candidate, finding, root, git_sha) do
    params = %{
      candidate: candidate,
      finding: finding,
      root: root,
      record: false,
      git_sha: git_sha
    }

    case SweepCandidate.run(params, %{}) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:sweep_failed, reason}}
    end
  end

  # G3 precision gate: admit? → :ok; else carry the reason out as a {:flagged, _}.
  defp gate(%{admit?: true}), do: :ok
  defp gate(%{admit?: false, reason: reason}), do: {:flagged, reason}

  # ---------------------------------------------------------------------------
  # Proposal assembly (admit path)
  # ---------------------------------------------------------------------------

  defp build_proposal(candidate, siblings, verdicts, assessment) do
    spec = candidate.spec
    {confirmed, refuted} = split_by_verdicts(siblings, verdicts)

    test_source =
      DetectorTestTemplate.generate(
        spec,
        candidate.module_name,
        confirmed,
        refuted,
        module_source: candidate.module_source
      )

    %DetectorProposal{
      spec: spec,
      shape: spec.shape,
      module_source: candidate.module_source,
      module_name: candidate.module_name,
      target_path: DetectorProposal.target_path(spec),
      registration_edits: DetectorProposal.registration_edits(spec),
      test_source: test_source,
      test_path: DetectorProposal.test_path(spec),
      siblings: siblings,
      fp_hits: refuted,
      precision: assessment,
      admit?: true,
      summary: summary(spec, siblings, confirmed, refuted, assessment)
    }
  end

  # Split swept siblings into confirmed / refuted using the verdict map. A sibling
  # with no verdict is dropped from BOTH lists (un-triaged → neither a positive
  # seed nor an FP pin). Confirmed seed the positive test; refuted the FP tests.
  defp split_by_verdicts(siblings, verdicts) do
    Enum.reduce(siblings, {[], []}, fn finding, {confirmed, refuted} ->
      case Map.get(verdicts, finding_id(finding)) do
        :confirmed -> {[finding | confirmed], refuted}
        :refuted -> {confirmed, [finding | refuted]}
        _ -> {confirmed, refuted}
      end
    end)
    |> then(fn {c, r} -> {Enum.reverse(c), Enum.reverse(r)} end)
  end

  defp finding_id(%Finding{id: id}), do: id
  defp finding_id(%{id: id}), do: id
  defp finding_id(%{"id" => id}), do: id
  defp finding_id(_), do: nil

  defp summary(%DetectorSpec{} = spec, siblings, confirmed, refuted, assessment) do
    "Synthesized #{spec.shape} detector for #{inspect(spec.category)}: " <>
      "#{length(siblings)} siblings swept (#{length(confirmed)} confirmed, " <>
      "#{length(refuted)} refuted), precision #{assessment.precision} — admitted for human review."
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp threshold_opts(opts) do
    case opts[:threshold] do
      t when is_number(t) -> [threshold: t]
      _ -> []
    end
  end
end
