defmodule Arbor.Trust.CapabilityEnforcementMatrix do
  @moduledoc """
  Declared soft/hard enforcement pairings for high-risk capability profiles.

  This is an audit surface, not an authorization path. `CapabilityRiskProfiles`
  owns the high-risk URI set; this module records the in-process soft gate and
  the independent containment or administrative hard gate expected for each
  high-risk class.

  The hard gate must not depend on the same `Arbor.Security.authorize/4`
  decision path as the soft gate. That separation is the K5 defense-in-depth
  property: a bug in capability/policy authorization should not also remove the
  host, filesystem, network, or administrative boundary.
  """

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.{CapabilityProfileRegistry, CapabilityRiskProfiles}

  @type capability_class ::
          :shell_exec
          | :process_spawn
          | :network_egress
          | :filesystem_write
          | :local_write
          | :administrative_mutation
          | :financial

  @type gate :: %{
          required(:id) => atom(),
          required(:layer) => :soft | :hard,
          required(:owner) => atom(),
          required(:mechanism) => String.t(),
          required(:decision_path) => atom(),
          required(:authorize4_dependent?) => boolean()
        }

  @type row :: %{
          required(:uri_prefix) => String.t(),
          required(:capability_class) => capability_class(),
          required(:profile) => CapabilityProfile.t(),
          required(:soft_gate) => gate(),
          required(:hard_gate) => gate()
        }

  @soft_gates %{
    shell_exec: %{
      id: :trust_ask_ceiling,
      layer: :soft,
      owner: :arbor_trust,
      mechanism: "profile-derived :ask ceiling via ProfileResolver and ApprovalGuard",
      decision_path: :trust_policy_resolution,
      authorize4_dependent?: true
    },
    process_spawn: %{
      id: :trust_ask_ceiling,
      layer: :soft,
      owner: :arbor_trust,
      mechanism: "profile-derived :ask ceiling before spawning a process",
      decision_path: :trust_policy_resolution,
      authorize4_dependent?: true
    },
    network_egress: %{
      id: :egress_gate,
      layer: :soft,
      owner: :arbor_security,
      mechanism: "EgressGate tier, taint, and destination decision",
      decision_path: :egress_gate,
      authorize4_dependent?: false
    },
    filesystem_write: %{
      id: :file_guard,
      layer: :soft,
      owner: :arbor_security,
      mechanism: "FileGuard path-scope and traversal check",
      decision_path: :file_guard,
      authorize4_dependent?: false
    },
    local_write: %{
      id: :trust_ask_ceiling,
      layer: :soft,
      owner: :arbor_trust,
      mechanism: "profile-derived :ask ceiling for local write effects",
      decision_path: :trust_policy_resolution,
      authorize4_dependent?: true
    },
    administrative_mutation: %{
      id: :capability_gate,
      layer: :soft,
      owner: :arbor_security,
      mechanism: "capability authorization for identity, governance, or trust mutation",
      decision_path: :security_authorize,
      authorize4_dependent?: true
    },
    financial: %{
      id: :capability_gate,
      layer: :soft,
      owner: :arbor_security,
      mechanism: "capability authorization for metered or financial effects",
      decision_path: :security_authorize,
      authorize4_dependent?: true
    }
  }

  @hard_gates %{
    shell_exec: %{
      id: :sandbox_no_nic,
      layer: :hard,
      owner: :arbor_sandbox,
      mechanism: "sandboxed execution boundary with no NIC unless explicitly projected",
      decision_path: :host_execution_containment,
      authorize4_dependent?: false
    },
    process_spawn: %{
      id: :sandbox_no_nic,
      layer: :hard,
      owner: :arbor_sandbox,
      mechanism: "sandboxed execution boundary for subprocess or code execution",
      decision_path: :host_execution_containment,
      authorize4_dependent?: false
    },
    network_egress: %{
      id: :host_route_or_netns_filter,
      layer: :hard,
      owner: :arbor_sandbox,
      mechanism: "host route or network namespace filter projected from egress capability",
      decision_path: :host_network_boundary,
      authorize4_dependent?: false
    },
    filesystem_write: %{
      id: :worktree_mount_confinement,
      layer: :hard,
      owner: :arbor_sandbox,
      mechanism: "worktree or mount confinement for writable paths",
      decision_path: :host_filesystem_boundary,
      authorize4_dependent?: false
    },
    local_write: %{
      id: :worktree_mount_confinement,
      layer: :hard,
      owner: :arbor_sandbox,
      mechanism: "worktree or mount confinement for local mutations",
      decision_path: :host_filesystem_boundary,
      authorize4_dependent?: false
    },
    administrative_mutation: %{
      id: :non_agent_admin_boundary,
      layer: :hard,
      owner: :arbor_security,
      mechanism: "non-agent-owned administrative boundary for privileged writes",
      decision_path: :operator_admin_boundary,
      authorize4_dependent?: false
    },
    financial: %{
      id: :budget_or_payment_boundary,
      layer: :hard,
      owner: :arbor_security,
      mechanism: "non-agent-owned budget or payment boundary",
      decision_path: :operator_budget_boundary,
      authorize4_dependent?: false
    }
  }

  @doc "Return one enforcement row for each declared high-risk capability profile."
  @spec rows() :: [row()]
  def rows do
    Enum.map(CapabilityRiskProfiles.high_risk_profiles(), &row_for!/1)
  end

  @doc "Resolve the enforcement row covering a high-risk profile or URI."
  @spec row_for(CapabilityProfile.t() | String.t()) :: {:ok, row()} | {:error, term()}
  def row_for(%CapabilityProfile{} = profile) do
    with {:ok, capability_class} <- capability_class(profile),
         {:ok, soft_gate} <- gate_for(@soft_gates, capability_class),
         {:ok, hard_gate} <- gate_for(@hard_gates, capability_class) do
      {:ok,
       %{
         uri_prefix: profile.uri_prefix,
         capability_class: capability_class,
         profile: profile,
         soft_gate: soft_gate,
         hard_gate: hard_gate
       }}
    end
  end

  def row_for(uri) when is_binary(uri) do
    case CapabilityProfileRegistry.profile_for(uri) do
      %CapabilityProfile{} = profile -> high_risk_row_for(profile)
      nil -> {:error, :unknown_high_risk_profile}
    end
  end

  def row_for(_value), do: {:error, :invalid_profile_or_uri}

  @doc "Resolve an enforcement row, raising on an unsupported high-risk profile."
  @spec row_for!(CapabilityProfile.t() | String.t()) :: row()
  def row_for!(profile_or_uri) do
    case row_for(profile_or_uri) do
      {:ok, row} ->
        row

      {:error, reason} ->
        raise ArgumentError,
              "missing capability enforcement matrix row: #{inspect(reason)}"
    end
  end

  defp capability_class(%CapabilityProfile{uri_prefix: "arbor://shell"}) do
    {:ok, :shell_exec}
  end

  defp capability_class(%CapabilityProfile{uri_prefix: "arbor://fs/write"}) do
    {:ok, :filesystem_write}
  end

  defp capability_class(%CapabilityProfile{effect_class: :network_egress}) do
    {:ok, :network_egress}
  end

  defp capability_class(%CapabilityProfile{effect_class: effect_class})
       when effect_class in [:identity_mutating, :governance, :trust_mutating] do
    {:ok, :administrative_mutation}
  end

  defp capability_class(%CapabilityProfile{effect_class: :process_spawn}) do
    {:ok, :process_spawn}
  end

  defp capability_class(%CapabilityProfile{effect_class: :local_write}) do
    {:ok, :local_write}
  end

  defp capability_class(%CapabilityProfile{effect_class: :financial}) do
    {:ok, :financial}
  end

  defp capability_class(%CapabilityProfile{uri_prefix: uri_prefix, effect_class: effect_class}) do
    {:error, {:unsupported_high_risk_class, uri_prefix, effect_class}}
  end

  defp high_risk_row_for(%CapabilityProfile{} = profile) do
    case row_for(profile) do
      {:error, {:unsupported_high_risk_class, _uri_prefix, _effect_class}} ->
        {:error, :unknown_high_risk_profile}

      result ->
        result
    end
  end

  defp gate_for(gates, capability_class) do
    case Map.fetch(gates, capability_class) do
      {:ok, gate} -> {:ok, gate}
      :error -> {:error, {:missing_gate, capability_class}}
    end
  end
end
