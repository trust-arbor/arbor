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

  The `SynthesizeDetector` `{:ok, _}` map is passed through as the candidate,
  plus the seed `Finding`:

    * `candidate` — the synthesize result map. Its `spec` is the ONLY thing the
      sweep compiles from (see Provenance below); `module_source`, when present,
      must be byte-identical to what that spec regenerates. `shape` is
      informative only — the validated `spec.shape` drives dispatch.
    * `finding` — the confirmed seed `Finding` (struct or map). Excluded from the
      sweep results: the seed is the bug we already know, not a new sibling.

  ## Provenance: the candidate is REBUILT from its spec, never compiled as given

  This action compiles and runs code in the VM, and its `candidate` param is
  reachable from an agent-authored DOT graph (every exec node runs
  `pipeline_internal`-allowed). Compiling `candidate.module_source` verbatim
  would therefore be an arbitrary-code-execution crossing: anything that can put
  a map in the context could run module-body code at compile time and
  `detect/1` / `run/1` right after (2026-10-11 cross-library review F-008; the
  same class as the 2026-08-16 in-VM code-execution crossings).

  So the sweep never compiles caller-supplied text:

    1. `candidate.spec` is coerced through `DetectorSpec.coerce/1` — the same
       allowlist path `SynthesizeDetector` uses for LLM/JSON specs — into a
       validated `%DetectorSpec{}`. It may arrive as the struct (in-process), an
       atom-keyed map, or a JSON-clean string-keyed map (after the Engine
       context boundary). Missing or invalid →
       `{:error, {:sweep_failed, :invalid_spec}}`.
    2. The detector source is REGENERATED from that spec via
       `DetectorTemplate.module_source/2` (the one spec→source dispatch) and
       compiled under a fresh unique module name.
    3. If `candidate.module_source` is present it must equal the regenerated
       source modulo the leading `defmodule` header (the module name is
       per-run). Any difference →
       `{:error, {:sweep_failed, :module_source_provenance_mismatch}}` — and
       nothing is compiled.

  A genuine `SynthesizeDetector` result always passes (its `module_source` IS the
  template output for its `spec`), so the shipped `synthesize-and-sweep.dot`
  pipeline is unaffected. Only text that did not come from the template for this
  spec is refused.

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
    tags: ["security", "sentinel", "synthesis", "sweep", "e1", "pipeline_internal"],
    schema: [
      candidate: [
        type: {:or, [:map, :struct]},
        required: true,
        doc:
          "The SynthesizeDetector {:ok, _} result map. `spec` is required and is " <>
            "what gets compiled (regenerated via DetectorTemplate); `module_source` " <>
            "is optional and, when present, must match that regeneration"
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
  alias Arbor.Actions.Security.{DetectorSpec, DetectorTemplate}
  alias Arbor.Actions.Security.Recorder
  alias Arbor.Contracts.Security.Finding

  @impl true
  def run(%{candidate: candidate, finding: finding} = params, _context) do
    seed = normalize_finding(finding)
    root = params[:root] || "apps"

    with {:ok, spec} <- candidate_spec(candidate),
         :ok <- verify_provenance(candidate, spec),
         {:ok, module} <- compile_from_spec(spec) do
      raw = sweep(spec.shape, module, spec, seed, root, params[:git_sha])
      {siblings, seed_excluded?} = exclude_seed_and_dedup(raw, seed)

      summary = maybe_record(siblings, params)

      {:ok,
       %{
         siblings: siblings,
         hit_count: length(siblings),
         seed_excluded: seed_excluded?,
         shape: spec.shape,
         summary: summary
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Sweep dispatch by shape (the validated spec's shape — the template that was
  # actually compiled — never the candidate's informative `shape` field)
  # ---------------------------------------------------------------------------

  # S3: the generated whole-tree detector already returns [Finding].
  defp sweep(:s3, module, _spec, _seed, root, git_sha) do
    module.detect(root: root, git_sha: git_sha)
  end

  # S1: per-file AST. Enumerate, parse, run/1, convert violations → Findings,
  # mirroring StaticScan's conversion (the candidate is a `use Arbor.Eval`
  # module, so we drive its run/1 ourselves rather than via the suite).
  defp sweep(:s1, module, spec, _seed, root, git_sha) do
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
  defp finding_from_violation(file, violation, %DetectorSpec{} = spec, git_sha) do
    Finding.new(
      category: spec.category,
      title: violation[:message] || "Synthesized detector match",
      git_sha: git_sha,
      detector: %{layer: "L0", name: spec.name, version: "1", synthesized: true},
      severity: %{level: severity_level(violation[:severity])},
      confidence: %{score: 0.6, rationale: "synthesized S1 sweep (#{violation[:type]})"},
      location: %{
        library: Common.library_of(file),
        file: file,
        line: violation[:line],
        function: violation[:function]
      },
      invariant_violated: spec.invariant,
      evidence: %{
        smell_match: violation[:type],
        code_excerpt: Common.code_excerpt(file, violation[:function], violation[:line])
      },
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
  # Provenance: spec → regenerate → (optional) compare → compile (F-008)
  # ---------------------------------------------------------------------------

  # The candidate's spec is the only trusted input. DetectorSpec.coerce/1 accepts
  # the struct, an atom-keyed map, or a JSON-clean string-keyed map, through the
  # same allowlist path SynthesizeDetector uses — and fails closed on anything
  # else (nil, non-map, unsupported/invalid spec).
  defp candidate_spec(candidate) do
    case DetectorSpec.coerce(fetch(candidate, :spec)) do
      {:ok, %DetectorSpec{} = spec} -> {:ok, spec}
      {:error, _reason} -> {:error, {:sweep_failed, :invalid_spec}}
    end
  end

  # A supplied module_source is never compiled — it is only compared against what
  # the spec regenerates (modulo the per-run `defmodule` header). Absent is fine
  # (the spec alone fully determines the detector); present-but-different, or
  # not a string, is a provenance mismatch and the sweep refuses before any
  # compile.
  defp verify_provenance(candidate, spec) do
    case fetch(candidate, :module_source) do
      nil ->
        :ok

      supplied when is_binary(supplied) ->
        if strip_header(supplied) == strip_header(DetectorTemplate.module_source(spec)),
          do: :ok,
          else: {:error, {:sweep_failed, :module_source_provenance_mismatch}}

      _other ->
        {:error, {:sweep_failed, :module_source_provenance_mismatch}}
    end
  end

  # Regenerate the source from the validated spec under a fresh, unique module
  # name (collision-free across sweeps and vs. the synthesis-time G1 module) and
  # compile THAT — never the caller's text.
  defp compile_from_spec(spec) do
    unique = "Arbor.Actions.Security.Sweep.Candidate_#{System.unique_integer([:positive])}"
    source = DetectorTemplate.module_source(spec, module: unique)

    try do
      # `source` is DetectorTemplate output for a validated %DetectorSpec{} (every
      # spec value reaches it via inspect/1 or escape_doc/1) — never caller text;
      # a caller-supplied module_source was only COMPARED above, never compiled.
      # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
      [{compiled, _bin} | _] = Code.compile_string(source)
      {:ok, compiled}
    rescue
      e -> {:error, {:sweep_failed, {:compile_error, Exception.message(e)}}}
    catch
      kind, reason -> {:error, {:sweep_failed, {:compile_throw, kind, reason}}}
    end
  end

  # The generated source names its module exactly once, in the leading
  # `defmodule` line, and that name is per-run (`.G1_<n>` at synthesis,
  # `Sweep.Candidate_<n>` here). The comparison masks that header only.
  defp strip_header(source) do
    Regex.replace(~r/\Adefmodule\s+[A-Za-z0-9_.]+\s+do/, source, "defmodule __CANDIDATE__ do",
      global: false
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Read a candidate field from a struct, an atom-keyed map, or a string-keyed
  # map (the DOT/JSON path).
  defp fetch(%_{} = struct, key), do: Map.get(struct, key)
  defp fetch(map, key) when is_map(map), do: map[key] || map[Atom.to_string(key)]
  defp fetch(_other, _key), do: nil

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
