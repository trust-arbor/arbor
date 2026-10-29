defmodule Arbor.Contracts.API.Trust do
  @moduledoc """
  Public API contract for the Arbor.Trust library.

  This contract defines the facade interface that external consumers use to
  interact with the trust system. It provides a unified entry point for:

  - **Trust Profiles** - Create and manage agent trust profiles
  - **Trust Events** - Record trust-affecting events
  - **Trust Freezing** - Freeze/unfreeze trust progression

  ## Quick Start

      # Start the trust system
      {:ok, _} = Arbor.Trust.start_link()

      # Create a trust profile for an agent
      {:ok, profile} = Arbor.Trust.create_trust_profile("agent_001")

      # Record trust events
      :ok = Arbor.Trust.record_trust_event("agent_001", :action_success, %{action: "sort"})

  @version "1.0.0"
  """

  alias Arbor.Types

  # ===========================================================================
  # Types
  # ===========================================================================

  @type principal_id :: Types.agent_id()
  @type trust_profile :: map()

  # ===========================================================================
  # Trust Management
  # ===========================================================================

  @doc """
  Create a new trust profile for a principal.
  """
  @callback create_trust_profile_for_principal(principal_id()) ::
              {:ok, trust_profile()} | {:error, :already_exists | term()}

  @doc """
  Get the complete trust profile for a principal.

  Returns the trust profile including baseline, rules, and frozen state.
  """
  @callback get_trust_profile_for_principal(principal_id()) ::
              {:ok, trust_profile()} | {:error, :not_found}

  @doc """
  Record a trust-affecting event for a principal with metadata.

  Events are recorded for audit/observability and feed the circuit breaker.
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

  Allows components to react to trust freeze/unfreeze and audit events.
  """
  @callback subscribe_to_trust_events_for_principal(
              principal_id() | :all,
              handler :: function()
            ) :: {:ok, subscription_id :: String.t()} | {:error, term()}

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
    subscribe_to_trust_events_for_principal: 2
  ]
end
