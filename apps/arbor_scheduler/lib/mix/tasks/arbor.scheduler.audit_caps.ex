defmodule Mix.Tasks.Arbor.Scheduler.AuditCaps do
  @shortdoc "List scheduler .caps.json files and their load status"

  @moduledoc """
  Scan a directory of scheduler pipelines and report the load status of
  each `.caps.json` file.

  Phase 4 of the scheduler-privesc redesign. Operational tool for
  validating that every signed caps file in a pipeline tree still loads —
  catches drift between enrolled issuers and shipped pipeline declarations
  (e.g., an issuer was revoked but their `.caps.json` files are still in
  the tree; or someone added a new pipeline DOT without the matching caps
  file).

  ## Usage

      mix arbor.scheduler.audit_caps
      mix arbor.scheduler.audit_caps --pipelines-dir apps/arbor_scheduler/priv/pipelines
      mix arbor.scheduler.audit_caps --local

  ## Options

    * `--pipelines-dir <path>` — directory to scan (default:
      `apps/arbor_scheduler/priv/pipelines`)
    * `--format <human|json>` — output format (default: human)
    * `--local` — scan in this Mix process instead of RPCing into the
      running Arbor server. Intended for tests/offline diagnostics.

  By default this task does **not** start the Arbor application locally. It
  connects to the running development server and executes the audit there, so
  verification uses the live identity/issuer registry state.

  ## What it reports

  For each `.dot` file found, looks for a sibling `.caps.json` and reports:

    - `ok` — caps file loads cleanly; declared caps are inside issuer's
      envelope and signature verifies
    - `missing` — `.dot` exists but no `.caps.json` (the pipeline won't
      get any caps granted; file_write etc. will hit approval gates)
    - `{:error, reason}` — caps file exists but fails CapsFile.load
      verification; the inspect-printed reason names the failure mode
      (`:issuer_not_found`, `:issuer_revoked`, `:invalid_signature`,
      `{:cap_exceeds_envelope, uri}`, etc.)

  Exit code: 0 if all pipelines OK or missing-but-unsigned, 1 if any
  caps file fails to load.
  """

  use Mix.Task

  alias Arbor.Scheduler.CapsAudit
  alias Mix.Tasks.Arbor.Helpers, as: ArborServer

  @default_dir "apps/arbor_scheduler/priv/pipelines"

  @impl true
  def run(args) do
    {opts, _positional, _} =
      OptionParser.parse(args,
        strict: [pipelines_dir: :string, format: :string, local: :boolean],
        aliases: [d: :pipelines_dir, f: :format]
      )

    dir = Keyword.get(opts, :pipelines_dir, @default_dir)
    format = Keyword.get(opts, :format, "human")
    local? = Keyword.get(opts, :local, false)

    {source, scan_result} = run_scan(dir, local?)

    case scan_result do
      {:ok, results} ->
        case format do
          "json" -> emit_json(results)
          _ -> emit_human(dir, source, results)
        end

        if CapsAudit.errors?(results) do
          exit({:shutdown, 1})
        end

      {:error, {:read_failed, failed_dir, reason}} ->
        Mix.shell().error("Failed to read #{failed_dir}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp run_scan(dir, true) do
    Mix.Task.run("app.start")
    {"local", CapsAudit.scan(dir)}
  end

  defp run_scan(dir, false) do
    ArborServer.ensure_distribution()

    if ArborServer.server_running?() do
      node = ArborServer.full_node_name()
      {"rpc #{node}", ArborServer.rpc!(node, CapsAudit, :scan, [dir])}
    else
      Mix.shell().error("""
      Arbor server is not running. Start it first:

          mix arbor.start

      Or pass --local to scan in this Mix process.
      """)

      exit({:shutdown, 1})
    end
  end

  defp emit_human(dir, source, []) do
    Mix.shell().info("No pipelines found in #{dir} (#{source})")
  end

  defp emit_human(dir, source, results) do
    Mix.shell().info("Scheduler pipeline caps audit — #{dir} (#{source})")
    Mix.shell().info(String.duplicate("─", 60))

    for {base, status} <- results do
      label = String.pad_trailing(base, 36)

      case status do
        {:ok, caps} ->
          Mix.shell().info("  #{label} ✓ ok (#{length(caps)} caps)")

        :missing ->
          Mix.shell().info("  #{label} ◌ missing (.caps.json not present)")

        {:error, reason} ->
          Mix.shell().error("  #{label} ✗ #{inspect(reason)}")
      end
    end

    %{ok: ok, missing: missing, error: errors} = CapsAudit.counts(results)

    Mix.shell().info(String.duplicate("─", 60))

    Mix.shell().info(
      "Total: #{length(results)} pipeline(s) — ok=#{ok}, missing=#{missing}, error=#{errors}"
    )
  end

  defp emit_json(results) do
    payload =
      Enum.map(results, fn
        {base, {:ok, caps}} -> %{pipeline: base, status: "ok", caps_count: length(caps)}
        {base, :missing} -> %{pipeline: base, status: "missing"}
        {base, {:error, reason}} -> %{pipeline: base, status: "error", reason: inspect(reason)}
      end)

    Mix.shell().info(Jason.encode!(payload, pretty: true))
  end
end
