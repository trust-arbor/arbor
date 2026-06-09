defmodule Arbor.Actions.Security.WholeTreeScan do
  @moduledoc """
  Runs the Security Sentinel's **whole-tree** (cross-file) detectors — the L0b
  layer — and records any findings.

  Where `StaticScan` runs per-file `Arbor.Eval` checks, these detectors correlate
  definitions across the codebase (e.g. a struct and its `signing_payload/1`).
  Each detector exposes `detect(opts) :: [Finding]`; results flow through the
  shared `Recorder` (status-aware `FindingStore` + signals) exactly like static
  findings.
  """

  alias Arbor.Actions.Security.Detectors.SignedFieldCoverage
  alias Arbor.Actions.Security.Recorder
  alias Arbor.Contracts.Security.Finding

  @default_output_dir ".arbor/security/findings"

  # Registered whole-tree detectors. New L0b detectors (URI-registration
  # coverage, regression-test presence, serializer⊇signed) are added here.
  @detectors [SignedFieldCoverage]

  @doc """
  Run all whole-tree detectors over `root` (default `"apps"`). Returns
  `{findings, summary}`; records unless `record: false`.
  """
  @spec scan(keyword()) :: {[Finding.t()], Recorder.summary()}
  def scan(opts \\ []) do
    record? = Keyword.get(opts, :record, true)
    dir = Keyword.get(opts, :output_dir, @default_output_dir)
    root = Keyword.get(opts, :root, "apps")
    git_sha = Keyword.get(opts, :git_sha)

    findings =
      @detectors
      |> Enum.flat_map(& &1.detect(root: root, git_sha: git_sha))
      |> Enum.uniq_by(& &1.id)

    {_outcomes, summary} = Recorder.record_all(findings, record?, dir)
    {findings, summary}
  end

  @doc "The registered whole-tree detector modules."
  @spec detectors() :: [module()]
  def detectors, do: @detectors
end
