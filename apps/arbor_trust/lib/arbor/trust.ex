defmodule Arbor.Trust do
  @moduledoc """
  Public API facade for the Arbor Trust system.

  This module implements the `Arbor.Contracts.Libraries.Trust` behaviour,
  providing a unified entry point for all trust operations:

  - **Trust Profiles** - Create and manage agent trust profiles
  - **Trust Scoring** - Calculate and query trust scores
  - **Trust Events** - Record trust-affecting events
  - **Trust Authorization** - Check trust-tier-based access
  - **Trust Freezing** - Freeze/unfreeze trust progression
  - **Decay Management** - Periodic trust decay for inactive agents

  ## Quick Start

      # Start the trust system (usually via Application supervisor)
      {:ok, _} = Arbor.Trust.start_link()

      # Create a trust profile for an agent
      {:ok, profile} = Arbor.Trust.create_trust_profile("agent_001")

      # Record trust events
      :ok = Arbor.Trust.record_trust_event("agent_001", :action_success, %{action: "sort"})

      # Check trust tier
      {:ok, :authorized} = Arbor.Trust.check_trust_authorization("agent_001", :trusted)

      # Get trust tier
      {:ok, :probationary} = Arbor.Trust.get_trust_tier("agent_001")

      # Freeze trust on security incident
      :ok = Arbor.Trust.freeze_trust("agent_001", :security_violation)

  ## Trust Tiers

  | Tier | Score | Capabilities |
  |------|-------|--------------|
  | `:untrusted` | 0-19 | Read own code only |
  | `:probationary` | 20-49 | Git, limited FS read |
  | `:trusted` | 50-74 | Full read, workspace write |
  | `:veteran` | 75-89 | Extensive access |
  | `:autonomous` | 90-100 | Self-modification |

  ## Architecture

  This facade delegates to specialized modules:
  - `Arbor.Trust.Manager` - Trust profiles, scoring, and authorization
  - `Arbor.Trust.Store` - In-memory trust profile storage
  - `Arbor.Trust.Calculator` - Trust score computation
  - `Arbor.Trust.TierResolver` - Score-to-tier mapping
  - `Arbor.Trust.EventStore` - Durable event persistence
  - `Arbor.Trust.Config` - Centralized configuration
  """

  @behaviour Arbor.Contracts.Libraries.Trust

  alias Arbor.Trust.Manager

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Start the trust system supervisor.

  This is typically called by the application supervisor, but can be called
  directly for testing or manual startup.

  ## Options

  - `:circuit_breaker` - Enable circuit breaker (default: true)
  - `:decay` - Enable automatic trust decay (default: true)
  - `:event_store` - Enable durable event persistence (default: true)
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Trust.Supervisor.start_link(opts)
  end

  @doc """
  Check if the trust system is running and healthy.

  Returns `true` if the trust manager process is alive.
  """
  @impl true
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(Manager) != nil
  end

  # ===========================================================================
  # Public API — short, human-friendly names
  # ===========================================================================

  @doc """
  Create a trust profile for a new agent.

  ## Examples

      {:ok, profile} = Arbor.Trust.create_trust_profile("agent_001")
  """
  @spec create_trust_profile(String.t()) ::
          {:ok, Arbor.Contracts.Trust.Profile.t()} | {:error, term()}
  def create_trust_profile(agent_id), do: create_trust_profile_for_principal(agent_id)

  @doc """
  Get the trust profile for an agent.

  ## Examples

      {:ok, profile} = Arbor.Trust.get_trust_profile("agent_001")
  """
  @spec get_trust_profile(String.t()) ::
          {:ok, Arbor.Contracts.Trust.Profile.t()} | {:error, :not_found | term()}
  def get_trust_profile(agent_id), do: get_trust_profile_for_principal(agent_id)

  @doc """
  Get the current trust tier for an agent.

  ## Examples

      {:ok, :trusted} = Arbor.Trust.get_trust_tier("agent_001")
  """
  @spec get_trust_tier(String.t()) :: {:ok, atom()} | {:error, :not_found | term()}
  def get_trust_tier(agent_id), do: get_current_trust_tier_for_principal(agent_id)

  @doc """
  Calculate the current trust score for an agent.

  ## Examples

      {:ok, 67} = Arbor.Trust.calculate_trust_score("agent_001")
  """
  @spec calculate_trust_score(String.t()) ::
          {:ok, Arbor.Contracts.Trust.trust_score()} | {:error, term()}
  def calculate_trust_score(agent_id), do: calculate_trust_score_for_principal(agent_id)

  @doc """
  Record a trust-affecting event.

  ## Examples

      :ok = Arbor.Trust.record_trust_event("agent_001", :action_success, %{action: "sort"})
  """
  @spec record_trust_event(String.t(), atom(), map()) :: :ok
  def record_trust_event(agent_id, event_type, metadata \\ %{}),
    do: record_trust_event_for_principal_with_metadata(agent_id, event_type, metadata)

  @doc "Freeze an agent's trust progression."
  @spec freeze_trust(String.t(), atom()) :: :ok | {:error, term()}
  def freeze_trust(agent_id, reason),
    do: freeze_trust_progression_for_principal_with_reason(agent_id, reason)

  @doc "Unfreeze an agent's trust progression."
  @spec unfreeze_trust(String.t()) :: :ok | {:error, term()}
  def unfreeze_trust(agent_id), do: unfreeze_trust_progression_for_principal(agent_id)

  @doc """
  Check if an agent has sufficient trust for an operation.

  ## Examples

      {:ok, :authorized} = Arbor.Trust.check_trust_authorization("agent_001", :trusted)
  """
  @spec check_trust_authorization(String.t(), atom()) ::
          {:ok, :authorized} | {:error, :insufficient_trust | :trust_frozen | :not_found}
  def check_trust_authorization(agent_id, required_tier),
    do: check_if_principal_meets_required_trust_tier(agent_id, required_tier)

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl true
  def create_trust_profile_for_principal(agent_id) do
    Manager.create_trust_profile(agent_id)
  end

  @impl true
  def get_trust_profile_for_principal(agent_id) do
    Manager.get_trust_profile(agent_id)
  end

  @impl true
  def get_current_trust_tier_for_principal(agent_id) do
    case Manager.get_trust_profile(agent_id) do
      {:ok, profile} -> {:ok, profile.tier}
      {:error, _} = error -> error
    end
  end

  @impl true
  def calculate_trust_score_for_principal(agent_id) do
    Manager.calculate_trust_score(agent_id)
  end

  @impl true
  def record_trust_event_for_principal_with_metadata(agent_id, event_type, metadata) do
    Manager.record_trust_event(agent_id, event_type, metadata)
  end

  @impl true
  def freeze_trust_progression_for_principal_with_reason(agent_id, reason) do
    Manager.freeze_trust(agent_id, reason)
  end

  @impl true
  def unfreeze_trust_progression_for_principal(agent_id) do
    Manager.unfreeze_trust(agent_id)
  end

  @impl true
  def check_if_principal_meets_required_trust_tier(agent_id, required_tier) do
    Manager.check_trust_authorization(agent_id, required_tier)
  end

  # ===========================================================================
  # Administration
  # ===========================================================================

  @doc """
  List all trust profiles.

  ## Options

  - `:limit` - Maximum number of profiles to return
  - `:tier` - Filter by trust tier

  ## Examples

      {:ok, profiles} = Arbor.Trust.list_profiles()
      {:ok, profiles} = Arbor.Trust.list_profiles(tier: :trusted)
  """
  @spec list_profiles(keyword()) :: {:ok, [Arbor.Contracts.Trust.Profile.t()]}
  def list_profiles(opts \\ []) do
    Manager.list_profiles(opts)
  end

  @doc """
  Get recent trust events for an agent.

  ## Options

  - `:limit` - Maximum number of events to return (default: 50)

  ## Examples

      {:ok, events} = Arbor.Trust.get_events("agent_001")
      {:ok, events} = Arbor.Trust.get_events("agent_001", limit: 10)
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [Arbor.Contracts.Trust.Event.t()]}
  def get_events(agent_id, opts \\ []) do
    Manager.get_events(agent_id, opts)
  end

  @doc """
  Trigger trust decay check for all profiles.

  Should be called periodically (e.g., daily) to apply inactivity decay.
  Trust decays 1 point per day after 7 days of inactivity, with a floor of 10.

  ## Examples

      :ok = Arbor.Trust.run_decay_check()
  """
  @spec run_decay_check() :: :ok
  def run_decay_check do
    Manager.run_decay_check()
  end
end
