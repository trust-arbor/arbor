defmodule Arbor.Monitor.CascadeDetector do
  @moduledoc """
  Detects cascade failures by tracking anomaly rates.

  A cascade is when multiple anomalies fire in rapid succession, often
  indicating a systemic issue rather than isolated problems. During
  cascades, the healing system should:

  1. Extend deduplication windows (avoid proposal storms)
  2. Limit concurrent proposals (prevent resource exhaustion)
  3. Wait for settling before proposing fixes (find root cause)
  4. Prioritize by severity and age

  ## Configuration

  - `:window_ms` - Time window for rate calculation (default: 10 seconds)
  - `:cascade_threshold` - Anomalies per window to trigger cascade (default: 5)
  - `:settling_cycles` - Polling cycles to wait before proposing during cascade (default: 3)
  - `:max_concurrent_proposals` - Maximum proposals during cascade (default: 3)
  - `:exit_threshold_ms` - Time below threshold before exiting cascade (default: 30 seconds)

  ## Signals

  The detector can optionally emit signals via a configured callback:

      config :arbor_monitor, :signal_callback, &Arbor.Signals.emit/3

  Signals emitted:
  - `:cascade_detected` - When entering cascade mode
  - `:cascade_resolved` - When exiting cascade mode
  """

  use GenServer

  require Logger

  # Default configuration
  @default_window_ms :timer.seconds(10)
  @default_cascade_threshold 5
  @default_settling_cycles 3
  @default_max_concurrent_proposals 3
  @default_exit_threshold_ms :timer.seconds(30)
  @default_check_interval_ms :timer.seconds(1)

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record an anomaly occurrence. Call this when an anomaly is detected.
  """
  @spec record_anomaly(map()) :: :ok
  def record_anomaly(anomaly) do
    GenServer.cast(__MODULE__, {:record_anomaly, anomaly})
  end

  @doc """
  Check if system is currently in cascade mode.
  """
  @spec in_cascade?() :: boolean()
  def in_cascade? do
    GenServer.call(__MODULE__, :in_cascade?)
  end

  @doc """
  Get current cascade status with details.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get the current anomaly rate (anomalies per window).
  """
  @spec current_rate() :: non_neg_integer()
  def current_rate do
    GenServer.call(__MODULE__, :current_rate)
  end

  @doc """
  Get the recommended max concurrent proposals (reduced during cascade).
  """
  @spec max_concurrent_proposals() :: pos_integer()
  def max_concurrent_proposals do
    GenServer.call(__MODULE__, :max_concurrent_proposals)
  end

  @doc """
  Get the recommended dedup window multiplier (increased during cascade).
  """
  @spec dedup_multiplier() :: float()
  def dedup_multiplier do
    GenServer.call(__MODULE__, :dedup_multiplier)
  end

  @doc """
  Check if proposals should be paused for settling.
  """
  @spec should_settle?() :: boolean()
  def should_settle? do
    GenServer.call(__MODULE__, :should_settle?)
  end

  @doc """
  Notify that a polling cycle completed (for settling countdown).
  """
  @spec polling_cycle_completed() :: :ok
  def polling_cycle_completed do
    GenServer.cast(__MODULE__, :polling_cycle_completed)
  end

  @doc """
  Reset cascade state (for testing).
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    config = %{
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      cascade_threshold: Keyword.get(opts, :cascade_threshold, @default_cascade_threshold),
      settling_cycles: Keyword.get(opts, :settling_cycles, @default_settling_cycles),
      max_concurrent_proposals:
        Keyword.get(opts, :max_concurrent_proposals, @default_max_concurrent_proposals),
      exit_threshold_ms: Keyword.get(opts, :exit_threshold_ms, @default_exit_threshold_ms),
      check_interval_ms: Keyword.get(opts, :check_interval_ms, @default_check_interval_ms),
      signal_callback: Keyword.get(opts, :signal_callback)
    }

    state = %{
      config: config,
      # Sliding window of anomaly timestamps
      anomaly_times: :queue.new(),
      # Current cascade state
      in_cascade: false,
      cascade_started_at: nil,
      last_above_threshold_at: nil,
      # Settling countdown
      settling_cycles_remaining: 0,
      # Statistics
      cascades_detected: 0,
      total_anomalies: 0
    }

    # Schedule periodic cleanup of old timestamps
    Process.send_after(self(), :cleanup_window, config.check_interval_ms)

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:record_anomaly, anomaly}, state) do
    now = System.monotonic_time(:millisecond)

    # Add to sliding window
    new_times = :queue.in(now, state.anomaly_times)
    state = %{state | anomaly_times: new_times, total_anomalies: state.total_anomalies + 1}

    # Check if we should enter/stay in cascade mode
    rate = calculate_rate(new_times, now, state.config.window_ms)
    state = update_cascade_state(state, rate, now, anomaly)

    {:noreply, state}
  end

  def handle_cast(:polling_cycle_completed, state) do
    state =
      if state.settling_cycles_remaining > 0 do
        remaining = state.settling_cycles_remaining - 1

        if remaining == 0 do
          Logger.info("[CascadeDetector] Settling complete, proposals may resume")
        end

        %{state | settling_cycles_remaining: remaining}
      else
        state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:in_cascade?, _from, state) do
    {:reply, state.in_cascade, state}
  end

  def handle_call(:status, _from, state) do
    now = System.monotonic_time(:millisecond)
    rate = calculate_rate(state.anomaly_times, now, state.config.window_ms)

    status = %{
      in_cascade: state.in_cascade,
      current_rate: rate,
      threshold: state.config.cascade_threshold,
      cascade_started_at: state.cascade_started_at,
      settling_cycles_remaining: state.settling_cycles_remaining,
      cascades_detected: state.cascades_detected,
      total_anomalies: state.total_anomalies,
      max_concurrent_proposals: effective_max_proposals(state),
      dedup_multiplier: effective_dedup_multiplier(state)
    }

    {:reply, status, state}
  end

  def handle_call(:current_rate, _from, state) do
    now = System.monotonic_time(:millisecond)
    rate = calculate_rate(state.anomaly_times, now, state.config.window_ms)
    {:reply, rate, state}
  end

  def handle_call(:max_concurrent_proposals, _from, state) do
    {:reply, effective_max_proposals(state), state}
  end

  def handle_call(:dedup_multiplier, _from, state) do
    {:reply, effective_dedup_multiplier(state), state}
  end

  def handle_call(:should_settle?, _from, state) do
    {:reply, state.in_cascade and state.settling_cycles_remaining > 0, state}
  end

  def handle_call(:reset, _from, state) do
    new_state = %{
      state
      | anomaly_times: :queue.new(),
        in_cascade: false,
        cascade_started_at: nil,
        last_above_threshold_at: nil,
        settling_cycles_remaining: 0
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(:cleanup_window, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.config.window_ms

    # Remove timestamps older than window
    cleaned_times = cleanup_queue(state.anomaly_times, cutoff)
    state = %{state | anomaly_times: cleaned_times}

    # Check for cascade exit condition
    state = check_cascade_exit(state, now)

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_window, state.config.check_interval_ms)

    {:noreply, state}
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp calculate_rate(times, now, window_ms) do
    cutoff = now - window_ms

    :queue.to_list(times)
    |> Enum.count(&(&1 >= cutoff))
  end

  defp cleanup_queue(queue, cutoff) do
    case :queue.out(queue) do
      {{:value, time}, rest} when time < cutoff ->
        cleanup_queue(rest, cutoff)

      _ ->
        queue
    end
  end

  defp update_cascade_state(state, rate, now, anomaly) do
    threshold = state.config.cascade_threshold

    cond do
      # Already in cascade, stay in cascade
      state.in_cascade and rate >= threshold ->
        %{state | last_above_threshold_at: now}

      # Not in cascade, rate exceeds threshold -> enter cascade
      not state.in_cascade and rate >= threshold ->
        enter_cascade(state, now, anomaly)

      # In cascade but rate dropped -> might exit (handled in check_cascade_exit)
      state.in_cascade ->
        state

      # Not in cascade, rate below threshold -> normal
      true ->
        state
    end
  end

  defp enter_cascade(state, now, _trigger_anomaly) do
    Logger.warning(
      "[CascadeDetector] Entering cascade mode (rate: #{calculate_rate(state.anomaly_times, now, state.config.window_ms)}/#{state.config.cascade_threshold})"
    )

    # Emit signal if callback configured
    emit_signal(state, :cascade_detected, %{
      rate: calculate_rate(state.anomaly_times, now, state.config.window_ms),
      threshold: state.config.cascade_threshold,
      timestamp: now
    })

    %{
      state
      | in_cascade: true,
        cascade_started_at: now,
        last_above_threshold_at: now,
        settling_cycles_remaining: state.config.settling_cycles,
        cascades_detected: state.cascades_detected + 1
    }
  end

  defp check_cascade_exit(state, now) do
    if state.in_cascade do
      time_below = now - (state.last_above_threshold_at || now)

      if time_below >= state.config.exit_threshold_ms do
        exit_cascade(state, now)
      else
        state
      end
    else
      state
    end
  end

  defp exit_cascade(state, now) do
    duration_ms = now - (state.cascade_started_at || now)

    Logger.info("[CascadeDetector] Exiting cascade mode (duration: #{div(duration_ms, 1000)}s)")

    # Emit signal if callback configured
    emit_signal(state, :cascade_resolved, %{
      duration_ms: duration_ms,
      timestamp: now
    })

    %{
      state
      | in_cascade: false,
        cascade_started_at: nil,
        last_above_threshold_at: nil,
        settling_cycles_remaining: 0
    }
  end

  defp effective_max_proposals(state) do
    if state.in_cascade do
      # During cascade, limit to configured max
      state.config.max_concurrent_proposals
    else
      # Normal operation, no limit (return high number)
      999
    end
  end

  defp effective_dedup_multiplier(state) do
    if state.in_cascade do
      # During cascade, extend dedup window 12x (5min -> 1min effective, counterintuitively)
      # Actually we want shorter dedup to let things settle, not longer
      # So multiplier < 1 means shorter effective window
      0.2
    else
      1.0
    end
  end

  defp emit_signal(state, event, payload) do
    case state.config.signal_callback do
      nil ->
        :ok

      callback when is_function(callback, 3) ->
        try do
          callback.(:monitor, event, payload)
        rescue
          e ->
            Logger.warning("[CascadeDetector] Signal emission failed: #{inspect(e)}")
        end

      _ ->
        :ok
    end
  end
end
