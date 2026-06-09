defmodule Arbor.Actions.Security.StaticScan do
  @moduledoc """
  Core of the Security Sentinel's static-analysis pass (Phase 1).

  Runs the `Arbor.Eval.Suites.Security` L0 detectors over one or more paths,
  converts each violation into a structured `Arbor.Contracts.Security.Finding`,
  and (by default) records each finding as a markdown file + emits a
  `security.sentinel_finding` signal.

  This module is the shared engine behind both the `RunStaticDetectors` Jido
  action (so a DOT pipeline / agent can drive it) and the
  `mix arbor.security.scan` task (the human / CI / diff trigger).

  Findings are written to `.arbor/security/findings/<id>.md`. Because the file
  name is the finding's stable `dedup_key`, re-running is idempotent — the same
  issue overwrites its own file rather than spawning duplicates. (Lifecycle
  status tracking via a BufferedStore-backed `FindingStore` is Phase 2.)
  """

  alias Arbor.Actions.Security.FindingStore
  alias Arbor.Contracts.Security.Finding

  @default_output_dir ".arbor/security/findings"

  # Detector name -> Finding category. New L0 detectors register their mapping
  # here as the L3 synthesis loop adds them.
  @category_by_detector %{
    "authorization_smells" => :fail_open_authz
  }

  @invariant_by_category %{
    fail_open_authz:
      "Authorization/verification must FAIL CLOSED — an error or unknown case must deny, never allow."
  }

  # Path fragments whose findings are hard-capped to :high risk (never
  # auto-remediated) — mirrors Finding.high_risk_location?/1.
  @high_risk_markers ["arbor_security", "capability", "trust", "auth"]

  @type summary :: %{
          total: non_neg_integer(),
          by_category: %{optional(atom()) => non_neg_integer()},
          by_severity: %{optional(atom()) => non_neg_integer()},
          by_outcome: %{optional(atom()) => non_neg_integer()},
          recorded_to: String.t() | nil
        }

  @doc """
  Scan `paths` (directories and/or `.ex` files) with the security suite.

  Returns `{findings, summary}`. Records findings to disk + emits signals unless
  `record: false`.

  ## Options

    * `:record` — write finding files + emit signals (default `true`)
    * `:output_dir` — finding directory (default `#{@default_output_dir}`)
    * `:git_sha` — recorded on each finding for provenance
  """
  @spec scan(String.t() | [String.t()], keyword()) :: {[Finding.t()], summary()}
  def scan(paths, opts \\ []) do
    record? = Keyword.get(opts, :record, true)
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    git_sha = Keyword.get(opts, :git_sha)

    findings =
      paths
      |> List.wrap()
      |> Enum.flat_map(&scan_path(&1, git_sha))
      |> Enum.uniq_by(& &1.id)

    outcomes = if record?, do: Enum.map(findings, &record(&1, output_dir)), else: []

    {findings, summarize(findings, outcomes, record?, output_dir)}
  end

  @doc """
  Records a single finding through the status-aware `FindingStore`, emitting a
  `security.sentinel_finding` signal only for genuinely NEW or REGRESSED
  findings (suppressed/refreshed ones stay quiet). Returns the store outcome.
  """
  @spec record(Finding.t(), String.t()) :: FindingStore.record_outcome()
  def record(%Finding{} = finding, output_dir \\ @default_output_dir) do
    outcome = FindingStore.record(finding, output_dir)

    case outcome do
      {:recorded, f} -> emit_signal(f, Path.join(output_dir, f.id <> ".md"))
      {:reopened, f} -> emit_signal(f, Path.join(output_dir, f.id <> ".md"))
      _suppressed_or_updated -> :ok
    end

    outcome
  end

  # ---------------------------------------------------------------------------
  # Scan → findings
  # ---------------------------------------------------------------------------

  defp scan_path(path, git_sha) do
    result =
      cond do
        File.dir?(path) -> Arbor.Eval.Suites.Security.check_directory(path)
        File.regular?(path) -> Arbor.Eval.Suites.Security.check_files([path])
        true -> {:error, {:not_found, path}}
      end

    case result do
      {:ok, suite_result} -> findings_from_result(suite_result, git_sha)
      {:error, _} -> []
    end
  end

  defp findings_from_result(suite_result, git_sha) do
    for file_result <- suite_result.file_results,
        eval_result <- file_result.results,
        violation <- eval_result.violations,
        violation.severity in [:warning, :error] do
      finding_from_violation(file_result.file, eval_result, violation, git_sha)
    end
  end

  defp finding_from_violation(file, eval_result, violation, git_sha) do
    category = Map.get(@category_by_detector, eval_result.name, :other)

    Finding.new(
      category: category,
      title: violation.message,
      git_sha: git_sha,
      detector: %{layer: "L0", name: eval_result.name, version: "1"},
      severity: %{level: severity_level(violation.severity)},
      confidence: %{score: 0.8, rationale: "static AST match (#{violation.type})"},
      location: %{
        library: library_of(file),
        file: file,
        line: violation.line,
        function: violation[:function]
      },
      invariant_violated: Map.get(@invariant_by_category, category),
      evidence: %{smell_match: violation.type},
      recommendation: %{approach: violation[:suggestion]},
      actionability: %{auto_fixable: false, risk_class: risk_class(file)},
      verification: %{must_fail_on_revert: true}
    )
  end

  defp severity_level(:error), do: :high
  defp severity_level(:warning), do: :medium
  defp severity_level(_), do: :low

  defp risk_class(file) do
    if Enum.any?(@high_risk_markers, &String.contains?(file, &1)), do: :high, else: :medium
  end

  defp library_of(file) do
    case Regex.run(~r{apps/([^/]+)/}, file) do
      [_, lib] -> lib
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Record side-effects
  # ---------------------------------------------------------------------------

  defp emit_signal(finding, path) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 4) do
      apply(Arbor.Signals, :emit, [
        :security,
        :sentinel_finding,
        %{
          id: finding.id,
          category: finding.category,
          severity: finding.severity[:level],
          file: finding.location[:file],
          line: finding.location[:line],
          path: path
        },
        []
      ])
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp summarize(findings, outcomes, record?, output_dir) do
    %{
      total: length(findings),
      by_category: count_by(findings, & &1.category),
      by_severity: count_by(findings, &(&1.severity[:level] || :unknown)),
      by_outcome: count_by(outcomes, &elem(&1, 0)),
      recorded_to: if(record?, do: output_dir)
    }
  end

  defp count_by(findings, fun) do
    findings |> Enum.group_by(fun) |> Map.new(fn {k, v} -> {k, length(v)} end)
  end
end
