defmodule Mix.Tasks.Arbor.Security.Scan do
  @shortdoc "Run the Security Sentinel's static detectors and record findings"

  @moduledoc """
  Run the Security Sentinel L0 static detectors over the umbrella (or a subset)
  and record any findings.

  This is the human / CI / diff trigger for the Sentinel's static-analysis pass.
  It does NOT start the application — it only reads source and writes finding
  files — so it is safe to run alongside a live server.

      # Scan the whole umbrella
      mix arbor.security.scan

      # Scan specific paths
      mix arbor.security.scan apps/arbor_gateway/lib apps/arbor_ai/lib

      # Scan only files changed vs a base ref (diff trigger)
      mix arbor.security.scan --changed --base main

      # Dry run — report without writing finding files / emitting signals
      mix arbor.security.scan --no-record

  ## Options

    * `--changed`        — scan only `.ex` files changed vs `--base`
    * `--base REF`       — base ref for `--changed` (default: `HEAD`)
    * `--output-dir DIR` — finding directory (default `.arbor/security/findings`)
    * `--no-record`      — dry run; don't write files or emit signals

  Exits with status 1 when findings are recorded, so CI can gate on it.
  """

  use Mix.Task

  alias Arbor.Actions.Security.{Recorder, StaticScan, WholeTreeScan}

  @switches [
    changed: :boolean,
    base: :string,
    output_dir: :string,
    record: :boolean,
    whole_tree: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    # Compile but do NOT start the app — scanning needs no supervision tree.
    Mix.Task.run("compile")

    {opts, paths, _} = OptionParser.parse(argv, switches: @switches)

    targets = resolve_targets(opts, paths)
    git_sha = current_git_sha()
    dir = Keyword.get(opts, :output_dir, ".arbor/security/findings")
    record? = Keyword.get(opts, :record, true)

    # Detect first (record: false), then record the combined set once so static
    # (per-file) and whole-tree (cross-file) findings share one dedup + summary.
    static = StaticScan.scan(targets, record: false, git_sha: git_sha) |> elem(0)

    whole_tree =
      if Keyword.get(opts, :whole_tree, true) do
        WholeTreeScan.scan(record: false, git_sha: git_sha) |> elem(0)
      else
        []
      end

    findings = Enum.uniq_by(static ++ whole_tree, & &1.id)
    {_outcomes, summary} = Recorder.record_all(findings, record?, dir)

    report(findings, summary)

    # Gate only on UNRESOLVED findings — new, refreshed-open, or regressed.
    # Already-triaged (wontfix / false_positive / accepted) ones are suppressed
    # and must not fail CI.
    if record? and unresolved_count(summary) > 0 do
      exit({:shutdown, 1})
    end
  end

  defp unresolved_count(%{by_outcome: outcomes}) do
    Map.get(outcomes, :recorded, 0) + Map.get(outcomes, :updated, 0) +
      Map.get(outcomes, :reopened, 0)
  end

  defp unresolved_count(_), do: 0

  defp resolve_targets(opts, paths) do
    cond do
      opts[:changed] -> changed_files(opts[:base] || "HEAD")
      paths != [] -> paths
      true -> Path.wildcard("apps/*/lib")
    end
  end

  defp changed_files(base) do
    case System.cmd("git", ["diff", "--name-only", base], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&(String.ends_with?(&1, ".ex") and String.contains?(&1, "/lib/")))
        |> Enum.filter(&File.regular?/1)

      _ ->
        Mix.shell().error("git diff failed; scanning nothing for --changed")
        []
    end
  end

  defp current_git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp report([], _summary) do
    Mix.shell().info("Security Sentinel: no findings. ✓")
  end

  defp report(findings, summary) do
    Mix.shell().info("Security Sentinel: #{summary.total} finding(s) detected")
    Mix.shell().info("  by severity: #{inspect(summary.by_severity)}")
    Mix.shell().info("  by category: #{inspect(summary.by_category)}")

    if summary.recorded_to do
      Mix.shell().info("  outcomes: #{inspect(summary.by_outcome)}")
      Mix.shell().info("  unresolved (gates CI): #{unresolved_count(summary)}")
      Mix.shell().info("  recorded to: #{summary.recorded_to}/")
    end

    Mix.shell().info("")

    Enum.each(findings, fn f ->
      loc = "#{f.location[:file]}:#{f.location[:line]}"
      Mix.shell().info("  [#{f.severity[:level]}] #{loc} (#{f.category}) — #{f.id}")
    end)
  end
end
