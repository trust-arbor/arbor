defmodule Arbor.Contracts.Security.Trust do
  @moduledoc """
  Contract for the progressive trust system.

  This behaviour defines the interface for managing agent trust levels,
  which determine what self-modification capabilities an agent has earned.

  ## Trust Tiers

  Agents progress through trust tiers based on their operational history:

  | Tier | Score Range | Capabilities |
  |------|-------------|--------------|
  | :untrusted | 0-19 | Read own code only |
  | :probationary | 20-49 | Sandbox modifications |
  | :trusted | 50-74 | Self-modify with approval |
  | :veteran | 75-89 | Self-modify auto-approved |
  | :autonomous | 90-100 | Modify own capabilities |

  ## Usage

      case Trust.check_trust_authorization(agent_id, :trusted) do
        {:ok, :authorized} -> proceed_with_modification()
        {:error, :insufficient_trust} -> deny_modification()
      end
  """

  alias Arbor.Contracts.Security.TrustProfile

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

  # Tier thresholds
  @tier_thresholds %{
    untrusted: 0,
    probationary: 20,
    trusted: 50,
    veteran: 75,
    autonomous: 90
  }

  @doc """
  Get the trust profile for an agent.
  """
  @callback get_trust_profile(agent_id()) ::
              {:ok, TrustProfile.t()} | {:error, :not_found | term()}

  @doc """
  Calculate the current trust score for an agent.
  """
  @callback calculate_trust_score(agent_id()) :: {:ok, trust_score()} | {:error, term()}

  @doc """
  Get the capability tier for a given trust score.
  """
  @callback get_capability_tier(trust_score()) :: trust_tier()

  @doc """
  Check if an agent has sufficient trust for an operation.
  """
  @callback check_trust_authorization(agent_id(), required_tier :: trust_tier()) ::
              {:ok, :authorized} | {:error, :insufficient_trust | :trust_frozen | :not_found}

  @doc """
  Record a trust-affecting event.
  """
  @callback record_trust_event(agent_id(), trust_event_type(), metadata :: map()) :: :ok

  @doc """
  Freeze an agent's trust, preventing capability upgrades.
  """
  @callback freeze_trust(agent_id(), reason :: atom()) :: :ok | {:error, term()}

  @doc """
  Unfreeze an agent's trust.
  """
  @callback unfreeze_trust(agent_id()) :: :ok | {:error, term()}

  @doc """
  Create a new trust profile for an agent.
  """
  @callback create_trust_profile(agent_id()) :: {:ok, TrustProfile.t()} | {:error, term()}

  @doc """
  Delete a trust profile.
  """
  @callback delete_trust_profile(agent_id()) :: :ok | {:error, term()}

  # Helper functions available to all implementations

  @doc """
  Get the tier thresholds map.
  """
  @spec tier_thresholds() :: map()
  def tier_thresholds, do: @tier_thresholds

  @doc """
  Get all valid trust tiers in order.
  """
  @spec tiers() :: [trust_tier()]
  def tiers, do: [:untrusted, :probationary, :trusted, :veteran, :autonomous]

  @doc """
  Get the minimum score required for a tier.
  """
  @spec min_score_for_tier(trust_tier()) :: trust_score()
  def min_score_for_tier(tier), do: Map.fetch!(@tier_thresholds, tier)

  @doc """
  Check if tier_a is at least as high as tier_b.
  """
  @spec tier_sufficient?(trust_tier(), trust_tier()) :: boolean()
  def tier_sufficient?(tier_a, tier_b) do
    tier_order = %{untrusted: 0, probationary: 1, trusted: 2, veteran: 3, autonomous: 4}
    tier_order[tier_a] >= tier_order[tier_b]
  end
end
