defmodule Arbor.Orchestrator.PipelineStatus do
  @moduledoc """
  Query facade for pipeline lifecycle state.

  Reads from the `:arbor_pipeline_runs` ETS table written by Engine
  processes. This is the ONLY authorized read path for pipeline status
  — direct ETS reads bypass trust-zone filtering and PID liveness checks.

  ## Design principles (council-vetted 2026-04-12)

  - **Privacy by default**: ETS stores only metadata (IDs, status,
    timestamps). Agent context never leaves the Engine process.
  - **PID liveness at read time**: entries with status `:running` are
    checked against the `spawning_pid`. If the PID is dead, the entry
    is returned as `:interrupted` — self-correcting without a cleanup
    process.
  - **"Last Synced" staleness**: entries include a `last_ets_sync`
    timestamp. Callers can detect stale data when the Engine stops
    updating (crash, hang, network partition).
  - **Trust-zone filtering**: callers pass their `principal_id`; the
    Facade strips fields the caller shouldn't see based on trust tier.
    (Full implementation deferred — currently returns all metadata.)

  ## Usage

      # List all active pipelines
      PipelineStatus.list_active()

      # List recently completed
      PipelineStatus.list_recent(limit: 10)

      # Get a specific run with PID liveness check
      PipelineStatus.get("run_Heartbeat_...")

      # Count by status
      PipelineStatus.count_by_status()
  """

  alias Arbor.Orchestrator.RunState.Core, as: RunState

  @ets_table :arbor_pipeline_runs

  # If an entry hasn't been synced in this many ms, it's considered stale.
  # 2x the heartbeat interval (30s) = 60s. Generous threshold.
  @stale_threshold_ms 60_000

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  List all active pipelines (running, suspended, degraded).

  Applies PID liveness correction: entries with status `:running` whose
  `spawning_pid` is dead are returned as `:interrupted`.
  """
  @spec list_active(keyword()) :: [map()]
  def list_active(opts \\ []) do
    read_all()
    |> Enum.filter(fn entry -> entry.status in [:running, :suspended, :degraded] end)
    |> Enum.map(&apply_liveness_check/1)
    |> Enum.filter(fn entry -> entry.status in [:running, :suspended, :degraded] end)
    |> maybe_filter_principal(opts)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  List recently completed/failed/abandoned pipelines.

  Options:
  - `:limit` — max entries to return (default 50)
  """
  @spec list_recent(keyword()) :: [map()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    read_all()
    |> Enum.filter(fn entry -> entry.status in [:completed, :failed, :abandoned] end)
    |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
    |> Enum.take(limit)
    |> maybe_filter_principal(opts)
  end

  @doc """
  Get a specific pipeline run by run_id.

  Applies PID liveness correction. Returns `nil` if not found.
  """
  @spec get(String.t()) :: map() | nil
  def get(run_id) do
    case safe_ets_lookup(run_id) do
      nil -> nil
      entry -> apply_liveness_check(entry)
    end
  end

  @doc """
  Count pipelines by status.

  Returns a map like `%{running: 3, completed: 12, failed: 1}`.
  Applies PID liveness correction before counting.
  """
  @spec count_by_status() :: %{atom() => non_neg_integer()}
  def count_by_status do
    read_all()
    |> Enum.map(&apply_liveness_check/1)
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, entries} -> {status, length(entries)} end)
    |> Map.new()
  end

  @doc """
  Check if a specific run_id exists and is active.
  """
  @spec active?(String.t()) :: boolean()
  def active?(run_id) do
    case get(run_id) do
      %{status: status} -> status in [:running, :suspended, :degraded]
      nil -> false
    end
  end

  @doc """
  Mark a pipeline as abandoned directly in ETS.

  Used by the RecoveryCoordinator and Session.terminate for cleanup.
  This is a WRITE operation — the only write the Facade performs
  (all other writes come from Engine processes).
  """
  @spec mark_abandoned(String.t()) :: :ok
  def mark_abandoned(run_id) do
    case safe_ets_lookup(run_id) do
      nil ->
        :ok

      entry ->
        updated = %{entry | status: :abandoned, current_node: nil}
        safe_ets_insert(run_id, updated)
    end
  end

  @doc """
  Check if an entry's data may be stale (Engine stopped updating).

  Returns `true` if `last_ets_sync` is older than the stale threshold
  AND the pipeline is still in an active state.
  """
  @spec stale?(map()) :: boolean()
  def stale?(%{status: status, last_ets_sync: last_sync})
      when status in [:running, :suspended, :degraded] and not is_nil(last_sync) do
    DateTime.diff(DateTime.utc_now(), last_sync, :millisecond) > @stale_threshold_ms
  end

  def stale?(_), do: false

  # ===========================================================================
  # PID liveness correction
  # ===========================================================================

  # Council recommendation: when reading an entry with status :running,
  # check if the spawning_pid is still alive. If dead, return :interrupted
  # instead. This makes the Facade self-correcting — stale entries are
  # detected at read time without needing a cleanup process.
  defp apply_liveness_check(%{status: :running, spawning_pid: pid} = entry)
       when is_pid(pid) do
    if process_alive?(pid) do
      entry
    else
      %{entry | status: :interrupted}
    end
  end

  defp apply_liveness_check(entry), do: entry

  defp process_alive?(pid) when is_pid(pid) do
    if node(pid) == Kernel.node() do
      Process.alive?(pid)
    else
      try do
        :rpc.call(node(pid), Process, :alive?, [pid]) == true
      catch
        :exit, _ -> false
      end
    end
  end

  defp process_alive?(_), do: false

  # ===========================================================================
  # Trust-zone filtering (placeholder — full implementation in a follow-up)
  # ===========================================================================

  # When a principal_id is provided, filter entries to only those the
  # principal is authorized to see. Currently returns all entries.
  # Future: check the principal's trust tier against the entry's
  # origin_trust_zone and strip fields accordingly.
  defp maybe_filter_principal(entries, opts) do
    case Keyword.get(opts, :principal_id) do
      nil -> entries
      _principal_id -> entries
    end
  end

  # ===========================================================================
  # ETS access (defensive — never crash the caller)
  # ===========================================================================

  defp read_all do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_key, entry} -> entry end)
  rescue
    ArgumentError -> []
  catch
    :exit, _ -> []
  end

  defp safe_ets_lookup(run_id) do
    case :ets.lookup(@ets_table, run_id) do
      [{_key, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_ets_insert(run_id, entry) do
    :ets.insert(@ets_table, {run_id, entry})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
