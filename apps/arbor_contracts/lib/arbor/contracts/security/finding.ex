defmodule Arbor.Contracts.Security.Finding do
  @moduledoc """
  A structured, actionable security finding produced by the Security Sentinel.

  A `Finding` is the central contract between the **assessment** half of the
  Sentinel (detect → verify → document) and the future **action** half
  (remediate → verify-fix → land). It carries enough detail that a remediation
  agent can read `recommendation` + `actionability` + `verification` and act
  without re-deriving the analysis.

  Findings are produced by detectors (per-file `Arbor.Eval` checks and
  whole-tree analysis actions), stored in a `FindingStore` (BufferedStore
  pattern), projected to the roadmap inbox for human review, and emitted as
  signals for dashboards.

  ## Categories

  Seeded from the classes fixed in the 2026-06-09 security reviews:

  - `:fail_open_authz` — an authorization/verification path returns an allow
    value on error/unknown (H1, M1, M2, L1, C10)
  - `:crypto_weakness` — wrong hash mode, missing sender auth, MAC ordering (C2/C4/C9)
  - `:capability_overmatch` — capability match grants beyond exact + `/**` (C8)
  - `:serialization_drop` — a persisted struct drops a signed field (C11)
  - `:missing_regression_test` — a security fix lacks a fail-on-revert test
  - `:unsafe_atom` — `String.to_atom/1` on untrusted input
  - `:config_fail_open` — a security flag defaults to the permissive value (M3)
  - `:unregistered_uri` — an `arbor://` URI used in authz but absent from the
    canonical registry (the signals-subscribe gap)
  - `:other`

  ## Risk class and the hard cap

  `actionability.risk_class` gates trust-tiered auto-action. It is **hard-capped
  to `:high`** for anything touching `arbor_security` auth/crypto, capability
  grants, or trust profiles — those are never auto-merged regardless of the
  Sentinel's trust tier. See `high_risk_location?/1`.

  ## Verification invariant

  `verification.must_fail_on_revert` encodes the CLAUDE.md rule: a remediation
  is only accepted if its regression test fails on `git checkout HEAD~1` of the
  fix alone. A Finding cannot be closed as `:fixed` by weakening a check.
  """

  use TypedStruct

  @typedoc "Lifecycle status of a finding"
  @type status ::
          :open
          | :triaged
          | :accepted
          | :wontfix
          | :in_remediation
          | :fixed
          | :regressed
          | :false_positive

  @typedoc "Detector taxonomy category"
  @type category ::
          :fail_open_authz
          | :crypto_weakness
          | :capability_overmatch
          | :serialization_drop
          | :missing_regression_test
          | :unsafe_atom
          | :config_fail_open
          | :unregistered_uri
          | :path_traversal
          | :secret_exposure
          | :other

  @typedoc "Qualitative severity"
  @type severity_level :: :critical | :high | :medium | :low | :info

  @typedoc "Remediation risk class (gates auto-action)"
  @type risk_class :: :low | :medium | :high

  @valid_statuses [
    :open,
    :triaged,
    :accepted,
    :wontfix,
    :in_remediation,
    :fixed,
    :regressed,
    :false_positive
  ]

  @terminal_statuses [:fixed, :wontfix, :false_positive]

  # Libraries/paths where any change is hard-capped to :high risk (never
  # auto-merged) — the fox-henhouse guard.
  @high_risk_path_markers ["arbor_security", "capability", "trust", "auth"]

  typedstruct do
    @typedoc "A security finding"

    field(:id, String.t(), enforce: true)
    field(:schema_version, String.t(), default: "1.0")
    field(:detected_at, DateTime.t())
    field(:git_sha, String.t() | nil, default: nil)

    # Provenance: which detector found it.
    field(:detector, map(), default: %{})

    field(:status, status(), default: :open)
    field(:category, category(), enforce: true)
    field(:title, String.t(), enforce: true)

    # severity: %{level: severity_level(), cvss_vector: String.t() | nil, score: float() | nil}
    field(:severity, map(), default: %{level: :medium})
    # confidence: %{score: float(), rationale: String.t()}
    field(:confidence, map(), default: %{score: 0.5, rationale: ""})

    # location: %{library, file, line_range, function, resource_uri}
    field(:location, map(), default: %{})
    field(:invariant_violated, String.t() | nil, default: nil)
    # threat_model: %{actor, capability_needed, attack, impact}
    field(:threat_model, map(), default: %{})
    # evidence: %{code_excerpt, smell_match, repro}
    field(:evidence, map(), default: %{})

    # recommendation: %{approach, affected_call_sites, patch_sketch,
    #                   regression_test, references}
    field(:recommendation, map(), default: %{})
    # actionability: %{auto_fixable, risk_class, blast_radius, rollback, est_effort}
    field(:actionability, map(), default: %{auto_fixable: false, risk_class: :high})
    # verification: %{fix_confirmed_by, must_fail_on_revert}
    field(:verification, map(), default: %{must_fail_on_revert: true})

    field(:human_feedback, map() | nil, default: nil)
    field(:metadata, map(), default: %{})
  end

  @doc """
  Creates a new Finding with a generated id and detection timestamp.

  Required opts: `:category`, `:title`. The `:detected_at` defaults to now.
  The `:id` is derived from `dedup_key/1` when not supplied, so the same
  underlying issue produces a stable id across detection runs.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    category = Keyword.fetch!(opts, :category)
    title = Keyword.fetch!(opts, :title)

    base = %__MODULE__{
      # placeholder, replaced below once we can compute the dedup key
      id: "pending",
      category: category,
      title: title,
      schema_version: opts[:schema_version] || "1.0",
      detected_at: opts[:detected_at] || DateTime.utc_now(),
      git_sha: opts[:git_sha],
      detector: opts[:detector] || %{},
      status: opts[:status] || :open,
      severity: opts[:severity] || %{level: :medium},
      confidence: opts[:confidence] || %{score: 0.5, rationale: ""},
      location: opts[:location] || %{},
      invariant_violated: opts[:invariant_violated],
      threat_model: opts[:threat_model] || %{},
      evidence: opts[:evidence] || %{},
      recommendation: opts[:recommendation] || %{},
      actionability: opts[:actionability] || %{auto_fixable: false, risk_class: :high},
      verification: opts[:verification] || %{must_fail_on_revert: true},
      human_feedback: opts[:human_feedback],
      metadata: opts[:metadata] || %{}
    }

    id = opts[:id] || dedup_key(base)
    %{base | id: id}
  end

  @doc """
  Computes a stable dedup key for a finding from its category, normalized
  location, and violated invariant.

  Two detection runs that surface the same issue at the same place produce the
  same key, so the FindingStore can suppress duplicates and re-open regressions
  without spawning new ids. Line numbers are deliberately excluded so that
  unrelated edits above the finding don't change its identity.
  """
  @spec dedup_key(t()) :: String.t()
  def dedup_key(%__MODULE__{} = finding) do
    file = finding.location[:file] || finding.location["file"] || ""
    function = finding.location[:function] || finding.location["function"] || ""

    payload =
      [
        to_string(finding.category),
        normalize_path(file),
        to_string(function),
        finding.invariant_violated || ""
      ]
      |> Enum.join("\n")

    digest = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    "sec-finding_" <> binary_part(digest, 0, 16)
  end

  @doc "Returns true if the finding is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @doc """
  Transitions a finding to a new status. Returns `{:error, :invalid_status}`
  for an unknown status atom (fail closed — never silently accept garbage).
  """
  @spec update_status(t(), status()) :: {:ok, t()} | {:error, :invalid_status}
  def update_status(%__MODULE__{} = finding, status) when status in @valid_statuses do
    {:ok, %{finding | status: status}}
  end

  def update_status(%__MODULE__{}, _status), do: {:error, :invalid_status}

  @doc """
  Marks a finding as a false positive with a human note. Feeds the detector
  feedback channel (the note is preserved for detector tuning).
  """
  @spec mark_false_positive(t(), String.t() | nil) :: t()
  def mark_false_positive(%__MODULE__{} = finding, note \\ nil) do
    %{finding | status: :false_positive, human_feedback: %{verdict: :false_positive, note: note}}
  end

  @doc """
  Returns true when the finding's location is in security-critical code whose
  remediation must never be auto-merged (the hard cap). Used to clamp
  `actionability.risk_class` to `:high`.
  """
  @spec high_risk_location?(t()) :: boolean()
  def high_risk_location?(%__MODULE__{} = finding) do
    file = finding.location[:file] || finding.location["file"] || ""
    Enum.any?(@high_risk_path_markers, &String.contains?(file, &1))
  end

  @doc """
  Renders a finding as a roadmap-inbox markdown projection (the human view).

  Pure formatting — the `show` step of the CRC pattern.
  """
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%__MODULE__{} = finding) do
    loc = finding.location
    file = loc[:file] || loc["file"] || "(unknown)"
    line = loc[:line] || loc[:line_range] || loc["line"] || "?"
    sev = finding.severity[:level] || finding.severity["level"] || :medium

    """
    # [#{sev}] #{finding.title}

    - **id:** `#{finding.id}`
    - **category:** `#{finding.category}`
    - **status:** `#{finding.status}`
    - **location:** `#{file}:#{line}`#{function_suffix(loc)}
    - **detected_at:** #{finding.detected_at && DateTime.to_iso8601(finding.detected_at)}
    - **detector:** #{format_detector(finding.detector)}

    ## Invariant violated
    #{finding.invariant_violated || "(not specified)"}

    ## Recommendation
    #{finding.recommendation[:approach] || finding.recommendation["approach"] || "(none yet)"}

    ## Verification
    - must fail on revert of fix alone: #{finding.verification[:must_fail_on_revert] != false}
    - risk class: #{finding.actionability[:risk_class] || :high}
    """
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp normalize_path(""), do: ""

  defp normalize_path(path) when is_binary(path) do
    # Make the key stable across absolute/relative roots — keep the repo-
    # relative tail from "apps/" onward when present.
    case String.split(path, "apps/", parts: 2) do
      [_, tail] -> "apps/" <> tail
      [only] -> only
    end
  end

  defp function_suffix(loc) do
    case loc[:function] || loc["function"] do
      nil -> ""
      fun -> " in `#{fun}`"
    end
  end

  defp format_detector(%{} = d) when map_size(d) > 0 do
    name = d[:name] || d["name"] || "?"
    layer = d[:layer] || d["layer"] || "?"
    "#{name} (#{layer})"
  end

  defp format_detector(_), do: "(unknown)"
end

defimpl Jason.Encoder, for: Arbor.Contracts.Security.Finding do
  def encode(finding, opts) do
    finding
    |> Map.from_struct()
    |> Map.update(:detected_at, nil, &datetime_to_string/1)
    |> Jason.Encode.map(opts)
  end

  defp datetime_to_string(nil), do: nil
  defp datetime_to_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
