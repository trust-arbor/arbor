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
  alias Arbor.Contracts.Security.TrustProfile
  alias Arbor.Security.{CapabilityStore, TrustStore}
  alias Arbor.Signals

  # Core Authorization

  @doc """
  Authorize an operation on a resource.

  The resource URI includes the action: `arbor://{type}/{action}/{path}`

  Checks both capability and trust requirements. Returns:

  - `{:ok, :authorized}` - Operation allowed
  - `{:error, :unauthorized}` - No valid capability
  - `{:error, :capability_expired}` - Capability has expired
  - `{:error, :trust_frozen}` - Agent's trust is frozen

  ## Options

  - `:context` - Additional context for authorization decision
  - `:skip_consensus` - Skip consensus check (default: false)
  - `:trace_id` - Trace ID for correlation

  ## Examples

      # Action is in the URI
      Arbor.Security.authorize("agent_001", "arbor://fs/read/docs")
  """
  @impl true
  @spec authorize(String.t(), String.t(), atom(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize(principal_id, resource_uri, _action \\ nil, opts \\ []) do
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

  @doc """
  Fast capability-only check.

  Returns true if the principal has a valid capability for the resource URI.
  Does not check trust status. The action is encoded in the URI.
  """
  @impl true
  @spec can?(String.t(), String.t(), atom()) :: boolean()
  def can?(principal_id, resource_uri, _action \\ nil) do
    case CapabilityStore.find_authorizing(principal_id, resource_uri) do
      {:ok, _cap} -> true
      {:error, _} -> false
    end
  end

  # Capability Management

  @doc """
  Grant a capability to an agent.

  The action is encoded in the resource URI: `arbor://{type}/{action}/{path}`

  ## Options

  - `:principal` - Agent ID (required)
  - `:resource` - Resource URI (required), e.g. "arbor://fs/read/project/docs"
  - `:constraints` - Additional constraints map
  - `:expires_at` - Expiration DateTime
  - `:delegation_depth` - How many times this can be delegated (default: 3)
  """
  @impl true
  @spec grant(keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def grant(opts) do
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

  @doc """
  Revoke a capability.
  """
  @impl true
  @spec revoke(String.t(), keyword()) :: :ok | {:error, :not_found | term()}
  def revoke(capability_id, _opts \\ []) do
    case CapabilityStore.revoke(capability_id) do
      :ok ->
        emit_capability_revoked(capability_id)
        :ok

      error ->
        error
    end
  end

  @doc """
  List capabilities for an agent.

  ## Options

  - `:include_expired` - Include expired capabilities (default: false)
  """
  @impl true
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_capabilities(principal_id, opts \\ []) do
    CapabilityStore.list_for_principal(principal_id, opts)
  end

  # Trust Management

  @doc """
  Create a trust profile for a new agent.
  """
  @impl true
  @spec create_trust_profile(String.t()) ::
          {:ok, TrustProfile.t()} | {:error, :already_exists | term()}
  def create_trust_profile(principal_id) do
    case TrustStore.create(principal_id) do
      {:ok, profile} ->
        emit_trust_profile_created(profile)
        {:ok, profile}

      error ->
        error
    end
  end

  @doc """
  Get the trust profile for an agent.
  """
  @impl true
  @spec get_trust_profile(String.t()) :: {:ok, TrustProfile.t()} | {:error, :not_found}
  def get_trust_profile(principal_id) do
    TrustStore.get(principal_id)
  end

  @doc """
  Get the current trust tier for an agent.
  """
  @impl true
  @spec get_trust_tier(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_trust_tier(principal_id) do
    TrustStore.get_tier(principal_id)
  end

  @doc """
  Record a trust-affecting event.

  ## Event Types

  - `:action_success` - Successful action completion
  - `:action_failure` - Failed action
  - `:security_violation` - Security boundary violation
  - `:test_passed` - Test passed
  - `:test_failed` - Test failed
  """
  @impl true
  @spec record_trust_event(String.t(), atom(), map()) :: :ok
  def record_trust_event(principal_id, event_type, metadata \\ %{}) do
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

  @doc """
  Freeze an agent's trust progression.

  When frozen, the agent cannot earn additional trust and may have
  reduced capabilities.
  """
  @impl true
  @spec freeze_trust(String.t(), atom()) :: :ok | {:error, term()}
  def freeze_trust(principal_id, reason) do
    case TrustStore.freeze(principal_id, reason) do
      {:ok, profile} ->
        emit_trust_frozen(profile, reason)
        :ok

      error ->
        error
    end
  end

  @doc """
  Unfreeze an agent's trust progression.
  """
  @impl true
  @spec unfreeze_trust(String.t()) :: :ok | {:error, term()}
  def unfreeze_trust(principal_id) do
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
