defmodule Arbor.Contracts.API.Trust do
  @moduledoc """
  Public API contract for the Arbor.Trust library.

  This contract defines the facade interface that external consumers use to
  interact with the trust system. It provides a unified entry point for:

  - **Trust Profiles** - Create and manage agent trust profiles
  - **Trust Scoring** - Calculate and query trust scores
  - **Trust Events** - Record trust-affecting events
  - **Trust Authorization** - Check trust-tier-based access
  - **Trust Freezing** - Freeze/unfreeze trust progression

  ## Quick Start

      # Start the trust system
      {:ok, _} = Arbor.Trust.start_link()

      # Create a trust profile for an agent
      {:ok, profile} = Arbor.Trust.create_trust_profile("agent_001")

      # Record trust events
      :ok = Arbor.Trust.record_trust_event("agent_001", :action_success, %{action: "sort"})

      # Check trust tier
      {:ok, :authorized} = Arbor.Trust.check_trust_authorization("agent_001", :trusted)

  ## Trust Tiers

  | Tier | Score | Capabilities |
  |------|-------|--------------|
  | `:untrusted` | 0-19 | Read own code only |
  | `:probationary` | 20-49 | Git, limited FS read |
  | `:trusted` | 50-74 | Full read, workspace write |
  | `:veteran` | 75-89 | Extensive access |
  | `:autonomous` | 90-100 | Self-modification |

  @version "1.0.0"
  """

  alias Arbor.Types

  # ===========================================================================
  # Types
  # ===========================================================================

  @type principal_id :: Types.agent_id()
  @type trust_tier :: :untrusted | :probationary | :trusted | :veteran | :autonomous
  @type trust_score :: 0..100
  @type trust_profile :: map()

  # ===========================================================================
  # Trust Management
  # ===========================================================================

  @doc """
  Create a new trust profile for a principal.

  Initializes the principal with `:untrusted` tier (score 0).
  """
  @callback create_trust_profile_for_principal(principal_id()) ::
              {:ok, trust_profile()} | {:error, :already_exists | term()}

  @doc """
  Get the complete trust profile for a principal.

  Returns the trust profile including score, tier, and metrics.
  """
  @callback get_trust_profile_for_principal(principal_id()) ::
              {:ok, trust_profile()} | {:error, :not_found}

  @doc """
  Get the current trust tier for a principal.
  """
  @callback get_current_trust_tier_for_principal(principal_id()) ::
              {:ok, trust_tier()} | {:error, :not_found}

  @doc """
  Record a trust-affecting event for a principal with metadata.

  Events modify the principal's trust score and may trigger tier changes.
  """
  @callback record_trust_event_for_principal_with_metadata(
              principal_id(),
              event_type :: atom(),
              metadata :: map()
            ) :: :ok

  @doc """
  Freeze trust progression for a principal with a stated reason.

  Frozen principals keep current capabilities but cannot earn more trust.
  """
  @callback freeze_trust_progression_for_principal_with_reason(
              principal_id(),
              reason :: atom()
            ) :: :ok | {:error, term()}

  @doc """
  Unfreeze trust progression for a principal.
  """
  @callback unfreeze_trust_progression_for_principal(principal_id()) ::
              :ok | {:error, term()}

  @doc """
  Check if trust is frozen for a principal.
  """
  @callback check_if_trust_frozen_for_principal(principal_id()) :: boolean()

  @doc """
  Subscribe to trust events for a principal or all principals.

  Allows components to react to trust score and tier changes.
  """
  @callback subscribe_to_trust_events_for_principal(
              principal_id() | :all,
              handler :: function()
            ) :: {:ok, subscription_id :: String.t()} | {:error, term()}

  @doc """
  Check if a principal meets the required trust tier.
  """
  @callback check_if_principal_meets_required_trust_tier(
              principal_id(),
              required_tier :: trust_tier()
            ) :: {:ok, :authorized} | {:error, :insufficient_trust | :trust_frozen | :not_found}

  @doc """
  Calculate the trust score for a principal from their event history.
  """
  @callback calculate_trust_score_for_principal(principal_id()) ::
              {:ok, trust_score()} | {:error, term()}

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the trust system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the trust system is running and healthy.
  """
  @callback healthy?() :: boolean()

  # ===========================================================================
  # Optional Callbacks
  # ===========================================================================

  @optional_callbacks [
    check_if_trust_frozen_for_principal: 1,
    subscribe_to_trust_events_for_principal: 2,
    check_if_principal_meets_required_trust_tier: 2,
    calculate_trust_score_for_principal: 1
  ]
end
