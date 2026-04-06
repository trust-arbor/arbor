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

      # Check authorization (with audit logging)
      case Arbor.Security.authorize("agent_001", "arbor://fs/read/docs", :read) do
        {:ok, :authorized} -> proceed()
        {:error, reason} -> handle_denial(reason)
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
  alias Arbor.Contracts.Security.InvocationReceipt
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Constraint
  alias Arbor.Security.Constraint.RateLimiter
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.Events
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.Keychain
  alias Arbor.Security.Reflex
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SystemAuthority

  require Logger

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

  @doc """
  Delegate matching capabilities from a parent to an agent.

  For each resource URI, finds the parent's authorizing capability and
  creates a signed delegation. Skips resources where the parent has no
  matching capability (logs a warning).

  ## Options

  - `:delegator_private_key` - Private key for signing delegation records (required)
  - `:resources` - List of resource URIs to delegate (required)

  ## Examples

      {:ok, caps} = Security.delegate_to_agent(human_id, agent_id,
        delegator_private_key: key,
        resources: ["arbor://fs/read/**", "arbor://fs/**"]
      )
  """
  @spec delegate_to_agent(String.t(), String.t(), keyword()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def delegate_to_agent(parent_id, agent_id, opts \\ []) do
    private_key = Keyword.fetch!(opts, :delegator_private_key)
    resources = Keyword.get(opts, :resources, [])

    delegated =
      Enum.reduce(resources, [], fn resource_uri, acc ->
        case CapabilityStore.find_authorizing(parent_id, resource_uri) do
          {:ok, parent_cap} ->
            case delegate(parent_cap.id, agent_id, delegator_private_key: private_key) do
              {:ok, delegated_cap} ->
                [delegated_cap | acc]

              {:error, reason} ->
                Logger.warning(
                  "[Security] Failed to delegate #{resource_uri} to #{agent_id}: #{inspect(reason)}"
                )

                acc
            end

          {:error, :not_found} ->
            Logger.warning(
              "[Security] Parent #{parent_id} has no capability for #{resource_uri}, skipping delegation"
            )

            acc
        end
      end)

    {:ok, Enum.reverse(delegated)}
  end

  @doc """
  Assign a role to a principal, granting all capabilities defined in the role.

  Grants are idempotent — capabilities that already exist are skipped.

  ## Options

  - `:delegation_depth` - Delegation depth for granted capabilities (default: 3)

  ## Examples

      {:ok, caps} = Security.assign_role("human_abc123", :admin)
  """
  @spec assign_role(String.t(), atom(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def assign_role(principal_id, role_name, opts \\ []) do
    alias Arbor.Security.Role

    case Role.get(role_name) do
      {:ok, resource_uris} ->
        delegation_depth = Keyword.get(opts, :delegation_depth, 3)

        granted =
          Enum.reduce(resource_uris, [], fn resource_uri, acc ->
            case grant(
                   principal: principal_id,
                   resource: resource_uri,
                   delegation_depth: delegation_depth
                 ) do
              {:ok, cap} ->
                [cap | acc]

              {:error, _reason} ->
                # Idempotent — skip if already granted or other non-fatal error
                acc
            end
          end)

        Logger.info(
          "[Security] Assigned role #{role_name} to #{principal_id} (#{length(granted)} capabilities)"
        )

        {:ok, Enum.reverse(granted)}

      {:error, :unknown_role} = error ->
        error
    end
  end

  @doc "List capabilities for an agent."
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_capabilities(principal_id, opts \\ []),
    do: list_capabilities_for_principal(principal_id, opts)

  @doc """
  Generate a unique trace ID for request correlation.

  Trace IDs link authorization, verification, and delegation events
  across a single request. Generate at the request boundary and pass
  as `trace_id: id` in authorize opts.
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    "trace_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

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
  Remove an agent's identity from the registry.
  """
  @spec deregister_identity(String.t()) :: :ok | {:error, term()}
  def deregister_identity(agent_id) when is_binary(agent_id) do
    Registry.deregister(agent_id)
  end

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
    Registry.identity_status(agent_id)
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
        action,
        opts
      ) do
    # Step 1: Reflexes — instant safety block, must run before anything else
    reflex_context = build_reflex_context(resource_uri, action, opts)

    with :ok <- check_reflexes(principal_id, reflex_context, resource_uri, action, opts) do
      # Step 2: Build AuthContext with identity, capabilities, trust profile
      auth = build_auth_context(principal_id, opts)

      # Step 3: Pure authorization decision (no side effects)
      case AuthDecision.evaluate(auth, resource_uri, action, opts) do
        {:ok, :authorized, auth} ->
          handle_authorized(auth, principal_id, resource_uri, action, opts)

        {:ok, :requires_approval, cap, auth} ->
          handle_requires_approval(cap, auth, principal_id, resource_uri, action, opts)

        {:error, reason, _auth} ->
          Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
        error
    end
  end

  # Side effects for authorized decisions
  defp handle_authorized(_auth, principal_id, resource_uri, action, opts) do
    # Stateful constraint checks (rate limiting)
    cap = find_capability_for_side_effects(principal_id, resource_uri)

    with :ok <- if(cap, do: maybe_enforce_constraints(cap, principal_id, resource_uri), else: :ok) do
      # FileGuard for fs:// URIs with file_path
      case maybe_check_file_guard(principal_id, resource_uri, opts) do
        :ok ->
          Events.record_authorization_granted(principal_id, resource_uri, opts)
          if cap, do: maybe_check_max_uses(cap)
          if cap, do: maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, opts)
          {:ok, :authorized}

        {:ok, resolved_path} ->
          Events.record_authorization_granted(principal_id, resource_uri, opts)
          if cap, do: maybe_check_max_uses(cap)
          if cap, do: maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, opts)
          {:ok, :authorized, resolved_path}

        {:error, reason} ->
          Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
        error
    end
  end

  # Side effects for requires_approval decisions
  defp handle_requires_approval(cap, _auth, principal_id, resource_uri, action, opts) do
    # Escalate to Consensus via ApprovalGuard (side effect — GenServer call)
    case Arbor.Security.ApprovalGuard.check(cap, principal_id, resource_uri) do
      :ok ->
        # Graduated — treat as authorized
        Events.record_authorization_granted(principal_id, resource_uri, opts)
        maybe_check_max_uses(cap)
        maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, opts)
        {:ok, :authorized}

      {:ok, :pending_approval, proposal_id} ->
        Events.record_authorization_pending(principal_id, resource_uri, proposal_id, opts)
        maybe_emit_receipt(cap, principal_id, resource_uri, action, :pending_approval, opts)
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
        {:error, reason}
    end
  end

  defp build_auth_context(principal_id, opts) do
    alias Arbor.Contracts.Security.AuthContext

    AuthContext.new(principal_id,
      signed_request: Keyword.get(opts, :signed_request),
      signer: Keyword.get(opts, :signer),
      session_id: Keyword.get(opts, :session_id)
    )
    |> AuthContext.load()
  end

  # Look up capability for side-effect operations (max_uses, receipt).
  # AuthDecision already verified the capability exists — this is just
  # to get the struct for the side-effect helpers.
  defp find_capability_for_side_effects(principal_id, resource_uri) do
    case CapabilityStore.find_authorizing(principal_id, resource_uri) do
      {:ok, cap} -> cap
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @impl Arbor.Contracts.API.Security
  def grant_capability_to_principal_for_resource(opts) do
    principal_id = Keyword.fetch!(opts, :principal)
    resource_uri = Keyword.fetch!(opts, :resource)

    case Capability.new(
           resource_uri: resource_uri,
           principal_id: principal_id,
           expires_at: Keyword.get(opts, :expires_at),
           not_before: Keyword.get(opts, :not_before),
           constraints: Keyword.get(opts, :constraints, %{}),
           delegation_depth: Keyword.get(opts, :delegation_depth, 3),
           max_uses: Keyword.get(opts, :max_uses),
           allowed_delegatees: Keyword.get(opts, :allowed_delegatees),
           session_id: Keyword.get(opts, :session_id),
           task_id: Keyword.get(opts, :task_id),
           principal_scope: Keyword.get(opts, :principal_scope),
           metadata: Keyword.get(opts, :metadata, %{})
         ) do
      {:ok, cap} ->
        {:ok, signed_cap} = SystemAuthority.sign_capability(cap)

        case CapabilityStore.put(signed_cap) do
          {:ok, :stored} ->
            Events.record_capability_granted(signed_cap)
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
        Events.record_capability_revoked(capability_id)
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
         # Create the delegated capability once (without delegation record)
         {:ok, new_cap} <-
           Capability.delegate(parent_cap, new_principal_id,
             constraints: Keyword.get(opts, :constraints, %{}),
             expires_at: Keyword.get(opts, :expires_at)
           ),
         # Sign a delegation record over the new cap's payload
         delegation_record =
           Signer.sign_delegation(parent_cap, new_cap, delegator_private_key),
         # Attach the chain to the SAME capability (preserving id/timestamps)
         new_cap_with_chain = %{
           new_cap
           | delegation_chain: parent_cap.delegation_chain ++ [delegation_record]
         },
         # Sign the new capability with system authority
         {:ok, signed_cap} <- SystemAuthority.sign_capability(new_cap_with_chain),
         # Store with quota enforcement
         {:ok, :stored} <- CapabilityStore.put(signed_cap) do
      Events.record_capability_granted(signed_cap)
      Events.record_delegation_created(parent_cap.principal_id, new_principal_id, signed_cap.id)
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
        Events.record_identity_registered(identity.agent_id)
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
        Events.record_identity_verification_succeeded(agent_id,
          signature: Base.encode64(request.signature),
          payload_hash: Base.encode16(:crypto.hash(:sha256, request.payload), case: :lower),
          nonce: Base.encode64(request.nonce),
          signed_at: DateTime.to_iso8601(request.timestamp)
        )

        {:ok, agent_id}

      {:error, reason} = error ->
        Events.record_identity_verification_failed(request.agent_id, reason,
          nonce: Base.encode64(request.nonce),
          signed_at: DateTime.to_iso8601(request.timestamp)
        )

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
      Process.whereis(RateLimiter) != nil and
      Process.whereis(Arbor.Security.Reflex.Registry) != nil
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
  # Reflex System (Seed/Host Phase 4)
  # ===========================================================================

  @doc """
  Check context against all active reflexes.

  Returns `:ok`, `{:blocked, reflex, reason}`, or `{:warned, warnings}`.
  """
  defdelegate check_reflex(context), to: Reflex, as: :check

  # ===========================================================================
  # Keychain (Seed/Host Phase 4)
  # ===========================================================================

  @doc """
  Endorse an agent's identity by signing their public key with the system authority.
  """
  defdelegate endorse_agent(identity), to: SystemAuthority

  @doc """
  Verify an agent endorsement signed by the system authority.
  """
  defdelegate verify_agent_endorsement(endorsement), to: SystemAuthority

  @doc """
  Create a new keychain for an agent (signing + encryption keypairs).
  """
  defdelegate new_keychain(agent_id), to: Keychain, as: :new

  # ===========================================================================
  # Signing Key Storage
  # ===========================================================================

  @doc """
  Store an agent's signing private key (encrypted at rest).

  Called during agent creation to persist the Ed25519 private key.
  The key is encrypted with AES-256-GCM using a master key.
  """
  defdelegate store_signing_key(agent_id, private_key), to: SigningKeyStore, as: :put

  @doc """
  Load an agent's signing private key.

  Returns `{:ok, private_key}` or `{:error, :no_signing_key}`.
  """
  defdelegate load_signing_key(agent_id), to: SigningKeyStore, as: :get

  @doc """
  Delete an agent's signing key.

  Called during agent destruction.
  """
  defdelegate delete_signing_key(agent_id), to: SigningKeyStore, as: :delete

  @doc """
  Create a signer function for an agent.

  Returns a function that closes over the agent_id and private_key,
  producing a fresh SignedRequest for any given payload. The orchestrator
  receives this function — never the raw private key.

  ## Example

      {:ok, signer} = Arbor.Security.make_signer(agent_id, private_key)
      {:ok, signed} = signer.("arbor://fs/read")
  """
  @spec make_signer(String.t(), binary()) ::
          (binary() -> {:ok, SignedRequest.t()} | {:error, term()})
  def make_signer(agent_id, private_key)
      when is_binary(agent_id) and is_binary(private_key) do
    fn payload -> SignedRequest.sign(payload, agent_id, private_key) end
  end

  # ===========================================================================
  # OIDC Authentication
  # ===========================================================================

  @doc """
  Authenticate a human operator via OIDC device flow.

  Starts the device authorization grant (RFC 8628), waits for the user
  to authorize in their browser, then binds persistent keypairs to the
  OIDC identity.

  Returns `{:ok, agent_id, signer}` where signer is a function
  `(payload -> {:ok, SignedRequest.t()})`.
  """
  @spec authenticate_oidc(map() | nil) :: {:ok, String.t(), function()} | {:error, term()}
  def authenticate_oidc(config \\ nil) do
    alias Arbor.Security.OIDC
    OIDC.authenticate_device_flow(config)
  end

  @doc """
  Authenticate using an existing OIDC ID token.

  Verifies the token, loads the bound keypair, and returns a signer.
  """
  @spec authenticate_oidc_token(String.t(), map() | nil) ::
          {:ok, String.t(), function()} | {:error, term()}
  def authenticate_oidc_token(id_token, config \\ nil) do
    alias Arbor.Security.OIDC
    OIDC.authenticate_token(id_token, config)
  end

  @doc """
  Check if an agent ID represents a human (OIDC-authenticated) identity.
  """
  @spec human_identity?(String.t()) :: boolean()
  def human_identity?(agent_id) when is_binary(agent_id) do
    String.starts_with?(agent_id, "human_")
  end

  # ===========================================================================
  # Private functions
  # ===========================================================================

  # Old helpers moved to AuthDecision — deleted to avoid dead code.

  defp maybe_emit_receipt(cap, principal_id, resource_uri, action, result, opts) do
    if Config.invocation_receipts_enabled?() do
      case InvocationReceipt.new(
             capability_id: cap.id,
             principal_id: principal_id,
             resource_uri: resource_uri,
             action: action,
             result: result,
             delegation_chain: cap.delegation_chain,
             session_id: cap.session_id,
             task_id: cap.task_id
           ) do
        {:ok, receipt} ->
          case SystemAuthority.sign_receipt(receipt) do
            {:ok, signed_receipt} ->
              Events.record_invocation_receipt(signed_receipt)
              Keyword.get(opts, :receipt_callback, &Function.identity/1).(signed_receipt)

            {:error, _} ->
              :ok
          end

        {:error, _} ->
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  # check_scope_binding moved to AuthDecision

  defp maybe_check_max_uses(%Capability{max_uses: nil}), do: :ok

  defp maybe_check_max_uses(%Capability{max_uses: max_uses} = cap) do
    case CapabilityStore.increment_usage(cap.id) do
      {:ok, count} when count >= max_uses ->
        CapabilityStore.revoke(cap.id)
        Events.record_capability_revoked(cap.id)

      {:ok, _count} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  # maybe_verify_delegation_chain moved to AuthDecision

  defp maybe_enforce_constraints(cap, principal_id, resource_uri) do
    if Config.constraint_enforcement_enabled?() and cap.constraints != %{} do
      Constraint.enforce(cap.constraints, principal_id, resource_uri)
    else
      :ok
    end
  end

  # When authorizing arbor://fs/* URIs with a file_path option,
  # verify the path via FileGuard. This integrates path-scoped
  # authorization into the main auth chain instead of requiring
  # callers to call FileGuard separately.
  defp maybe_check_file_guard(principal_id, resource_uri, opts) do
    file_path = Keyword.get(opts, :file_path)

    if file_path && String.starts_with?(resource_uri, "arbor://fs/") do
      if Code.ensure_loaded?(Arbor.Security.FileGuard) do
        operation = infer_fs_operation(resource_uri)
        Arbor.Security.FileGuard.authorize(principal_id, file_path, operation)
      else
        :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp infer_fs_operation("arbor://fs/read" <> _), do: :read
  defp infer_fs_operation("arbor://fs/write" <> _), do: :write
  defp infer_fs_operation("arbor://fs/execute" <> _), do: :execute
  defp infer_fs_operation("arbor://fs/delete" <> _), do: :delete
  defp infer_fs_operation("arbor://fs/list" <> _), do: :list
  defp infer_fs_operation(_), do: :read

  # Reflex checking — instant safety blocks before expensive authorization
  defp check_reflexes(principal_id, context, resource_uri, action, _opts) do
    if Config.reflex_checking_enabled?() do
      case Reflex.check(context) do
        :ok ->
          :ok

        {:blocked, reflex, message} ->
          Events.record_reflex_triggered(principal_id, reflex, resource_uri, action, :blocked)
          {:error, {:reflex_blocked, reflex.id, message}}

        {:warned, warnings} ->
          # Log warnings but allow the request to proceed
          for {reflex, message} <- warnings do
            Events.record_reflex_warning(principal_id, reflex.id, message)
          end

          :ok
      end
    else
      :ok
    end
  rescue
    _ ->
      Logger.error("Reflex check failed due to exception — failing closed for safety")
      {:error, {:reflex_check_failed, :exception}}
  end

  defp build_reflex_context(resource_uri, action, opts) do
    context = %{resource: resource_uri, action: action}

    # Add command if provided in opts (for shell operations)
    context =
      case Keyword.get(opts, :command) do
        nil -> context
        cmd -> Map.put(context, :command, cmd)
      end

    # Add path if it can be extracted from the resource URI
    context =
      case extract_path_from_uri(resource_uri) do
        nil -> context
        path -> Map.put(context, :path, path)
      end

    # Add URL if provided
    context =
      case Keyword.get(opts, :url) do
        nil -> context
        url -> Map.put(context, :url, url)
      end

    context
  end

  # Extract file path from arbor:// resource URIs
  defp extract_path_from_uri("arbor://fs/" <> rest), do: "/" <> rest
  defp extract_path_from_uri(_), do: nil

end
