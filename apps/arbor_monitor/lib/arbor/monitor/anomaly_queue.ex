defmodule Arbor.Monitor.AnomalyQueue do
  @moduledoc """
  ETS-backed anomaly queue with fingerprint deduplication and lease-based claiming.

  This GenServer coordinates self-healing by:
  1. Receiving anomalies from Monitor and deduplicating by fingerprint
  2. Providing lease-based work claiming for DebugAgents
  3. Tracking outcomes and managing verification state
  4. Maintaining a suppression list for anomalies that exceeded retry limits

  ## ETS Tables

  - `:arbor_healing_queue` - Main queue: `{anomaly_id, queued_anomaly}`
  - `:arbor_healing_fingerprints` - Dedup window: `{fingerprint_hash, anomaly_id, expires_at}`
  - `:arbor_healing_suppressed` - Suppression list: `{family_hash, reason, expires_at}`

  ## Configuration

  - `:dedup_window_ms` - Time window for deduplication (default: 5 minutes)
  - `:lease_timeout_ms` - Lease expiration time (default: 60 seconds)
  - `:check_interval_ms` - How often to check for expired leases (default: 15 seconds)
  - `:max_attempts` - Maximum retry attempts before escalation (default: 3)
  - `:suppression_window_ms` - How long to suppress escalated fingerprints (default: 30 minutes)
  """

  use GenServer

  require Logger

  alias Arbor.Monitor.{CascadeDetector, Fingerprint}

  # ETS table names
  @queue_table :arbor_healing_queue
  @fingerprint_table :arbor_healing_fingerprints
  @suppressed_table :arbor_healing_suppressed

  # Default configuration
  @default_dedup_window_ms :timer.minutes(5)
  @default_lease_timeout_ms :timer.seconds(60)
  @default_check_interval_ms :timer.seconds(15)
  @default_max_attempts 3
  @default_suppression_window_ms :timer.minutes(30)

  # ============================================================================
  # Client API (implements AnomalyQueue behaviour)
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue an anomaly for processing.

  Returns `{:ok, :enqueued}` if this is a new anomaly, or
  `{:ok, :deduplicated}` if an anomaly with the same fingerprint
  is already in the queue (extends its window).
  """
  @spec enqueue(map()) :: {:ok, :enqueued | :deduplicated} | {:error, term()}
  def enqueue(anomaly) do
    # Notify cascade detector if running
    notify_cascade_detector(anomaly)
    GenServer.call(__MODULE__, {:enqueue, anomaly})
  end

  @doc """
  Claim the next available anomaly for processing.

  Returns a lease token and the anomaly. The agent must call
  `complete/2` or `release/1` before the lease expires.
  """
  @spec claim_next(String.t()) :: {:ok, {tuple(), map()}} | {:error, :empty | :settling}
  def claim_next(agent_id) do
    # Check if we should wait for settling during cascade
    if should_settle?() do
      {:error, :settling}
    else
      GenServer.call(__MODULE__, {:claim_next, agent_id})
    end
  end

  @doc """
  Release a claimed anomaly without completing it.
  """
  @spec release(tuple()) :: :ok | {:error, :invalid_lease}
  def release(lease_token) do
    GenServer.call(__MODULE__, {:release, lease_token})
  end

  @doc """
  Mark an anomaly as complete with an outcome.
  """
  @spec complete(tuple(), atom() | tuple()) :: :ok | {:error, term()}
  def complete(lease_token, outcome) do
    GenServer.call(__MODULE__, {:complete, lease_token, outcome})
  end

  @doc """
  List all pending anomalies.
  """
  @spec list_pending() :: [map()]
  def list_pending do
    list_by_state(:pending)
  end

  @doc """
  List all anomalies in a given state.
  """
  @spec list_by_state(atom()) :: [map()]
  def list_by_state(state) do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@queue_table)
    |> Enum.map(fn {_id, queued} -> queued end)
    |> Enum.filter(fn queued ->
      queued.state == state or
        (state == :pending and queued.state == :claimed and
           queued.lease_expires != nil and queued.lease_expires < now)
    end)
    |> Enum.sort_by(& &1.enqueued_at)
  end

  @doc """
  Get queue statistics.
  """
  @spec stats() :: map()
  def stats do
    now = System.monotonic_time(:millisecond)
    day_ago = now - :timer.hours(24)

    all = :ets.tab2list(@queue_table) |> Enum.map(fn {_, q} -> q end)

    %{
      pending: Enum.count(all, &(&1.state == :pending)),
      claimed: Enum.count(all, &(&1.state == :claimed and &1.lease_expires > now)),
      verifying: Enum.count(all, &(&1.state == :verifying)),
      resolved_24h: Enum.count(all, &(&1.state == :resolved and &1.enqueued_at > day_ago)),
      escalated_24h: Enum.count(all, &(&1.state == :escalated and &1.enqueued_at > day_ago))
    }
  end

  @doc """
  Check if a fingerprint is currently suppressed.
  """
  @spec suppressed?(Fingerprint.t()) :: boolean()
  def suppressed?(%Fingerprint{} = fingerprint) do
    now = System.monotonic_time(:millisecond)
    family = Fingerprint.family_hash(fingerprint)

    case :ets.lookup(@suppressed_table, family) do
      [{^family, _reason, expires}] when expires > now -> true
      _ -> false
    end
  end

  @doc """
  Manually suppress a fingerprint.
  """
  @spec suppress(Fingerprint.t(), String.t(), pos_integer()) :: :ok
  def suppress(%Fingerprint{} = fingerprint, reason, ttl_minutes) do
    GenServer.call(__MODULE__, {:suppress, fingerprint, reason, ttl_minutes})
  end

  # Additional helper functions (not part of behaviour)

  @doc """
  Get the current queue size (pending + claimed).
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@queue_table, :size)
  end

  @doc """
  Clear all data (for testing).
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    # Create ETS tables (or recover if they exist)
    create_or_recover_tables()

    config = %{
      dedup_window_ms: get_config(opts, :dedup_window_ms, @default_dedup_window_ms),
      lease_timeout_ms: get_config(opts, :lease_timeout_ms, @default_lease_timeout_ms),
      check_interval_ms: get_config(opts, :check_interval_ms, @default_check_interval_ms),
      max_attempts: get_config(opts, :max_attempts, @default_max_attempts),
      suppression_window_ms: get_config(opts, :suppression_window_ms, @default_suppression_window_ms)
    }

    # Schedule periodic lease checking
    Process.send_after(self(), :check_leases, config.check_interval_ms)

    {:ok, config}
  end

  @impl GenServer
  def handle_call({:enqueue, anomaly}, _from, config) do
    result = do_enqueue(anomaly, config)
    {:reply, result, config}
  end

  def handle_call({:claim_next, agent_id}, _from, config) do
    result = do_claim_next(agent_id, config)
    {:reply, result, config}
  end

  def handle_call({:release, lease_token}, _from, config) do
    result = do_release(lease_token)
    {:reply, result, config}
  end

  def handle_call({:complete, lease_token, outcome}, _from, config) do
    result = do_complete(lease_token, outcome, config)
    {:reply, result, config}
  end

  def handle_call({:suppress, fingerprint, reason, ttl_minutes}, _from, config) do
    now = System.monotonic_time(:millisecond)
    expires = now + :timer.minutes(ttl_minutes)
    family = Fingerprint.family_hash(fingerprint)
    :ets.insert(@suppressed_table, {family, reason, expires})
    {:reply, :ok, config}
  end

  def handle_call(:clear_all, _from, config) do
    :ets.delete_all_objects(@queue_table)
    :ets.delete_all_objects(@fingerprint_table)
    :ets.delete_all_objects(@suppressed_table)
    {:reply, :ok, config}
  end

  @impl GenServer
  def handle_info(:check_leases, config) do
    expire_stale_leases()
    cleanup_expired_fingerprints()
    cleanup_expired_suppressions()

    Process.send_after(self(), :check_leases, config.check_interval_ms)
    {:noreply, config}
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp create_or_recover_tables do
    # Queue table - keyed by anomaly_id
    if :ets.whereis(@queue_table) == :undefined do
      :ets.new(@queue_table, [:named_table, :set, :public, read_concurrency: true])
    end

    # Fingerprint dedup table - keyed by fingerprint hash
    if :ets.whereis(@fingerprint_table) == :undefined do
      :ets.new(@fingerprint_table, [:named_table, :set, :public, read_concurrency: true])
    end

    # Suppression table - keyed by family hash
    if :ets.whereis(@suppressed_table) == :undefined do
      :ets.new(@suppressed_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp do_enqueue(anomaly, config) do
    case Fingerprint.from_anomaly(anomaly) do
      {:ok, fingerprint} ->
        if suppressed?(fingerprint) do
          Logger.debug("[AnomalyQueue] Anomaly suppressed: #{Fingerprint.to_string(fingerprint)}")
          {:ok, :deduplicated}
        else
          enqueue_with_fingerprint(anomaly, fingerprint, config)
        end

      {:error, reason} ->
        {:error, {:invalid_anomaly, reason}}
    end
  end

  defp enqueue_with_fingerprint(anomaly, fingerprint, config) do
    now = System.monotonic_time(:millisecond)
    fp_hash = Fingerprint.hash(fingerprint)
    # Adjust dedup window during cascade mode
    effective_window = effective_dedup_window(config.dedup_window_ms)
    window_expires = now + effective_window

    case :ets.lookup(@fingerprint_table, fp_hash) do
      [{^fp_hash, existing_id, _old_expires}] ->
        # Extend the dedup window
        :ets.insert(@fingerprint_table, {fp_hash, existing_id, window_expires})
        Logger.debug("[AnomalyQueue] Deduplicated: #{Fingerprint.to_string(fingerprint)}")
        {:ok, :deduplicated}

      [] ->
        # New anomaly - create queue entry
        anomaly_id = Map.get(anomaly, :id) || System.unique_integer([:positive])

        queued = %{
          id: anomaly_id,
          anomaly: anomaly,
          fingerprint: fingerprint,
          state: :pending,
          enqueued_at: now,
          claimed_by: nil,
          lease_expires: nil,
          attempt_count: 0
        }

        :ets.insert(@queue_table, {anomaly_id, queued})
        :ets.insert(@fingerprint_table, {fp_hash, anomaly_id, window_expires})

        Logger.info(
          "[AnomalyQueue] Enqueued: #{Fingerprint.to_string(fingerprint)} (id=#{anomaly_id})"
        )

        {:ok, :enqueued}
    end
  end

  defp do_claim_next(agent_id, config) do
    now = System.monotonic_time(:millisecond)

    # Find oldest pending anomaly
    pending =
      :ets.tab2list(@queue_table)
      |> Enum.map(fn {_id, q} -> q end)
      |> Enum.filter(&(&1.state == :pending))
      |> Enum.sort_by(& &1.enqueued_at)

    case pending do
      [] ->
        {:error, :empty}

      [oldest | _] ->
        lease_expires = now + config.lease_timeout_ms
        lease_token = {oldest.id, agent_id, lease_expires}

        updated = %{
          oldest
          | state: :claimed,
            claimed_by: agent_id,
            lease_expires: lease_expires,
            attempt_count: oldest.attempt_count + 1
        }

        :ets.insert(@queue_table, {oldest.id, updated})

        Logger.info(
          "[AnomalyQueue] Claimed by #{agent_id}: #{Fingerprint.to_string(oldest.fingerprint)} (attempt #{updated.attempt_count})"
        )

        {:ok, {lease_token, oldest.anomaly}}
    end
  end

  defp do_release({anomaly_id, agent_id, _expires}) do
    case :ets.lookup(@queue_table, anomaly_id) do
      [{^anomaly_id, queued}] when queued.claimed_by == agent_id ->
        updated = %{queued | state: :pending, claimed_by: nil, lease_expires: nil}
        :ets.insert(@queue_table, {anomaly_id, updated})
        Logger.info("[AnomalyQueue] Released: #{Fingerprint.to_string(queued.fingerprint)}")
        :ok

      _ ->
        {:error, :invalid_lease}
    end
  end

  defp do_complete({anomaly_id, agent_id, _expires}, outcome, config) do
    case :ets.lookup(@queue_table, anomaly_id) do
      [{^anomaly_id, queued}] when queued.claimed_by == agent_id ->
        handle_outcome(anomaly_id, queued, outcome, config)

      _ ->
        {:error, :invalid_lease}
    end
  end

  defp handle_outcome(anomaly_id, queued, :fixed, _config) do
    updated = %{queued | state: :verifying, claimed_by: nil, lease_expires: nil}
    :ets.insert(@queue_table, {anomaly_id, updated})
    Logger.info("[AnomalyQueue] Fixed, verifying: #{Fingerprint.to_string(queued.fingerprint)}")
    :ok
  end

  defp handle_outcome(anomaly_id, queued, :escalated, config) do
    updated = %{queued | state: :escalated, claimed_by: nil, lease_expires: nil}
    :ets.insert(@queue_table, {anomaly_id, updated})

    # Add to suppression list
    family = Fingerprint.family_hash(queued.fingerprint)
    now = System.monotonic_time(:millisecond)
    expires = now + config.suppression_window_ms
    :ets.insert(@suppressed_table, {family, "Exceeded retry limit", expires})

    Logger.warning("[AnomalyQueue] Escalated: #{Fingerprint.to_string(queued.fingerprint)}")
    :ok
  end

  defp handle_outcome(anomaly_id, queued, {:retry, reason}, config) do
    if queued.attempt_count >= config.max_attempts do
      handle_outcome(anomaly_id, queued, :escalated, config)
    else
      updated = %{queued | state: :pending, claimed_by: nil, lease_expires: nil}
      :ets.insert(@queue_table, {anomaly_id, updated})

      Logger.info(
        "[AnomalyQueue] Retry queued: #{Fingerprint.to_string(queued.fingerprint)} (#{reason})"
      )

      :ok
    end
  end

  defp handle_outcome(anomaly_id, queued, {:ineffective, reason}, _config) do
    updated = %{queued | state: :ineffective, claimed_by: nil, lease_expires: nil}
    :ets.insert(@queue_table, {anomaly_id, updated})

    Logger.warning(
      "[AnomalyQueue] Ineffective fix: #{Fingerprint.to_string(queued.fingerprint)} (#{reason})"
    )

    :ok
  end

  # Resolved = fix was successful and verified
  defp handle_outcome(anomaly_id, queued, :resolved, _config) do
    :ets.delete(@queue_table, anomaly_id)
    Logger.info("[AnomalyQueue] Resolved: #{Fingerprint.to_string(queued.fingerprint)}")
    :ok
  end

  # Failed = diagnosis or proposal failed, retry if attempts remain
  defp handle_outcome(anomaly_id, queued, :failed, config) do
    handle_outcome(anomaly_id, queued, {:retry, "diagnosis failed"}, config)
  end

  # Rejected = proposal was rejected by council, retry if attempts remain
  defp handle_outcome(anomaly_id, queued, :rejected, config) do
    handle_outcome(anomaly_id, queued, {:retry, "proposal rejected"}, config)
  end

  defp expire_stale_leases do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@queue_table)
    |> Enum.each(fn {anomaly_id, queued} ->
      if queued.state == :claimed and queued.lease_expires != nil and queued.lease_expires < now do
        updated = %{queued | state: :pending, claimed_by: nil, lease_expires: nil}
        :ets.insert(@queue_table, {anomaly_id, updated})

        Logger.warning(
          "[AnomalyQueue] Lease expired, reclaiming: #{Fingerprint.to_string(queued.fingerprint)}"
        )
      end
    end)
  end

  defp cleanup_expired_fingerprints do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@fingerprint_table)
    |> Enum.each(fn {hash, _id, expires} ->
      if expires < now do
        :ets.delete(@fingerprint_table, hash)
      end
    end)
  end

  defp cleanup_expired_suppressions do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@suppressed_table)
    |> Enum.each(fn {family, _reason, expires} ->
      if expires < now do
        :ets.delete(@suppressed_table, family)
      end
    end)
  end

  # ============================================================================
  # Cascade Integration
  # ============================================================================

  defp notify_cascade_detector(anomaly) do
    if cascade_detector_running?() do
      CascadeDetector.record_anomaly(anomaly)
    end
  end

  defp should_settle? do
    if cascade_detector_running?() do
      CascadeDetector.should_settle?()
    else
      false
    end
  end

  defp cascade_detector_running? do
    Process.whereis(CascadeDetector) != nil
  end

  @doc """
  Get the effective dedup window, adjusted for cascade mode.
  """
  @spec effective_dedup_window(non_neg_integer()) :: non_neg_integer()
  def effective_dedup_window(base_window) do
    multiplier =
      if cascade_detector_running?() do
        CascadeDetector.dedup_multiplier()
      else
        1.0
      end

    round(base_window * multiplier)
  end

  @doc """
  Check if system is in cascade mode.
  """
  @spec in_cascade?() :: boolean()
  def in_cascade? do
    if cascade_detector_running?() do
      CascadeDetector.in_cascade?()
    else
      false
    end
  end

  # ============================================================================
  # Configuration Helpers
  # ============================================================================

  # Get config value: opts > Application env > default
  defp get_config(opts, key, default) do
    Keyword.get(opts, key) ||
      Application.get_env(:arbor_monitor, key) ||
      default
  end
end
