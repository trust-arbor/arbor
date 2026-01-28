defmodule Arbor.Contracts.Trust do
  @moduledoc """
  Contract for the progressive trust system.

  This behaviour defines the interface for managing agent trust levels,
  which determine what self-modification capabilities an agent has earned.

  ## Trust Tiers

  Agents progress through trust tiers based on their operational history:

  | Tier | Score Range | Name | Capabilities |
  |------|-------------|------|--------------|
  | 0 | 0-19 | Untrusted | Read own code only |
  | 1 | 20-49 | Probationary | Sandbox modifications |
  | 2 | 50-74 | Trusted | Self-modify with approval |
  | 3 | 75-89 | Veteran | Self-modify auto-approved |
  | 4 | 90-100 | Autonomous | Can modify own capabilities |

  ## Trust Score Calculation

  The trust score is calculated as a weighted average:

      trust_score = (success_rate * 0.30) +
                    (uptime * 0.15) +
                    (security_compliance * 0.25) +
                    (test_pass_rate * 0.20) +
                    (rollback_stability * 0.10)

  ## Safety Mechanisms

  - **Circuit Breaker**: Freezes trust on anomalous behavior
  - **Decay**: Trust decays 1 point/day after 7 days of inactivity
  - **Minimum Floor**: Trust never decays below 10 (preserves read access)

  ## Usage

      # Check if agent has sufficient trust
      case Trust.check_trust_authorization(agent_id, :trusted) do
        {:ok, :authorized} -> proceed_with_modification()
        {:error, :insufficient_trust} -> deny_modification()
      end

      # Record trust-affecting events
      Trust.record_trust_event(agent_id, :action_success, %{action: "sort"})
      Trust.record_trust_event(agent_id, :security_violation, %{reason: :blocked_module})

  @version "1.0.0"
  """

  alias Arbor.Contracts.Trust.Profile

  # Types
  @type trust_score :: 0..100
  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous
  @type agent_id :: String.t()

  @type trust_event_type ::
          :action_success
          | :action_failure
          | :test_passed
          | :test_failed
          | :rollback_executed
          | :security_violation
          | :improvement_applied
          | :trust_frozen
          | :trust_unfrozen
          | :trust_decayed

  # Default tier thresholds
  @default_tier_thresholds %{
    untrusted: 0,
    probationary: 20,
    trusted: 50,
    veteran: 75,
    autonomous: 90
  }

  @doc """
  Get the trust profile for an agent.

  Returns the complete trust profile including score, tier, and all
  component metrics.

  ## Example

      {:ok, profile} = Trust.get_trust_profile("agent_123")
      profile.tier
      #=> :probationary
  """
  @callback get_trust_profile(agent_id()) ::
              {:ok, Profile.t()} | {:error, :not_found | term()}

  @doc """
  Calculate the current trust score for an agent.

  Recalculates the score based on current metrics. This is typically
  called automatically when trust-affecting events occur.

  ## Example

      {:ok, 67} = Trust.calculate_trust_score("agent_123")
  """
  @callback calculate_trust_score(agent_id()) :: {:ok, trust_score()} | {:error, term()}

  @doc """
  Get the capability tier for a given trust score.

  Pure function that maps a score to a tier.

  ## Example

      Trust.get_capability_tier(67)
      #=> :trusted
  """
  @callback get_capability_tier(trust_score()) :: trust_tier()

  @doc """
  Check if an agent has sufficient trust for an operation.

  Used by the security enforcer to gate self-modification capabilities.

  ## Example

      {:ok, :authorized} = Trust.check_trust_authorization("agent_123", :trusted)
      {:error, :insufficient_trust} = Trust.check_trust_authorization("agent_456", :veteran)
  """
  @callback check_trust_authorization(agent_id(), required_tier :: trust_tier()) ::
              {:ok, :authorized} | {:error, :insufficient_trust | :trust_frozen | :not_found}

  @doc """
  Record a trust-affecting event.

  Events are processed asynchronously and may trigger trust recalculation.

  ## Event Types

  - `:action_success` - Successful action execution (+success_rate)
  - `:action_failure` - Failed action execution (-success_rate)
  - `:test_passed` - Test passed (+test_pass_rate)
  - `:test_failed` - Test failed (-test_pass_rate)
  - `:rollback_executed` - Code rollback occurred (-rollback_stability)
  - `:security_violation` - Security policy violated (-security_compliance)
  - `:improvement_applied` - Self-improvement was applied (+improvement_count)

  ## Example

      :ok = Trust.record_trust_event("agent_123", :action_success, %{
        action: "sort_list",
        duration_ms: 42
      })
  """
  @callback record_trust_event(agent_id(), trust_event_type(), metadata :: map()) :: :ok

  @doc """
  Freeze an agent's trust, preventing capability upgrades.

  Used by circuit breakers when anomalous behavior is detected.
  Frozen agents retain their current capabilities but cannot earn more.

  ## Example

      :ok = Trust.freeze_trust("agent_123", :rapid_failures)
  """
  @callback freeze_trust(agent_id(), reason :: atom()) :: :ok | {:error, term()}

  @doc """
  Unfreeze an agent's trust, allowing normal trust progression.

  Should be called after manual review or automatic cooldown period.

  ## Example

      :ok = Trust.unfreeze_trust("agent_123")
  """
  @callback unfreeze_trust(agent_id()) :: :ok | {:error, term()}

  @doc """
  Create a new trust profile for an agent.

  Called when a new self-improving agent is spawned. Initial trust
  score is 0 (untrusted tier).

  ## Example

      {:ok, profile} = Trust.create_trust_profile("agent_new")
      profile.tier
      #=> :untrusted
  """
  @callback create_trust_profile(agent_id()) :: {:ok, Profile.t()} | {:error, term()}

  @doc """
  Delete a trust profile.

  Called when an agent is permanently removed from the system.

  ## Example

      :ok = Trust.delete_trust_profile("agent_123")
  """
  @callback delete_trust_profile(agent_id()) :: :ok | {:error, term()}

  # Helper functions available to all implementations

  @doc """
  Get the default tier thresholds map.
  """
  @spec tier_thresholds() :: %{
          untrusted: 0,
          probationary: 20,
          trusted: 50,
          veteran: 75,
          autonomous: 90
        }
  def tier_thresholds, do: @default_tier_thresholds

  @doc """
  Get the tier thresholds, optionally overridden by custom thresholds.
  """
  @spec tier_thresholds(map()) :: map()
  def tier_thresholds(custom) when is_map(custom), do: Map.merge(@default_tier_thresholds, custom)

  @doc """
  Get all valid trust tiers in order.
  """
  @spec tiers() :: [:untrusted | :probationary | :trusted | :veteran | :autonomous, ...]
  def tiers, do: [:untrusted, :probationary, :trusted, :veteran, :autonomous]

  @doc """
  Get the minimum score required for a tier.
  """
  @spec min_score_for_tier(trust_tier()) :: trust_score()
  def min_score_for_tier(tier), do: Map.fetch!(@default_tier_thresholds, tier)

  @doc """
  Get the minimum score required for a tier with custom thresholds.
  """
  @spec min_score_for_tier(trust_tier(), map()) :: trust_score()
  def min_score_for_tier(tier, thresholds), do: Map.fetch!(thresholds, tier)

  @doc """
  Check if tier_a is at least as high as tier_b.
  """
  @spec tier_sufficient?(trust_tier(), trust_tier()) :: boolean()
  def tier_sufficient?(tier_a, tier_b) do
    tier_order = %{untrusted: 0, probationary: 1, trusted: 2, veteran: 3, autonomous: 4}
    tier_order[tier_a] >= tier_order[tier_b]
  end
end
