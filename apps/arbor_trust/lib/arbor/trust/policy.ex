defmodule Arbor.Trust.Policy do
  @moduledoc """
  Bridges trust tiers to capability grants.

  The Policy module is the glue between `Arbor.Trust` (behavioral scoring,
  tier resolution) and `Arbor.Security` (capability-based authorization).
  It answers two questions:

  1. **What can this agent do?** — Given an agent's trust tier, what
     capabilities should they hold?
  2. **How do capabilities change on tier transitions?** — When an agent
     is promoted or demoted, what capabilities are granted or revoked?

  ## Key Design Principles

  - `effective_tier = min(behavioral_tier, policy_ceiling)` — policy can
    restrict but NEVER elevate above earned behavioral tier
  - `shell_exec` is NEVER auto-approved at any tier
  - All capability mutations emit signals for audit
  - Fail closed: if any infrastructure is unavailable, deny

  ## Usage

      # Check if agent's current tier allows a resource
      Policy.allowed?("agent_123", "arbor://code/write/self/impl/*")

      # Grant all capabilities for a tier
      {:ok, caps} = Policy.grant_tier_capabilities("agent_123", :trusted)

      # Sync capabilities on tier change (revoke old, grant new)
      {:ok, result} = Policy.sync_capabilities("agent_123", :probationary, :trusted)

      # Get the effective tier (min of behavioral + ceiling)
      {:ok, :trusted} = Policy.effective_tier("agent_123")
  """

  alias Arbor.Trust.{CapabilityTemplates, ConfirmationMatrix, TierResolver}

  require Logger

  @type sync_result :: %{
          granted: non_neg_integer(),
          revoked: non_neg_integer(),
          effective_tier: TierResolver.trust_tier()
        }

  # ===========================================================================
  # Query API
  # ===========================================================================

  @doc """
  Check if an agent's current trust tier allows a resource URI.

  Resolves the agent's effective tier, then checks whether that tier
  includes the requested capability.

  Returns `false` if the trust system is unavailable (fail closed).

  ## Examples

      Policy.allowed?("agent_123", "arbor://code/read/self/*")
      #=> true

      Policy.allowed?("agent_123", "arbor://governance/change/self/*")
      #=> false
  """
  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(agent_id, resource_uri) do
    case effective_tier(agent_id) do
      {:ok, tier} ->
        CapabilityTemplates.has_capability?(tier, resource_uri)

      {:error, _} ->
        false
    end
  end

  @doc """
  Check if a resource requires approval at the agent's current tier.

  Returns `true` if the capability exists but has `requires_approval: true`,
  `false` if the capability exists without approval requirement,
  and `{:error, :denied}` if the capability is not available at all.

  ## Examples

      Policy.requires_approval?("agent_123", "arbor://code/write/self/impl/*")
      #=> true  (at :trusted tier)

      Policy.requires_approval?("agent_123", "arbor://code/write/self/impl/*")
      #=> false  (at :veteran tier)
  """
  @spec requires_approval?(String.t(), String.t()) :: boolean() | {:error, :denied | term()}
  def requires_approval?(agent_id, resource_uri) do
    case effective_tier(agent_id) do
      {:ok, tier} ->
        if CapabilityTemplates.has_capability?(tier, resource_uri) do
          CapabilityTemplates.requires_approval?(tier, resource_uri)
        else
          {:error, :denied}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get the effective tier for an agent.

  The effective tier is `min(behavioral_tier, policy_ceiling)`.
  Currently, policy_ceiling defaults to `:autonomous` (no ceiling)
  since the ceiling system is not yet implemented. When policy ceilings
  are added (roadmap Phase 4), this function will incorporate them.

  ## Examples

      Policy.effective_tier("agent_123")
      #=> {:ok, :trusted}
  """
  @spec effective_tier(String.t()) :: {:ok, TierResolver.trust_tier()} | {:error, term()}
  def effective_tier(agent_id) do
    with {:ok, behavioral_tier} <- get_behavioral_tier(agent_id),
         ceiling <- get_policy_ceiling(agent_id) do
      {:ok, min_tier(behavioral_tier, ceiling)}
    end
  end

  @doc """
  Get the confirmation mode for a capability at the agent's current tier.

  Returns:
  - `:auto` — capability is auto-approved (no confirmation needed)
  - `:gated` — capability requires human confirmation before execution
  - `:deny` — capability is not available at this tier

  Shell exec is always `:gated` regardless of tier (security invariant).

  ## Examples

      Policy.confirmation_mode("agent_123", "arbor://code/read/self/*")
      #=> :auto

      Policy.confirmation_mode("agent_123", "arbor://code/write/self/impl/*")
      #=> :gated  (at :trusted tier)

      Policy.confirmation_mode("agent_123", "arbor://shell/exec/*")
      #=> :gated  (always, at any tier)
  """
  @spec confirmation_mode(String.t(), String.t()) :: :auto | :gated | :deny
  def confirmation_mode(agent_id, resource_uri) do
    case effective_tier(agent_id) do
      {:ok, tier} ->
        policy_tier = ConfirmationMatrix.to_policy_tier(tier)

        # Primary path: ConfirmationMatrix (bundle × tier → mode)
        case ConfirmationMatrix.resolve_bundle(resource_uri) do
          nil ->
            # URI not in any bundle — fall back to CapabilityTemplates
            capability_templates_mode(tier, resource_uri)

          _bundle ->
            ConfirmationMatrix.mode_for(resource_uri, policy_tier)
        end

      {:error, _} ->
        :deny
    end
  end

  @doc """
  Get the minimum tier required for a resource URI.

  Delegates to `CapabilityTemplates.min_tier_for_capability/1`.

  ## Examples

      Policy.min_tier_for("arbor://code/write/self/impl/*")
      #=> :trusted

      Policy.min_tier_for("arbor://capability/request/self/*")
      #=> :autonomous
  """
  @spec min_tier_for(String.t()) :: TierResolver.trust_tier() | nil
  def min_tier_for(resource_uri) do
    CapabilityTemplates.min_tier_for_capability(resource_uri)
  end

  # ===========================================================================
  # Capability Provisioning
  # ===========================================================================

  @doc """
  Grant all capabilities for a tier to an agent.

  Creates capability entries in the CapabilityStore for each capability
  template defined at the given tier. Uses `Security.grant/1` which
  signs capabilities via SystemAuthority.

  Returns `{:ok, count}` with the number of capabilities granted,
  or `{:error, reason}` if the security infrastructure is unavailable.

  ## Examples

      {:ok, 12} = Policy.grant_tier_capabilities("agent_123", :trusted)
  """
  @spec grant_tier_capabilities(String.t(), TierResolver.trust_tier()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def grant_tier_capabilities(agent_id, tier) do
    templates = CapabilityTemplates.capabilities_for_tier(tier)

    with :ok <- ensure_security_available() do
      results =
        Enum.map(templates, fn template ->
          resource_uri = resolve_uri(template.resource_uri, agent_id)

          Arbor.Security.grant(
            principal: agent_id,
            resource: resource_uri,
            constraints: template.constraints,
            metadata: %{source: :trust_tier, tier: tier}
          )
        end)

      granted = Enum.count(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors != [] do
        Logger.warning(
          "[Policy] #{length(errors)} capability grants failed for #{agent_id}: #{inspect(Enum.take(errors, 3))}"
        )
      end

      safe_emit(:capabilities_granted, %{
        agent_id: agent_id,
        tier: tier,
        granted: granted,
        failed: length(errors)
      })

      {:ok, granted}
    end
  end

  @doc """
  Sync capabilities when an agent's tier changes.

  Revokes all existing tier-sourced capabilities and grants the new tier's
  capabilities. This is atomic in the sense that revocation + grant happens
  in sequence — if grant fails partway, some capabilities may be missing
  (fail closed is acceptable).

  ## Examples

      {:ok, %{granted: 12, revoked: 8, effective_tier: :trusted}} =
        Policy.sync_capabilities("agent_123", :probationary, :trusted)
  """
  @spec sync_capabilities(String.t(), TierResolver.trust_tier(), TierResolver.trust_tier()) ::
          {:ok, sync_result()} | {:error, term()}
  def sync_capabilities(agent_id, old_tier, new_tier) do
    with :ok <- ensure_security_available() do
      # Revoke all existing capabilities for this agent
      revoked =
        case revoke_agent_capabilities(agent_id) do
          {:ok, count} -> count
          {:error, _} -> 0
        end

      # Grant new tier capabilities
      case grant_tier_capabilities(agent_id, new_tier) do
        {:ok, granted} ->
          direction =
            if tier_index(new_tier) > tier_index(old_tier), do: :promoted, else: :demoted

          safe_emit(:tier_capabilities_synced, %{
            agent_id: agent_id,
            old_tier: old_tier,
            new_tier: new_tier,
            direction: direction,
            granted: granted,
            revoked: revoked
          })

          {:ok, %{granted: granted, revoked: revoked, effective_tier: new_tier}}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Revoke all capabilities for an agent.

  Calls `CapabilityStore.revoke_all/1` directly since the Security facade
  doesn't expose bulk revocation.

  ## Examples

      {:ok, 12} = Policy.revoke_agent_capabilities("agent_123")
  """
  @spec revoke_agent_capabilities(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_agent_capabilities(agent_id) do
    with :ok <- ensure_security_available() do
      Arbor.Security.CapabilityStore.revoke_all(agent_id)
    end
  rescue
    e ->
      Logger.error("[Policy] Failed to revoke capabilities for #{agent_id}: #{inspect(e)}")
      {:error, :revoke_failed}
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp get_behavioral_tier(agent_id) do
    if trust_available?() do
      Arbor.Trust.get_trust_tier(agent_id)
    else
      {:error, :trust_unavailable}
    end
  end

  # Policy ceiling — not yet implemented (roadmap Phase 4: onboarding interview).
  # Returns :autonomous (no ceiling) so effective_tier = behavioral_tier.
  defp get_policy_ceiling(_agent_id), do: :autonomous

  defp min_tier(behavioral, ceiling) do
    if tier_index(behavioral) <= tier_index(ceiling) do
      behavioral
    else
      ceiling
    end
  end

  defp tier_index(tier), do: TierResolver.tier_index(tier)

  defp resolve_uri(template_uri, agent_id) do
    template_uri
    |> String.replace("/self/", "/#{agent_id}/")
    |> String.replace(~r"/self$", "/#{agent_id}")
  end

  # Fallback for URIs not in any bundle — use CapabilityTemplates directly
  defp capability_templates_mode(tier, resource_uri) do
    cond do
      not CapabilityTemplates.has_capability?(tier, resource_uri) ->
        :deny

      shell_exec?(resource_uri) ->
        :gated

      CapabilityTemplates.requires_approval?(tier, resource_uri) ->
        :gated

      true ->
        :auto
    end
  end

  defp shell_exec?(resource_uri) do
    String.starts_with?(resource_uri, "arbor://shell/exec")
  end

  defp trust_available? do
    Process.whereis(Arbor.Trust.Manager) != nil
  end

  defp ensure_security_available do
    if Process.whereis(Arbor.Security.CapabilityStore) != nil do
      :ok
    else
      {:error, :security_unavailable}
    end
  end

  defp safe_emit(type, data) do
    if Code.ensure_loaded?(Arbor.Signals) and
         function_exported?(Arbor.Signals, :emit, 3) do
      Arbor.Signals.emit(:trust, type, data)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
