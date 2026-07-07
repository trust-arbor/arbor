defmodule Arbor.Security.AuthDecision do
  @moduledoc """
  Pure authorization decision — no GenServer calls, no side effects.

  Takes an `AuthContext` (pre-loaded identity and capabilities)
  and a resource URI. Returns a decision. The caller handles the decision
  (escalate, deny, proceed).

  ## Usage with AuthContext (preferred)

      auth = AuthContext.new("agent_123", signer: signer) |> AuthContext.load()

      case AuthDecision.evaluate(auth, "arbor://fs/read") do
        {:ok, :authorized, cap, auth} → proceed (cap is the matching capability)
        {:ok, :requires_approval, cap, auth} → escalate externally
        {:error, reason, auth} → deny
      end

  ## Usage with loose params (convenience, builds AuthContext internally)

      case AuthDecision.check("agent_123", "arbor://fs/read") do
        :authorized → proceed
        {:requires_approval, cap} → escalate
        {:error, reason} → deny
      end

  ## Why This Exists

  `Security.authorize` mixed pure decisions with side effects (Escalation,
  Consensus.submit, event emission). This caused deadlocks when called from
  within the Consensus Coordinator. AuthDecision is purely functional —
  it reads from the AuthContext struct (or ETS on fallback) and returns a
  decision without triggering any side effects.
  """

  alias Arbor.Contracts.Security.AuthContext
  alias Arbor.Security.{CapabilityStore, EgressGate, Identity.Verifier, UriRegistry}

  require Logger

  @type decision_result ::
          {:ok, :authorized, map(), AuthContext.t()}
          | {:ok, :requires_approval, map(), AuthContext.t()}
          | {:error, term(), AuthContext.t()}

  @type simple_decision ::
          :authorized
          | {:requires_approval, map()}
          | :unauthorized
          | {:error, term()}

  # ===========================================================================
  # Primary API — AuthContext-based (pure)
  # ===========================================================================

  @doc """
  Evaluate authorization using a pre-loaded AuthContext.

  Returns `{:ok, :authorized, updated_auth}`, `{:ok, :requires_approval, cap, updated_auth}`,
  or `{:error, reason, updated_auth}`. The updated auth has the decision recorded
  in its audit trail.
  """
  @spec evaluate(AuthContext.t(), String.t(), atom(), keyword()) :: decision_result()
  def evaluate(%AuthContext{} = auth, resource_uri, _action \\ :execute, opts \\ []) do
    with {:ok, auth} <- check_uri(auth, resource_uri),
         {:ok, auth} <- check_identity(auth),
         {:ok, auth} <- verify_signed_request(auth, resource_uri, opts),
         {:ok, cap, auth} <- find_matching_capability(auth, resource_uri),
         {:ok, auth} <- check_scope_binding(auth, cap, opts),
         {:ok, auth} <- check_delegation_chain(auth, cap),
         {:ok, auth} <- check_time_constraints(auth, cap),
         {:ok, auth} <- check_file_guard(auth, resource_uri),
         {:ok, auth} <- check_egress_block(auth, opts),
         result <- check_approval(auth, cap, resource_uri),
         result <- apply_egress_ask(result, cap, resource_uri, opts) do
      case result do
        {:authorized, auth} ->
          {:ok, :authorized, cap, AuthContext.record_decision(auth, resource_uri, :authorized)}

        {:requires_approval, cap, auth} ->
          {:ok, :requires_approval, cap,
           AuthContext.record_decision(auth, resource_uri, {:requires_approval, cap.id})}
      end
    else
      {:error, reason, auth} ->
        {:error, reason, AuthContext.record_decision(auth, resource_uri, {:error, reason})}
    end
  end

  # ===========================================================================
  # Convenience API — loose params (builds AuthContext internally)
  # ===========================================================================

  @doc """
  Simple authorization check with loose params. Builds AuthContext internally.
  Used by code that doesn't have an AuthContext yet (e.g., Coordinator).
  """
  @spec check(String.t(), String.t(), atom(), keyword()) :: simple_decision()
  def check(principal_id, resource_uri, action \\ :execute, opts \\ []) do
    auth =
      AuthContext.new(principal_id, opts)
      |> AuthContext.load()

    case evaluate(auth, resource_uri, action, opts) do
      {:ok, :authorized, _cap, _auth} -> :authorized
      {:ok, :requires_approval, cap, _auth} -> {:requires_approval, cap}
      {:error, reason, _auth} -> {:error, reason}
    end
  end

  # ===========================================================================
  # Private — pure decision functions
  # ===========================================================================

  defp check_uri(auth, resource_uri) do
    if Code.ensure_loaded?(UriRegistry) and function_exported?(UriRegistry, :validate, 1) do
      case UriRegistry.validate(resource_uri) do
        :ok -> {:ok, auth}
        {:error, reason} -> {:error, {:uri_rejected, reason}, auth}
      end
    else
      {:ok, auth}
    end
  end

  defp check_identity(%AuthContext{identity_verified: true} = auth) do
    # Already verified — skip
    {:ok, auth}
  end

  # H5: every principal — human_ or agent_ — goes through the same registry
  # status check. The previous "humans are always active" branch let suspended
  # or revoked OIDC users continue to authorize because their existing
  # capabilities were never invalidated by the registry status change.
  defp check_identity(%AuthContext{principal_id: pid} = auth) do
    check_identity_status(auth, pid)
  end

  # H5: rescue and catch now consult strict_identity_mode? just like the live
  # registry-failure path. Pre-fix, the rescue clause returned {:ok, auth}
  # unconditionally — any exception while reading the registry silently
  # permitted the caller. The catch clause already did the right thing; the
  # rescue clause is now aligned with it.
  defp check_identity_status(auth, principal_id) do
    registry = Arbor.Security.Identity.Registry

    if Code.ensure_loaded?(registry) and function_exported?(registry, :identity_status, 1) do
      case apply(registry, :identity_status, [principal_id]) do
        {:ok, :active} ->
          {:ok, auth}

        {:ok, :suspended} ->
          {:error, {:unauthorized, :identity_suspended}, auth}

        {:ok, :revoked} ->
          {:error, {:unauthorized, :identity_revoked}, auth}

        {:error, :not_found} ->
          if strict_identity_mode?(),
            do: {:error, {:unauthorized, :unknown_identity}, auth},
            else: {:ok, auth}
      end
    else
      # Registry not loaded — permissive by default outside strict mode
      if strict_identity_mode?(),
        do: {:error, {:unauthorized, :identity_registry_unavailable}, auth},
        else: {:ok, auth}
    end
  rescue
    _ ->
      if strict_identity_mode?(),
        do: {:error, {:unauthorized, :identity_registry_unavailable}, auth},
        else: {:ok, auth}
  catch
    :exit, _ ->
      if strict_identity_mode?(),
        do: {:error, {:unauthorized, :identity_registry_unavailable}, auth},
        else: {:ok, auth}
  end

  defp strict_identity_mode? do
    config = Arbor.Security.Config

    Code.ensure_loaded?(config) and function_exported?(config, :strict_identity_mode?, 0) and
      apply(config, :strict_identity_mode?, [])
  end

  # H5: when CapabilityStore is unavailable or raises, the pre-fix code fell
  # back to AuthContext.capabilities — caller-supplied (or replay-derived)
  # records whose issuer_signature was never re-verified. In strict mode the
  # store outage now denies; in permissive mode the preloaded fallback is
  # still used (legitimate test paths and replay scenarios rely on it), but
  # only after a debug log so partial outages are visible.
  defp find_matching_capability(%AuthContext{} = auth, resource_uri) do
    store = capability_store_module()

    if Code.ensure_loaded?(store) and
         function_exported?(store, :find_authorizing, 2) do
      case store.find_authorizing(auth.principal_id, resource_uri) do
        {:ok, cap} ->
          {:ok, cap, auth}

        {:error, :not_found} ->
          {:error, :unauthorized, auth}
      end
    else
      capability_store_unavailable_fallback(auth, resource_uri)
    end
  rescue
    _ -> capability_store_unavailable_fallback(auth, resource_uri)
  catch
    :exit, _ -> capability_store_unavailable_fallback(auth, resource_uri)
  end

  # CapabilityStore module, overridable via config for tests (e.g. to
  # simulate a store outage and exercise the preloaded fallback).
  defp capability_store_module do
    config = Arbor.Security.Config

    if Code.ensure_loaded?(config) and function_exported?(config, :capability_store_module, 0) do
      apply(config, :capability_store_module, [])
    else
      CapabilityStore
    end
  end

  defp capability_store_unavailable_fallback(auth, resource_uri) do
    if strict_capability_store_mode?() do
      {:error, {:unauthorized, :capability_store_unavailable}, auth}
    else
      try_preloaded_capabilities(auth, resource_uri)
    end
  end

  defp strict_capability_store_mode? do
    # Reuse the same strict_identity_mode? config: an operator that wants
    # strict identity checks almost certainly also wants strict store checks.
    # If we ever need to split these, introduce a dedicated config key.
    strict_identity_mode?()
  end

  # Fallback (CapabilityStore unavailable, non-strict mode): search the
  # pre-loaded AuthContext capabilities.
  #
  # M2 review fix (2026-06-09): this used to match on `uri_matches?` ALONE —
  # no signature check, no expiry check. That made the store-outage fallback
  # a signature bypass: any unsigned/expired cap in the AuthContext was
  # honored. It now applies the SAME gates the primary path
  # (CapabilityStore.find_authorizing) applies — capability validity AND
  # signature acceptability — so the fallback can never honor a cap the
  # store itself would reject. When `capability_signing_required` is true
  # (dev/prod default) an unsigned preloaded cap is now refused.
  defp try_preloaded_capabilities(%AuthContext{capabilities: caps} = auth, resource_uri)
       when caps != [] do
    matching =
      Enum.find(caps, fn cap ->
        uri_matches?(cap.resource_uri, resource_uri) and
          preloaded_cap_acceptable?(cap)
      end)

    if matching do
      {:ok, matching, auth}
    else
      {:error, :unauthorized, auth}
    end
  end

  defp try_preloaded_capabilities(auth, _resource_uri) do
    {:error, :unauthorized, auth}
  end

  # Mirror of CapabilityStore.signature_acceptable?/1 + Capability.valid?/1
  # for the preloaded fallback. A signed cap must verify; an unsigned cap is
  # accepted only when capability signing is not required.
  defp preloaded_cap_acceptable?(cap) do
    Arbor.Contracts.Security.Capability.valid?(cap) and signature_acceptable?(cap)
  end

  defp signature_acceptable?(cap) do
    cap_mod = Arbor.Contracts.Security.Capability
    authority = Arbor.Security.SystemAuthority
    config = Arbor.Security.Config

    signing_required? =
      Code.ensure_loaded?(config) and
        function_exported?(config, :capability_signing_required?, 0) and
        apply(config, :capability_signing_required?, [])

    cond do
      apply(cap_mod, :signed?, [cap]) ->
        Code.ensure_loaded?(authority) and
          function_exported?(authority, :verify_capability_signature, 1) and
          apply(authority, :verify_capability_signature, [cap]) == :ok

      signing_required? ->
        false

      true ->
        true
    end
  rescue
    # Any failure resolving the verification path denies this preloaded cap.
    _ -> false
  catch
    :exit, _ -> false
  end

  # Verify signed request — identity binding + resource binding
  defp verify_signed_request(%AuthContext{identity_verified: true} = auth, _resource_uri, _opts) do
    # Already verified — skip
    {:ok, auth}
  end

  defp verify_signed_request(%AuthContext{} = auth, resource_uri, opts) do
    # Check if verification is required: explicit opt > config default
    config = Arbor.Security.Config

    verify? =
      case Keyword.get(opts, :verify_identity) do
        nil ->
          Code.ensure_loaded?(config) and
            function_exported?(config, :identity_verification_enabled?, 0) and
            apply(config, :identity_verification_enabled?, [])

        val ->
          val
      end

    if not verify? do
      {:ok, auth}
    else
      do_verify_signed_request(auth, resource_uri, opts)
    end
  end

  defp do_verify_signed_request(%AuthContext{signed_request: nil} = auth, _resource_uri, _opts) do
    {:error, :missing_signed_request, auth}
  end

  defp do_verify_signed_request(
         %AuthContext{signed_request: sr, principal_id: pid} = auth,
         _resource_uri,
         opts
       ) do
    # Only check resource binding when caller explicitly sets expected_resource.
    # Some signers use a different payload format (e.g., "authorize" string).
    expected = Keyword.get(opts, :expected_resource)

    with {:ok, verified_id} <- Verifier.verify(sr),
         :ok <- check_identity_binding(verified_id, pid),
         :ok <- maybe_check_resource_binding(sr, expected) do
      {:ok, AuthContext.mark_verified(auth)}
    else
      {:error, reason} -> {:error, reason, auth}
    end
  rescue
    e ->
      {:error, {:verification_error, Exception.message(e)}, auth}
  catch
    :exit, reason ->
      {:error, {:verification_exit, reason}, auth}
  end

  defp check_identity_binding(verified_id, principal_id) do
    if verified_id == principal_id,
      do: :ok,
      else: {:error, {:identity_mismatch, verified_id, principal_id}}
  end

  defp maybe_check_resource_binding(_sr, nil), do: :ok

  defp maybe_check_resource_binding(%{payload: payload}, expected) do
    if payload == expected, do: :ok, else: {:error, {:resource_mismatch, payload, expected}}
  end

  defp maybe_check_resource_binding(_, _), do: :ok

  # Scope binding — session_id/task_id must match if set on capability
  defp check_scope_binding(auth, cap, opts) do
    cap_mod = Arbor.Contracts.Security.Capability

    if Code.ensure_loaded?(cap_mod) and function_exported?(cap_mod, :scope_matches?, 2) do
      scope_context =
        [session_id: auth.session_id] ++
          if(opts[:task_id], do: [task_id: opts[:task_id]], else: []) ++
          if(opts[:principal_scope], do: [principal_scope: opts[:principal_scope]], else: [])

      if apply(cap_mod, :scope_matches?, [cap, scope_context]) do
        {:ok, auth}
      else
        {:error, :scope_mismatch, auth}
      end
    else
      {:ok, auth}
    end
  end

  # Delegation chain verification (pure crypto — may need key lookup from ETS)
  defp check_delegation_chain(auth, %{delegation_chain: []}) do
    {:ok, auth}
  end

  defp check_delegation_chain(auth, cap) do
    config = Arbor.Security.Config
    signer = delegation_signer_module()
    registry = Arbor.Security.Identity.Registry

    enabled =
      Code.ensure_loaded?(config) and
        function_exported?(config, :delegation_chain_verification_enabled?, 0) and
        apply(config, :delegation_chain_verification_enabled?, [])

    if enabled and Code.ensure_loaded?(signer) and
         function_exported?(signer, :verify_delegation_chain, 2) do
      key_lookup_fn = fn agent_id ->
        if Code.ensure_loaded?(registry) and function_exported?(registry, :lookup, 1) do
          apply(registry, :lookup, [agent_id])
        else
          {:error, :registry_unavailable}
        end
      end

      case apply(signer, :verify_delegation_chain, [cap, key_lookup_fn]) do
        :ok -> {:ok, auth}
        {:error, reason} -> {:error, {:delegation_chain_invalid, reason}, auth}
      end
    else
      # Verification intentionally disabled (or signer absent) — not an
      # error path; honor the cap. Only an active-verification crash below
      # fails closed.
      {:ok, auth}
    end
  rescue
    # M1 review fix (2026-06-09): an exception while verifying delegation
    # signatures must NOT accept the (possibly forged/corrupt) chain. The
    # explicit {:error, {:delegation_chain_invalid, _}} above shows the
    # intent is to reject bad chains; a crash is at least as suspicious.
    # Fail closed. (Was `{:ok, auth}`.)
    _ -> {:error, {:delegation_chain_invalid, :verification_error}, auth}
  catch
    :exit, _ -> {:error, {:delegation_chain_invalid, :verification_exit}, auth}
  end

  # Delegation-chain signer module, overridable via config for tests.
  defp delegation_signer_module do
    config = Arbor.Security.Config

    if Code.ensure_loaded?(config) and function_exported?(config, :delegation_signer_module, 0) do
      apply(config, :delegation_signer_module, [])
    else
      Arbor.Security.Signer
    end
  end

  # Time constraints — not_before / expires_at (pure time comparison)
  defp check_time_constraints(auth, cap) do
    now = DateTime.utc_now()

    cond do
      cap.not_before && DateTime.compare(now, cap.not_before) == :lt ->
        {:error, {:not_yet_valid, cap.not_before}, auth}

      cap.expires_at && DateTime.compare(now, cap.expires_at) == :gt ->
        {:error, {:expired, cap.expires_at}, auth}

      true ->
        {:ok, auth}
    end
  end

  # File guard — path validation for arbor://fs/* URIs (pure)
  defp check_file_guard(auth, resource_uri) do
    if String.starts_with?(resource_uri, "arbor://fs/") do
      # FileGuard check happens in the imperative shell (Security.authorize)
      # because it needs the file_path from opts. AuthDecision just passes through.
      {:ok, auth}
    else
      {:ok, auth}
    end
  end

  defp check_approval(%AuthContext{} = auth, cap, _resource_uri) do
    if has_approval_constraint?(cap),
      do: {:requires_approval, cap, auth},
      else: {:authorized, auth}
  end

  # ===========================================================================
  # Egress gate (2026-06-14 URI-addressing-vs-classification decision)
  # ===========================================================================
  #
  # Keys off the *resolved classification* threaded in via opts
  # (`:egress_tier`, `:egress_taint`), NOT off parsing the URI string. Two
  # pure steps:
  #
  #   check_egress_block/2 — hard-block untrusted/hostile data flowing OUT to an
  #     external destination (the outbound mirror of the taint rebuild's inbound
  #     control-param protection).
  #   apply_egress_ask/4 — escalate external egress to the ceiling :ask path,
  #     unless a provenance-bound pre-approved cap already covers it.
  #
  # BOTH are inert unless egress enforcement is switched on
  # (`config :arbor_security, :egress_gate_enforcing`, default false). The gate
  # lands dark: classification is resolved and observed (telemetry lives in the
  # impure caller, `Arbor.Actions.authorize_and_execute/4`) before enforcement
  # is enabled, so turning it on is a deliberate operator action that won't
  # surprise the running agents (whose heartbeats make routine LLM egress).

  # Egress decision delegates to the shared Arbor.Security.EgressGate (also used
  # by the standalone Arbor.Security.authorize_egress/3 for the compute-node LLM
  # path). Here the matched capability is the only refinement candidate.
  #
  #   check_egress_block/2 — hard-block (taint conjunct OR supplied policy :block).
  #   apply_egress_ask/4    — escalate :ask to the ceiling approval path.
  defp check_egress_block(auth, opts) do
    tier = Keyword.get(opts, :egress_tier, :none)

    case EgressGate.decide(auth.principal_id, tier, opts, []) do
      {:block, reason} -> {:error, {:egress_blocked, tier, reason}, auth}
      _ -> {:ok, auth}
    end
  end

  # Escalate external egress to :ask unless the matched cap's egress constraint
  # covers the resolved tier/destination. Receives + returns check_approval/3 shape.
  defp apply_egress_ask({:authorized, auth} = result, cap, _resource_uri, opts) do
    tier = Keyword.get(opts, :egress_tier, :none)

    case EgressGate.decide(auth.principal_id, tier, opts, [cap]) do
      :ask -> {:requires_approval, cap, auth}
      _ -> result
    end
  end

  # Already requires approval (or any other shape) — leave untouched.
  defp apply_egress_ask(result, _cap, _resource_uri, _opts), do: result

  defp has_approval_constraint?(cap) do
    cap.constraints[:requires_approval] == true or
      cap.constraints["requires_approval"] == true
  end

  # Check if a capability URI matches a resource URI.
  # Supports exact match and wildcard patterns (/** suffix).
  defp uri_matches?(cap_uri, resource_uri) when is_binary(cap_uri) and is_binary(resource_uri) do
    cond do
      # Exact match
      cap_uri == resource_uri ->
        true

      # Explicit wildcards. L1 review fix (2026-06-09): require a segment
      # boundary so the prefix can't bleed across siblings, matching
      # CapabilityStore.authorizes_resource?/2. Pre-fix, a cap
      # `arbor://agent/profile/agent_X/**` (prefix `…/agent_X`) matched
      # `…/agent_XEVIL/secret` because the bare `starts_with?` had no `/`
      # boundary.
      String.ends_with?(cap_uri, "/**") ->
        prefix = String.trim_trailing(cap_uri, "/**")
        resource_uri == prefix or String.starts_with?(resource_uri, prefix <> "/")

      String.ends_with?(cap_uri, "/*") ->
        prefix = String.trim_trailing(cap_uri, "/*")
        resource_uri == prefix or String.starts_with?(resource_uri, prefix <> "/")

      # C8 review fix (2026-06-09): a CONCRETE capability URI grants ONLY its
      # exact resource — no implicit subtree. Subtree access requires an
      # explicit `/**` (or `/*`). Mirrors CapabilityStore.authorizes_resource?/2.
      # Pre-fix, `String.starts_with?(resource_uri, cap_uri <> "/")` made every
      # concrete grant a silent `/**`.
      true ->
        false
    end
  end

  defp uri_matches?(_, _), do: false
end
