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
  alias Arbor.Common.SafePath
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Config
  alias Arbor.Security.Constraint
  alias Arbor.Security.Constraint.RateLimiter
  alias Arbor.Security.AuthDecision
  alias Arbor.Security.EgressGate
  alias Arbor.Security.Events
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.Identity.Verifier
  alias Arbor.Security.Keychain
  alias Arbor.Security.Reflex
  alias Arbor.Security.SigningKeyStore
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.UriRegistry

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
  Record a durable security event for an answered approval request.

  External approval surfaces should use this facade instead of writing directly
  to the event backend.
  """
  @spec record_approval_answered(String.t(), String.t(), atom(), atom(), keyword()) ::
          :ok | {:error, term()}
  def record_approval_answered(actor_id, approval_id, source, decision, opts \\ []) do
    Events.record_approval_answered(actor_id, approval_id, source, decision, opts)
  end

  @doc """
  Record a durable security event for an async orchestration task dispatch.

  External orchestration surfaces should use this facade after starting a task.
  """
  @spec record_orchestration_task_dispatched(String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_orchestration_task_dispatched(actor_id, task_id, agent_id, opts \\ []) do
    Events.record_orchestration_task_dispatched(actor_id, task_id, agent_id, opts)
  end

  @doc """
  Return the effective resource URI used by the authorization matcher.

  This is exposed so policy-layer code can perform explicit pre-authorization
  decisions against the same URI the security kernel will check. In particular,
  bare `arbor://fs/<op>` URIs plus `file_path:` are synthesized into the
  path-embedded URI before capability lookup.
  """
  @spec authorization_resource_uri(String.t(), keyword()) :: String.t()
  def authorization_resource_uri(resource_uri, opts \\ []),
    do: maybe_synthesize_fs_path_uri(resource_uri, opts)

  @doc """
  Return the checked effective resource URI used by authorization.

  Unlike `authorization_resource_uri/2`, this reports path-normalization errors
  instead of falling back to the caller's original URI. Authorization and trust
  policy callers use this form so invalid `file_path:` input fails closed before
  capability lookup or policy minting.
  """
  @spec normalize_authorization_resource_uri(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def normalize_authorization_resource_uri(resource_uri, opts \\ []),
    do: synthesize_fs_path_uri(resource_uri, opts)

  @doc """
  Standalone egress authorization for callers WITHOUT an operation capability
  (2026-06-14 URI-addressing-vs-classification decision) — notably the
  compute-node LLM path (`LlmHandler`), where pipeline LLM calls have no per-op
  capability. Unlike `authorize/4`, this checks ONLY egress (it does not require
  or look up a capability authorizing the operation itself); it supplies the
  agent's egress-constrained caps to `EgressGate` for the `:ask`-downgrade
  refinement.

  Inert (`:allow`) unless `config :arbor_security, :egress_gate_enforcing`. The
  security kernel does not consult trust policy directly; callers that want
  profile standing pass `:egress_mode` in `opts` or use `Arbor.Trust.authorize_egress/3`.
  Emits `:egress_observed` telemetry for boundary-crossing egress regardless, so
  the compute-node egress surface is observable while the gate is dark. Arbor's
  signal runtime bridges this telemetry back to signals when `arbor_signals` is
  running.

  ## Parameters
  - `egress_tier` — resolved `Arbor.Contracts.Security.Classification.egress_tier`
  - `opts` — `:egress_taint` (level/Taint), `:egress_destination` (host/provider),
    `:egress_mode` (`:allow`/`:ask`/`:block`/`:auto`) from a policy layer

  ## Returns
  - `:allow`
  - `{:requires_approval, :egress}` — the agent lacks standing; caller decides how
    to surface (the compute-node path halts the node)
  - `{:error, {:egress_blocked, tier, reason}}` — taint exfil or profile `:block`
  """
  @spec authorize_egress(String.t(), atom(), keyword()) ::
          :allow
          | {:requires_approval, :egress}
          | {:error, {:egress_blocked, atom(), atom()}}
  def authorize_egress(principal_id, egress_tier, opts \\ []) do
    emit_egress_observed(principal_id, egress_tier, opts)

    caps =
      case CapabilityStore.list_for_principal(principal_id) do
        {:ok, list} -> list
        _ -> []
      end

    case EgressGate.decide(principal_id, egress_tier, opts, caps) do
      :allow -> :allow
      :ask -> {:requires_approval, :egress}
      {:block, reason} -> {:error, {:egress_blocked, egress_tier, reason}}
    end
  end

  # Observability for boundary-crossing egress on the standalone path. Fire-and-
  # forget; only for external tiers (on_host/on_premises are low-signal).
  defp emit_egress_observed(principal_id, tier, opts)
       when tier in [:external_provider, :external_peer] do
    data = %{
      agent_id: principal_id,
      egress_tier: tier,
      enforcing: EgressGate.enforcing?(),
      egress_destination: Keyword.get(opts, :egress_destination),
      # The flowing data's taint level — THE signal for observe-before-enable:
      # whether real egress carries untrusted data the taint conjunct would block.
      egress_taint: egress_taint_level(Keyword.get(opts, :egress_taint)),
      source: :compute_node
    }

    # Prefer durable bridging so observe-before-enable data persists to the
    # EventLog (security:events stream), matching the action path when the
    # signals telemetry bridge is attached.
    Arbor.Security.Telemetry.emit(:egress_observed, data,
      signal_durable: true,
      stream_id: "security:events"
    )

    :ok
  rescue
    _ -> :ok
  end

  defp emit_egress_observed(_principal_id, _tier, _opts), do: :ok

  # Normalize an egress taint opt (level atom or Taint struct) to a level atom.
  defp egress_taint_level(%{level: level}), do: level
  defp egress_taint_level(level) when is_atom(level), do: level
  defp egress_taint_level(_), do: nil

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
  Revoke all session-scoped capabilities for a session.

  Used to clean up capabilities granted for a session's lifetime (e.g. after a
  trust-profile change or session termination). Capabilities not bound to the
  given `session_id` are left untouched.
  """
  @spec revoke_by_session(String.t()) :: {:ok, non_neg_integer()}
  def revoke_by_session(session_id), do: CapabilityStore.revoke_by_session(session_id)

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
  Side-effect-free check that a capability can authorize a resource URI.

  This mirrors the non-mutating parts of the authorization matcher for
  enumeration and self-inspection paths: capability validity, scope bindings,
  resource matching, and signature acceptability. It does not emit signals,
  increment usage counters, or revoke max-use capabilities.
  """
  @spec capability_authorizes?(Capability.t(), String.t(), keyword()) :: boolean()
  def capability_authorizes?(capability, resource_uri, opts \\ [])

  def capability_authorizes?(%Capability{} = cap, resource_uri, opts)
      when is_binary(resource_uri) do
    Capability.valid?(cap) and Capability.scope_matches?(cap, scope_context(opts)) and
      Capability.grants_access?(cap, resource_uri) and capability_signature_acceptable?(cap)
  end

  def capability_authorizes?(_capability, _resource_uri, _opts), do: false

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

  defp scope_context(opts) do
    []
    |> maybe_put_scope(:session_id, Keyword.get(opts, :session_id))
    |> maybe_put_scope(:task_id, Keyword.get(opts, :task_id))
    |> maybe_put_scope(:principal_scope, Keyword.get(opts, :principal_scope))
  end

  defp maybe_put_scope(scope, _key, nil), do: scope
  defp maybe_put_scope(scope, key, value), do: Keyword.put(scope, key, value)

  defp capability_signature_acceptable?(%Capability{} = cap) do
    cond do
      Capability.signed?(cap) ->
        SystemAuthority.verify_capability_signature(cap) == :ok

      Config.capability_signing_required?() ->
        false

      true ->
        true
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
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
    # If the caller passed `:file_path` and the URI is the bare
    # `arbor://fs/<op>` form, synthesize the path-embedded URI for
    # cap lookup. Without this, path-scoped caps like
    # `arbor://fs/read/Users/azmaveth/.arbor/reports/upstream-deps/**`
    # don't match the action's bare URI. With this synthesis, the per-run cap
    # matches via the shared capability URI wildcard matcher and AuthDecision
    # returns `:authorized` without the approval detour.
    # FileGuard still runs in `maybe_check_file_guard/4` as
    # defense-in-depth path normalization. Surfaced 2026-06-06 by the
    # morning-digest pipelines hitting the gate when run via the
    # per-run identity flow.
    # Step 1: Reflexes — instant safety block, must run before anything else
    requested_resource_uri = resource_uri

    with {:ok, resource_uri} <- normalize_authorization_resource_uri(resource_uri, opts),
         reflex_context = build_reflex_context(resource_uri, action, opts),
         :ok <- check_reflexes(principal_id, reflex_context, resource_uri, action, opts) do
      # Step 2: Build AuthContext with identity, capabilities, trust profile
      auth = build_auth_context(principal_id, opts)

      # Step 3: Pure authorization decision (no side effects)
      case AuthDecision.evaluate(auth, resource_uri, action, opts) do
        {:ok, :authorized, cap, auth} ->
          handle_authorized(cap, auth, principal_id, resource_uri, action, opts)

        {:ok, :requires_approval, cap, auth} ->
          handle_requires_approval(cap, auth, principal_id, resource_uri, action, opts)

        {:error, reason, _auth} ->
          Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
          {:error, reason}
      end
    else
      {:error, reason} = error ->
        Events.record_authorization_denied(principal_id, requested_resource_uri, reason, opts)
        error
    end
  end

  # Side effects for authorized decisions
  defp handle_authorized(cap, _auth, principal_id, resource_uri, action, opts) do
    # Stateful constraint checks (rate limiting) — cap was already found by AuthDecision
    with :ok <- if(cap, do: maybe_enforce_constraints(cap, principal_id, resource_uri), else: :ok) do
      # FileGuard for fs:// URIs — runs explicit (caller passed :file_path)
      # OR implicit (we have a matched cap and the URI's path-part is the
      # implicit file_path) defense-in-depth normalization.
      file_guard_result = maybe_check_file_guard(principal_id, resource_uri, opts, cap)

      case normalize_file_guard_result(file_guard_result) do
        :ok ->
          Events.record_authorization_granted(principal_id, resource_uri, opts)
          if cap, do: maybe_check_max_uses(cap)
          if cap, do: maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, opts)
          {:ok, :authorized}

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
    # Escalate to Consensus for kernel-owned capability constraints. Trust policy
    # approval lives in Arbor.Trust.ApprovalGuard.
    escalation_opts =
      opts
      |> Keyword.put_new(:gate, :capability_constraint)
      |> Keyword.put_new(:reason, :capability_requires_approval)

    case Arbor.Security.Escalation.maybe_escalate(
           cap,
           principal_id,
           resource_uri,
           escalation_opts
         ) do
      :ok ->
        # Graduated — still enforce constraints (rate limits, time windows)
        # AND run the implicit FileGuard normalization for fs URIs. The
        # approval-graduated path is structurally just another success
        # path and needs the same path-normalization defense as
        # handle_authorized — otherwise an fs cap with requires_approval
        # silently skips symlink-escape detection.
        with :ok <- maybe_enforce_constraints(cap, principal_id, resource_uri),
             fg_result <- maybe_check_file_guard(principal_id, resource_uri, opts, cap),
             :ok <- normalize_file_guard_result(fg_result) do
          Events.record_authorization_granted(principal_id, resource_uri, opts)
          maybe_check_max_uses(cap)
          maybe_emit_receipt(cap, principal_id, resource_uri, action, :granted, opts)
          {:ok, :authorized}
        else
          {:error, reason} = error ->
            Events.record_authorization_denied(principal_id, resource_uri, reason, opts)
            error
        end

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

    ctx =
      AuthContext.new(principal_id,
        signed_request: Keyword.get(opts, :signed_request),
        signer: Keyword.get(opts, :signer),
        session_id: Keyword.get(opts, :session_id)
      )
      |> AuthContext.load()

    # `identity_verified: true` is set by callers that have ALREADY verified the
    # signer's per-request signature upstream (e.g. the Gateway's
    # SignedRequestAuth, which also consumed the single-use nonce). It marks the
    # context verified so AuthDecision skips re-verification — re-running it would
    # trip the nonce replay guard. Only set this after a genuine upstream verify.
    if Keyword.get(opts, :identity_verified, false),
      do: AuthContext.mark_verified(ctx),
      else: ctx
  end

  # Look up capability for side-effect operations (max_uses, receipt).
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

  @doc """
  Returns the canonical `arbor://` URI prefixes the registry recognizes.

  Pure (reads the compile-time prefix list) — usable without the registry
  GenServer running. Exposed for tooling such as the Security Sentinel's
  URI-registration-coverage detector.
  """
  defdelegate canonical_uri_prefixes(), to: UriRegistry, as: :canonical_prefixes

  @doc "Return whether a URI matches a canonical or runtime-registered prefix."
  @spec uri_registered?(String.t()) :: boolean()
  defdelegate uri_registered?(uri), to: UriRegistry, as: :registered?

  @doc "Register an additional runtime URI prefix."
  @spec register_uri_prefix(String.t()) :: :ok | {:error, term()}
  defdelegate register_uri_prefix(prefix), to: UriRegistry, as: :register

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

  defp maybe_enforce_constraints(cap, principal_id, resource_uri) do
    if Config.constraint_enforcement_enabled?() and cap.constraints != %{} do
      Constraint.enforce(cap.constraints, principal_id, resource_uri)
    else
      :ok
    end
  end

  # Synthesize the path-embedded URI when the caller passed a bare
  # `arbor://fs/<op>` URI plus the `:file_path` opt. Lets path-scoped
  # caps participate in the URI matcher directly.
  defp maybe_synthesize_fs_path_uri(resource_uri, opts) when is_binary(resource_uri) do
    case synthesize_fs_path_uri(resource_uri, opts) do
      {:ok, effective_uri} -> effective_uri
      {:error, _reason} -> resource_uri
    end
  end

  defp maybe_synthesize_fs_path_uri(resource_uri, _opts), do: resource_uri

  defp synthesize_fs_path_uri(resource_uri, opts) when is_binary(resource_uri) do
    case Keyword.get(opts, :file_path) do
      file_path when is_binary(file_path) ->
        if bare_fs_op_uri?(resource_uri) do
          with {:ok, path} <- normalize_fs_authorization_path(file_path, opts) do
            {:ok, append_fs_authorization_path(resource_uri, path)}
          else
            {:error, reason} -> {:error, {:invalid_file_path, reason}}
          end
        else
          {:ok, resource_uri}
        end

      nil ->
        {:ok, resource_uri}

      _other ->
        if bare_fs_op_uri?(resource_uri) do
          {:error, {:invalid_file_path, :not_binary}}
        else
          {:ok, resource_uri}
        end
    end
  end

  defp synthesize_fs_path_uri(resource_uri, _opts), do: {:ok, resource_uri}

  defp append_fs_authorization_path(resource_uri, ""), do: resource_uri
  defp append_fs_authorization_path(resource_uri, path), do: "#{resource_uri}/#{path}"

  defp normalize_fs_authorization_path(file_path, opts) do
    case workspace_root(opts) do
      {:ok, workspace} ->
        with {:ok, resolved} <- SafePath.resolve_within(file_path, workspace) do
          {:ok, relativize_path(resolved, workspace)}
        end

      :none ->
        normalize_unscoped_fs_path(file_path)
    end
  end

  defp workspace_root(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) and workspace != "" ->
        {:ok, SafePath.normalize(workspace)}

      _ ->
        :none
    end
  end

  defp relativize_path(path, root) do
    case Path.relative_to(path, root) do
      "." -> ""
      relative -> String.trim_leading(relative, "/")
    end
  end

  defp normalize_unscoped_fs_path(file_path) do
    with :ok <- SafePath.validate(file_path) do
      if SafePath.absolute?(file_path) do
        {:ok, file_path |> SafePath.normalize() |> String.trim_leading("/")}
      else
        normalize_relative_fs_path(file_path)
      end
    end
  end

  defp normalize_relative_fs_path(file_path) do
    result =
      file_path
      |> Path.split()
      |> Enum.reduce_while({:ok, []}, fn
        ".", {:ok, parts} ->
          {:cont, {:ok, parts}}

        "..", {:ok, []} ->
          {:halt, {:error, :path_traversal}}

        "..", {:ok, [_ | rest]} ->
          {:cont, {:ok, rest}}

        part, {:ok, parts} ->
          {:cont, {:ok, [part | parts]}}
      end)

    case result do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join("/")}
      {:error, _reason} = error -> error
    end
  end

  defp file_guard_authorization_path(file_path, opts) do
    with {:ok, path} <- normalize_fs_authorization_path(file_path, opts) do
      {:ok, "/" <> path}
    end
  end

  # `arbor://fs/<op>` with no further path segments. Matches:
  #   "arbor://fs/read", "arbor://fs/write", "arbor://fs/list", etc.
  # Doesn't match: "arbor://fs/read/some/path" (already path-embedded).
  defp bare_fs_op_uri?("arbor://fs/" <> rest), do: not String.contains?(rest, "/")
  defp bare_fs_op_uri?(_), do: false

  # When authorizing arbor://fs/* URIs with a file_path option,
  # verify the path via FileGuard. This integrates path-scoped
  # authorization into the main auth chain instead of requiring
  # callers to call FileGuard separately.
  # Reduce maybe_check_file_guard's three-shape return to :ok / {:error, _}
  # for use in `with` chains that just need a pass/fail signal.
  defp normalize_file_guard_result(:ok), do: :ok
  defp normalize_file_guard_result({:ok, _resolved_path}), do: :ok
  defp normalize_file_guard_result({:error, _} = err), do: err

  defp maybe_check_file_guard(principal_id, resource_uri, opts, cap) do
    file_path = Keyword.get(opts, :file_path)
    file_guard = file_guard_module()

    cond do
      # Explicit path: caller knows they want path-bound checking. Full
      # FileGuard.authorize/3 lookup-and-resolve against the same canonical
      # path form used for capability lookup above.
      file_path && String.starts_with?(resource_uri, "arbor://fs/") ->
        if Code.ensure_loaded?(file_guard) do
          operation = infer_fs_operation(resource_uri)

          with {:ok, guard_path} <- file_guard_authorization_path(file_path, opts) do
            file_guard.authorize(principal_id, guard_path, operation)
          end
        else
          :ok
        end

      # Implicit path defense-in-depth: caller didn't pass :file_path, but
      # the URI itself is an fs:// URI and we have a matched cap. Run pure
      # path normalization (SafePath + symlink-escape detection) on the
      # URI's path-part against the cap's root. The URI matcher's prefix
      # check already accepted; this adds the SafePath layer that callers
      # used to have to opt into.
      cap != nil and String.starts_with?(resource_uri, "arbor://fs/") and
          Code.ensure_loaded?(file_guard) ->
        case file_guard.normalize_uri_path_for_capability(resource_uri, cap) do
          {:ok, resolved} -> {:ok, resolved}
          :not_applicable -> :ok
          {:error, _reason} = err -> err
        end

      true ->
        :ok
    end
  rescue
    # H2 review fix (2026-06-09): a crash in path validation must NOT skip
    # the path-binding check and authorize. In the explicit-path branch
    # FileGuard.authorize/3 IS the binding of a bare arbor://fs/<op> cap to
    # a concrete path — swallowing its exception and returning :ok would let
    # a broad fs cap write/read anywhere. Fail closed, matching
    # check_reflexes/5 in this same module. (Was `:ok`.)
    _ -> {:error, {:file_guard_error, :exception}}
  catch
    :exit, _ -> {:error, {:file_guard_error, :exit}}
  end

  # FileGuard module, overridable via config for tests / deployment swaps.
  defp file_guard_module do
    if Code.ensure_loaded?(Config) and function_exported?(Config, :file_guard_module, 0) do
      Config.file_guard_module()
    else
      Arbor.Security.FileGuard
    end
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
