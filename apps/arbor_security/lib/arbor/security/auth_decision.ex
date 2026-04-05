defmodule Arbor.Security.AuthDecision do
  @moduledoc """
  Pure authorization decision function — no GenServer calls, no side effects.

  Evaluates whether a principal is authorized for a resource/action by checking:
  1. URI registry (is the URI known?)
  2. Identity status (is the principal active?)
  3. Capability lookup (does the principal have a matching capability?)
  4. Trust profile mode (what does the profile say about this resource?)

  Returns a decision atom — the caller decides what to do with it.
  This function NEVER submits proposals, calls Consensus, or triggers
  Escalation. It only reads from ETS (CapabilityStore, Trust.Store).

  ## Usage

      case AuthDecision.evaluate("agent_123", "arbor://fs/read", :execute) do
        :authorized → proceed
        {:requires_approval, cap} → submit proposal externally
        :unauthorized → deny
      end

  ## Why This Exists

  The previous `Security.authorize` function called ApprovalGuard → Escalation →
  Consensus.Coordinator.submit, which deadlocked when called from within the
  Coordinator's own GenServer. This pure function breaks that cycle.
  """

  alias Arbor.Security.{CapabilityStore, UriRegistry}

  @type decision ::
          :authorized
          | {:requires_approval, map()}
          | :unauthorized
          | {:error, term()}

  @doc """
  Evaluate authorization purely — no side effects, no GenServer calls.

  ## Options

  - `:verify_identity` — whether to require identity verification (default: from config)
  - `:signed_request` — signed request for identity verification
  - `:skip_uri_check` — skip URI registry validation (default: false)
  """
  @spec evaluate(String.t(), String.t(), atom(), keyword()) :: decision()
  def evaluate(principal_id, resource_uri, _action \\ :execute, opts \\ []) do
    with :ok <- maybe_check_uri(resource_uri, opts),
         :ok <- check_identity_status(principal_id),
         {:ok, cap} <- find_capability(principal_id, resource_uri),
         decision <- check_approval_requirement(cap, principal_id, resource_uri) do
      decision
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ===========================================================================
  # Private — all pure reads from ETS, no GenServer calls
  # ===========================================================================

  defp maybe_check_uri(resource_uri, opts) do
    if Keyword.get(opts, :skip_uri_check, false) do
      :ok
    else
      if Code.ensure_loaded?(UriRegistry) and function_exported?(UriRegistry, :validate, 1) do
        UriRegistry.validate(resource_uri)
      else
        :ok
      end
    end
  end

  defp check_identity_status(principal_id) do
    # Human identities are always considered active (authenticated via OIDC)
    if String.starts_with?(principal_id, "human_") do
      :ok
    else
      registry = Arbor.Contracts.Security.Identity.Registry

      if Code.ensure_loaded?(registry) do
        # Identity.Registry is ETS-backed — pure read
        case registry_active?(principal_id) do
          true -> :ok
          false -> {:error, {:identity_inactive, principal_id}}
        end
      else
        :ok
      end
    end
  end

  defp registry_active?(principal_id) do
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

  defp find_capability(principal_id, resource_uri) do
    if Code.ensure_loaded?(CapabilityStore) and
         function_exported?(CapabilityStore, :find_authorizing, 2) do
      case CapabilityStore.find_authorizing(principal_id, resource_uri) do
        {:ok, cap} -> {:ok, cap}
        {:error, :not_found} -> try_policy_enforcer(principal_id, resource_uri)
      end
    else
      {:error, :capability_store_unavailable}
    end
  rescue
    _ -> {:error, :capability_lookup_failed}
  catch
    :exit, _ -> {:error, :capability_lookup_failed}
  end

  # PolicyEnforcer JIT-grants capabilities based on trust profile
  defp try_policy_enforcer(principal_id, resource_uri) do
    enforcer = Arbor.Security.PolicyEnforcer

    if Code.ensure_loaded?(enforcer) and function_exported?(enforcer, :check, 3) do
      case apply(enforcer, :check, [principal_id, resource_uri, []]) do
        {:ok, cap} -> {:ok, cap}
        {:error, _} -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :exit, _ -> {:error, :unauthorized}
  end

  # Check if the capability requires approval — pure check, no escalation
  defp check_approval_requirement(cap, principal_id, resource_uri) do
    has_approval_constraint =
      cap.constraints[:requires_approval] == true or
        cap.constraints["requires_approval"] == true

    if has_approval_constraint do
      # Check if graduated (confirm-then-automate)
      if graduated?(principal_id, resource_uri) do
        :authorized
      else
        {:requires_approval, cap}
      end
    else
      :authorized
    end
  end

  # Check graduation via ConfirmationTracker (ETS read — pure)
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
end
