defmodule Arbor.Trust.ProfileExitAudit do
  @moduledoc """
  Ring A exit-gate audit for trust profiles.

  The Ring A authorization-model rework forbids legacy permissive baselines
  (`:auto`/`:allow`) and requires autonomous auto/allow standing to have an
  explicit capability bundle before agents restart. This module keeps that gate
  repeatable for live nodes and offline diagnostics.
  """

  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.{Authority, Store}

  @type rule_finding :: %{
          required(:uri) => String.t(),
          required(:mode) => :allow | :auto,
          required(:suggested_capability) => String.t(),
          optional(:capability_error) => term()
        }

  @type profile_finding :: %{
          required(:agent_id) => String.t(),
          required(:baseline) => atom(),
          required(:legacy_baseline) => boolean(),
          required(:mint_reliant_rules) => [rule_finding()]
        }

  @type audit_result :: %{
          required(:generated_at) => String.t(),
          required(:clean) => boolean(),
          required(:counts) => map(),
          required(:findings) => [profile_finding()]
        }

  @legacy_baselines [:allow, :auto]
  @autonomous_modes [:allow, :auto]
  @default_limit 10_000

  @doc """
  Audit profiles currently loaded in `Arbor.Trust.Store`.

  Options:

    * `:limit` - maximum profiles to read from the store. Defaults to 10,000.
  """
  @spec audit(keyword()) :: {:ok, audit_result()} | {:error, term()}
  def audit(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, profiles} <- Store.list_profiles(limit: limit) do
      {:ok, audit_profiles(profiles, &list_capabilities/1)}
    end
  end

  @doc """
  Audit a provided profile set with an injected capability lookup.

  Kept public for deterministic tests and dry-run tooling.
  """
  @spec audit_profiles([Profile.t()], (String.t() -> {:ok, [map()]} | {:error, term()})) ::
          audit_result()
  def audit_profiles(profiles, caps_lookup)
      when is_list(profiles) and is_function(caps_lookup, 1) do
    findings =
      profiles
      |> Enum.map(&audit_profile(&1, caps_lookup))
      |> Enum.reject(&clean_profile?/1)

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      clean: findings == [],
      counts: counts(profiles, findings),
      findings: findings
    }
  end

  @doc """
  Migrate loaded profiles for the Ring A exit gate.

  By default this only normalizes legacy permissive baselines to `:ask`.
  Pass `grant_missing: true` to also grant explicit capabilities derived from
  auto/allow URI-prefix rules that have no equivalent held capability. If a
  profile cannot receive a capability because its principal ID is invalid, the
  rule is demoted to `:ask` so stale non-agent profiles cannot keep autonomous
  standing.

  Options:

    * `:baseline` - `:ask` or `:block` for legacy baselines. Defaults to `:ask`.
    * `:grant_missing` - whether to grant missing explicit rule capabilities.
    * `:limit` - maximum profiles to read from the store. Defaults to 10,000.
  """
  @spec migrate(keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(opts \\ []) do
    baseline = migration_baseline(Keyword.get(opts, :baseline, :ask))
    grant_missing? = Keyword.get(opts, :grant_missing, false)

    with {:ok, before_audit} <- audit(opts) do
      baseline_migrations = migrate_baselines(before_audit.findings, baseline)
      grants = maybe_grant_missing(before_audit.findings, grant_missing?)

      with {:ok, after_audit} <- audit(opts) do
        {:ok,
         %{
           generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           baseline: baseline,
           grant_missing: grant_missing?,
           before: before_audit,
           baseline_migrations: baseline_migrations,
           grants: grants,
           after: after_audit,
           errors: migration_errors(baseline_migrations, grants)
         }}
      end
    end
  end

  @doc """
  Convert a trust URI-prefix rule to an equivalent capability URI.

  Trust rules match by prefix. Capabilities require an explicit wildcard for
  subtree reach, so `arbor://fs/read` becomes `arbor://fs/read/**`.
  """
  @spec suggested_capability_uri(String.t()) :: String.t()
  def suggested_capability_uri(uri) when is_binary(uri) do
    uri
    |> canonical_rule_uri()
    |> add_capability_wildcard()
  end

  defp audit_profile(%Profile{} = profile, caps_lookup) do
    autonomous_rules = autonomous_rules(profile.rules || %{})

    {capabilities, capability_error} =
      capabilities_for(profile.agent_id, autonomous_rules, caps_lookup)

    %{
      agent_id: profile.agent_id,
      baseline: Authority.normalize_mode(profile.baseline),
      legacy_baseline: legacy_baseline?(profile.baseline),
      mint_reliant_rules:
        Enum.flat_map(autonomous_rules, fn {uri, mode} ->
          audit_rule(uri, mode, capabilities, capability_error)
        end)
    }
  end

  defp autonomous_rules(rules) when is_map(rules) do
    rules
    |> Enum.map(fn {uri, mode} -> {to_string(uri), Authority.normalize_mode(mode)} end)
    |> Enum.filter(fn {uri, mode} -> uri != "" and mode in @autonomous_modes end)
    |> Enum.sort_by(fn {uri, _mode} -> uri end)
  end

  defp autonomous_rules(_rules), do: []

  defp capabilities_for(_agent_id, [], _caps_lookup), do: {[], nil}

  defp capabilities_for(agent_id, _rules, caps_lookup) do
    case caps_lookup.(agent_id) do
      {:ok, caps} -> {caps, nil}
      {:error, reason} -> {[], reason}
    end
  end

  defp audit_rule(uri, mode, capabilities, nil) do
    suggested = suggested_capability_uri(uri)

    if Enum.any?(capabilities, &Arbor.Security.capability_authorizes?(&1, suggested)) do
      []
    else
      [%{uri: canonical_rule_uri(uri), mode: mode, suggested_capability: suggested}]
    end
  end

  defp audit_rule(uri, mode, _capabilities, capability_error) do
    [
      %{
        uri: canonical_rule_uri(uri),
        mode: mode,
        suggested_capability: suggested_capability_uri(uri),
        capability_error: capability_error
      }
    ]
  end

  defp clean_profile?(finding) do
    not finding.legacy_baseline and finding.mint_reliant_rules == []
  end

  defp counts(profiles, findings) do
    %{
      profiles: length(profiles),
      profiles_with_findings: length(findings),
      legacy_baselines: Enum.count(findings, & &1.legacy_baseline),
      mint_reliant_rules:
        findings
        |> Enum.map(&length(&1.mint_reliant_rules))
        |> Enum.sum()
    }
  end

  defp migrate_baselines(findings, baseline) do
    findings
    |> Enum.filter(& &1.legacy_baseline)
    |> Enum.map(fn finding ->
      case Store.update_profile(finding.agent_id, fn profile ->
             %{profile | baseline: baseline}
           end) do
        {:ok, _profile} ->
          %{agent_id: finding.agent_id, status: :ok, baseline: baseline}

        {:error, reason} ->
          %{agent_id: finding.agent_id, status: :error, reason: reason, baseline: baseline}
      end
    end)
  end

  defp maybe_grant_missing(_findings, false), do: []

  defp maybe_grant_missing(findings, true) do
    for finding <- findings,
        rule <- finding.mint_reliant_rules do
      grant_missing(finding.agent_id, rule)
    end
  end

  defp grant_missing(agent_id, rule) do
    grant_opts = [
      principal: agent_id,
      resource: rule.suggested_capability,
      metadata: %{
        source: :trust_profile_exit_migration,
        trust_rule_uri: rule.uri,
        trust_rule_mode: rule.mode,
        migrated_at: DateTime.utc_now()
      }
    ]

    case Arbor.Security.grant(grant_opts) do
      {:ok, cap} ->
        %{
          agent_id: agent_id,
          status: :ok,
          capability_id: cap.id,
          resource_uri: cap.resource_uri,
          rule_uri: rule.uri,
          mode: rule.mode
        }

      {:error, {:invalid_principal_id, _principal} = reason} ->
        demote_ungrantable_rule(agent_id, rule, reason)

      {:error, reason} ->
        grant_error(agent_id, rule, reason)
    end
  end

  defp demote_ungrantable_rule(agent_id, rule, reason) do
    case Store.update_profile(agent_id, fn profile ->
           %{profile | rules: demote_rule(profile.rules || %{}, rule.uri)}
         end) do
      {:ok, _profile} ->
        %{
          agent_id: agent_id,
          status: :demoted,
          reason: reason,
          resource_uri: rule.suggested_capability,
          rule_uri: rule.uri,
          mode: rule.mode,
          demoted_to: :ask
        }

      {:error, update_reason} ->
        grant_error(agent_id, rule, {:demotion_failed, reason, update_reason})
    end
  end

  defp grant_error(agent_id, rule, reason) do
    %{
      agent_id: agent_id,
      status: :error,
      reason: reason,
      resource_uri: rule.suggested_capability,
      rule_uri: rule.uri,
      mode: rule.mode
    }
  end

  defp demote_rule(rules, canonical_uri) do
    for {uri, mode} <- rules, into: %{} do
      uri = to_string(uri)

      if canonical_rule_uri(uri) == canonical_uri do
        {uri, :ask}
      else
        {uri, mode}
      end
    end
  end

  defp migration_errors(baseline_migrations, grants) do
    (baseline_migrations ++ grants)
    |> Enum.filter(&(Map.get(&1, :status) == :error))
  end

  defp list_capabilities(agent_id) do
    Arbor.Security.list_capabilities(agent_id)
  rescue
    _ -> {:error, :capability_store_unavailable}
  catch
    :exit, _ -> {:error, :capability_store_unavailable}
  end

  defp legacy_baseline?(baseline), do: Authority.normalize_mode(baseline) in @legacy_baselines

  defp migration_baseline(mode) when mode in [:ask, "ask"], do: :ask
  defp migration_baseline(mode) when mode in [:block, "block"], do: :block
  defp migration_baseline(_mode), do: :ask

  defp canonical_rule_uri(uri) do
    uri
    |> String.trim()
    |> String.replace_suffix("/**", "")
    |> String.replace_suffix("/*", "")
  end

  defp add_capability_wildcard("arbor://**"), do: "arbor://**"
  defp add_capability_wildcard(uri), do: uri <> "/**"
end
