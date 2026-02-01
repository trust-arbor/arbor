defmodule Arbor.Security do
  @moduledoc """
  Capability-based security for the Arbor platform.

  Arbor.Security provides authorization through unforgeable capability tokens,
  manages capability lifecycle (grant, revoke, list), and handles cryptographic
  agent identity (keypair generation, registration, signed request verification).

  Trust profile management (creation, scoring, tier progression, freezing) is
  handled by the separate `Arbor.Trust` library. Security focuses on capabilities
  and identity — callers that need trust operations should use `Arbor.Trust`
  directly.

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
  - `{:security, :capability_revoked, %{...}}`
  """

  @behaviour Arbor.Contracts.API.Security
  @behaviour Arbor.Contracts.API.Identity

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Constraint
  alias Arbor.Security.Constraint.RateLimiter
  alias Arbor.Security.Escalation
  alias Arbor.Security.Events
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.SystemAuthority

  # ===========================================================================
  # Public API — short, human-friendly names
  # ===========================================================================

  @doc """
  Authorize an operation on a resource.

  Checks whether the principal holds a valid capability for the resource.

  ## Examples

      Arbor.Security.authorize("agent_001", "arbor://fs/read/docs")
  """
  @spec authorize(String.t(), String.t(), atom(), keyword()) ::
          {:ok, :authorized}
          | {:ok, :pending_approval, String.t()}
          | {:error, term()}
  def authorize(principal_id, resource_uri, action \\ nil, opts \\ []),
    do:
      check_if_principal_has_capability_for_resource_action(
        principal_id,
        resource_uri,
        action,
        opts
      )

  @doc """
  Fast capability-only boolean check.
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

  @doc """
  Delegate a capability to another agent.

  Creates a new signed capability derived from an existing one.

  ## Options

  - `:constraints` - Additional constraints to apply
  - `:expires_at` - Override expiration (cannot exceed parent)
  - `:delegator_private_key` - Private key for signing the delegation record
  """
  @spec delegate(String.t(), String.t(), keyword()) :: {:ok, Capability.t()} | {:error, term()}
  def delegate(capability_id, new_principal_id, opts \\ []),
    do: delegate_capability_from_principal_to_principal(capability_id, new_principal_id, opts)

  @doc "List capabilities for an agent."
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_capabilities(principal_id, opts \\ []),
    do: list_capabilities_for_principal(principal_id, opts)

  # ===========================================================================
  # Public API — Identity (short names)
  # ===========================================================================

  @doc """
  Generate a new cryptographic identity.

  ## Examples

      {:ok, identity} = Arbor.Security.generate_identity()
      identity.agent_id
      #=> "agent_a1b2c3..."
  """
  @spec generate_identity(keyword()) :: {:ok, Identity.t()} | {:error, term()}
  def generate_identity(opts \\ []),
    do: generate_cryptographic_identity_keypair(opts)

  @doc """
  Register an agent's identity (public key).

  ## Examples

      :ok = Arbor.Security.register_identity(identity)
  """
  @spec register_identity(Identity.t()) :: :ok | {:error, term()}
  def register_identity(identity),
    do: register_agent_identity_with_public_key(identity)

  @doc """
  Look up the public key for an agent.
  """
  @spec lookup_public_key(String.t()) :: {:ok, binary()} | {:error, :not_found}
  def lookup_public_key(agent_id),
    do: lookup_public_key_for_agent(agent_id)

  @doc """
  Verify a signed request's authenticity.
  """
  @spec verify_request(SignedRequest.t()) :: {:ok, String.t()} | {:error, atom()}
  def verify_request(signed_request),
    do: verify_signed_request_authenticity(signed_request)

  # ===========================================================================
  # Public API — Identity Lifecycle (short names)
  # ===========================================================================

  @doc """
  Suspend an agent's identity.

  Sets the identity status to `:suspended`. Suspended identities cannot
  be used for lookups or authorization but can be resumed later.

  ## Options

  - `:reason` - Optional reason for suspension

  ## Examples

      :ok = Arbor.Security.suspend_identity("agent_001", reason: "Suspicious activity")
  """
  @spec suspend_identity(String.t(), keyword()) :: :ok | {:error, term()}
  def suspend_identity(agent_id, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    case Registry.suspend(agent_id, reason) do
      :ok ->
        Events.record_identity_suspended(agent_id, reason)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Resume a suspended identity.

  Sets the identity status back to `:active`. Only works for `:suspended`
  identities — revoked identities cannot be resumed.

  ## Examples

      :ok = Arbor.Security.resume_identity("agent_001")
  """
  @spec resume_identity(String.t()) :: :ok | {:error, term()}
  def resume_identity(agent_id) do
    case Registry.resume(agent_id) do
      :ok ->
        Events.record_identity_resumed(agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Revoke an agent's identity.

  Sets the identity status to `:revoked` (terminal state). This also
  revokes all capabilities held by the agent. The identity entry remains
  for audit trail purposes.

  ## Options

  - `:reason` - Optional reason for revocation

  ## Examples

      :ok = Arbor.Security.revoke_identity("agent_001", reason: "Account compromised")
  """
  @spec revoke_identity(String.t(), keyword()) :: :ok | {:error, term()}
  def revoke_identity(agent_id, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    case Registry.revoke_identity(agent_id, reason) do
      {:ok, cascade_count} ->
        Events.record_identity_revoked(agent_id, reason, cascade_count)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get the current status of an identity.

  ## Examples

      {:ok, :active} = Arbor.Security.identity_status("agent_001")
      {:ok, :suspended} = Arbor.Security.identity_status("agent_002")
  """
  @spec identity_status(String.t()) :: {:ok, Identity.status()} | {:error, :not_found}
  def identity_status(agent_id) do
    Registry.get_status(agent_id)
  end

  @doc """
  Check if an identity is active.

  Returns `true` only if the identity exists AND has status `:active`.

  ## Examples

      true = Arbor.Security.identity_active?("agent_001")
      false = Arbor.Security.identity_active?("suspended_agent")
  """
  @spec identity_active?(String.t()) :: boolean()
  def identity_active?(agent_id) do
    Registry.active?(agent_id)
  end

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl Arbor.Contracts.API.Security
  def check_if_principal_has_capability_for_resource_action(
        principal_id,
        resource_uri,
        _action,
        opts
      ) do
    with :ok <- check_identity_status(principal_id),
         :ok <- maybe_verify_identity(opts),
         {:ok, cap} <- find_capability(principal_id, resource_uri),
         :ok <- maybe_enforce_constraints(cap, principal_id, resource_uri),
         escalation_result <- Escalation.maybe_escalate(cap, principal_id, resource_uri) do
      case escalation_result do
        :ok ->
          emit_authorization_granted(principal_id, resource_uri, opts)
          {:ok, :authorized}

        {:ok, :pending_approval, proposal_id} ->
          emit_authorization_pending(principal_id, resource_uri, proposal_id, opts)
          {:ok, :pending_approval, proposal_id}

        {:error, reason} ->
          emit_authorization_denied(principal_id, resource_uri, reason, opts)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        emit_authorization_denied(principal_id, resource_uri, reason, opts)
        error
    end
  end

  @impl Arbor.Contracts.API.Security
  def check_if_principal_can_perform_operation_on_resource(principal_id, resource_uri, _action) do
    case CapabilityStore.find_authorizing(principal_id, resource_uri) do
      {:ok, _cap} -> true
      {:error, _} -> false
    end
  end

  @impl Arbor.Contracts.API.Security
  def grant_capability_to_principal_for_resource(opts) do
    principal_id = Keyword.fetch!(opts, :principal)
    resource_uri = Keyword.fetch!(opts, :resource)

    case Capability.new(
           resource_uri: resource_uri,
           principal_id: principal_id,
           expires_at: Keyword.get(opts, :expires_at),
           constraints: Keyword.get(opts, :constraints, %{}),
           delegation_depth: Keyword.get(opts, :delegation_depth, 3),
           metadata: Keyword.get(opts, :metadata, %{})
         ) do
      {:ok, cap} ->
        {:ok, signed_cap} = SystemAuthority.sign_capability(cap)

        case CapabilityStore.put(signed_cap) do
          {:ok, :stored} ->
            emit_capability_granted(signed_cap)
            {:ok, signed_cap}

          {:error, _} = error ->
            error
        end

      error ->
        error
    end
  end

  @impl Arbor.Contracts.API.Security
  def revoke_capability_by_id(capability_id, _opts) do
    case CapabilityStore.revoke(capability_id) do
      :ok ->
        emit_capability_revoked(capability_id)
        :ok

      error ->
        error
    end
  end

  @impl Arbor.Contracts.API.Security
  def list_capabilities_for_principal(principal_id, opts) do
    CapabilityStore.list_for_principal(principal_id, opts)
  end

  @impl Arbor.Contracts.API.Security
  def delegate_capability_from_principal_to_principal(capability_id, new_principal_id, opts) do
    with {:ok, parent_cap} <- CapabilityStore.get(capability_id),
         delegator_private_key = Keyword.fetch!(opts, :delegator_private_key),
         # Create the delegated capability (without delegation record yet)
         {:ok, new_cap} <-
           Capability.delegate(parent_cap, new_principal_id,
             constraints: Keyword.get(opts, :constraints, %{}),
             expires_at: Keyword.get(opts, :expires_at)
           ),
         # Sign a delegation record with the delegator's private key
         delegation_record =
           Signer.sign_delegation(parent_cap, new_cap, delegator_private_key),
         # Recreate with the delegation chain
         {:ok, new_cap_with_chain} <-
           Capability.delegate(parent_cap, new_principal_id,
             constraints: Keyword.get(opts, :constraints, %{}),
             expires_at: Keyword.get(opts, :expires_at),
             delegation_record: delegation_record
           ),
         # Sign the new capability with system authority
         {:ok, signed_cap} <- SystemAuthority.sign_capability(new_cap_with_chain),
         # Store with quota enforcement
         {:ok, :stored} <- CapabilityStore.put(signed_cap) do
      emit_capability_granted(signed_cap)
      emit_delegation_created(parent_cap.principal_id, new_principal_id, signed_cap.id)
      {:ok, signed_cap}
    end
  end

  # ===========================================================================
  # Identity contract implementations
  # ===========================================================================

  @impl Arbor.Contracts.API.Identity
  def generate_cryptographic_identity_keypair(opts) do
    Identity.generate(opts)
  end

  @impl Arbor.Contracts.API.Identity
  def register_agent_identity_with_public_key(%Identity{} = identity) do
    case Registry.register(Identity.public_only(identity)) do
      :ok ->
        emit_identity_registered(identity.agent_id)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @impl Arbor.Contracts.API.Identity
  def lookup_public_key_for_agent(agent_id) do
    Registry.lookup(agent_id)
  end

  @impl Arbor.Contracts.API.Identity
  def verify_signed_request_authenticity(%SignedRequest{} = request) do
    case Verifier.verify(request) do
      {:ok, agent_id} ->
        emit_identity_verification_succeeded(agent_id)
        {:ok, agent_id}

      {:error, reason} = error ->
        emit_identity_verification_failed(request.agent_id, reason)
        error
    end
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the security system.

  Normally started automatically by the application supervisor.
  """
  @impl Arbor.Contracts.API.Security
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Security.Application.start(:normal, opts)
  end

  @doc """
  Check if the security system is healthy.
  """
  @impl Arbor.Contracts.API.Security
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(CapabilityStore) != nil and
      Process.whereis(Registry) != nil and
      Process.whereis(Arbor.Security.Identity.NonceCache) != nil and
      Process.whereis(SystemAuthority) != nil and
      Process.whereis(RateLimiter) != nil
  end

  @doc """
  Get system statistics.
  """
  @spec stats() :: map()
  def stats do
    system_authority_id =
      if Process.whereis(SystemAuthority),
        do: SystemAuthority.agent_id(),
        else: nil

    rate_limiter_stats =
      if Process.whereis(RateLimiter),
        do: RateLimiter.stats(),
        else: %{bucket_count: 0, buckets: %{}}

    %{
      capabilities: CapabilityStore.stats(),
      identities: Registry.stats(),
      rate_limiter: rate_limiter_stats,
      system_authority_id: system_authority_id,
      healthy: healthy?()
    }
  end

  # ===========================================================================
  # Private functions
  # ===========================================================================

  defp check_identity_status(principal_id) do
    case Registry.get_status(principal_id) do
      {:ok, :active} ->
        :ok

      {:ok, :suspended} ->
        {:error, {:unauthorized, :identity_suspended}}

      {:ok, :revoked} ->
        {:error, {:unauthorized, :identity_revoked}}

      {:error, :not_found} ->
        # Identity not registered — allow authorization to proceed
        # (the capability check will handle unknown principals)
        :ok
    end
  end

  defp maybe_verify_identity(opts) do
    verify? = Keyword.get(opts, :verify_identity, Config.identity_verification_enabled?())
    signed_request = Keyword.get(opts, :signed_request)

    cond do
      not verify? ->
        :ok

      is_nil(signed_request) ->
        # No signed request provided — allow if verification not forced
        :ok

      true ->
        case Verifier.verify(signed_request) do
          {:ok, _agent_id} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  defp find_capability(principal_id, resource_uri) do
    case CapabilityStore.find_authorizing(principal_id, resource_uri) do
      {:ok, cap} -> {:ok, cap}
      {:error, :not_found} -> {:error, :unauthorized}
    end
  end

  defp maybe_enforce_constraints(cap, principal_id, resource_uri) do
    if Config.constraint_enforcement_enabled?() and cap.constraints != %{} do
      Constraint.enforce(cap.constraints, principal_id, resource_uri)
    else
      :ok
    end
  end

  # Event recording (dual-emit: EventLog + signal bus)
  # Delegates to Security.Events which persists to EventLog first,
  # then emits on the signal bus for real-time notification.

  defp emit_authorization_granted(principal_id, resource_uri, opts) do
    Events.record_authorization_granted(principal_id, resource_uri, opts)
  end

  defp emit_authorization_pending(principal_id, resource_uri, proposal_id, opts) do
    Events.record_authorization_pending(principal_id, resource_uri, proposal_id, opts)
  end

  defp emit_authorization_denied(principal_id, resource_uri, reason, opts) do
    Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
  end

  defp emit_capability_granted(cap) do
    Events.record_capability_granted(cap)
  end

  defp emit_capability_revoked(capability_id) do
    Events.record_capability_revoked(capability_id)
  end

  defp emit_identity_registered(agent_id) do
    Events.record_identity_registered(agent_id)
  end

  defp emit_identity_verification_succeeded(agent_id) do
    Events.record_identity_verification_succeeded(agent_id)
  end

  defp emit_identity_verification_failed(agent_id, reason) do
    Events.record_identity_verification_failed(agent_id, reason)
  end

  defp emit_delegation_created(delegator_id, recipient_id, capability_id) do
    Events.record_delegation_created(delegator_id, recipient_id, capability_id)
  end
end
