defmodule Arbor.Security do
  @moduledoc """
  Capability-based security for the Arbor platform.

  Arbor.Security provides authorization through unforgeable capability tokens
  and trust-based access control. Agents earn trust through successful actions
  and can have their trust frozen when anomalous behavior is detected.

  ## Quick Start

      # Check authorization
      case Arbor.Security.authorize("agent_001", "arbor://fs/read/docs", :read) do
        {:ok, :authorized} -> proceed()
        {:error, reason} -> handle_denial(reason)
      end

      # Fast boolean check
      if Arbor.Security.can?("agent_001", "arbor://fs/read/docs", :read) do
        # proceed
      end

  ## Trust Tiers

  | Tier | Score | Capabilities |
  |------|-------|--------------|
  | `:untrusted` | 0-19 | Read own code only |
  | `:probationary` | 20-49 | Limited access |
  | `:trusted` | 50-74 | Standard access |
  | `:veteran` | 75-89 | Extended access |
  | `:autonomous` | 90-100 | Self-modification |

  ## Capability Model

  Capabilities are unforgeable tokens that grant specific permissions:

      {:ok, cap} = Arbor.Security.grant(
        principal: "agent_001",
        resource: "arbor://fs/read/project/src",
        action: :read,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

  ## Signals

  Security emits signals for observability:

  - `{:security, :authorization_granted, %{...}}`
  - `{:security, :authorization_denied, %{...}}`
  - `{:security, :capability_granted, %{...}}`
  - `{:security, :trust_tier_changed, %{...}}`
  """

  @behaviour Arbor.Contracts.Libraries.Security

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Trust.Profile, as: TrustProfile
  alias Arbor.Security.{CapabilityStore, TrustStore}
  alias Arbor.Signals

  # ===========================================================================
  # Public API — short, human-friendly names
  # ===========================================================================

  @doc """
  Authorize an operation on a resource.

  The resource URI includes the action: `arbor://{type}/{action}/{path}`

  ## Examples

      Arbor.Security.authorize("agent_001", "arbor://fs/read/docs")
  """
  @spec authorize(String.t(), String.t(), atom(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize(principal_id, resource_uri, action \\ nil, opts \\ []),
    do: check_if_principal_has_capability_for_resource_action(principal_id, resource_uri, action, opts)

  @doc """
  Fast capability-only check. Does not verify trust status.
  """
  @spec can?(String.t(), String.t(), atom()) :: boolean()
  def can?(principal_id, resource_uri, action \\ nil),
    do: check_if_principal_can_perform_operation_on_resource(principal_id, resource_uri, action)

  @doc """
  Grant a capability to an agent.

  ## Options

  - `:principal` - Agent ID (required)
  - `:resource` - Resource URI (required)
  - `:constraints` - Additional constraints map
  - `:expires_at` - Expiration DateTime
  - `:delegation_depth` - How many times this can be delegated (default: 3)
  """
  @spec grant(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def grant(opts), do: grant_capability_to_principal_for_resource(opts)

  @doc "Revoke a capability."
  @spec revoke(String.t(), keyword()) :: :ok | {:error, :not_found | term()}
  def revoke(capability_id, opts \\ []), do: revoke_capability_by_id(capability_id, opts)

  @doc "List capabilities for an agent."
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_capabilities(principal_id, opts \\ []), do: list_capabilities_for_principal(principal_id, opts)

  @doc "Create a trust profile for a new agent."
  @spec create_trust_profile(String.t()) :: {:ok, TrustProfile.t()} | {:error, :already_exists | term()}
  def create_trust_profile(principal_id), do: create_trust_profile_for_principal(principal_id)

  @doc "Get the trust profile for an agent."
  @spec get_trust_profile(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def get_trust_profile(principal_id), do: get_trust_profile_for_principal(principal_id)

  @doc "Get the current trust tier for an agent."
  @spec get_trust_tier(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_trust_tier(principal_id), do: get_current_trust_tier_for_principal(principal_id)

  @doc "Record a trust-affecting event."
  @spec record_trust_event(String.t(), atom(), map()) :: :ok
  def record_trust_event(principal_id, event_type, metadata \\ %{}),
    do: record_trust_event_for_principal_with_metadata(principal_id, event_type, metadata)

  @doc "Freeze an agent's trust progression."
  @spec freeze_trust(String.t(), atom()) :: :ok | {:error, term()}
  def freeze_trust(principal_id, reason),
    do: freeze_trust_progression_for_principal_with_reason(principal_id, reason)

  @doc "Unfreeze an agent's trust progression."
  @spec unfreeze_trust(String.t()) :: :ok | {:error, term()}
  def unfreeze_trust(principal_id), do: unfreeze_trust_progression_for_principal(principal_id)

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl true
  def check_if_principal_has_capability_for_resource_action(principal_id, resource_uri, _action, opts) do
    with {:ok, _profile} <- check_trust_not_frozen(principal_id),
         {:ok, _cap} <- find_capability(principal_id, resource_uri) do
      emit_authorization_granted(principal_id, resource_uri, opts)
      {:ok, :authorized}
    else
      {:error, reason} = error ->
        emit_authorization_denied(principal_id, resource_uri, reason, opts)
        error
    end
  end

  @impl true
  def check_if_principal_can_perform_operation_on_resource(principal_id, resource_uri, _action) do
    case CapabilityStore.find_authorizing(principal_id, resource_uri) do
      {:ok, _cap} -> true
      {:error, _} -> false
    end
  end

  @impl true
  def grant_capability_to_principal_for_resource(opts) do
    principal_id = Keyword.fetch!(opts, :principal)
    resource_uri = Keyword.fetch!(opts, :resource)

    case Capability.new(
           resource_uri: resource_uri,
           principal_id: principal_id,
           expires_at: Keyword.get(opts, :expires_at),
           constraints: Keyword.get(opts, :constraints, %{}),
           delegation_depth: Keyword.get(opts, :delegation_depth, 3)
         ) do
      {:ok, cap} ->
        :ok = CapabilityStore.put(cap)
        emit_capability_granted(cap)
        {:ok, cap}

      error ->
        error
    end
  end

  @impl true
  def revoke_capability_by_id(capability_id, _opts) do
    case CapabilityStore.revoke(capability_id) do
      :ok ->
        emit_capability_revoked(capability_id)
        :ok

      error ->
        error
    end
  end

  @impl true
  def list_capabilities_for_principal(principal_id, opts) do
    CapabilityStore.list_for_principal(principal_id, opts)
  end

  @impl true
  def create_trust_profile_for_principal(principal_id) do
    case TrustStore.create(principal_id) do
      {:ok, profile} ->
        emit_trust_profile_created(profile)
        {:ok, profile}

      error ->
        error
    end
  end

  @impl true
  def get_trust_profile_for_principal(principal_id) do
    TrustStore.get(principal_id)
  end

  @impl true
  def get_current_trust_tier_for_principal(principal_id) do
    TrustStore.get_tier(principal_id)
  end

  @impl true
  def record_trust_event_for_principal_with_metadata(principal_id, event_type, metadata) do
    result =
      case event_type do
        :action_success -> TrustStore.record_success(principal_id)
        :action_failure -> TrustStore.record_failure(principal_id)
        :security_violation -> TrustStore.record_violation(principal_id)
        _ -> {:ok, :ignored}
      end

    case result do
      {:ok, profile} when is_map(profile) ->
        emit_trust_event(principal_id, event_type, profile, metadata)

      _ ->
        :ok
    end

    :ok
  end

  @impl true
  def freeze_trust_progression_for_principal_with_reason(principal_id, reason) do
    case TrustStore.freeze(principal_id, reason) do
      {:ok, profile} ->
        emit_trust_frozen(profile, reason)
        :ok

      error ->
        error
    end
  end

  @impl true
  def unfreeze_trust_progression_for_principal(principal_id) do
    case TrustStore.unfreeze(principal_id) do
      {:ok, profile} ->
        emit_trust_unfrozen(profile)
        :ok

      error ->
        error
    end
  end

  # System API

  @doc """
  Start the security system.

  Normally started automatically by the application supervisor.
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Security.Application.start(:normal, opts)
  end

  @doc """
  Check if the security system is healthy.
  """
  @impl true
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(CapabilityStore) != nil and Process.whereis(TrustStore) != nil
  end

  @doc """
  Get system statistics.
  """
  @spec stats() :: map()
  def stats do
    %{
      capabilities: CapabilityStore.stats(),
      trust: TrustStore.stats(),
      healthy: healthy?()
    }
  end

  # Private functions

  defp check_trust_not_frozen(principal_id) do
    case TrustStore.get(principal_id) do
      {:ok, %{frozen: true}} -> {:error, :trust_frozen}
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp find_capability(principal_id, resource_uri) do
    case CapabilityStore.find_authorizing(principal_id, resource_uri) do
      {:ok, cap} -> {:ok, cap}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  # Signal emission

  defp emit_authorization_granted(principal_id, resource_uri, opts) do
    Signals.emit(:security, :authorization_granted, %{
      principal_id: principal_id,
      resource_uri: resource_uri,
      trace_id: Keyword.get(opts, :trace_id)
    })
  end

  defp emit_authorization_denied(principal_id, resource_uri, reason, opts) do
    Signals.emit(:security, :authorization_denied, %{
      principal_id: principal_id,
      resource_uri: resource_uri,
      reason: reason,
      trace_id: Keyword.get(opts, :trace_id)
    })
  end

  defp emit_capability_granted(cap) do
    Signals.emit(:security, :capability_granted, %{
      capability_id: cap.id,
      principal_id: cap.principal_id,
      resource_uri: cap.resource_uri
    })
  end

  defp emit_capability_revoked(capability_id) do
    Signals.emit(:security, :capability_revoked, %{
      capability_id: capability_id
    })
  end

  defp emit_trust_profile_created(profile) do
    Signals.emit(:security, :trust_profile_created, %{
      agent_id: profile.agent_id,
      tier: profile.tier
    })
  end

  defp emit_trust_event(principal_id, event_type, profile, metadata) do
    Signals.emit(:security, :trust_event, %{
      principal_id: principal_id,
      event_type: event_type,
      new_score: profile.trust_score,
      new_tier: profile.tier,
      metadata: metadata
    })
  end

  defp emit_trust_frozen(profile, reason) do
    Signals.emit(:security, :trust_frozen, %{
      agent_id: profile.agent_id,
      reason: reason
    })
  end

  defp emit_trust_unfrozen(profile) do
    Signals.emit(:security, :trust_unfrozen, %{
      agent_id: profile.agent_id
    })
  end
end
