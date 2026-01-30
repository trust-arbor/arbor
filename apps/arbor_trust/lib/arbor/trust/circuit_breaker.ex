defmodule Arbor.Trust.CircuitBreaker do
  @moduledoc """
  Circuit breaker for trust anomaly detection.

  This module monitors trust events and triggers protective actions
  when anomalous patterns are detected. It helps prevent gaming of
  the trust system and provides rapid response to security incidents.

  ## Circuit Breaker Rules

  | Trigger | Threshold | Window | Action |
  |---------|-----------|--------|--------|
  | Rapid failures | 5 failures | 60 seconds | Freeze trust |
  | Security violations | 3 violations | 1 hour | Freeze trust for 24h |
  | Rollback spike | 3 rollbacks | 1 hour | Drop 1 tier |
  | Test failure spike | 5 failures | 5 minutes | Pause improvements |

  ## States

  - `:closed` - Normal operation, events flow through
  - `:open` - Circuit tripped, trust frozen
  - `:half_open` - Testing recovery, limited operations

  ## Usage

      # Check if circuit breaker is tripped
      case CircuitBreaker.check("agent_123") do
        :ok -> proceed()
        {:error, :circuit_open} -> handle_frozen()
      end

      # Record event for monitoring
      CircuitBreaker.record_event("agent_123", :action_failure)
  """

  use GenServer

  alias Arbor.Signals
  alias Arbor.Trust.{Config, Manager}

  require Logger

  @type circuit_state :: :closed | :open | :half_open

  defstruct [
    :agent_events,
    :circuit_states,
    :config
  ]

  # Client API

  @doc """
  Start the circuit breaker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if an agent's circuit is open (frozen).
  """
  @spec check(String.t()) :: :ok | {:error, :circuit_open}
  def check(agent_id) do
    GenServer.call(__MODULE__, {:check, agent_id})
  end

  @doc """
  Record an event for circuit breaker monitoring.
  """
  @spec record_event(String.t(), atom(), map()) :: :ok
  def record_event(agent_id, event_type, metadata \\ %{}) do
    GenServer.cast(__MODULE__, {:record_event, agent_id, event_type, metadata})
  end

  @doc """
  Get the circuit state for an agent.
  """
  @spec get_state(String.t()) :: circuit_state()
  def get_state(agent_id) do
    GenServer.call(__MODULE__, {:get_state, agent_id})
  end

  @doc """
  Reset the circuit breaker for an agent (admin action).
  """
  @spec reset(String.t()) :: :ok
  def reset(agent_id) do
    GenServer.call(__MODULE__, {:reset, agent_id})
  end

  @doc """
  Get current configuration.
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    default_config = Config.circuit_breaker_config()
    config = Map.merge(default_config, Keyword.get(opts, :config, %{}))

    # Schedule periodic cleanup of old events
    schedule_cleanup()

    state = %__MODULE__{
      agent_events: %{},
      circuit_states: %{},
      config: config
    }

    Logger.info("Trust.CircuitBreaker started")

    {:ok, state}
  end

  @impl true
  def handle_call({:check, agent_id}, _from, state) do
    result =
      case Map.get(state.circuit_states, agent_id, :closed) do
        :open -> {:error, :circuit_open}
        :half_open -> {:error, :circuit_open}
        :closed -> :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_state, agent_id}, _from, state) do
    circuit_state = Map.get(state.circuit_states, agent_id, :closed)
    {:reply, circuit_state, state}
  end

  @impl true
  def handle_call({:reset, agent_id}, _from, state) do
    new_states = Map.put(state.circuit_states, agent_id, :closed)
    new_events = Map.delete(state.agent_events, agent_id)

    # Unfreeze trust
    Manager.unfreeze_trust(agent_id)

    Logger.info("Circuit breaker reset for agent #{agent_id}")

    {:reply, :ok, %{state | circuit_states: new_states, agent_events: new_events}}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_cast({:record_event, agent_id, event_type, metadata}, state) do
    now = DateTime.utc_now()

    # Add event to history
    event = %{type: event_type, timestamp: now, metadata: metadata}
    agent_events = Map.get(state.agent_events, agent_id, [])
    updated_events = [event | agent_events]

    new_agent_events = Map.put(state.agent_events, agent_id, updated_events)
    state = %{state | agent_events: new_agent_events}

    # Check for circuit breaker triggers
    state = check_triggers(agent_id, state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove old events (older than max window)
    max_window = max_window_seconds(state.config)
    cutoff = DateTime.add(DateTime.utc_now(), -max_window, :second)

    new_agent_events =
      Map.new(state.agent_events, fn {agent_id, events} ->
        filtered =
          Enum.filter(events, fn event ->
            DateTime.compare(event.timestamp, cutoff) == :gt
          end)

        {agent_id, filtered}
      end)
      |> Enum.reject(fn {_agent_id, events} -> events == [] end)
      |> Map.new()

    schedule_cleanup()

    {:noreply, %{state | agent_events: new_agent_events}}
  end

  @impl true
  def handle_info({:half_open, agent_id}, state) do
    # Transition from open to half-open
    case Map.get(state.circuit_states, agent_id) do
      :open ->
        Logger.info("Circuit breaker entering half-open state for agent #{agent_id}")
        new_states = Map.put(state.circuit_states, agent_id, :half_open)
        {:noreply, %{state | circuit_states: new_states}}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:auto_close, agent_id}, state) do
    # Auto-close circuit after half-open period
    case Map.get(state.circuit_states, agent_id) do
      :half_open ->
        Logger.info("Circuit breaker auto-closing for agent #{agent_id}")
        new_states = Map.put(state.circuit_states, agent_id, :closed)
        Manager.unfreeze_trust(agent_id)
        {:noreply, %{state | circuit_states: new_states}}

      _ ->
        {:noreply, state}
    end
  end

  # Private functions

  defp check_triggers(agent_id, state) do
    events = Map.get(state.agent_events, agent_id, [])
    config = state.config
    now = DateTime.utc_now()

    cond do
      # Check rapid failures
      check_threshold(
        events,
        :action_failure,
        config.rapid_failure_threshold,
        config.rapid_failure_window_seconds,
        now
      ) ->
        trip_circuit(agent_id, :rapid_failures, state)

      # Check security violations
      check_threshold(
        events,
        :security_violation,
        config.security_violation_threshold,
        config.security_violation_window_seconds,
        now
      ) ->
        trip_circuit(agent_id, :security_violations, state)

      # Check rollback spike
      check_threshold(
        events,
        :rollback_executed,
        config.rollback_threshold,
        config.rollback_window_seconds,
        now
      ) ->
        handle_rollback_spike(agent_id, state)

      # Check test failure spike
      check_threshold(
        events,
        :test_failed,
        config.test_failure_threshold,
        config.test_failure_window_seconds,
        now
      ) ->
        trip_circuit(agent_id, :test_failures, state)

      true ->
        state
    end
  end

  defp check_threshold(events, event_type, threshold, window_seconds, now) do
    cutoff = DateTime.add(now, -window_seconds, :second)

    count =
      Enum.count(events, fn event ->
        event.type == event_type and DateTime.compare(event.timestamp, cutoff) == :gt
      end)

    count >= threshold
  end

  defp trip_circuit(agent_id, reason, state) do
    Logger.warning("Circuit breaker tripped for agent #{agent_id}: #{reason}",
      agent_id: agent_id,
      reason: reason
    )

    # Freeze trust
    Manager.freeze_trust(agent_id, reason)

    # Emit signal for real-time observability
    emit_circuit_breaker_triggered(agent_id, reason)

    # Schedule half-open transition
    Process.send_after(
      self(),
      {:half_open, agent_id},
      state.config.freeze_duration_seconds * 1000
    )

    new_states = Map.put(state.circuit_states, agent_id, :open)
    %{state | circuit_states: new_states}
  end

  defp handle_rollback_spike(agent_id, state) do
    # Don't freeze, just log warning for rollback spikes
    # The Manager handles tier demotion
    Logger.warning("Rollback spike detected for agent #{agent_id}",
      agent_id: agent_id
    )

    state
  end

  defp max_window_seconds(config) do
    Enum.max([
      config.rapid_failure_window_seconds,
      config.security_violation_window_seconds,
      config.rollback_window_seconds,
      config.test_failure_window_seconds
    ])
  end

  defp schedule_cleanup do
    # Clean up every 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end

  # Signal emission helper

  defp emit_circuit_breaker_triggered(agent_id, reason) do
    Signals.emit(:trust, :circuit_breaker_triggered, %{
      agent_id: agent_id,
      reason: reason
    })
  end
end
