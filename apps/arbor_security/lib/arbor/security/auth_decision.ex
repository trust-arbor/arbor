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
  alias Arbor.Security.{CapabilityStore, UriRegistry}

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
  @spec evaluate(AuthContext.t(), String.t(), atom()) :: decision_result()
  def evaluate(%AuthContext{} = auth, resource_uri, action \\ :execute) do
    with {:ok, auth} <- check_uri(auth, resource_uri),
         {:ok, auth} <- check_identity(auth),
         {:ok, cap, auth} <- find_matching_capability(auth, resource_uri),
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

    case evaluate(auth, resource_uri, action) do
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
      case identity_active?(pid) do
        true -> {:ok, auth}
        false -> {:error, {:identity_inactive, pid}, auth}
      end
    end
  end

  defp identity_active?(principal_id) do
    registry = Arbor.Security.Identity.Registry

    if Code.ensure_loaded?(registry) and function_exported?(registry, :active?, 1) do
      apply(registry, :active?, [principal_id])
    else
      true
    end
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  defp find_matching_capability(%AuthContext{capabilities: caps} = auth, resource_uri)
       when caps != [] do
    # Search pre-loaded capabilities first (pure — no ETS read)
    matching =
      Enum.find(caps, fn cap ->
        uri_matches?(cap.resource_uri, resource_uri)
      end)

    if matching do
      {:ok, matching, auth}
    else
      # Capabilities were pre-loaded but none match — try PolicyEnforcer for JIT grant
      case try_policy_enforcer(auth.principal_id, resource_uri) do
        {:ok, cap} -> {:ok, cap, auth}
        {:error, _} -> {:error, :unauthorized, auth}
      end
    end
  end

  defp find_matching_capability(%AuthContext{} = auth, resource_uri) do
    # No pre-loaded capabilities — fall back to CapabilityStore (ETS read)
    if Code.ensure_loaded?(CapabilityStore) and
         function_exported?(CapabilityStore, :find_authorizing, 2) do
      case CapabilityStore.find_authorizing(auth.principal_id, resource_uri) do
        {:ok, cap} -> {:ok, cap, auth}
        {:error, :not_found} ->
          case try_policy_enforcer(auth.principal_id, resource_uri) do
            {:ok, cap} -> {:ok, cap, auth}
            {:error, _} -> {:error, :unauthorized, auth}
          end
      end
    else
      {:error, :capability_store_unavailable, auth}
    end
  rescue
    _ -> {:error, :capability_lookup_failed, auth}
  catch
    :exit, _ -> {:error, :capability_lookup_failed, auth}
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
      cap_uri == resource_uri -> true
      String.ends_with?(cap_uri, "/**") ->
        prefix = String.trim_trailing(cap_uri, "/**")
        String.starts_with?(resource_uri, prefix)
      String.ends_with?(cap_uri, "/*") ->
        prefix = String.trim_trailing(cap_uri, "/*")
        String.starts_with?(resource_uri, prefix)
      true -> false
    end
  end

  defp uri_matches?(_, _), do: false
end
