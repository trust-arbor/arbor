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
