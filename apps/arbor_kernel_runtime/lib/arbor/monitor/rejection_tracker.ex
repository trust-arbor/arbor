defmodule Arbor.Monitor.RejectionTracker do
  @moduledoc """
  Tracks proposal rejections and implements three-strike escalation policy.

  When a proposal is rejected by the consensus council, the tracker:

  1. **First rejection**: Mark for retry with more context
     - Wait for next occurrence of the same fingerprint
     - Gather additional diagnostic information
     - Retry with enriched analysis

  2. **Second rejection**: Reduce scope of proposed fix
     - Try a more conservative fix (e.g., restart vs reconfigure)
     - Smaller blast radius

  3. **Third rejection**: Escalate to human
     - Emit `:healing_blocked` signal
     - Add to suppression list (30-minute TTL)
     - Surface to dashboard for human attention

  ## ETS Table

  - `:arbor_healing_rejections` - Tracks rejections: `{family_hash, count, last_rejection, reasons}`

  ## Configuration

  - `:max_rejections` - Rejections before escalation (default: 3)
  - `:rejection_window_ms` - Window for counting rejections (default: 1 hour)
  - `:suppression_ttl_minutes` - How long to suppress after escalation (default: 30)
  """

  use GenServer

  require Logger

  alias Arbor.Monitor.Fingerprint

  @rejection_table :arbor_healing_rejections

  # Default configuration
  @default_max_rejections 3
  @default_rejection_window_ms :timer.hours(1)
  @default_suppression_ttl_minutes 30
  @default_cleanup_interval_ms :timer.minutes(5)

  # Escalation strategies for each strike
  @strategies %{
    1 => :retry_with_context,
    2 => :reduce_scope,
    3 => :escalate_to_human
  }

  # ============================================================================
  # Types
  # ============================================================================

  @type rejection_record :: %{
          family_hash: integer(),
          count: non_neg_integer(),
          last_rejection_at: integer(),
          reasons: [String.t()],
          proposal_ids: [String.t()]
        }

  @type escalation_strategy :: :retry_with_context | :reduce_scope | :escalate_to_human

  @type rejection_result :: %{
          strategy: escalation_strategy(),
          rejection_count: non_neg_integer(),
          should_suppress: boolean(),
          message: String.t()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record a proposal rejection and get the recommended escalation strategy.

  Returns a map with:
  - `:strategy` - The recommended next action
  - `:rejection_count` - How many times this fingerprint family has been rejected
  - `:should_suppress` - Whether to add to suppression list
  - `:message` - Human-readable explanation
  """
  @spec record_rejection(Fingerprint.t(), String.t(), String.t()) :: rejection_result()
  def record_rejection(%Fingerprint{} = fingerprint, proposal_id, reason) do
    GenServer.call(__MODULE__, {:record_rejection, fingerprint, proposal_id, reason})
  end

  @doc """
  Get the current rejection count for a fingerprint family.
  """
  @spec rejection_count(Fingerprint.t()) :: non_neg_integer()
  def rejection_count(%Fingerprint{} = fingerprint) do
    family_hash = Fingerprint.family_hash(fingerprint)

    case :ets.lookup(@rejection_table, family_hash) do
      [{^family_hash, record}] -> record.count
      [] -> 0
    end
  end

  @doc """
  Get the full rejection record for a fingerprint family.
  """
  @spec get_record(Fingerprint.t()) :: rejection_record() | nil
  def get_record(%Fingerprint{} = fingerprint) do
    family_hash = Fingerprint.family_hash(fingerprint)

    case :ets.lookup(@rejection_table, family_hash) do
      [{^family_hash, record}] -> record
      [] -> nil
    end
  end

  @doc """
  Clear rejection history for a fingerprint family (e.g., after successful fix).
  """
  @spec clear_rejections(Fingerprint.t()) :: :ok
  def clear_rejections(%Fingerprint{} = fingerprint) do
    GenServer.call(__MODULE__, {:clear_rejections, fingerprint})
  end

  @doc """
  List all fingerprint families with rejections.
  """
  @spec list_rejected() :: [rejection_record()]
  def list_rejected do
    :ets.tab2list(@rejection_table)
    |> Enum.map(fn {_hash, record} -> record end)
    |> Enum.sort_by(& &1.last_rejection_at, :desc)
  end

  @doc """
  Get statistics about rejections.
  """
  @spec stats() :: map()
  def stats do
    all = list_rejected()

    %{
      total_families: length(all),
      strike_1: Enum.count(all, &(&1.count == 1)),
      strike_2: Enum.count(all, &(&1.count == 2)),
      strike_3_plus: Enum.count(all, &(&1.count >= 3)),
      total_rejections: Enum.sum(Enum.map(all, & &1.count))
    }
  end

  @doc """
  Clear all rejection data (for testing).
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
    if :ets.whereis(@rejection_table) == :undefined do
      :ets.new(@rejection_table, [:named_table, :set, :public, read_concurrency: true])
    end

    config = %{
      max_rejections: Keyword.get(opts, :max_rejections, @default_max_rejections),
      rejection_window_ms: Keyword.get(opts, :rejection_window_ms, @default_rejection_window_ms),
      suppression_ttl_minutes:
        Keyword.get(opts, :suppression_ttl_minutes, @default_suppression_ttl_minutes),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms),
      signal_callback: Keyword.get(opts, :signal_callback)
    }

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup_old_rejections, config.cleanup_interval_ms)

    {:ok, config}
  end

  @impl GenServer
  def handle_call({:record_rejection, fingerprint, proposal_id, reason}, _from, config) do
    result = do_record_rejection(fingerprint, proposal_id, reason, config)
    {:reply, result, config}
  end

  def handle_call({:clear_rejections, fingerprint}, _from, config) do
    family_hash = Fingerprint.family_hash(fingerprint)
    :ets.delete(@rejection_table, family_hash)
    {:reply, :ok, config}
  end

  def handle_call(:clear_all, _from, config) do
    :ets.delete_all_objects(@rejection_table)
    {:reply, :ok, config}
  end

  @impl GenServer
  def handle_info(:cleanup_old_rejections, config) do
    cleanup_expired_rejections(config.rejection_window_ms)
    Process.send_after(self(), :cleanup_old_rejections, config.cleanup_interval_ms)
    {:noreply, config}
  end

  # ============================================================================
  # Internal Functions
  # ============================================================================

  defp do_record_rejection(fingerprint, proposal_id, reason, config) do
    now = System.monotonic_time(:millisecond)
    family_hash = Fingerprint.family_hash(fingerprint)

    # Get or create record
    record =
      case :ets.lookup(@rejection_table, family_hash) do
        [{^family_hash, existing}] ->
          # Check if within window
          if now - existing.last_rejection_at < config.rejection_window_ms do
            %{
              existing
              | count: existing.count + 1,
                last_rejection_at: now,
                reasons: Enum.take([reason | existing.reasons], 10),
                proposal_ids: Enum.take([proposal_id | existing.proposal_ids], 10)
            }
          else
            # Window expired, start fresh
            new_record(family_hash, proposal_id, reason, now)
          end

        [] ->
          new_record(family_hash, proposal_id, reason, now)
      end

    # Store updated record
    :ets.insert(@rejection_table, {family_hash, record})

    # Determine strategy
    strike = min(record.count, config.max_rejections)
    strategy = Map.get(@strategies, strike, :escalate_to_human)
    should_suppress = record.count >= config.max_rejections

    # Log and emit signal
    log_rejection(fingerprint, record.count, strategy)

    if should_suppress do
      emit_healing_blocked(fingerprint, record, config)
    end

    %{
      strategy: strategy,
      rejection_count: record.count,
      should_suppress: should_suppress,
      message: strategy_message(strategy, record.count)
    }
  end

  defp new_record(family_hash, proposal_id, reason, now) do
    %{
      family_hash: family_hash,
      count: 1,
      last_rejection_at: now,
      reasons: [reason],
      proposal_ids: [proposal_id]
    }
  end

  defp log_rejection(fingerprint, count, strategy) do
    fp_str = Fingerprint.to_string(fingerprint)

    case strategy do
      :retry_with_context ->
        Logger.info("[RejectionTracker] Strike 1 for #{fp_str}: will retry with more context")

      :reduce_scope ->
        Logger.warning("[RejectionTracker] Strike 2 for #{fp_str}: will reduce fix scope")

      :escalate_to_human ->
        Logger.warning(
          "[RejectionTracker] Strike #{count} for #{fp_str}: escalating to human attention"
        )
    end
  end

  defp emit_healing_blocked(fingerprint, record, config) do
    case config.signal_callback do
      nil ->
        :ok

      callback when is_function(callback, 3) ->
        payload = %{
          fingerprint: Fingerprint.to_string(fingerprint),
          family_hash: record.family_hash,
          rejection_count: record.count,
          reasons: record.reasons,
          proposal_ids: record.proposal_ids,
          suppression_ttl_minutes: config.suppression_ttl_minutes
        }

        try do
          callback.(:healing, :healing_blocked, payload)
        rescue
          e ->
            Logger.warning("[RejectionTracker] Signal emission failed: #{inspect(e)}")
        end

      _ ->
        :ok
    end
  end

  defp strategy_message(:retry_with_context, _count) do
    "Proposal rejected. Will gather more context and retry."
  end

  defp strategy_message(:reduce_scope, _count) do
    "Proposal rejected twice. Will try a more conservative fix."
  end

  defp strategy_message(:escalate_to_human, count) do
    "Proposal rejected #{count} times. Escalating to human attention."
  end

  defp cleanup_expired_rejections(window_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    :ets.tab2list(@rejection_table)
    |> Enum.each(fn {family_hash, record} ->
      if record.last_rejection_at < cutoff do
        :ets.delete(@rejection_table, family_hash)
      end
    end)
  end
end
