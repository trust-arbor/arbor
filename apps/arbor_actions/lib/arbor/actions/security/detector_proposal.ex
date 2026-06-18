defmodule Arbor.Actions.Security.DetectorProposal do
  @moduledoc """
  The full, reviewable output of detector synthesis — the Security Sentinel's
  **E1.4** deliverable, held entirely **as DATA**.

  A `DetectorProposal` is what `DetectorSynthesisLoop.propose/3` returns on the
  admit path: everything a human reviewer needs to decide whether to land a
  synthesized detector, with **no side effects**. Per the Sentinel's locked
  decisions, the actual repo-materialization (writing the module + test files,
  cutting a git branch/PR, auto-registering in the suite) is **DEFERRED** — this
  struct describes *what would be written and where*, but applies nothing.

  ## Fields

    * `spec` — the `DetectorSpec` the detector was synthesized from
    * `shape` — `:s1` (per-file AST) or `:s3` (whole-tree); selects both homes
      and idioms below
    * `module_source` — the G1-validated detector module source
    * `module_name` — the name `module_source` is currently compiled under (a
      per-run-unique synthesis name); the proposal's `target_path` carries the
      canonical name the human would rename it to
    * `target_path` — where the detector module WOULD be written:
      * S1 → `apps/arbor_common/lib/arbor/eval/checks/<name>.ex`
      * S3 → `apps/arbor_actions/lib/arbor/actions/security/detectors/<name>.ex`
    * `registration_edits` — the suite-registration changes needed, **as a
      description (data), NOT applied** — see `t:registration_edit/0`:
      * S1 → add the module to `Arbor.Eval.Suites.Security.evals/0` and add the
        `@category_by_detector` / `@invariant_by_category` entries in `StaticScan`
      * S3 → add the module to `WholeTreeScan`'s `@detectors`
    * `test_source` — the generated G4 FP-regression test source
    * `test_path` — where the test WOULD be written (mirrors `target_path`)
    * `siblings` — the swept sibling findings (seed excluded)
    * `fp_hits` — the refuted siblings (the false positives the G4 tests pin out)
    * `precision` — the `Precision.assess/3` assessment map
    * `admit?` — whether the precision gate admitted the candidate (always `true`
      for a built proposal; a non-admit is returned as `{:flagged, reason}` by
      the loop, never as a proposal)
    * `summary` — a short human-readable one-liner

  This struct is JSON-clean enough to flow through the engine context if a DOT
  pipeline ever drives the loop; it carries source strings + plain maps, no PIDs
  or rich typed envelopes.
  """

  use TypedStruct

  alias Arbor.Actions.Security.DetectorSpec
  alias Arbor.Contracts.Security.Finding

  @typedoc """
  One suite-registration change, described as data (never applied).

    * `kind` — what kind of edit (`:append_to_suite_evals`,
      `:add_static_scan_mappings`, `:append_to_whole_tree_detectors`)
    * `file` — the file the human would edit
    * `module` — the detector module reference
    * `description` — a human sentence describing the edit
    * `details` — kind-specific data (e.g. the category/invariant mappings)
  """
  @type registration_edit :: %{
          kind: atom(),
          file: String.t(),
          module: String.t(),
          description: String.t(),
          details: map()
        }

  typedstruct do
    @typedoc "A fully-assembled, reviewable detector synthesis proposal (DATA only)"

    field(:spec, DetectorSpec.t(), enforce: true)
    field(:shape, DetectorSpec.shape(), enforce: true)
    field(:module_source, String.t(), enforce: true)
    field(:module_name, String.t(), enforce: true)
    field(:target_path, String.t(), enforce: true)
    field(:registration_edits, [registration_edit()], default: [])
    field(:test_source, String.t(), enforce: true)
    field(:test_path, String.t(), enforce: true)
    field(:siblings, [Finding.t()], default: [])
    field(:fp_hits, [Finding.t()], default: [])
    field(:precision, map(), default: %{})
    field(:admit?, boolean(), default: true)
    field(:summary, String.t(), default: "")
  end

  @doc """
  The canonical filesystem path a synthesized detector of `spec` WOULD be written
  to (NOT created here). S1 detectors live in `arbor_common`'s eval checks; S3
  detectors in `arbor_actions`'s security detectors.
  """
  @spec target_path(DetectorSpec.t()) :: String.t()
  def target_path(%DetectorSpec{shape: :s3, name: name}),
    do: "apps/arbor_actions/lib/arbor/actions/security/detectors/#{file_basename(name)}.ex"

  def target_path(%DetectorSpec{name: name}),
    do: "apps/arbor_common/lib/arbor/eval/checks/#{file_basename(name)}.ex"

  @doc """
  The canonical filesystem path the generated G4 test WOULD be written to (NOT
  created here), mirroring `target_path/1`.
  """
  @spec test_path(DetectorSpec.t()) :: String.t()
  def test_path(%DetectorSpec{shape: :s3, name: name}),
    do: "apps/arbor_actions/test/arbor/actions/security/detectors/#{file_basename(name)}_test.exs"

  def test_path(%DetectorSpec{name: name}),
    do: "apps/arbor_common/test/arbor/eval/checks/#{file_basename(name)}_test.exs"

  @doc """
  The canonical module name a synthesized detector of `spec` WOULD use once
  landed (the human-facing name, distinct from the per-run-unique synthesis
  compile name).
  """
  @spec canonical_module_name(DetectorSpec.t()) :: String.t()
  def canonical_module_name(%DetectorSpec{shape: :s3, name: name}),
    do: "Arbor.Actions.Security.Detectors.Synthesized." <> camelize(name)

  def canonical_module_name(%DetectorSpec{name: name}),
    do: "Arbor.Eval.Checks.Synthesized." <> camelize(name)

  @doc """
  Builds the `registration_edits` description list for `spec` (DATA — nothing is
  applied). Mirrors the manual registration steps the E1 design documents.
  """
  @spec registration_edits(DetectorSpec.t()) :: [registration_edit()]
  def registration_edits(%DetectorSpec{shape: :s3} = spec) do
    module = canonical_module_name(spec)

    [
      %{
        kind: :append_to_whole_tree_detectors,
        file: "apps/arbor_actions/lib/arbor/actions/security/whole_tree_scan.ex",
        module: module,
        description: "Append #{module} to WholeTreeScan's @detectors list.",
        details: %{attribute: "@detectors", category: spec.category}
      }
    ]
  end

  def registration_edits(%DetectorSpec{} = spec) do
    module = canonical_module_name(spec)

    [
      %{
        kind: :append_to_suite_evals,
        file: "apps/arbor_common/lib/arbor/eval/suites/security.ex",
        module: module,
        description: "Append #{module} to Arbor.Eval.Suites.Security.evals/0.",
        details: %{function: "evals/0"}
      },
      %{
        kind: :add_static_scan_mappings,
        file: "apps/arbor_actions/lib/arbor/actions/security/static_scan.ex",
        module: module,
        description:
          "Add @category_by_detector and @invariant_by_category entries in StaticScan " <>
            "for the synthesized detector.",
        details: %{
          category_by_detector: %{spec.name => spec.category},
          invariant_by_category: %{spec.category => spec.invariant}
        }
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp file_basename(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.downcase()
  end

  defp camelize(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> Macro.camelize()
  end
end
