defmodule Mix.Tasks.Arbor.Trust.AuditProfiles do
  @shortdoc "Audit/migrate trust profiles for the Ring A authorization exit gate"

  @moduledoc """
  Audit trust profiles before restarting agents after the Ring A authorization
  model rework.

  ## Usage

      mix arbor.trust.audit_profiles
      mix arbor.trust.audit_profiles --local
      mix arbor.trust.audit_profiles --migrate --grant-missing
      mix arbor.trust.audit_profiles --migrate --baseline block
      mix arbor.trust.audit_profiles --format json
      mix arbor.trust.audit_profiles --verbose

  ## Options

    * `--format <human|json>` - output format. Defaults to `human`.
    * `--limit <n>` - maximum profiles to scan. Defaults to 10,000.
    * `--findings-limit <n>` - maximum findings to print in human mode unless
      `--verbose` is passed. Defaults to 20.
    * `--local` - run in this Mix process instead of RPCing into the running
      Arbor server. Intended for tests/offline diagnostics.
    * `--migrate` - normalize legacy permissive baselines to the selected
      baseline.
    * `--baseline <ask|block>` - migration target for legacy baselines. Defaults
      to `ask`.
    * `--grant-missing` - with `--migrate`, grant explicit capabilities for
      auto/allow URI-prefix rules that currently rely on policy JIT minting.
    * `--verbose` - print every profile finding in human mode.

  By default this task does not start Arbor locally. It RPCs into the running
  server so the audit observes live trust profiles and capability stores. Use
  `--local` only when the server is stopped or for offline diagnostics.

  Exit code: 0 when the post-operation audit is clean, 1 when findings or
  migration errors remain.
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: ArborServer

  @default_limit 10_000

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          format: :string,
          limit: :integer,
          findings_limit: :integer,
          local: :boolean,
          migrate: :boolean,
          baseline: :string,
          grant_missing: :boolean,
          verbose: :boolean
        ],
        aliases: [f: :format]
      )

    format = Keyword.get(opts, :format, "human")
    local? = Keyword.get(opts, :local, false)
    migrate? = Keyword.get(opts, :migrate, false)

    output_opts = [
      verbose: Keyword.get(opts, :verbose, false),
      findings_limit: findings_limit(opts)
    ]

    if local? and format != "json" do
      Logger.configure(level: :warning)
    end

    audit_opts = [
      limit: Keyword.get(opts, :limit, @default_limit),
      baseline: Keyword.get(opts, :baseline, "ask"),
      grant_missing: Keyword.get(opts, :grant_missing, false)
    ]

    {source, result} = run_gate(migrate?, audit_opts, local?)

    case result do
      {:ok, payload} ->
        emit(format, source, migrate?, payload, output_opts)

        unless clean_result?(migrate?, payload) do
          exit({:shutdown, 1})
        end

      {:error, reason} ->
        Mix.shell().error("Trust profile audit failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp run_gate(migrate?, opts, true) do
    {:ok, _apps} = Application.ensure_all_started(:arbor_trust)
    {"local", call_gate(migrate?, opts)}
  end

  defp run_gate(migrate?, opts, false) do
    ArborServer.ensure_distribution()

    if ArborServer.server_running?() do
      node = ArborServer.full_node_name()
      {"rpc #{node}", ArborServer.rpc!(node, Arbor.Trust, gate_fun(migrate?), [opts])}
    else
      Mix.shell().error("""
      Arbor server is not running. Start it first:

          mix arbor.start

      Or pass --local to scan in this Mix process.
      """)

      exit({:shutdown, 1})
    end
  end

  defp call_gate(false, opts), do: Arbor.Trust.audit_profile_exit_gate(opts)
  defp call_gate(true, opts), do: Arbor.Trust.migrate_profile_exit_gate(opts)

  defp gate_fun(false), do: :audit_profile_exit_gate
  defp gate_fun(true), do: :migrate_profile_exit_gate

  defp emit("json", source, action?, payload, _output_opts) do
    Mix.shell().info(
      Jason.encode!(%{source: source, action: action_name(action?), result: payload},
        pretty: true
      )
    )
  end

  defp emit(_format, source, false, audit, output_opts) do
    Mix.shell().info("Trust profile exit-gate audit (#{source})")
    emit_audit_summary(audit)
    emit_findings(audit.findings, output_opts)
  end

  defp emit(_format, source, true, result, output_opts) do
    Mix.shell().info("Trust profile exit-gate migration (#{source})")
    Mix.shell().info("Before:")
    emit_audit_summary(result.before)

    emit_baseline_migrations(result.baseline_migrations, output_opts)
    emit_grants(result.grants, result.grant_missing, output_opts)

    Mix.shell().info("After:")
    emit_audit_summary(result.after)
    emit_findings(result.after.findings, output_opts)

    if result.errors != [] do
      Mix.shell().error("Migration errors:")

      for error <- result.errors do
        Mix.shell().error("  #{error.agent_id}: #{inspect(error.reason)}")
      end
    end
  end

  defp emit_audit_summary(audit) do
    counts = audit.counts

    Mix.shell().info(
      "  profiles=#{counts.profiles} findings=#{counts.profiles_with_findings} " <>
        "legacy_baselines=#{counts.legacy_baselines} " <>
        "mint_reliant_rules=#{counts.mint_reliant_rules}"
    )

    if audit.clean do
      Mix.shell().info("  OK: no legacy permissive baselines or auto/allow mint-reliant rules")
    end
  end

  defp emit_findings([], _output_opts), do: :ok

  defp emit_findings(findings, output_opts) do
    Mix.shell().info("Findings:")

    visible_findings = visible_findings(findings, output_opts)

    for finding <- visible_findings do
      Mix.shell().info("  #{finding.agent_id} baseline=#{finding.baseline}")

      if finding.legacy_baseline do
        Mix.shell().info("    legacy permissive baseline: migrate to :ask or :block")
      end

      for rule <- finding.mint_reliant_rules do
        extra =
          case Map.fetch(rule, :capability_error) do
            {:ok, reason} -> " capability_lookup=#{inspect(reason)}"
            :error -> ""
          end

        Mix.shell().info(
          "    #{rule.mode} #{rule.uri} missing explicit cap #{rule.suggested_capability}" <>
            extra
        )
      end
    end

    remaining = length(findings) - length(visible_findings)

    if remaining > 0 do
      Mix.shell().info(
        "  ... #{remaining} more finding(s); rerun with --verbose or --format json"
      )
    end
  end

  defp emit_baseline_migrations([], _output_opts),
    do: Mix.shell().info("Baseline migrations: none")

  defp emit_baseline_migrations(results, output_opts) do
    %{ok: ok, error: error} = status_counts(results)
    Mix.shell().info("Baseline migrations: ok=#{ok} error=#{error}")

    visible_results = visible_findings(results, output_opts)

    for result <- visible_results do
      case result.status do
        :ok -> Mix.shell().info("  #{result.agent_id}: baseline=#{result.baseline}")
        :error -> Mix.shell().error("  #{result.agent_id}: #{inspect(result.reason)}")
      end
    end

    emit_remaining_count(results, visible_results)
  end

  defp emit_grants([], false, _output_opts), do: Mix.shell().info("Capability grants: skipped")
  defp emit_grants([], true, _output_opts), do: Mix.shell().info("Capability grants: none")

  defp emit_grants(grants, _grant_missing?, output_opts) do
    %{ok: ok, demoted: demoted, error: error} = status_counts(grants)
    Mix.shell().info("Capability grants: ok=#{ok} demoted=#{demoted} error=#{error}")

    visible_grants = visible_findings(grants, output_opts)

    for grant <- visible_grants do
      case grant.status do
        :ok ->
          Mix.shell().info("  #{grant.agent_id}: #{grant.resource_uri} (#{grant.capability_id})")

        :demoted ->
          Mix.shell().info(
            "  #{grant.agent_id}: demoted #{grant.rule_uri} to #{grant.demoted_to} " <>
              "(grant failed: #{inspect(grant.reason)})"
          )

        :error ->
          Mix.shell().error("  #{grant.agent_id}: #{grant.resource_uri} #{inspect(grant.reason)}")
      end
    end

    emit_remaining_count(grants, visible_grants)
  end

  defp clean_result?(false, audit), do: audit.clean
  defp clean_result?(true, result), do: result.after.clean and result.errors == []

  defp action_name(false), do: "audit"
  defp action_name(true), do: "migrate"

  defp findings_limit(opts), do: Keyword.get(opts, :findings_limit, 20)

  defp visible_findings(findings, output_opts) do
    if Keyword.get(output_opts, :verbose, false) do
      findings
    else
      Enum.take(findings, Keyword.fetch!(output_opts, :findings_limit))
    end
  end

  defp status_counts(results) do
    Enum.reduce(results, %{ok: 0, demoted: 0, error: 0}, fn result, counts ->
      Map.update!(counts, Map.get(result, :status, :error), &(&1 + 1))
    end)
  end

  defp emit_remaining_count(results, visible_results) do
    remaining = length(results) - length(visible_results)

    if remaining > 0 do
      Mix.shell().info("  ... #{remaining} more result(s); rerun with --verbose or --format json")
    end
  end
end
