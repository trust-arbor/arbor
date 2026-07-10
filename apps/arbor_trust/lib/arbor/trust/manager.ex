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

      # Record trust events
      :ok = Trust.Manager.record_trust_event("agent_123", :action_success, %{})

      # Freeze trust on security incident
      :ok = Trust.Manager.freeze_trust("agent_123", :security_violation)
  """

  use GenServer

  @behaviour Arbor.Trust.Behaviour

  alias Arbor.Contracts.Trust.{Event, Profile}
  alias Arbor.Trust.Behaviour, as: Trust
  alias Arbor.Trust.{Authority, Config, EventStore, Store}

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
    EventStore.get_events(Keyword.merge(opts, agent_id: agent_id))
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
          case Store.start_link(opts) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

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
  def handle_call({:freeze_trust, agent_id, reason}, _from, state) do
    {reply, state} = do_freeze_trust(agent_id, reason, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:unfreeze_trust, agent_id}, _from, state) do
    case Store.unfreeze_profile(agent_id) do
      {:ok, _profile} ->
        {:ok, event} = Event.freeze_event(agent_id, :unfrozen)

        record_event(event, state)

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
    # Use Authority.new_profile to create with default preset rules.
    profile = Authority.new_profile(agent_id)
    Store.store_profile(profile)

    {:ok, event} =
      Event.new(
        agent_id: agent_id,
        event_type: :profile_created
      )

    record_event(event, state)

    Logger.info("Trust profile created for agent #{agent_id}", agent_id: agent_id)

    broadcast_trust_event(agent_id, :profile_created, %{})
    safe_grant_base_capabilities(agent_id)

    {:reply, {:ok, profile}, state}
  end

  @impl true
  def handle_call({:delete_trust_profile, agent_id}, _from, state) do
    case Store.get_profile(agent_id) do
      {:ok, _profile} ->
        case Store.delete_profile(agent_id) do
          :ok ->
            {:ok, event} =
              Event.new(
                agent_id: agent_id,
                event_type: :profile_deleted
              )

            record_event(event, state)

            Logger.info("Trust profile deleted for agent #{agent_id}",
              agent_id: agent_id
            )

            {:reply, :ok, state}

          {:error, _} = error ->
            {:reply, error, state}
        end

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
    # Trust decay was removed (tiers-retirement phase 3b). The public
    # run_decay_check/0 entry point is retained as a no-op so callers and
    # scheduled jobs don't break; a future rebuild is tracked in
    # `.arbor/roadmap/.../earned-trust-feedback-loop.md`.
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
      {:ok, _profile} ->
        case Event.new(
               agent_id: agent_id,
               event_type: event_type,
               metadata: metadata
             ) do
          {:ok, event} ->
            record_event(event, state)

            # Broadcast event
            broadcast_trust_event(agent_id, event_type, metadata)

            # NOTE: trust events are audit/observability only — they don't mutate
            # the profile. Authorization reads `baseline` + `rules`. There is no
            # trust tier band.

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

  defp check_circuit_breaker(agent_id, state) do
    # Get recent events to check for patterns
    {:ok, events} = EventStore.get_events(agent_id: agent_id, limit: 20)

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

    # Trigger circuit breaker if thresholds exceeded.
    #
    # NOTE: the rapid-rollbacks branch that demoted tier was removed in the
    # tier-minting kill sweep (P0 gate #1) — tier demotion minted/stripped
    # capabilities through a second authority path. The freeze branches remain:
    # freeze is rules-compatible enforcement (it revokes modifiable capabilities
    # via the :trust_frozen handler) and does not move tiers. A rollback-based
    # abuse response will return with the capability-risk-profiles work.
    cond do
      recent_failures >= 5 ->
        {_reply, state} = do_freeze_trust(agent_id, :rapid_failures, state)
        state

      recent_violations >= 3 ->
        {_reply, state} = do_freeze_trust(agent_id, :security_violations, state)
        state

      true ->
        state
    end
  end

  defp do_freeze_trust(agent_id, reason, state) do
    case Store.freeze_profile(agent_id, reason) do
      {:ok, _profile} ->
        # Store freeze event
        {:ok, event} = Event.freeze_event(agent_id, :frozen, reason: reason)

        record_event(event, state)

        Logger.warning("Trust frozen for agent #{agent_id}: #{reason}",
          agent_id: agent_id,
          reason: reason
        )

        broadcast_trust_event(agent_id, :trust_frozen, %{reason: reason})

        safe_emit_signal(:trust_frozen, %{
          agent_id: agent_id,
          reason: reason
        })

        {:ok, state}

      {:error, _} = error ->
        {error, state}
    end
  end

  defp broadcast_trust_event(agent_id, event_type, metadata) do
    pubsub = Config.pubsub()

    # PubSub for real-time LiveView updates
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

    # Signal for queryable history via Historian
    Arbor.Signals.emit(:trust, event_type, Map.merge(metadata, %{agent_id: agent_id}))
  rescue
    _ -> :ok
  end

  defp safe_emit_signal(type, data) do
    Arbor.Signals.emit(:trust, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp record_event(event, state) do
    if state.event_store_enabled do
      safe_record_event(event)
    end
  end

  defp safe_record_event(event) do
    case EventStore.record_event(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist trust event to EventStore: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("EventStore persistence failed: #{Exception.message(e)}")
      :ok
  end

  # Policy integration — safe wrappers that never crash the Manager
  defp safe_grant_base_capabilities(agent_id) do
    if policy_available?() do
      case Arbor.Trust.Policy.grant_base_capabilities(agent_id) do
        {:ok, count} ->
          Logger.debug("Granted #{count} baseline capabilities for #{agent_id}")

        {:error, reason} ->
          Logger.warning(
            "Failed to grant baseline capabilities for #{agent_id}: #{inspect(reason)}"
          )
      end
    end
  rescue
    e -> Logger.warning("Policy.grant_base_capabilities failed: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("Policy.grant_base_capabilities exit: #{inspect(reason)}")
  end

  # NOTE: safe_sync_capabilities/3, safe_reset_confirmations/1 and
  # maybe_update_profile_rules/2 were removed in the tier-minting kill sweep
  # (P0 gate #1). They existed to re-mint capabilities and reset rules when an
  # agent's tier changed. The creation grant is now tier-independent —
  # safe_grant_base_capabilities/1 above grants the universal baseline; any
  # role-specific caps come from the agent's template.

  defp policy_available? do
    Process.whereis(Arbor.Security.CapabilityStore) != nil
  end
end
