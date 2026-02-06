defmodule Arbor.Monitor.Verification do
  @moduledoc """
  Tracks fix verification during a soak period.

  After a fix is applied, the verification system:

  1. Marks the anomaly's fingerprint as `verifying`
  2. Sets a countdown of N polling cycles (default: 5)
  3. Each cycle, checks for fingerprint recurrence in new anomalies
  4. If same fingerprint reappears → mark `ineffective`, trigger retry
  5. If countdown reaches 0 without recurrence → mark `resolved`

  ## Signals

  The verifier can optionally emit signals via a configured callback:

  - `:healing_verified` - Fix held through soak period
  - `:healing_ineffective` - Fingerprint recurred during soak

  ## ETS Table

  - `:arbor_healing_verifying` - Active verifications: `{fingerprint_hash, record}`
  """

  use GenServer

  require Logger

  alias Arbor.Monitor.Fingerprint

  @verifying_table :arbor_healing_verifying

  # Default configuration
  @default_soak_cycles 5
  @default_check_interval_ms :timer.seconds(5)

  # ============================================================================
  # Types
  # ============================================================================

  @type verification_record :: %{
          fingerprint: Fingerprint.t(),
          fingerprint_hash: integer(),
          proposal_id: String.t(),
          started_at: integer(),
          cycles_remaining: non_neg_integer(),
          outcome: :verifying | :verified | :ineffective
        }

  @type verification_result :: %{
          status: :verified | :ineffective,
          fingerprint: Fingerprint.t(),
          proposal_id: String.t(),
          soak_cycles: non_neg_integer()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start verification for a fix. Call after a proposal is accepted.

  Returns {:ok, verification_id} if started, {:error, :already_verifying} if
  the same fingerprint is already being verified.
  """
  @spec start_verification(Fingerprint.t(), String.t()) ::
          {:ok, String.t()} | {:error, :already_verifying}
  def start_verification(%Fingerprint{} = fingerprint, proposal_id) do
    GenServer.call(__MODULE__, {:start_verification, fingerprint, proposal_id})
  end

  @doc """
  Check for recurrences in a batch of anomalies.

  Call this after each polling cycle with the newly detected anomalies.
  Returns list of verifications that failed due to recurrence.
  """
  @spec check_recurrences([map()]) :: [verification_result()]
  def check_recurrences(anomalies) when is_list(anomalies) do
    GenServer.call(__MODULE__, {:check_recurrences, anomalies})
  end

  @doc """
  Advance all verification countdowns by one cycle.

  Call this after each polling cycle. Returns list of verifications
  that completed successfully (countdown reached 0).
  """
  @spec tick() :: [verification_result()]
  def tick do
    GenServer.call(__MODULE__, :tick)
  end

  @doc """
  Get verification record for a fingerprint.
  """
  @spec get_verification(Fingerprint.t()) :: verification_record() | nil
  def get_verification(%Fingerprint{} = fingerprint) do
    fp_hash = Fingerprint.hash(fingerprint)

    case :ets.lookup(@verifying_table, fp_hash) do
      [{^fp_hash, record}] -> record
      [] -> nil
    end
  end

  @doc """
  List all active verifications.
  """
  @spec list_verifying() :: [verification_record()]
  def list_verifying do
    :ets.tab2list(@verifying_table)
    |> Enum.map(fn {_hash, record} -> record end)
    |> Enum.filter(&(&1.outcome == :verifying))
  end

  @doc """
  Cancel verification for a fingerprint.
  """
  @spec cancel_verification(Fingerprint.t()) :: :ok
  def cancel_verification(%Fingerprint{} = fingerprint) do
    GenServer.call(__MODULE__, {:cancel_verification, fingerprint})
  end

  @doc """
  Get verification statistics.
  """
  @spec stats() :: map()
  def stats do
    all = :ets.tab2list(@verifying_table) |> Enum.map(fn {_h, r} -> r end)

    %{
      active: Enum.count(all, &(&1.outcome == :verifying)),
      verified: Enum.count(all, &(&1.outcome == :verified)),
      ineffective: Enum.count(all, &(&1.outcome == :ineffective)),
      total: length(all)
    }
  end

  @doc """
  Clear all verification data (for testing).
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
    # Create ETS table if it doesn't exist
    if :ets.whereis(@verifying_table) == :undefined do
      :ets.new(@verifying_table, [:named_table, :set, :public, read_concurrency: true])
    end

    config = %{
      soak_cycles: Keyword.get(opts, :soak_cycles, @default_soak_cycles),
      check_interval_ms: Keyword.get(opts, :check_interval_ms, @default_check_interval_ms),
      signal_callback: Keyword.get(opts, :signal_callback)
    }

    {:ok, config}
  end

  @impl GenServer
  def handle_call({:start_verification, fingerprint, proposal_id}, _from, config) do
    fp_hash = Fingerprint.hash(fingerprint)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@verifying_table, fp_hash) do
      [{^fp_hash, %{outcome: :verifying}}] ->
        {:reply, {:error, :already_verifying}, config}

      _ ->
        record = %{
          fingerprint: fingerprint,
          fingerprint_hash: fp_hash,
          proposal_id: proposal_id,
          started_at: now,
          cycles_remaining: config.soak_cycles,
          outcome: :verifying
        }

        :ets.insert(@verifying_table, {fp_hash, record})

        Logger.info(
          "[Verification] Started soak period for #{Fingerprint.to_string(fingerprint)} " <>
            "(#{config.soak_cycles} cycles)"
        )

        verification_id = "ver_#{fp_hash}_#{now}"
        {:reply, {:ok, verification_id}, config}
    end
  end

  def handle_call({:check_recurrences, anomalies}, _from, config) do
    # Build fingerprints for all incoming anomalies
    incoming_hashes =
      anomalies
      |> Enum.map(&fingerprint_from_anomaly/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, fp} -> Fingerprint.hash(fp) end)
      |> MapSet.new()

    # Check each verifying record for recurrence
    failures =
      list_verifying()
      |> Enum.filter(fn record -> MapSet.member?(incoming_hashes, record.fingerprint_hash) end)
      |> Enum.map(fn record ->
        mark_ineffective(record, config)
      end)

    {:reply, failures, config}
  end

  def handle_call(:tick, _from, config) do
    # Decrement countdown for all verifying records
    verified =
      list_verifying()
      |> Enum.map(fn record ->
        new_cycles = record.cycles_remaining - 1

        if new_cycles <= 0 do
          mark_verified(record, config)
        else
          updated = %{record | cycles_remaining: new_cycles}
          :ets.insert(@verifying_table, {record.fingerprint_hash, updated})
          nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    {:reply, verified, config}
  end

  def handle_call({:cancel_verification, fingerprint}, _from, config) do
    fp_hash = Fingerprint.hash(fingerprint)
    :ets.delete(@verifying_table, fp_hash)
    {:reply, :ok, config}
  end

  def handle_call(:clear_all, _from, config) do
    :ets.delete_all_objects(@verifying_table)
    {:reply, :ok, config}
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp fingerprint_from_anomaly(%{
         skill: skill,
         details: %{metric: metric, value: value, ewma: ewma}
       }) do
    direction = if value > ewma, do: :above, else: :below
    {:ok, Fingerprint.new(skill, metric, direction)}
  end

  defp fingerprint_from_anomaly(_other), do: {:error, :invalid_anomaly}

  defp mark_ineffective(record, config) do
    updated = %{record | outcome: :ineffective}
    :ets.insert(@verifying_table, {record.fingerprint_hash, updated})

    Logger.warning(
      "[Verification] Fix ineffective: #{Fingerprint.to_string(record.fingerprint)} " <>
        "recurred during soak period"
    )

    emit_signal(config, :healing_ineffective, %{
      fingerprint: Fingerprint.to_string(record.fingerprint),
      fingerprint_hash: record.fingerprint_hash,
      proposal_id: record.proposal_id,
      cycles_completed: config.soak_cycles - record.cycles_remaining
    })

    %{
      status: :ineffective,
      fingerprint: record.fingerprint,
      proposal_id: record.proposal_id,
      soak_cycles: config.soak_cycles - record.cycles_remaining
    }
  end

  defp mark_verified(record, config) do
    updated = %{record | outcome: :verified, cycles_remaining: 0}
    :ets.insert(@verifying_table, {record.fingerprint_hash, updated})

    Logger.info(
      "[Verification] Fix verified: #{Fingerprint.to_string(record.fingerprint)} " <>
        "held through soak period"
    )

    emit_signal(config, :healing_verified, %{
      fingerprint: Fingerprint.to_string(record.fingerprint),
      fingerprint_hash: record.fingerprint_hash,
      proposal_id: record.proposal_id,
      soak_cycles: config.soak_cycles
    })

    %{
      status: :verified,
      fingerprint: record.fingerprint,
      proposal_id: record.proposal_id,
      soak_cycles: config.soak_cycles
    }
  end

  defp emit_signal(config, event, payload) do
    case config.signal_callback do
      nil ->
        :ok

      callback when is_function(callback, 3) ->
        try do
          callback.(:healing, event, payload)
        rescue
          e ->
            Logger.warning("[Verification] Signal emission failed: #{inspect(e)}")
        end

      _ ->
        :ok
    end
  end
end
