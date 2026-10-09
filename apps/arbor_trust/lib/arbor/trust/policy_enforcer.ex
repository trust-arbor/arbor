defmodule Arbor.Trust.PolicyEnforcer do
  @moduledoc """
  Trust-layer JIT capability granting.

  This module is the policy-side pre-authorize step from the A1 authorization
  boundary move. It may mint a session-scoped capability from an explicit trust
  policy decision, then the security kernel authorizes that concrete capability.

  `Arbor.Security.AuthDecision` must not call this module. The dependency only
  points policy -> kernel.
  """

  alias Arbor.Trust.CapabilityProfileRegistry
  alias Arbor.Trust.CapabilityGrantOwner
  alias Arbor.Trust.Config

  require Logger

  @source :trust_policy_enforcer
  @legacy_source :policy_enforcer

  @doc """
  Ensure `principal_id` has a capability for `resource_uri`.

  Existing capabilities are returned unchanged. On a miss, the trust policy may
  mint an explicit capability. `:block` denies; `:ask`, `:allow`, and `:auto`
  mint normal capabilities stamped with policy provenance. Runtime ask-vs-auto
  modulation happens in `Arbor.Trust.ApprovalGuard`, not in the security kernel.
  """
  @spec ensure_capability(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure_capability(principal_id, resource_uri, opts \\ []) do
    with {:ok, resource_uri} <-
           Arbor.Security.normalize_authorization_resource_uri(resource_uri, opts) do
      case find_existing_capability(principal_id, resource_uri, opts) do
        {:ok, cap} -> {:ok, cap}
        {:error, :not_found} -> check(principal_id, resource_uri, opts)
        {:error, _reason} -> {:error, :unauthorized}
      end
    end
  end

  @doc """
  Check trust profile and optionally mint a session-scoped capability.
  """
  @spec check(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def check(principal_id, resource_uri, opts \\ []) do
    if enabled?() do
      with signed_request when not is_nil(signed_request) <-
             Keyword.get(opts, :capability_grant_request),
           {:ok, cap} <- CapabilityGrantOwner.request(signed_request, grant_owner()) do
        if cap.principal_id == principal_id and cap.resource_uri == resource_uri do
          {:ok, cap}
        else
          {:error, :unauthorized}
        end
      else
        _ -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  @spec grant_spec(String.t(), String.t(), keyword()) ::
          {:ok, %{profile: map(), mode: :ask | :allow | :auto, constraints: map()}}
          | {:error, :unauthorized}
  def grant_spec(principal_id, resource_uri, opts \\ []) do
    if enabled?() do
      mode = get_effective_mode(principal_id, resource_uri, opts)

      case grant_decision(resource_uri, mode) do
        {:grant, profile, grant_mode} ->
          {:ok,
           %{
             profile: profile,
             mode: grant_mode,
             constraints: profile.default_constraints
           }}

        {:deny, reason} ->
          log_mint_denial(principal_id, resource_uri, mode, reason)
          {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :exit, _ -> {:error, :unauthorized}
  end

  @doc """
  Return whether trust policy may mint a missing capability for a resource.

  This is a read-only mirror of `check/3` for authority enumeration. It does not
  grant capabilities or emit grant signals.
  """
  @spec mintable?(String.t(), String.t(), keyword()) :: boolean()
  def mintable?(principal_id, resource_uri, opts \\ []) do
    if enabled?() do
      with {:ok, resource_uri} <-
             Arbor.Security.normalize_authorization_resource_uri(resource_uri, opts) do
        mode = get_effective_mode(principal_id, resource_uri, opts)

        case grant_decision(resource_uri, mode) do
          {:grant, _profile, _grant_mode} -> true
          {:deny, _reason} -> false
        end
      else
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Audit and re-sync trust-minted capabilities after a profile change.

  Requires a caller-owned Security signing authority in `:actor_authority`.
  """
  @spec sync_capabilities(String.t(), keyword()) :: :ok | {:error, term()}
  def sync_capabilities(principal_id, opts \\ []) do
    if enabled?() do
      with {:ok, actor_authority} <- fetch_actor_authority(opts) do
        do_sync_capabilities(principal_id, actor_authority)
      end
    else
      :ok
    end
  end

  @doc "Whether trust-policy JIT minting is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.policy_enforcer_enabled?()

  defp find_existing_capability(principal_id, resource_uri, opts) do
    with {:ok, capabilities} <- Arbor.Security.list_capabilities(principal_id) do
      case Enum.find(capabilities, fn capability ->
             Arbor.Security.capability_authorizes?(capability, resource_uri, opts)
           end) do
        nil -> {:error, :not_found}
        capability -> {:ok, capability}
      end
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  defp do_sync_capabilities(principal_id, actor_authority) do
    with {:ok, caps} <- Arbor.Security.list_capabilities(principal_id) do
      stale_caps =
        caps
        |> Enum.filter(&trust_minted?/1)
        |> Enum.filter(fn cap ->
          current_mode = get_effective_mode(principal_id, cap.resource_uri, [])
          minted_mode = minted_mode(cap)
          requires_approval? = approval_required?(cap)

          cond do
            current_mode == :block -> true
            minted_mode == :ask -> current_mode != :ask
            minted_mode in [:auto, :allow] -> current_mode not in [:auto, :allow]
            is_nil(minted_mode) and requires_approval? -> current_mode in [:auto, :allow]
            is_nil(minted_mode) and not requires_approval? -> current_mode == :ask
            true -> false
          end
        end)

      revoke_stale_capabilities(stale_caps, principal_id, actor_authority)
    else
      {:error, reason} -> {:error, {:capability_list_failed, reason}}
    end
  rescue
    e ->
      Logger.warning("[Trust.PolicyEnforcer] sync_capabilities crashed: #{inspect(e)}")
      {:error, :capability_sync_failed}
  catch
    :exit, reason -> {:error, {:capability_sync_exit, reason}}
  end

  defp revoke_stale_capabilities(stale_caps, principal_id, actor_authority) do
    stale_caps
    |> Enum.reduce_while({:ok, 0}, fn cap, {:ok, revoked} ->
      case Arbor.Security.revoke(cap.id, actor_authority: actor_authority) do
        :ok -> {:cont, {:ok, revoked + 1}}
        {:error, reason} -> {:halt, {:error, {:capability_revocation_failed, cap.id, reason}}}
        other -> {:halt, {:error, {:capability_revocation_failed, cap.id, other}}}
      end
    end)
    |> case do
      {:ok, revoked} ->
        if revoked > 0 do
          Logger.info(
            "[Trust.PolicyEnforcer] Synced #{revoked} stale capabilities for #{principal_id}",
            principal_id: principal_id,
            revoked: revoked
          )
        end

        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_actor_authority(opts) when is_list(opts) do
    case Keyword.fetch(opts, :actor_authority) do
      {:ok, authority} when not is_nil(authority) -> {:ok, authority}
      _ -> {:error, :capability_mutation_unauthorized}
    end
  end

  defp fetch_actor_authority(_opts), do: {:error, :capability_mutation_unauthorized}

  defp grant_owner do
    Application.get_env(:arbor_trust, :capability_grant_owner, CapabilityGrantOwner)
  end

  defp get_effective_mode(principal_id, resource_uri, opts) do
    policy = Config.policy_module()

    if Code.ensure_loaded?(policy) and function_exported?(policy, :effective_mode, 3) do
      apply(policy, :effective_mode, [principal_id, resource_uri, opts])
    else
      :block
    end
  rescue
    _ -> :block
  catch
    :exit, _ -> :block
  end

  defp grant_decision(resource_uri, mode) do
    case CapabilityProfileRegistry.profile_for(resource_uri) do
      nil ->
        {:deny, :unprofiled}

      %{default_approval: :forbid} ->
        {:deny, :forbidden_profile}

      profile ->
        grant_decision_for_profile(profile, mode)
    end
  end

  defp grant_decision_for_profile(_profile, :block), do: {:deny, :blocked}

  defp grant_decision_for_profile(profile, :ask), do: {:grant, profile, :ask}

  # A profile :auto/:allow rule on a high-risk capability must not mint an
  # unattended cap. Clamp it to :ask so ApprovalGuard escalates instead.
  defp grant_decision_for_profile(profile, mode) when mode in [:auto, :allow] do
    if auto_grantable_profile?(profile) do
      {:grant, profile, mode}
    else
      {:grant, profile, :ask}
    end
  end

  defp grant_decision_for_profile(_profile, mode), do: {:deny, {:unknown_mode, mode}}

  defp auto_grantable_profile?(%{
         blast_radius: :low,
         reversibility: reversibility,
         effect_class: effect_class,
         default_approval: default_approval,
         cost_class: :cheap
       })
       when reversibility in [:read_only, :reversible] and
              effect_class in [:read, :local_write] and
              default_approval in [:auto, :notify],
       do: true

  defp auto_grantable_profile?(_profile), do: false

  defp log_mint_denial(principal_id, resource_uri, mode, reason) do
    Logger.debug(
      "[Trust.PolicyEnforcer] refused to mint #{resource_uri}: #{inspect(reason)}",
      principal_id: principal_id,
      resource_uri: resource_uri,
      mode: mode,
      reason: reason
    )
  end

  defp trust_minted?(cap) do
    metadata = cap.metadata || %{}
    source = Map.get(metadata, :source) || Map.get(metadata, "source")
    legacy = Map.get(metadata, :legacy_source) || Map.get(metadata, "legacy_source")

    source in [@source, Atom.to_string(@source), @legacy_source, Atom.to_string(@legacy_source)] or
      legacy in [@legacy_source, Atom.to_string(@legacy_source)]
  end

  defp minted_mode(cap) do
    metadata = cap.metadata || %{}
    Map.get(metadata, :mode) || Map.get(metadata, "mode")
  end

  defp approval_required?(cap) do
    cap.constraints[:requires_approval] == true or
      cap.constraints["requires_approval"] == true
  end
end
