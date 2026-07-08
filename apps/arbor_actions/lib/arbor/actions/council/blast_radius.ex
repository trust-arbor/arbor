defmodule Arbor.Actions.Council.BlastRadius do
  @moduledoc """
  Pure tiering rules for council-reviewed code changes.

  The council can recommend that a change is safe to keep, but it is not the
  merge authority for high-blast-radius paths or for changes to its own gates.
  This module keeps that policy as a testable functional core. Callers may pass
  a policy map or a capability-profile lookup in opts; the defaults mirror the
  coding-agent review-loop spec.
  """

  alias Arbor.Contracts.Judge.Verdict
  alias Arbor.Contracts.Security.CapabilityProfile

  @policy_keys [
    :high_risk_prefixes,
    :high_risk_paths,
    :authority_surface_paths,
    :authority_surface_prefixes
  ]

  @type blast_radius :: :low | :high
  @type recommendation :: :keep | :revise | :reject
  @type route_action :: :auto_proceed | :human_review | :rework | :stop

  @type classification :: %{
          required(:blast_radius) => blast_radius(),
          required(:files) => [String.t()],
          required(:reasons) => [atom()],
          required(:authority_widening) => boolean()
        }

  @type route :: %{
          required(:action) => route_action(),
          required(:blast_radius) => blast_radius(),
          required(:recommendation) => recommendation(),
          required(:human_required) => boolean(),
          required(:security_veto) => boolean(),
          required(:authority_widening) => boolean(),
          required(:reasons) => [atom()]
        }

  @doc "Default file-path policy for the coding-agent review loop."
  @spec default_policy() :: map()
  def default_policy do
    %{
      high_risk_prefixes: [
        {"apps/arbor_security/", :security_app},
        {"apps/arbor_trust/", :trust_app},
        {"apps/arbor_contracts/", :contracts_app},
        {"apps/arbor_orchestrator/lib/arbor/orchestrator/engine", :dot_engine}
      ],
      high_risk_paths: [
        {"apps/arbor_agent/priv/templates/coding_agent.md", :coding_agent_manifest}
      ],
      authority_surface_paths: [
        {"apps/arbor_agent/priv/templates/coding_agent.md", :coding_agent_manifest},
        {"apps/arbor_agent/priv/templates/code_reviewer.md", :code_reviewer_manifest},
        {"apps/arbor_agent/priv/templates/council_evaluator.md", :council_evaluator_manifest},
        {"apps/arbor_orchestrator/specs/pipelines/code-review-council.dot",
         :code_review_council_dot},
        {"apps/arbor_actions/lib/arbor/actions/council.ex", :code_review_action_gate},
        {"apps/arbor_actions/lib/arbor/actions/council/blast_radius.ex", :tiering_policy}
      ],
      authority_surface_prefixes: [
        {"apps/arbor_security/", :security_authority_surface},
        {"apps/arbor_trust/", :trust_authority_surface},
        {"apps/arbor_contracts/lib/arbor/contracts/security/", :security_contract_surface}
      ]
    }
  end

  @doc "Return only the low/high blast-radius tier for a changed file list."
  @spec blast_radius([String.t()] | String.t(), keyword() | map()) :: blast_radius()
  def blast_radius(files, opts \\ []) do
    files
    |> classify(opts)
    |> Map.fetch!(:blast_radius)
  end

  @doc "Classify changed files and explain the path/profile reasons."
  @spec classify([String.t()] | String.t(), keyword() | map()) :: classification()
  def classify(files, opts \\ []) do
    policy = policy(opts)
    profile_lookup = option(opts, :capability_profile_for_path, nil)

    normalized_files =
      files
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&normalize_path/1)
      |> Enum.reject(&(&1 == ""))

    risk_reasons =
      normalized_files
      |> Enum.flat_map(&risk_reasons(&1, policy, profile_lookup))
      |> Enum.uniq()

    authority_reasons =
      normalized_files
      |> Enum.flat_map(&authority_reasons(&1, policy))
      |> Enum.uniq()

    reasons = Enum.uniq(risk_reasons ++ authority_reasons)

    authority_widening =
      truthy?(option(opts, :authority_widening?, false)) || authority_reasons != []

    blast_radius = if reasons == [], do: :low, else: :high

    %{
      blast_radius: blast_radius,
      files: normalized_files,
      reasons: reasons,
      authority_widening: authority_widening
    }
  end

  @doc """
  Route a verdict plus file classification to the next workflow action.

  `:keep` can auto-proceed only for low-risk changes with no security veto and
  no self-authority surface. `:revise` returns to the agent, and `:reject`
  stops unless a hard carve-out requires human review.
  """
  @spec route(
          Verdict.t() | recommendation() | map(),
          [String.t()] | String.t(),
          keyword() | map()
        ) ::
          route()
  def route(verdict_or_recommendation, files, opts \\ []) do
    classification = classify(files, opts)
    recommendation = recommendation(verdict_or_recommendation)
    security_veto = truthy?(option(opts, :security_veto?, option(opts, :security_veto, false)))

    action =
      cond do
        security_veto ->
          :human_review

        classification.authority_widening ->
          :human_review

        recommendation == :keep and classification.blast_radius == :high ->
          :human_review

        recommendation == :keep ->
          :auto_proceed

        recommendation == :revise ->
          :rework

        recommendation == :reject ->
          :stop
      end

    %{
      action: action,
      blast_radius: classification.blast_radius,
      recommendation: recommendation,
      human_required: action == :human_review,
      security_veto: security_veto,
      authority_widening: classification.authority_widening,
      reasons: route_reasons(action, classification.reasons, security_veto)
    }
  end

  defp route_reasons(action, reasons, security_veto) do
    []
    |> maybe_cons(action == :human_review, :human_review_required)
    |> maybe_cons(security_veto, :security_veto)
    |> Kernel.++(reasons)
    |> Enum.uniq()
  end

  defp maybe_cons(list, true, item), do: [item | list]
  defp maybe_cons(list, false, _item), do: list

  defp policy(opts) do
    overrides =
      opts
      |> option(:policy, %{})
      |> normalize_policy()

    Map.merge(default_policy(), overrides)
  end

  defp normalize_policy(nil), do: %{}
  defp normalize_policy(policy) when is_map(policy), do: string_key_map(policy)
  defp normalize_policy(policy) when is_list(policy), do: policy |> Map.new() |> string_key_map()
  defp normalize_policy(_policy), do: %{}

  defp risk_reasons(path, policy, profile_lookup) do
    []
    |> Kernel.++(entry_reasons(path, Map.get(policy, :high_risk_prefixes, []), :prefix))
    |> Kernel.++(entry_reasons(path, Map.get(policy, :high_risk_paths, []), :path))
    |> maybe_add_migration_reason(path)
    |> Kernel.++(profile_reasons(path, profile_lookup))
  end

  defp authority_reasons(path, policy) do
    []
    |> Kernel.++(entry_reasons(path, Map.get(policy, :authority_surface_paths, []), :path))
    |> Kernel.++(entry_reasons(path, Map.get(policy, :authority_surface_prefixes, []), :prefix))
  end

  defp entry_reasons(path, entries, mode) do
    entries
    |> List.wrap()
    |> Enum.flat_map(fn entry ->
      {pattern, reason} = normalize_policy_entry(entry)

      if policy_match?(mode, path, pattern) do
        [reason]
      else
        []
      end
    end)
  end

  defp normalize_policy_entry({pattern, reason}), do: {normalize_path(pattern), reason}
  defp normalize_policy_entry(pattern), do: {normalize_path(pattern), :configured_high_risk_path}

  defp policy_match?(:prefix, path, prefix), do: prefix_match?(path, prefix)
  defp policy_match?(:path, path, exact_path), do: path_match?(path, exact_path)

  defp prefix_match?(path, prefix) do
    String.starts_with?(path, prefix) or String.contains?(path, "/" <> prefix)
  end

  defp path_match?(path, exact_path) do
    path == exact_path or String.ends_with?(path, "/" <> exact_path)
  end

  defp maybe_add_migration_reason(reasons, path) do
    if "migrations" in path_segments(path) do
      [:migration | reasons]
    else
      reasons
    end
  end

  defp profile_reasons(_path, nil), do: []

  defp profile_reasons(path, lookup) when is_function(lookup, 1) do
    path
    |> lookup.()
    |> List.wrap()
    |> Enum.flat_map(&profile_reason/1)
  rescue
    _ -> [:capability_profile_lookup_failed]
  catch
    _, _ -> [:capability_profile_lookup_failed]
  end

  defp profile_reasons(_path, _lookup), do: []

  defp profile_reason(%CapabilityProfile{} = profile) do
    profile_reason(%{
      blast_radius: profile.blast_radius,
      reversibility: profile.reversibility
    })
  end

  defp profile_reason(%{} = profile) do
    []
    |> maybe_cons(value(profile, :blast_radius) in [:high, :critical], :capability_profile_high)
    |> maybe_cons(
      value(profile, :reversibility) == :irreversible,
      :capability_profile_irreversible
    )
  end

  defp profile_reason(_profile), do: []

  defp recommendation(%Verdict{recommendation: recommendation}), do: recommendation

  defp recommendation(%{} = map) do
    map
    |> value(:recommendation)
    |> recommendation()
  end

  defp recommendation(recommendation) when recommendation in [:keep, :revise, :reject] do
    recommendation
  end

  defp recommendation(recommendation) when is_binary(recommendation) do
    case recommendation do
      "keep" -> :keep
      "revise" -> :revise
      "reject" -> :reject
      _ -> :reject
    end
  end

  defp recommendation(_), do: :reject

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.trim()
    |> String.trim_leading("./")
  end

  defp normalize_path(path), do: path |> to_string() |> normalize_path()

  defp path_segments(path), do: String.split(path, "/", trim: true)

  defp option(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, Keyword.get(opts, key_without_question_mark(key), default))
  end

  defp option(opts, key, default) when is_map(opts) do
    Map.get(opts, key) ||
      Map.get(opts, Atom.to_string(key)) ||
      Map.get(opts, key_without_question_mark(key)) ||
      Map.get(opts, Atom.to_string(key_without_question_mark(key)), default)
  end

  defp option(_opts, _key, default), do: default

  defp key_without_question_mark(key) do
    key
    |> Atom.to_string()
    |> String.trim_trailing("?")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> key
  end

  defp string_key_map(map), do: Map.new(map, fn {key, value} -> {policy_key(key), value} end)

  defp policy_key(key) when is_atom(key), do: key

  defp policy_key(key) when is_binary(key) do
    Enum.find(@policy_keys, key, &(Atom.to_string(&1) == key))
  end

  defp policy_key(key), do: key

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
