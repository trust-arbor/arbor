defmodule Arbor.Agent.CircuitBreaker do
  @moduledoc """
  Circuit breaker for self-healing remediation attempts.

  Prevents repeated failed fixes on the same anomaly pattern. After a threshold
  of failures, the circuit opens and blocks further attempts until a cooldown
  period expires.

  ## States

  - `:closed` — Normal operation, attempts allowed
  - `:open` — Too many failures, attempts blocked until cooldown
  - `:half_open` — Cooldown expired, one test attempt allowed

  ## Usage

      # Check if we can attempt a fix
      case CircuitBreaker.can_attempt?(breaker, key) do
        true -> proceed_with_fix()
        false -> skip_or_escalate()
      end

      # Record outcome
      CircuitBreaker.record_success(breaker, key)
      CircuitBreaker.record_failure(breaker, key)
  """

  use GenServer

  require Logger

  @default_failure_threshold 3
  @default_cooldown_ms 60_000
  @default_half_open_max_attempts 1

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a circuit breaker.

  ## Options

    * `:name` — Process name (default: `{__MODULE__, :default}`)
    * `:failure_threshold` — Failures before opening (default: 3)
    * `:cooldown_ms` — Time before half-open (default: 60_000)
    * `:half_open_max_attempts` — Test attempts in half-open (default: 1)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, {:global, {__MODULE__, :default}})
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check if an attempt is allowed for the given key.

  Returns `true` if the circuit is closed or half-open (test allowed).
  Returns `false` if the circuit is open.
  """
  @spec can_attempt?(GenServer.server(), term()) :: boolean()
  def can_attempt?(server \\ default_server(), key) do
    GenServer.call(server, {:can_attempt?, key})
  end

  @doc """
  Record a successful remediation for the given key.

  Resets the failure count and closes the circuit.
  """
  @spec record_success(GenServer.server(), term()) :: :ok
  def record_success(server \\ default_server(), key) do
    GenServer.cast(server, {:record_success, key})
  end

  @doc """
  Record a failed remediation for the given key.

  Increments the failure count. Opens the circuit if threshold is reached.
  """
  @spec record_failure(GenServer.server(), term()) :: :ok
  def record_failure(server \\ default_server(), key) do
    GenServer.cast(server, {:record_failure, key})
  end

  @doc """
  Get the current state of a circuit for a given key.

  Returns `{state, failures, last_failure_time}`.
  """
  @spec get_state(GenServer.server(), term()) :: {atom(), non_neg_integer(), DateTime.t() | nil}
  def get_state(server \\ default_server(), key) do
    GenServer.call(server, {:get_state, key})
  end

  @doc """
  Reset a circuit to closed state.
  """
  @spec reset(GenServer.server(), term()) :: :ok
  def reset(server \\ default_server(), key) do
    GenServer.cast(server, {:reset, key})
  end

  @doc """
  Reset all circuits.
  """
  @spec reset_all(GenServer.server()) :: :ok
  def reset_all(server \\ default_server()) do
    GenServer.cast(server, :reset_all)
  end

  @doc """
  Get statistics about all circuits.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ default_server()) do
    GenServer.call(server, :stats)
  end

  defp default_server, do: {:global, {__MODULE__, :default}}

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %{
      circuits: %{},
      config: %{
        failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
        cooldown_ms: Keyword.get(opts, :cooldown_ms, @default_cooldown_ms),
        half_open_max_attempts: Keyword.get(opts, :half_open_max_attempts, @default_half_open_max_attempts)
      },
      stats: %{
        total_attempts: 0,
        blocked_attempts: 0,
        successful_attempts: 0,
        failed_attempts: 0
      }
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:can_attempt?, key}, _from, state) do
    {allowed, new_state} = check_and_update(state, key)
    {:reply, allowed, new_state}
  end

  @impl true
  def handle_call({:get_state, key}, _from, state) do
    circuit = Map.get(state.circuits, key, default_circuit())
    {:reply, {circuit.state, circuit.failures, circuit.last_failure_at}, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    circuit_summary = %{
      total_circuits: map_size(state.circuits),
      open_circuits: count_by_state(state.circuits, :open),
      closed_circuits: count_by_state(state.circuits, :closed),
      half_open_circuits: count_by_state(state.circuits, :half_open)
    }

    {:reply, Map.merge(state.stats, circuit_summary), state}
  end

  @impl true
  def handle_cast({:record_success, key}, state) do
    circuit = Map.get(state.circuits, key, default_circuit())

    updated_circuit = %{circuit | state: :closed, failures: 0, half_open_attempts: 0}

    new_state = %{
      state
      | circuits: Map.put(state.circuits, key, updated_circuit),
        stats: update_stat(state.stats, :successful_attempts)
    }

    Logger.debug("[CircuitBreaker] Success recorded for #{inspect(key)}, circuit closed")

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_failure, key}, state) do
    circuit = Map.get(state.circuits, key, default_circuit())
    config = state.config

    new_failures = circuit.failures + 1

    updated_circuit =
      if new_failures >= config.failure_threshold do
        Logger.warning("[CircuitBreaker] Circuit opened for #{inspect(key)} after #{new_failures} failures")

        %{
          circuit
          | state: :open,
            failures: new_failures,
            last_failure_at: DateTime.utc_now(),
            opened_at: DateTime.utc_now()
        }
      else
        %{circuit | failures: new_failures, last_failure_at: DateTime.utc_now()}
      end

    new_state = %{
      state
      | circuits: Map.put(state.circuits, key, updated_circuit),
        stats: update_stat(state.stats, :failed_attempts)
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:reset, key}, state) do
    new_circuits = Map.delete(state.circuits, key)
    {:noreply, %{state | circuits: new_circuits}}
  end

  @impl true
  def handle_cast(:reset_all, state) do
    {:noreply, %{state | circuits: %{}}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp check_and_update(state, key) do
    circuit = Map.get(state.circuits, key, default_circuit())
    config = state.config
    now = DateTime.utc_now()

    {allowed, updated_circuit} =
      case circuit.state do
        :closed ->
          {true, circuit}

        :open ->
          if cooldown_expired?(circuit, config, now) do
            Logger.debug("[CircuitBreaker] Cooldown expired for #{inspect(key)}, entering half-open")
            {true, %{circuit | state: :half_open, half_open_attempts: 1}}
          else
            {false, circuit}
          end

        :half_open ->
          if circuit.half_open_attempts < config.half_open_max_attempts do
            {true, %{circuit | half_open_attempts: circuit.half_open_attempts + 1}}
          else
            {false, circuit}
          end
      end

    new_stats =
      if allowed do
        update_stat(state.stats, :total_attempts)
      else
        state.stats
        |> update_stat(:total_attempts)
        |> update_stat(:blocked_attempts)
      end

    new_state = %{
      state
      | circuits: Map.put(state.circuits, key, updated_circuit),
        stats: new_stats
    }

    {allowed, new_state}
  end

  defp cooldown_expired?(circuit, config, now) do
    case circuit.opened_at do
      nil ->
        true

      opened_at ->
        diff_ms = DateTime.diff(now, opened_at, :millisecond)
        diff_ms >= config.cooldown_ms
    end
  end

  defp default_circuit do
    %{
      state: :closed,
      failures: 0,
      last_failure_at: nil,
      opened_at: nil,
      half_open_attempts: 0
    }
  end

  defp count_by_state(circuits, target_state) do
    Enum.count(circuits, fn {_key, circuit} -> circuit.state == target_state end)
  end

  defp update_stat(stats, key) do
    Map.update(stats, key, 1, &(&1 + 1))
  end
end
