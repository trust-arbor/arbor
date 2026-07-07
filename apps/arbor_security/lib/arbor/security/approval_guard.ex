defmodule Arbor.Security.ApprovalGuard do
  @moduledoc """
  Policy-based approval middleware for the authorization pipeline.

  The ApprovalGuard sits between constraint enforcement and escalation
  in the `Security.authorize/4` chain. It consults the trust tier policy
  (via `Trust.Policy.confirmation_mode`) to determine whether a capability
  request should be auto-approved, require human confirmation, or be denied.

  ## Authorization Chain Position

      check_reflexes → check_identity → verify_identity → find_capability
        → enforce_constraints → **ApprovalGuard** → escalation → result

  ## Decision Modes

  - `:auto` — proceed immediately (no approval needed)
  - `:gated` — escalate to consensus for human confirmation
  - `:deny` — hard block, capability not available at this tier

  ## Confirm-then-Automate

  When a capability is `:gated`, the ApprovalGuard checks if it has
  graduated to auto via `Trust.ConfirmationTracker`. Graduated capabilities
  are auto-approved without escalation. See `Arbor.Trust.ConfirmationTracker`
  for graduation thresholds and logic.

  ## Security Invariants

  - Shell exec is NEVER auto-approved at any tier (graduation threshold: `:never`)
  - If trust system is unavailable, falls back to capability constraints
  - If policy returns `:deny`, the request is blocked even if a capability exists

  ## Configuration

      config :arbor_security,
        approval_guard_enabled: true  # default: true

  When disabled, falls through to the existing `Escalation.maybe_escalate`
  behavior (checks `requires_approval` constraint only).
  """

  alias Arbor.Security.Escalation

  require Logger

  @doc """
  Check if an action requires approval based on trust tier policy.

  Called from the authorization pipeline after capability and constraint
  checks pass. Returns the same result types as `Escalation.maybe_escalate/3`
  for seamless integration.

  ## Returns

  - `:ok` — auto-approved, proceed
  - `{:ok, :pending_approval, proposal_id}` — submitted for consensus
  - `{:error, :policy_denied}` — blocked by policy (tier too low)
  - `{:error, reason}` — escalation or consensus failure
  """
  @spec check(map(), String.t(), String.t()) ::
          :ok | {:ok, :pending_approval, String.t()} | {:error, term()}
  def check(capability, principal_id, resource_uri) do
    if enabled?() and trust_policy_available?() do
      check_with_policy(capability, principal_id, resource_uri)
    else
      # Fallback: delegate to Escalation (existing behavior)
      Escalation.maybe_escalate(capability, principal_id, resource_uri)
    end
  end

  @doc """
  Check if the ApprovalGuard is enabled.

  Disabled by default — opt-in via config. When disabled, the authorize
  pipeline falls through to Escalation's constraint-based checks.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:arbor_security, :approval_guard_enabled, true)
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp check_with_policy(capability, principal_id, resource_uri) do
    case get_confirmation_mode(principal_id, resource_uri) do
      :auto ->
        safe_emit_signal(:approval_auto, %{
          principal_id: principal_id,
          resource_uri: resource_uri
        })

        :ok

      :gated ->
        # No graduation bypass here. Per TRUST-6 (2026-06-14) graduation is
        # suggestion-only: an accepted graduation is a profile rule, so
        # confirmation_mode returns :auto (the branch above) and never reaches
        # :gated. The old `graduated?`-flag bypass auto-approved on a streak
        # alone, without a human accepting — removed. A :gated op always
        # escalates for approval.
        safe_emit_signal(:approval_gated, %{
          principal_id: principal_id,
          resource_uri: resource_uri
        })

        # Delegate to Escalation for consensus-based approval
        Escalation.maybe_escalate(
          %{
            capability
            | constraints: Map.put(capability.constraints, :requires_approval, true)
          },
          principal_id,
          resource_uri
        )

      :deny ->
        Logger.info("Policy denied access for #{principal_id} to #{resource_uri}",
          principal_id: principal_id,
          resource_uri: resource_uri
        )

        safe_emit_signal(:approval_denied, %{
          principal_id: principal_id,
          resource_uri: resource_uri
        })

        {:error, :policy_denied}
    end
  end

  defp get_confirmation_mode(principal_id, resource_uri) do
    # Runtime indirection via Config so tests can substitute a stub (arbor_trust
    # deps arbor_security, not the reverse) and a deployment could swap the policy.
    # Mirrors AuthDecision.trust_profile_gates?/2.
    policy = trust_policy_module()

    if Code.ensure_loaded?(policy) and function_exported?(policy, :confirmation_mode, 2) do
      apply(policy, :confirmation_mode, [principal_id, resource_uri])
    else
      # K1 (fail-closed): Trust.Policy unavailable — escalate for approval (:gated),
      # NEVER :auto. A missing policy collaborator must not silently auto-approve.
      # Same defect class as the 2026-04-07 shell-auto-exec regression.
      warn_trust_unavailable(principal_id, resource_uri, :not_loaded)
      :gated
    end
  rescue
    e ->
      # A crash consulting the trust profile must NOT downgrade to auto-approve.
      warn_trust_unavailable(principal_id, resource_uri, {:raised, e})
      :gated
  catch
    :exit, reason ->
      warn_trust_unavailable(principal_id, resource_uri, {:exit, reason})
      :gated
  end

  defp trust_policy_available? do
    policy = trust_policy_module()
    Code.ensure_loaded?(policy) and function_exported?(policy, :confirmation_mode, 2)
  end

  # Trust.Policy module, overridable via config for tests / deployment swaps.
  defp trust_policy_module do
    config = Arbor.Security.Config

    if Code.ensure_loaded?(config) and function_exported?(config, :trust_policy_module, 0) do
      apply(config, :trust_policy_module, [])
    else
      Arbor.Trust.Policy
    end
  end

  defp warn_trust_unavailable(principal_id, resource_uri, cause) do
    Logger.warning(
      "ApprovalGuard: Trust.Policy unavailable (#{inspect(cause)}) — failing CLOSED to " <>
        ":gated for #{principal_id} -> #{resource_uri}",
      principal_id: principal_id,
      resource_uri: resource_uri
    )
  end

  defp safe_emit_signal(type, data) do
    Arbor.Signals.emit(:security, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
