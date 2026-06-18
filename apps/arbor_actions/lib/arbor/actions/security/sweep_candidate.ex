defmodule Arbor.Actions.Security.SweepCandidate do
  @moduledoc """
  Sweep a synthesized candidate detector over the umbrella — the Security
  Sentinel's **G2** stage (E1.3).

  `SynthesizeDetector` produces a G1-validated *candidate* (it re-catches its own
  seed). The value of synthesis, though, is in the *siblings*: the same class of
  bug sitting in unreviewed code. This action runs the candidate tree-wide and
  collects those siblings, so the existing adversarial verifier
  (`verify-pending.dot`) can triage them into confirmed-real vs. false-positive.

  ## Input

  The `SynthesizeDetector` `{:ok, _}` map is passed through as the candidate
  (`module_source` + `shape` + `spec`), plus the seed `Finding`:

    * `candidate` — the synthesize result map (must carry `module_source` and
      `shape`; `spec` supplies the category/invariant for S1 Finding conversion).
    * `finding` — the confirmed seed `Finding` (struct or map). Excluded from the
      sweep results: the seed is the bug we already know, not a new sibling.

  ## How the sweep runs (by shape)

    * **S1** (per-file AST): enumerate `Detectors.Common.elixir_source_files/1`
      under `root`, parse each with `Common.parse(file, columns: true)`, run the
      candidate's `run(%{ast: ast, file: file})`, and convert each violation into
      a `Finding` — mirroring `StaticScan`'s violation→Finding conversion (the
      category from the spec, location `{file, line, function}`, invariant,
      evidence, detector provenance marked `synthesized: true`).
    * **S3** (whole-tree): call the candidate's `detect(root: root)`, which
      already returns `[Finding]`.

  ## Seed exclusion + dedup

  Every hit whose `Finding.dedup_key/1` equals the seed's is dropped (the seed is
  not a new sibling). The remaining hits are deduped by `dedup_key/1` so a class
  matched twice at the same site collapses to one sibling.

  ## Recording

  By default the swept siblings are NOT recorded (so unit tests and dry runs stay
  side-effect-free). Pass `record: true` to route them through the shared
  `Recorder` (status-aware `FindingStore` + signals) — which is how the existing
  `verify-pending.dot` fan-out picks them up.

  ## Output

      {:ok, %{siblings: [Finding], hit_count: n, seed_excluded: bool,
              shape: :s1 | :s3, summary: map() | nil}}

  `seed_excluded` is `true` when at least one raw hit matched the seed's dedup key
  (i.e. the candidate re-caught its seed during the sweep, as G1 guarantees it
  should). `summary` is the `Recorder` summary when `record: true`, else `nil`.
  """

  use Jido.Action,
    name: "security_sweep_candidate",
    description: "Sweep a synthesized candidate detector over the umbrella and collect siblings",
    category: "security",
    tags: ["security", "sentinel", "synthesis", "sweep", "e1"],
    schema: [
      candidate: [
        type: {:or, [:map, :struct]},
        required: true,
        doc: "The SynthesizeDetector {:ok, _} result map (module_source + shape + spec)"
      ],
      finding: [
        type: {:or, [:map, :struct]},
        required: true,
        doc: "The confirmed seed Finding — excluded from the sweep results"
      ],
      root: [
        type: :string,
        default: "apps",
        doc: "Directory to sweep (default the umbrella `apps`; tests pass a fixture dir)"
      ],
      record: [
        type: :boolean,
        default: false,
        doc: "Record siblings via the Recorder (FindingStore + signals) — default false"
      ],
      output_dir: [
        type: :string,
        default: ".arbor/security/findings",
        doc: "FindingStore directory when record: true"
      ],
      git_sha: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Git SHA recorded on each sibling for provenance"
      ]
    ]

  alias Arbor.Actions.Security.Detectors.Common
  alias Arbor.Actions.Security.Recorder
  alias Arbor.Contracts.Security.Finding

  @impl true
  def run(%{candidate: candidate, finding: finding} = params, _context) do
    seed = normalize_finding(finding)
    root = params[:root] || "apps"
    shape = shape_of(candidate)
    source = candidate[:module_source] || candidate["module_source"]

    with {:ok, source} <- require_source(source),
         {:ok, module} <- compile_in_memory(source) do
      raw = sweep(shape, module, candidate, seed, root, params[:git_sha])
      {siblings, seed_excluded?} = exclude_seed_and_dedup(raw, seed)

      summary = maybe_record(siblings, params)

      {:ok,
       %{
         siblings: siblings,
         hit_count: length(siblings),
         seed_excluded: seed_excluded?,
         shape: shape,
         summary: summary
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Sweep dispatch by shape
  # ---------------------------------------------------------------------------

  # S3: the generated whole-tree detector already returns [Finding].
  defp sweep(:s3, module, _candidate, _seed, root, git_sha) do
    module.detect(root: root, git_sha: git_sha)
  end

  # S1: per-file AST. Enumerate, parse, run/1, convert violations → Findings,
  # mirroring StaticScan's conversion (the candidate is a `use Arbor.Eval`
  # module, so we drive its run/1 ourselves rather than via the suite).
  defp sweep(_s1, module, candidate, _seed, root, git_sha) do
    spec = candidate[:spec] || candidate["spec"]

    root
    |> Common.elixir_source_files()
    |> Enum.flat_map(&scan_file(&1, module, spec, git_sha))
  end

  defp scan_file(file, module, spec, git_sha) do
    case Common.parse(file, columns: true) do
      {:ok, ast} ->
        result = module.run(%{ast: ast, file: file})

        (result[:violations] || [])
        |> Enum.filter(&(&1[:severity] in [:warning, :error]))
        |> Enum.map(&finding_from_violation(file, &1, spec, git_sha))

      _ ->
        []
    end
  end

  # Mirror StaticScan.finding_from_violation/4: category + invariant come from
  # the spec; location {file,line,function}; detector provenance marked
  # synthesized so siblings are distinguishable from hand-authored L0 findings.
  defp finding_from_violation(file, violation, spec, git_sha) do
    category = spec_category(spec)
    invariant = spec_invariant(spec)

    Finding.new(
      category: category,
      title: violation[:message] || "Synthesized detector match",
      git_sha: git_sha,
      detector: %{layer: "L0", name: spec_name(spec), version: "1", synthesized: true},
      severity: %{level: severity_level(violation[:severity])},
      confidence: %{score: 0.6, rationale: "synthesized S1 sweep (#{violation[:type]})"},
      location: %{
        library: Common.library_of(file),
        file: file,
        line: violation[:line],
        function: violation[:function]
      },
      invariant_violated: invariant,
      evidence: %{smell_match: violation[:type]},
      recommendation: %{
        approach:
          violation[:suggestion] ||
            "Review this site against the invariant — the synthesized detector flagged it as a sibling."
      },
      actionability: %{auto_fixable: false, risk_class: risk_class(file)},
      verification: %{must_fail_on_revert: true}
    )
  end

  defp severity_level(:error), do: :high
  defp severity_level(:warning), do: :medium
  defp severity_level(_), do: :low

  # Mirror StaticScan/Finding.high_risk_location? markers.
  defp risk_class(file) do
    if Enum.any?(["arbor_security", "capability", "trust", "auth"], &String.contains?(file, &1)),
      do: :high,
      else: :medium
  end

  # ---------------------------------------------------------------------------
  # Seed exclusion + dedup
  # ---------------------------------------------------------------------------

  defp exclude_seed_and_dedup(raw, seed) do
    seed_key = Finding.dedup_key(seed)

    {seed_hits, others} =
      Enum.split_with(raw, fn f -> Finding.dedup_key(f) == seed_key end)

    siblings = Enum.uniq_by(others, &Finding.dedup_key/1)
    {siblings, seed_hits != []}
  end

  # ---------------------------------------------------------------------------
  # Recording (opt-in)
  # ---------------------------------------------------------------------------

  defp maybe_record(siblings, params) do
    if params[:record] do
      {_outcomes, summary} =
        Recorder.record_all(siblings, true, params[:output_dir] || ".arbor/security/findings")

      summary
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Candidate compile (mirrors SynthesizeDetector's in-memory compile)
  # ---------------------------------------------------------------------------

  defp require_source(src) when is_binary(src) and src != "", do: {:ok, src}
  defp require_source(_), do: {:error, {:sweep_failed, :no_module_source}}

  # Compile the candidate under a fresh, unique module name so a sweep never
  # clashes with the synthesis-time G1 module (or a prior sweep). The generated
  # source names its own module; we rewrite that to a per-run unique name.
  defp compile_in_memory(source) do
    try do
      [{compiled, _bin} | _] = Code.compile_string(rename_module(source))
      {:ok, compiled}
    rescue
      e -> {:error, {:sweep_failed, {:compile_error, Exception.message(e)}}}
    catch
      kind, reason -> {:error, {:sweep_failed, {:compile_throw, kind, reason}}}
    end
  end

  # Rewrite the `defmodule <Name> do` header to a unique sweep module name so the
  # in-memory compile is collision-free across runs.
  defp rename_module(source) do
    unique = "Arbor.Actions.Security.Sweep.Candidate_#{System.unique_integer([:positive])}"

    Regex.replace(~r/\Adefmodule\s+[A-Za-z0-9_.]+\s+do/, source, "defmodule #{unique} do",
      global: false
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp shape_of(candidate) do
    case candidate[:shape] || candidate["shape"] do
      :s3 -> :s3
      "s3" -> :s3
      _ -> :s1
    end
  end

  defp spec_category(spec), do: spec_field(spec, :category) || :other
  defp spec_invariant(spec), do: spec_field(spec, :invariant)
  defp spec_name(spec), do: spec_field(spec, :name) || "synthesized"

  # The spec carried in the candidate is a `%DetectorSpec{}` struct (no Access),
  # but may also arrive as a plain atom-/string-keyed map (DOT/JSON path). Read a
  # field from any of those forms.
  defp spec_field(%_{} = struct, field), do: Map.get(struct, field)

  defp spec_field(spec, field) when is_map(spec) do
    spec[field] || spec[Atom.to_string(field)]
  end

  defp spec_field(_spec, _field), do: nil

  defp normalize_finding(%Finding{} = f), do: f

  defp normalize_finding(map) when is_map(map) do
    %Finding{
      id: map[:id] || map["id"] || "seed",
      category: map[:category] || map["category"],
      title: map[:title] || map["title"] || "",
      location: map[:location] || map["location"] || %{},
      invariant_violated: map[:invariant_violated] || map["invariant_violated"],
      evidence: map[:evidence] || map["evidence"] || %{}
    }
  end
end
