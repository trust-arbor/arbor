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
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.SystemAuthority
  alias Arbor.Signals

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
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl Arbor.Contracts.API.Security
  def check_if_principal_has_capability_for_resource_action(
        principal_id,
        resource_uri,
        _action,
        opts
      ) do
    case maybe_verify_identity(opts) do
      :ok ->
        case find_capability(principal_id, resource_uri) do
          {:ok, _cap} ->
            emit_authorization_granted(principal_id, resource_uri, opts)
            {:ok, :authorized}

          {:error, reason} = error ->
            emit_authorization_denied(principal_id, resource_uri, reason, opts)
            error
        end

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
        :ok = CapabilityStore.put(signed_cap)
        emit_capability_granted(signed_cap)
        {:ok, signed_cap}

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
         {:ok, signed_cap} <- SystemAuthority.sign_capability(new_cap_with_chain) do
      :ok = CapabilityStore.put(signed_cap)
      emit_capability_granted(signed_cap)
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
      Process.whereis(SystemAuthority) != nil
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

    %{
      capabilities: CapabilityStore.stats(),
      identities: Registry.stats(),
      system_authority_id: system_authority_id,
      healthy: healthy?()
    }
  end

  # ===========================================================================
  # Private functions
  # ===========================================================================

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

  # Identity signals

  defp emit_identity_registered(agent_id) do
    Signals.emit(:security, :identity_registered, %{
      agent_id: agent_id
    })
  end

  defp emit_identity_verification_succeeded(agent_id) do
    Signals.emit(:security, :identity_verification_succeeded, %{
      agent_id: agent_id
    })
  end

  defp emit_identity_verification_failed(agent_id, reason) do
    Signals.emit(:security, :identity_verification_failed, %{
      agent_id: agent_id,
      reason: reason
    })
  end
end
