defmodule Arbor.Trust.CapabilityRiskProfiles do
  @moduledoc """
  A7 slice of capability risk profiles.

  The full `CapabilityProfile` contract/registry is deferred to Ring B. This
  module keeps the Ring A safety slice small: declare risk metadata for the
  highest-blast-radius URI classes and derive the security ceiling from that
  metadata instead of maintaining a separate ceiling map by hand.
  """

  @type blast_radius :: :low | :medium | :high | :critical
  @type reversibility :: :read_only | :reversible | :irreversible
  @type effect_class ::
          :read
          | :local_write
          | :process_spawn
          | :network_egress
          | :identity_mutating
          | :governance
          | :trust_mutating
  @type default_approval :: :auto | :notify | :require_human | :forbid
  @type ceiling_mode :: :block | :ask | :allow | :auto

  @type risk_profile :: %{
          required(:uri_prefix) => String.t(),
          required(:blast_radius) => blast_radius(),
          required(:reversibility) => reversibility(),
          required(:effect_class) => effect_class(),
          required(:arg_dependent) => boolean(),
          required(:default_approval) => default_approval(),
          required(:graduation_eligible) => boolean()
        }

  @high_risk_profiles [
    %{
      uri_prefix: "arbor://shell",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :process_spawn,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://governance",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :governance,
      arg_dependent: false,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://trust/write",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :trust_mutating,
      arg_dependent: false,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://trust/auto_promote",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :trust_mutating,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://agent/create",
      blast_radius: :high,
      reversibility: :irreversible,
      effect_class: :identity_mutating,
      arg_dependent: false,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://agent/destroy",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :identity_mutating,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://agent/spawn",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :identity_mutating,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://agent/spawn_worker",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :identity_mutating,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://consensus/admin",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :governance,
      arg_dependent: false,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://monitor/remediate",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :process_spawn,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://code/write",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://code/compile",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :process_spawn,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://code/reload",
      blast_radius: :critical,
      reversibility: :reversible,
      effect_class: :process_spawn,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://code/hot_load",
      blast_radius: :critical,
      reversibility: :irreversible,
      effect_class: :process_spawn,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: false
    },
    %{
      uri_prefix: "arbor://fs/write",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://action/git/commit",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://action/git/branch",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://action/github/pr",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :network_egress,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://action/mix/format",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    },
    %{
      uri_prefix: "arbor://action/code_review/apply_changes",
      blast_radius: :high,
      reversibility: :reversible,
      effect_class: :local_write,
      arg_dependent: true,
      default_approval: :require_human,
      graduation_eligible: true
    }
  ]

  @doc """
  Return declared high-risk URI profiles for the Ring A slice.
  """
  @spec high_risk_profiles() :: [risk_profile()]
  def high_risk_profiles, do: @high_risk_profiles

  @doc """
  Project high-risk capability profiles into security ceilings.
  """
  @spec security_ceilings() :: %{String.t() => ceiling_mode()}
  def security_ceilings do
    @high_risk_profiles
    |> Enum.flat_map(fn profile ->
      case ceiling_mode(profile) do
        nil -> []
        mode -> [{profile.uri_prefix, mode}]
      end
    end)
    |> Map.new()
  end

  @doc """
  Derive the ceiling mode from a capability risk profile.
  """
  @spec ceiling_mode(risk_profile()) :: ceiling_mode() | nil
  def ceiling_mode(%{default_approval: :forbid}), do: :block
  def ceiling_mode(%{default_approval: :require_human}), do: :ask
  def ceiling_mode(%{default_approval: :notify}), do: :allow
  def ceiling_mode(%{default_approval: :auto}), do: nil
end
