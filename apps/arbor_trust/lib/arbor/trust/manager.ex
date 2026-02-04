defmodule Arbor.Trust.Manager do
  @moduledoc """
  Trust management GenServer implementing the Trust behaviour.

  This is the main entry point for the progressive trust system. It
  coordinates trust profile management, score calculation, and
  authorization checks.

  ## Responsibilities

  - Create and manage trust profiles for self-improving agents
  - Record trust-affecting events
  - Calculate trust scores
  - Check trust authorization for operations
  - Manage trust freezing/unfreezing
  - Coordinate with circuit breakers

  ## Usage

      # Create a profile for a new agent
      {:ok, profile} = Trust.Manager.create_trust_profile("agent_123")

      # Check if agent has sufficient trust
      {:ok, :authorized} = Trust.Manager.check_trust_authorization("agent_123", :trusted)

      # Record trust events
      :ok = Trust.Manager.record_trust_event("agent_123", :action_success, %{})

      # Freeze trust on security incident
      :ok = Trust.Manager.freeze_trust("agent_123", :security_violation)
  """

  use GenServer

  @behaviour Arbor.Trust.Behaviour

  alias Arbor.Contracts.Trust.{Event, Profile}
  alias Arbor.Trust.Behaviour, as: Trust
  alias Arbor.Trust.{Calculator, Config, EventStore, Store, TierResolver}

  require Logger

  defstruct [
    :store_pid,
    :circuit_breaker_enabled,
    :decay_enabled,
    :event_store_enabled
  ]

  # Client API

  @doc """
  Start the trust manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the trust profile for an agent.
  """
  @impl Trust
  @spec get_trust_profile(String.t()) :: {:ok, Profile.t()} | {:error, :not_found | term()}
  def get_trust_profile(agent_id) do
    GenServer.call(__MODULE__, {:get_trust_profile, agent_id})
  end

  @doc """
  Calculate the current trust score for an agent.
  """
  @impl Trust
  @spec calculate_trust_score(String.t()) :: {:ok, Trust.trust_score()} | {:error, term()}
  def calculate_trust_score(agent_id) do
    GenServer.call(__MODULE__, {:calculate_trust_score, agent_id})
  end

  @doc """
  Get the capability tier for a trust score.
  """
  @impl Trust
  @spec get_capability_tier(Trust.trust_score()) :: Trust.trust_tier()
  def get_capability_tier(trust_score) do
    TierResolver.resolve(trust_score)
  end

  @doc """
  Check if an agent has sufficient trust for an operation.
  """
  @impl Trust
  @spec check_trust_authorization(String.t(), Trust.trust_tier()) ::
          {:ok, :authorized} | {:error, :insufficient_trust | :trust_frozen | :not_found}
  def check_trust_authorization(agent_id, required_tier) do
    GenServer.call(__MODULE__, {:check_trust_authorization, agent_id, required_tier})
  end

  @doc """
  Record a trust-affecting event.
  """
  @impl Trust
  @spec record_trust_event(String.t(), Trust.trust_event_type(), map()) :: :ok
  def record_trust_event(agent_id, event_type, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_trust_event, agent_id, event_type, metadata})
  end

  @doc """
  Freeze an agent's trust.
  """
  @impl Trust
  @spec freeze_trust(String.t(), atom()) :: :ok | {:error, term()}
  def freeze_trust(agent_id, reason) do
    GenServer.call(__MODULE__, {:freeze_trust, agent_id, reason})
  end

  @doc """
  Unfreeze an agent's trust.
  """
  @impl Trust
  @spec unfreeze_trust(String.t()) :: :ok | {:error, term()}
  def unfreeze_trust(agent_id) do
    GenServer.call(__MODULE__, {:unfreeze_trust, agent_id})
  end

  @doc """
  Create a new trust profile for an agent.
  """
  @impl Trust
  @spec create_trust_profile(String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def create_trust_profile(agent_id) do
    GenServer.call(__MODULE__, {:create_trust_profile, agent_id})
  end

  @doc """
  Delete a trust profile.
  """
  @impl Trust
  @spec delete_trust_profile(String.t()) :: :ok | {:error, term()}
  def delete_trust_profile(agent_id) do
    GenServer.call(__MODULE__, {:delete_trust_profile, agent_id})
  end

  @doc """
  Get all profiles (admin function).
  """
  @spec list_profiles(keyword()) :: {:ok, [Profile.t()]}
  def list_profiles(opts \\ []) do
    Store.list_profiles(opts)
  end

  @doc """
  Get recent events for an agent.
  """
  @spec get_events(String.t(), keyword()) :: {:ok, [Event.t()]}
  def get_events(agent_id, opts \\ []) do
    Store.get_events(agent_id, opts)
  end

  @doc """
  Trigger trust decay check for all profiles.

  Should be called periodically (e.g., daily) to apply inactivity decay.
  """
  @spec run_decay_check() :: :ok
  def run_decay_check do
    GenServer.cast(__MODULE__, :run_decay_check)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Ensure Store is started
    store_pid =
      case Process.whereis(Store) do
        nil ->
          {:ok, pid} = Store.start_link(opts)
          pid

        pid ->
          pid
      end

    state = %__MODULE__{
      store_pid: store_pid,
      circuit_breaker_enabled: Keyword.get(opts, :circuit_breaker, true),
      decay_enabled: Keyword.get(opts, :decay, true),
      event_store_enabled: Keyword.get(opts, :event_store, true)
    }

    Logger.info("Trust.Manager started")

    {:ok, state}
  end

  @impl true
  def handle_call({:get_trust_profile, agent_id}, _from, state) do
    result = Store.get_profile(agent_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:calculate_trust_score, agent_id}, _from, state) do
    case Store.get_profile(agent_id) do
      {:ok, profile} ->
        # Recalculate with current time for accurate uptime score
        updated = Calculator.recalculate_profile(profile, DateTime.utc_now())
        Store.store_profile(updated)
        {:reply, {:ok, updated.trust_score}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:check_trust_authorization, agent_id, required_tier}, _from, state) do
    result =
      case Store.get_profile(agent_id) do
        {:ok, %{frozen: true}} ->
          {:error, :trust_frozen}

        {:ok, profile} ->
          if TierResolver.sufficient?(profile.tier, required_tier) do
            {:ok, :authorized}
          else
            {:error, :insufficient_trust}
          end

        {:error, :not_found} ->
          {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:freeze_trust, agent_id, reason}, _from, state) do
    {reply, state} = do_freeze_trust(agent_id, reason, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:unfreeze_trust, agent_id}, _from, state) do
    case Store.unfreeze_profile(agent_id) do
      {:ok, profile} ->
        {:ok, event} =
          Event.freeze_event(agent_id, :unfrozen,
            previous_score: profile.trust_score,
            new_score: profile.trust_score
          )

        Store.store_event(event)
        persist_to_event_store(event, state)

        Logger.info("Trust unfrozen for agent #{agent_id}",
          agent_id: agent_id
        )

        broadcast_trust_event(agent_id, :trust_unfrozen, %{})
        {:reply, :ok, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:create_trust_profile, agent_id}, _from, state) do
    case Profile.new(agent_id) do
      {:ok, profile} ->
        Store.store_profile(profile)

        {:ok, event} =
          Event.new(
            agent_id: agent_id,
            event_type: :profile_created,
            new_score: 0
          )

        Store.store_event(event)
        persist_to_event_store(event, state)

        Logger.info("Trust profile created for agent #{agent_id}",
          agent_id: agent_id
        )

        # Broadcast event to trigger capability sync
        broadcast_trust_event(agent_id, :profile_created, %{tier: :untrusted})

        {:reply, {:ok, profile}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:delete_trust_profile, agent_id}, _from, state) do
    case Store.get_profile(agent_id) do
      {:ok, profile} ->
        Store.delete_profile(agent_id)

        {:ok, event} =
          Event.new(
            agent_id: agent_id,
            event_type: :profile_deleted,
            previous_score: profile.trust_score
          )

        Store.store_event(event)
        persist_to_event_store(event, state)

        Logger.info("Trust profile deleted for agent #{agent_id}",
          agent_id: agent_id
        )

        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:record_trust_event, agent_id, event_type, metadata}, state) do
    handle_trust_event(agent_id, event_type, metadata, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:run_decay_check, state) do
    if state.decay_enabled do
      run_decay_check_impl()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:check_circuit_breaker, agent_id}, state) do
    state =
      if state.circuit_breaker_enabled do
        check_circuit_breaker(agent_id, state)
      else
        state
      end

    {:noreply, state}
  end

  # Private functions

  defp handle_trust_event(agent_id, event_type, metadata, state) do
    case Store.get_profile(agent_id) do
      {:ok, old_profile} ->
        # Update profile based on event type
        {:ok, new_profile} = update_profile_for_event(agent_id, event_type, metadata)

        case Event.new(
               agent_id: agent_id,
               event_type: event_type,
               previous_score: old_profile.trust_score,
               new_score: new_profile.trust_score,
               previous_tier: old_profile.tier,
               new_tier: new_profile.tier,
               metadata: metadata
             ) do
          {:ok, event} ->
            Store.store_event(event)

            # Persist to durable event store
            persist_to_event_store(event, state)

            # Broadcast event
            broadcast_trust_event(agent_id, event_type, metadata)

            # Check circuit breaker for negative events
            maybe_trigger_circuit_breaker(event, agent_id, state)

          {:error, reason} ->
            Logger.warning("Trust event ignored due to invalid event type",
              agent_id: agent_id,
              event_type: event_type,
              reason: inspect(reason)
            )
        end

      {:error, :not_found} ->
        Logger.debug("Trust event for unknown agent #{agent_id}, creating profile")
        # Auto-create profile for unknown agents
        {:ok, _profile} = create_trust_profile(agent_id)
        # Retry the event
        handle_trust_event(agent_id, event_type, metadata, state)
    end
  end

  defp maybe_trigger_circuit_breaker(event, agent_id, state) do
    if Event.circuit_breaker_relevant?(event) and state.circuit_breaker_enabled do
      send(self(), {:check_circuit_breaker, agent_id})
    end
  end

  defp update_profile_for_event(agent_id, :action_success, _metadata),
    do: Store.record_action_success(agent_id)

  defp update_profile_for_event(agent_id, :action_failure, _metadata),
    do: Store.record_action_failure(agent_id)

  defp update_profile_for_event(agent_id, :test_passed, _metadata),
    do: Store.record_test_result(agent_id, :passed)

  defp update_profile_for_event(agent_id, :test_failed, _metadata),
    do: Store.record_test_result(agent_id, :failed)

  defp update_profile_for_event(agent_id, :rollback_executed, _metadata),
    do: Store.record_rollback(agent_id)

  defp update_profile_for_event(agent_id, :security_violation, _metadata),
    do: Store.record_security_violation(agent_id)

  defp update_profile_for_event(agent_id, :improvement_applied, _metadata),
    do: Store.record_improvement(agent_id)

  # Council-based trust earning events
  defp update_profile_for_event(agent_id, :proposal_submitted, _metadata),
    do: Store.record_proposal_submitted(agent_id)

  defp update_profile_for_event(agent_id, :proposal_approved, metadata),
    do: Store.record_proposal_approved(agent_id, Map.get(metadata, :impact, :medium))

  defp update_profile_for_event(agent_id, :proposal_rejected, _metadata),
    do: Store.get_profile(agent_id)

  defp update_profile_for_event(agent_id, :installation_success, metadata),
    do: Store.record_installation_success(agent_id, Map.get(metadata, :impact, :medium))

  defp update_profile_for_event(agent_id, :installation_rollback, _metadata),
    do: Store.record_installation_rollback(agent_id)

  defp update_profile_for_event(agent_id, :trust_points_awarded, metadata),
    do: Store.award_trust_points(agent_id, Map.get(metadata, :points, 0))

  defp update_profile_for_event(agent_id, :trust_points_deducted, metadata) do
    Store.deduct_trust_points(
      agent_id,
      Map.get(metadata, :points, 0),
      Map.get(metadata, :reason, :unknown)
    )
  end

  defp update_profile_for_event(agent_id, _event_type, _metadata),
    do: Store.get_profile(agent_id)

  defp check_circuit_breaker(agent_id, state) do
    # Get recent events to check for patterns
    {:ok, events} = Store.get_events(agent_id, limit: 20)

    now = DateTime.utc_now()
    one_minute_ago = DateTime.add(now, -60, :second)
    one_hour_ago = DateTime.add(now, -3600, :second)

    # Count recent negative events
    recent_failures =
      Enum.count(events, fn event ->
        DateTime.compare(event.timestamp, one_minute_ago) == :gt and
          event.event_type in [:action_failure, :test_failed]
      end)

    recent_violations =
      Enum.count(events, fn event ->
        DateTime.compare(event.timestamp, one_hour_ago) == :gt and
          event.event_type == :security_violation
      end)

    recent_rollbacks =
      Enum.count(events, fn event ->
        DateTime.compare(event.timestamp, one_hour_ago) == :gt and
          event.event_type == :rollback_executed
      end)

    # Trigger circuit breaker if thresholds exceeded
    cond do
      recent_failures >= 5 ->
        {_reply, state} = do_freeze_trust(agent_id, :rapid_failures, state)
        state

      recent_violations >= 3 ->
        {_reply, state} = do_freeze_trust(agent_id, :security_violations, state)
        state

      recent_rollbacks >= 3 ->
        # Just drop tier, don't freeze
        demote_tier(agent_id)
        state

      true ->
        state
    end
  end

  defp do_freeze_trust(agent_id, reason, state) do
    case Store.freeze_profile(agent_id, reason) do
      {:ok, profile} ->
        # Store freeze event
        {:ok, event} =
          Event.freeze_event(agent_id, :frozen,
            reason: reason,
            previous_score: profile.trust_score,
            new_score: profile.trust_score
          )

        Store.store_event(event)
        persist_to_event_store(event, state)

        Logger.warning("Trust frozen for agent #{agent_id}: #{reason}",
          agent_id: agent_id,
          reason: reason
        )

        broadcast_trust_event(agent_id, :trust_frozen, %{reason: reason})
        {:ok, state}

      {:error, _} = error ->
        {error, state}
    end
  end

  defp demote_tier(agent_id) do
    case Store.get_profile(agent_id) do
      {:ok, profile} ->
        apply_tier_demotion(agent_id, profile)

      _ ->
        :ok
    end
  end

  defp apply_tier_demotion(agent_id, profile) do
    case TierResolver.previous_tier(profile.tier) do
      nil ->
        :ok

      lower_tier ->
        new_score = TierResolver.max_score(lower_tier)

        Store.update_profile(agent_id, fn p ->
          %{p | trust_score: new_score, tier: lower_tier}
        end)

        Logger.warning(
          "Trust demoted for agent #{agent_id}: #{profile.tier} -> #{lower_tier}",
          agent_id: agent_id,
          old_tier: profile.tier,
          new_tier: lower_tier
        )
    end
  end

  defp run_decay_check_impl do
    now = DateTime.utc_now()

    {:ok, profiles} = Store.list_profiles([])

    Enum.each(profiles, fn profile ->
      days_inactive = calculate_days_inactive(profile, now)
      maybe_apply_decay(profile, days_inactive)
    end)
  end

  defp calculate_days_inactive(profile, now) do
    case profile.last_activity_at do
      nil -> DateTime.diff(now, profile.created_at, :day)
      last -> DateTime.diff(now, last, :day)
    end
  end

  defp maybe_apply_decay(profile, days_inactive) when days_inactive > 7 do
    decayed = Profile.apply_decay(profile, days_inactive)

    if decayed.trust_score != profile.trust_score do
      persist_decay(profile, decayed, days_inactive)
    end
  end

  defp maybe_apply_decay(_profile, _days_inactive), do: :ok

  defp persist_decay(profile, decayed, days_inactive) do
    Store.store_profile(decayed)

    {:ok, event} =
      Event.new(
        agent_id: profile.agent_id,
        event_type: :trust_decayed,
        previous_score: profile.trust_score,
        new_score: decayed.trust_score,
        metadata: %{days_inactive: days_inactive}
      )

    Store.store_event(event)

    Logger.debug("Trust decayed for inactive agent #{profile.agent_id}",
      agent_id: profile.agent_id,
      days_inactive: days_inactive,
      old_score: profile.trust_score,
      new_score: decayed.trust_score
    )
  end

  defp broadcast_trust_event(agent_id, event_type, metadata) do
    pubsub = Config.pubsub()

    Phoenix.PubSub.broadcast(
      pubsub,
      "trust:events",
      {:trust_event, agent_id, event_type, metadata}
    )

    Phoenix.PubSub.broadcast(
      pubsub,
      "trust:#{agent_id}",
      {:trust_event, agent_id, event_type, metadata}
    )
  rescue
    _ -> :ok
  end

  defp persist_to_event_store(event, state) do
    if state.event_store_enabled do
      case EventStore.record_event(event) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to persist trust event to EventStore: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("EventStore persistence failed: #{Exception.message(e)}")
      :ok
  end
end
