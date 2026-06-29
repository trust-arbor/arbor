defmodule Arbor.Trust.Behaviour do
  @moduledoc """
  Internal behaviour for the progressive trust system.

  This behaviour defines the interface that `Arbor.Trust.Manager` implements.
  It lives inside arbor_trust because it is an internal contract — only
  `Trust.Manager` implements it, and no other library depends on it.

  For the **public API** contract that external consumers use, see
  `Arbor.Contracts.API.Trust`.

  ## Trust Tiers

  Agents carry a trust tier (display band):

  | Tier | Name | Capabilities |
  |------|------|--------------|
  | 0 | Untrusted | Read own code only |
  | 1 | Probationary | Sandbox modifications |
  | 2 | Trusted | Self-modify with approval |
  | 3 | Veteran | Self-modify auto-approved |
  | 4 | Autonomous | Can modify own capabilities |

  ## Safety Mechanisms

  - **Circuit Breaker**: Freezes trust on anomalous behavior
  """

  alias Arbor.Contracts.Trust.Profile

  # Types
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

  # Default tier thresholds
  @default_tier_thresholds %{
    untrusted: 0,
    probationary: 20,
    trusted: 50,
    veteran: 75,
    autonomous: 90
  }

  @callback get_trust_profile(agent_id()) ::
              {:ok, Profile.t()} | {:error, :not_found | term()}

  @callback check_trust_authorization(agent_id(), required_tier :: trust_tier()) ::
              {:ok, :authorized} | {:error, :insufficient_trust | :trust_frozen | :not_found}

  @callback record_trust_event(agent_id(), trust_event_type(), metadata :: map()) :: :ok

  @callback freeze_trust(agent_id(), reason :: atom()) :: :ok | {:error, term()}

  @callback unfreeze_trust(agent_id()) :: :ok | {:error, term()}

  @callback create_trust_profile(agent_id()) :: {:ok, Profile.t()} | {:error, term()}

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
  Check if tier_a is at least as high as tier_b.
  """
  @spec tier_sufficient?(trust_tier(), trust_tier()) :: boolean()
  def tier_sufficient?(tier_a, tier_b) do
    tier_order = %{untrusted: 0, probationary: 1, trusted: 2, veteran: 3, autonomous: 4}
    tier_order[tier_a] >= tier_order[tier_b]
  end
end
