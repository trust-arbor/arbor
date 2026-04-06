defmodule Arbor.Security.AuthDecision do
  @moduledoc """
  Pure authorization decision — no GenServer calls, no side effects.

  Takes an `AuthContext` (pre-loaded identity, capabilities, trust profile)
  and a resource URI. Returns a decision. The caller handles the decision
  (escalate, deny, proceed).

  ## Usage with AuthContext (preferred)

      auth = AuthContext.new("agent_123", signer: signer) |> AuthContext.load()

      case AuthDecision.evaluate(auth, "arbor://fs/read") do
        {:ok, :authorized, auth} → proceed (auth has updated decisions trail)
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
  alias Arbor.Security.{CapabilityStore, Identity.Verifier, UriRegistry}

  require Logger

  @type decision_result ::
          {:ok, :authorized, AuthContext.t()}
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
         result <- check_approval(auth, cap, resource_uri) do
      case result do
        {:authorized, auth} ->
          {:ok, :authorized, AuthContext.record_decision(auth, resource_uri, :authorized)}

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
      {:ok, :authorized, _auth} -> :authorized
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

  defp check_identity(%AuthContext{principal_id: pid} = auth) do
    # Human identities are always considered active
    if String.starts_with?(pid, "human_") do
      {:ok, auth}
    else
      check_identity_status(auth, pid)
    end
  end

  # Match the permissive/strict mode behavior from Security.authorize.
  # In strict mode: unknown identity → reject. In permissive mode: allow through.
  defp check_identity_status(auth, principal_id) do
    registry = Arbor.Security.Identity.Registry
    config = Arbor.Security.Config

    strict? =
      Code.ensure_loaded?(config) and function_exported?(config, :strict_identity_mode?, 0) and
        apply(config, :strict_identity_mode?, [])

    if Code.ensure_loaded?(registry) and function_exported?(registry, :identity_status, 1) do
      case apply(registry, :identity_status, [principal_id]) do
        {:ok, :active} -> {:ok, auth}
        {:ok, :suspended} -> {:error, {:unauthorized, :identity_suspended}, auth}
        {:ok, :revoked} -> {:error, {:unauthorized, :identity_revoked}, auth}
        {:error, :not_found} ->
          if strict?, do: {:error, {:unauthorized, :unknown_identity}, auth}, else: {:ok, auth}
      end
    else
      # Registry not loaded — permissive by default
      {:ok, auth}
    end
  rescue
    _ -> {:ok, auth}
  catch
    :exit, _ ->
      config = Arbor.Security.Config

      if Code.ensure_loaded?(config) and function_exported?(config, :strict_identity_mode?, 0) and
           apply(config, :strict_identity_mode?, []) do
        {:error, {:unauthorized, :identity_registry_unavailable}, auth}
      else
        {:ok, auth}
      end
  end

  defp find_matching_capability(%AuthContext{} = auth, resource_uri) do
    # Always use CapabilityStore.find_authorizing when available — it verifies
    # issuer_signature on lookup, catching tampered capabilities. Pre-loaded
    # capabilities in AuthContext are used as fallback when the store isn't running.
    if Code.ensure_loaded?(CapabilityStore) and
         function_exported?(CapabilityStore, :find_authorizing, 2) do
      case CapabilityStore.find_authorizing(auth.principal_id, resource_uri) do
        {:ok, cap} ->
          {:ok, cap, auth}

        {:error, :not_found} ->
          # Try PolicyEnforcer for JIT grant — do NOT fall back to pre-loaded
          # capabilities (they haven't been signature-verified)
          case try_policy_enforcer(auth.principal_id, resource_uri) do
            {:ok, cap} -> {:ok, cap, auth}
            {:error, _} -> {:error, :unauthorized, auth}
          end
      end
    else
      # Store not available — fall back to pre-loaded capabilities
      try_preloaded_capabilities(auth, resource_uri)
    end
  rescue
    _ -> try_preloaded_capabilities(auth, resource_uri)
  catch
    :exit, _ -> try_preloaded_capabilities(auth, resource_uri)
  end

  # Fallback: search pre-loaded capabilities (no signature verification)
  defp try_preloaded_capabilities(%AuthContext{capabilities: caps} = auth, resource_uri)
       when caps != [] do
    matching = Enum.find(caps, fn cap -> uri_matches?(cap.resource_uri, resource_uri) end)

    if matching do
      {:ok, matching, auth}
    else
      {:error, :unauthorized, auth}
    end
  end

  defp try_preloaded_capabilities(auth, _resource_uri) do
    {:error, :unauthorized, auth}
  end

  defp try_policy_enforcer(principal_id, resource_uri) do
    enforcer = Arbor.Security.PolicyEnforcer

    if Code.ensure_loaded?(enforcer) and function_exported?(enforcer, :check, 3) do
      apply(enforcer, :check, [principal_id, resource_uri, []])
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :exit, _ -> {:error, :unauthorized}
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
          Code.ensure_loaded?(config) and function_exported?(config, :identity_verification_enabled?, 0) and
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

  defp do_verify_signed_request(%AuthContext{signed_request: sr, principal_id: pid} = auth, _resource_uri, opts) do
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
    if verified_id == principal_id, do: :ok, else: {:error, {:identity_mismatch, verified_id, principal_id}}
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
    signer = Arbor.Security.Signer
    registry = Arbor.Security.Identity.Registry

    enabled =
      Code.ensure_loaded?(config) and function_exported?(config, :delegation_chain_verification_enabled?, 0) and
        apply(config, :delegation_chain_verification_enabled?, [])

    if enabled and Code.ensure_loaded?(signer) and function_exported?(signer, :verify_delegation_chain, 2) do
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
      {:ok, auth}
    end
  rescue
    _ -> {:ok, auth}
  catch
    :exit, _ -> {:ok, auth}
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

  defp check_approval(%AuthContext{} = auth, cap, resource_uri) do
    has_approval_constraint =
      cap.constraints[:requires_approval] == true or
        cap.constraints["requires_approval"] == true

    if has_approval_constraint do
      if graduated?(auth.principal_id, resource_uri) do
        {:authorized, auth}
      else
        {:requires_approval, cap, auth}
      end
    else
      {:authorized, auth}
    end
  end

  defp graduated?(principal_id, resource_uri) do
    tracker = Arbor.Trust.ConfirmationTracker

    if Code.ensure_loaded?(tracker) and function_exported?(tracker, :graduated?, 2) do
      apply(tracker, :graduated?, [principal_id, resource_uri])
    else
      false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Check if a capability URI matches a resource URI.
  # Supports exact match and wildcard patterns (/** suffix).
  defp uri_matches?(cap_uri, resource_uri) when is_binary(cap_uri) and is_binary(resource_uri) do
    cond do
      # Exact match
      cap_uri == resource_uri -> true
      # Explicit wildcards
      String.ends_with?(cap_uri, "/**") ->
        prefix = String.trim_trailing(cap_uri, "/**")
        String.starts_with?(resource_uri, prefix)
      String.ends_with?(cap_uri, "/*") ->
        prefix = String.trim_trailing(cap_uri, "/*")
        String.starts_with?(resource_uri, prefix)
      # Prefix match: arbor://shell/exec/git matches arbor://shell/exec/git/status
      # (subpath access — matching CapabilityStore.find_authorizing behavior)
      String.starts_with?(resource_uri, cap_uri <> "/") -> true
      true -> false
    end
  end

  defp uri_matches?(_, _), do: false
end
