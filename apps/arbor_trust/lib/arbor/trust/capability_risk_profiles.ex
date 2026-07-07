defmodule Arbor.Trust.CapabilityRiskProfiles do
  @moduledoc """
  Capability risk profiles used by trust policy projections.

  Ring A introduced a small high-risk map local to `arbor_trust`. Ring B
  promotes that metadata to the shared `CapabilityProfile` contract while
  keeping the current high-risk ceiling projection intact.

  Operator profile overrides live in:

      config :arbor_trust, :capability_profile_overrides, %{
        "arbor://fs/write" => %{default_approval: :forbid}
      }

  The older `:security_ceilings` config still layers over the projected ceiling
  map in `ProfileResolver`; this module owns the profile-shaped default truth.
  """

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Contracts.Security.CapabilityUri

  @type risk_profile :: CapabilityProfile.t()
  @type ceiling_mode :: :block | :ask | :allow | :auto
  @type graduation_threshold :: non_neg_integer() | :never

  @high_risk_profile_specs [
    {"arbor://shell", :arbor_shell, :critical, :irreversible, :process_spawn, :restricted, true,
     :require_human, false, :cheap},
    {"arbor://governance", :arbor_trust, :critical, :irreversible, :governance, :restricted,
     false, :require_human, false, :cheap},
    {"arbor://trust/write", :arbor_trust, :critical, :irreversible, :trust_mutating, :restricted,
     false, :require_human, false, :cheap},
    {"arbor://trust/auto_promote", :arbor_trust, :critical, :irreversible, :trust_mutating,
     :restricted, true, :require_human, false, :cheap},
    {"arbor://agent/create", :arbor_agent, :high, :irreversible, :identity_mutating, :restricted,
     false, :require_human, false, :cheap},
    {"arbor://agent/destroy", :arbor_agent, :critical, :irreversible, :identity_mutating,
     :restricted, true, :require_human, false, :cheap},
    {"arbor://agent/spawn", :arbor_agent, :high, :reversible, :identity_mutating, :restricted,
     true, :require_human, false, :cheap},
    {"arbor://agent/spawn_worker", :arbor_agent, :high, :reversible, :identity_mutating,
     :restricted, true, :require_human, false, :cheap},
    {"arbor://consensus/admin", :arbor_consensus, :critical, :irreversible, :governance,
     :restricted, false, :require_human, false, :cheap},
    {"arbor://monitor/remediate", :arbor_monitor, :high, :reversible, :process_spawn, :restricted,
     true, :require_human, false, :cheap},
    {"arbor://code/write", :arbor_actions, :high, :reversible, :local_write, :confidential, true,
     :require_human, true, :cheap},
    {"arbor://code/compile", :arbor_actions, :high, :reversible, :process_spawn, :confidential,
     true, :require_human, true, :cheap},
    {"arbor://code/reload", :arbor_actions, :critical, :reversible, :process_spawn, :restricted,
     true, :require_human, false, :cheap},
    {"arbor://code/hot_load", :arbor_actions, :critical, :irreversible, :process_spawn,
     :restricted, true, :require_human, false, :cheap},
    {"arbor://fs/write", :arbor_security, :high, :reversible, :local_write, :confidential, true,
     :require_human, true, :cheap},
    {"arbor://action/git/commit", :arbor_actions, :high, :reversible, :local_write, :confidential,
     true, :require_human, true, :cheap},
    {"arbor://action/git/branch", :arbor_actions, :high, :reversible, :local_write, :confidential,
     true, :require_human, true, :cheap},
    {"arbor://action/github/pr", :arbor_actions, :high, :reversible, :network_egress,
     :confidential, true, :require_human, true, :metered},
    {"arbor://action/mix/format", :arbor_actions, :high, :reversible, :local_write, :confidential,
     true, :require_human, true, :cheap},
    {"arbor://action/code_review/apply_changes", :arbor_actions, :high, :reversible, :local_write,
     :confidential, true, :require_human, true, :cheap}
  ]

  @doc "Return inline high-risk URI profiles before operator overrides."
  @spec inline_profiles() :: [risk_profile()]
  def inline_profiles do
    Enum.map(@high_risk_profile_specs, &profile_from_spec!/1)
  end

  @doc "Return high-risk URI profiles with operator overrides applied."
  @spec profiles() :: [risk_profile()]
  def profiles do
    inline_profiles()
    |> apply_profile_overrides(profile_overrides())
  end

  @doc """
  Return declared high-risk URI profiles.

  Kept for the Ring A public API; equivalent to `profiles/0`.
  """
  @spec high_risk_profiles() :: [risk_profile()]
  def high_risk_profiles, do: profiles()

  @doc """
  Project high-risk capability profiles into security ceilings.
  """
  @spec security_ceilings() :: %{String.t() => ceiling_mode()}
  def security_ceilings do
    profiles()
    |> Enum.flat_map(fn profile ->
      case ceiling_mode(profile) do
        nil -> []
        mode -> [{profile.uri_prefix, mode}]
      end
    end)
    |> Map.new()
  end

  @doc "Project high-risk capability profiles into graduation thresholds."
  @spec graduation_thresholds() :: %{String.t() => graduation_threshold()}
  def graduation_thresholds do
    profiles()
    |> Map.new(fn profile -> {profile.uri_prefix, graduation_threshold(profile)} end)
  end

  @doc "Project high-risk capability profiles into default capability constraints."
  @spec default_constraints() :: %{String.t() => map()}
  def default_constraints do
    profiles()
    |> Map.new(fn profile -> {profile.uri_prefix, profile.default_constraints} end)
  end

  @doc "Project high-risk capability profiles into delegation defaults."
  @spec delegation_defaults() :: %{String.t() => boolean()}
  def delegation_defaults do
    profiles()
    |> Map.new(fn profile -> {profile.uri_prefix, profile.delegable} end)
  end

  @doc "Project high-risk capability profiles into approval defaults."
  @spec approval_defaults() :: %{String.t() => CapabilityProfile.default_approval()}
  def approval_defaults do
    profiles()
    |> Map.new(fn profile -> {profile.uri_prefix, profile.default_approval} end)
  end

  @doc """
  Derive the ceiling mode from a capability risk profile.
  """
  @spec ceiling_mode(risk_profile() | %{required(:default_approval) => atom()}) ::
          ceiling_mode() | nil
  def ceiling_mode(%{default_approval: :forbid}), do: :block
  def ceiling_mode(%{default_approval: :require_human}), do: :ask
  def ceiling_mode(%{default_approval: :notify}), do: :allow
  def ceiling_mode(%{default_approval: :auto}), do: nil

  @doc """
  Derive the confirmation threshold from a capability risk profile.

  Profiles opt into graduation explicitly via `graduation_eligible`. Mutating
  governance, trust, identity, and financial effects never graduate even if
  misconfigured as eligible. Egress and process-spawn profiles require a longer
  evidence streak than local writes.
  """
  @spec graduation_threshold(risk_profile()) :: graduation_threshold()
  def graduation_threshold(%CapabilityProfile{graduation_eligible: false}), do: :never
  def graduation_threshold(%CapabilityProfile{default_approval: :forbid}), do: :never
  def graduation_threshold(%CapabilityProfile{default_approval: :auto}), do: 0
  def graduation_threshold(%CapabilityProfile{effect_class: :governance}), do: :never
  def graduation_threshold(%CapabilityProfile{effect_class: :trust_mutating}), do: :never
  def graduation_threshold(%CapabilityProfile{effect_class: :identity_mutating}), do: :never
  def graduation_threshold(%CapabilityProfile{effect_class: :financial}), do: :never
  def graduation_threshold(%CapabilityProfile{reversibility: :irreversible}), do: :never
  def graduation_threshold(%CapabilityProfile{blast_radius: :critical}), do: :never
  def graduation_threshold(%CapabilityProfile{effect_class: :network_egress}), do: 5
  def graduation_threshold(%CapabilityProfile{effect_class: :process_spawn}), do: 5
  def graduation_threshold(%CapabilityProfile{blast_radius: :high}), do: 3
  def graduation_threshold(%CapabilityProfile{blast_radius: :medium}), do: 2
  def graduation_threshold(%CapabilityProfile{blast_radius: :low}), do: 1

  defp profile_from_spec!(
         {uri_prefix, owner, blast_radius, reversibility, effect_class, data_class, arg_dependent,
          default_approval, graduation_eligible, cost_class}
       ) do
    CapabilityProfile.new!(%{
      uri_prefix: uri_prefix,
      owner: owner,
      blast_radius: blast_radius,
      reversibility: reversibility,
      effect_class: effect_class,
      data_class: data_class,
      arg_dependent: arg_dependent,
      default_approval: default_approval,
      delegable: false,
      cost_class: cost_class,
      graduation_eligible: graduation_eligible
    })
  end

  defp apply_profile_overrides(profiles, overrides) do
    profile_uris = MapSet.new(profiles, & &1.uri_prefix)
    unknown_uris = overrides |> Map.keys() |> Enum.reject(&MapSet.member?(profile_uris, &1))

    if unknown_uris != [] do
      raise ArgumentError,
            "capability profile overrides reference unknown profile URIs: " <>
              inspect(Enum.sort(unknown_uris))
    end

    Enum.map(profiles, fn profile ->
      case Map.get(overrides, profile.uri_prefix) do
        nil -> profile
        attrs -> CapabilityProfile.merge!(profile, attrs)
      end
    end)
  end

  defp profile_overrides do
    :arbor_trust
    |> Application.get_env(:capability_profile_overrides, %{})
    |> Kernel.||(%{})
    |> canonicalize_override_keys()
  end

  defp canonicalize_override_keys(overrides) when is_map(overrides) do
    Map.new(overrides, fn {uri_prefix, attrs} ->
      {canonicalize_prefix!(uri_prefix), attrs}
    end)
  end

  defp canonicalize_override_keys(_overrides) do
    raise ArgumentError, ":capability_profile_overrides must be a map"
  end

  defp canonicalize_prefix!(uri_prefix) when is_binary(uri_prefix) do
    case CapabilityUri.parse(uri_prefix) do
      {:ok, %CapabilityUri{wildcard: :none, segments: segments} = parsed} ->
        if ".." in segments do
          raise ArgumentError,
                "invalid capability profile override URI #{inspect(uri_prefix)}: " <>
                  "traversal-like segments are not allowed"
        end

        CapabilityUri.canonical(parsed)

      {:ok, _parsed} ->
        raise ArgumentError,
              "invalid capability profile override URI #{inspect(uri_prefix)}: " <>
                "wildcards are not allowed"

      {:error, reason} ->
        raise ArgumentError,
              "invalid capability profile override URI #{inspect(uri_prefix)}: #{inspect(reason)}"
    end
  end

  defp canonicalize_prefix!(uri_prefix) do
    raise ArgumentError,
          "capability profile override URI must be a string: #{inspect(uri_prefix)}"
  end
end
