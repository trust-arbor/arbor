defmodule Arbor.Actions.Security do
  @moduledoc """
  Security Sentinel actions — static analysis and (later) verification,
  dependency scanning, and remediation helpers.

  These are the Jido actions a DOT pipeline (or the Sentinel agent) invokes to
  run the security assessment loop. Phase 1 ships `RunStaticDetectors`.
  """
end

defmodule Arbor.Actions.Security.RunStaticDetectors do
  @moduledoc """
  Run the L0 static security detectors (`Arbor.Eval.Suites.Security`) over a
  path and record any findings.

  Drives `Arbor.Actions.Security.StaticScan`. Returns a summary map; the
  findings themselves are persisted to the output directory and emitted as
  `security.sentinel_finding` signals.
  """

  use Jido.Action,
    name: "security_run_static_detectors",
    description: "Run static security detectors over a path and record findings",
    category: "security",
    tags: ["security", "static-analysis", "sentinel"],
    schema: [
      path: [
        type: {:or, [:string, {:list, :string}]},
        required: true,
        doc: "Directory or .ex file (or a list of them) to scan"
      ],
      output_dir: [
        type: :string,
        default: ".arbor/security/findings",
        doc: "Directory to write finding markdown files into"
      ],
      record: [
        type: :boolean,
        default: true,
        doc: "Write finding files + emit signals (false = dry run)"
      ],
      git_sha: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Git SHA recorded on each finding for provenance"
      ]
    ]

  alias Arbor.Actions.Security.StaticScan

  @impl true
  def run(%{path: path} = params, _context) do
    {findings, summary} =
      StaticScan.scan(path,
        output_dir: params[:output_dir] || ".arbor/security/findings",
        record: Map.get(params, :record, true),
        git_sha: params[:git_sha]
      )

    {:ok,
     %{
       total: summary.total,
       by_category: summary.by_category,
       by_severity: summary.by_severity,
       by_outcome: summary.by_outcome,
       recorded_to: summary.recorded_to,
       finding_ids: Enum.map(findings, & &1.id)
     }}
  end
end

defmodule Arbor.Actions.Security.RunDependencyScan do
  @moduledoc """
  Run the supply-chain dependency detector and record findings. Unlike the fast
  whole-tree pass, this enables the `mix hex.audit` retired-package check by
  default (the daily dependency pipeline drives it).
  """

  use Jido.Action,
    name: "security_run_dependency_scan",
    description: "Scan dependencies for supply-chain risk (mutable git deps, retired packages)",
    category: "security",
    tags: ["security", "supply-chain", "sentinel", "dependencies"],
    schema: [
      audit: [type: :boolean, default: true, doc: "Run mix hex.audit for retired packages"],
      output_dir: [type: :string, default: ".arbor/security/findings", doc: "Findings dir"],
      record: [type: :boolean, default: true, doc: "Write findings + emit signals"],
      git_sha: [type: {:or, [:string, nil]}, default: nil, doc: "Git SHA for provenance"]
    ]

  alias Arbor.Actions.Security.Detectors.DependencyScan
  alias Arbor.Actions.Security.Recorder

  @impl true
  def run(params, _context) do
    findings =
      DependencyScan.detect(audit: Map.get(params, :audit, true), git_sha: params[:git_sha])
      |> Enum.uniq_by(& &1.id)

    {_outcomes, summary} =
      Recorder.record_all(
        findings,
        Map.get(params, :record, true),
        params[:output_dir] || ".arbor/security/findings"
      )

    {:ok,
     %{
       total: summary.total,
       by_severity: summary.by_severity,
       by_outcome: summary.by_outcome,
       recorded_to: summary.recorded_to,
       finding_ids: Enum.map(findings, & &1.id)
     }}
  end
end

defmodule Arbor.Actions.Security.AggregateVerdict do
  @moduledoc """
  Aggregate the adversarial-verify skeptic outputs into a verdict and annotate
  the finding (advisory). The terminal node of `verify-finding.dot`: the N
  skeptic `compute` nodes feed their outputs here; this computes majority-refute
  via `Arbor.Actions.Security.Verifier` and appends the verdict to the finding.
  """

  use Jido.Action,
    name: "security_aggregate_verdict",
    description: "Aggregate adversarial verify-finding skeptic outputs into a verdict",
    category: "security",
    tags: ["security", "sentinel", "verify"],
    schema: [
      skeptic_1: [type: :string, default: ""],
      skeptic_2: [type: :string, default: ""],
      skeptic_3: [type: :string, default: ""],
      finding_id: [type: {:or, [:string, nil]}, default: nil],
      output_dir: [type: :string, default: ".arbor/security/findings"]
    ]

  alias Arbor.Actions.Security.{FindingStore, Verifier}
  alias Arbor.Contracts.Judge.Verdict

  @impl true
  def run(params, _context) do
    outputs =
      [params[:skeptic_1], params[:skeptic_2], params[:skeptic_3]]
      |> Enum.reject(&(&1 in [nil, ""]))

    verdict = Verifier.aggregate_verdict(outputs)

    if params[:finding_id] do
      FindingStore.annotate_verification(params[:finding_id], Verifier.to_annotation(verdict),
        dir: params[:output_dir] || ".arbor/security/findings"
      )
    end

    {:ok,
     %{
       verdict: verdict.meta.decision,
       recommendation: verdict.recommendation,
       confidence: verdict.overall_score,
       refuted: verdict.meta.refuted,
       total: verdict.meta.total,
       passed: Verdict.passed?(verdict)
     }}
  end
end

defmodule Arbor.Actions.Security.RunWholeTreeDetectors do
  @moduledoc """
  Run the cross-file (L0b) security detectors — e.g. signed-field coverage — over
  the codebase and record any findings. Drives
  `Arbor.Actions.Security.WholeTreeScan`.
  """

  use Jido.Action,
    name: "security_run_whole_tree_detectors",
    description: "Run cross-file security detectors over the codebase and record findings",
    category: "security",
    tags: ["security", "static-analysis", "sentinel", "whole-tree"],
    schema: [
      root: [type: :string, default: "apps", doc: "Root directory to analyze"],
      output_dir: [
        type: :string,
        default: ".arbor/security/findings",
        doc: "Directory to write finding markdown files into"
      ],
      record: [type: :boolean, default: true, doc: "Write findings + emit signals"],
      git_sha: [type: {:or, [:string, nil]}, default: nil, doc: "Git SHA for provenance"]
    ]

  alias Arbor.Actions.Security.WholeTreeScan

  @impl true
  def run(params, _context) do
    {findings, summary} =
      WholeTreeScan.scan(
        root: params[:root] || "apps",
        output_dir: params[:output_dir] || ".arbor/security/findings",
        record: Map.get(params, :record, true),
        git_sha: params[:git_sha]
      )

    {:ok,
     %{
       total: summary.total,
       by_category: summary.by_category,
       by_severity: summary.by_severity,
       by_outcome: summary.by_outcome,
       recorded_to: summary.recorded_to,
       finding_ids: Enum.map(findings, & &1.id)
     }}
  end
end
