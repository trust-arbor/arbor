defmodule Arbor.Orchestrator.PipelineStatus do
  @moduledoc """
  Canonical public boundary for current pipeline-run lifecycle state.

  All Engine, RecoveryCoordinator, and public facade reads/writes for
  **current** runs go through this module. It delegates to
  `Arbor.Orchestrator.RunJournal` and never requires callers to touch
  lifecycle ETS or `JobRegistry` for current records.

  ## Design principles

  - **Privacy by default**: lifecycle records hold bounded metadata only
    (IDs, status, timestamps, recovery pointers). Agent context never
    enters this boundary.
  - **PID liveness at read time**: entries with status `:running` are
    checked against `spawning_pid`. If the PID is dead, the correction
    is **persisted** as `:interrupted` and remains visible to recovery /
    `list_resumable`.
  - **"Last Synced" staleness**: entries include `last_ets_sync` for
    detecting when the Engine stops updating.
  - **Trust-zone filtering**: callers may pass `principal_id`; field
    stripping based on granular trust policy / trust zone is deferred
    (currently returns all metadata).
  - **Durability is explicit**: see `durability_status/0`. Writes are
    backend-first when a backend is configured; the default
    volatile/process-lifetime journal is **not** crash durable.
  - **Public maps are not JSON-clean**: runtime views may contain
    `DateTime`, atoms, and `PID`. Durable JSON is owned by RunJournal's
    adapter path.

  ## Usage

      PipelineStatus.list_active()
      PipelineStatus.list_recent(limit: 10)
      PipelineStatus.get("run_Heartbeat_...")
      PipelineStatus.put_run_state(run_state, logs_root: path)
      PipelineStatus.finalize(run_id, :completed, nil, duration_ms, meta)
      PipelineStatus.durability_status()
  """

  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Adapter
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunState.Core, as: RunState

  # If an entry hasn't been synced in this many ms, it's considered stale.
  # 2x the heartbeat interval (30s) = 60s.
  @stale_threshold_ms 60_000

  # ===========================================================================
  # Writes (canonical mutations)
  # ===========================================================================

  @doc "Put a lifecycle map or Record through the journal."
  @spec put(Record.t() | map(), keyword()) :: :ok | {:error, term()}
  def put(record_or_map, opts \\ []), do: RunJournal.put(record_or_map, opts)

  @doc """
  Sync process-local RunState into the canonical store.

  Optional meta keys: `:logs_root`, `:graph_hash`, `:dot_source_path`,
  `:origin_trust_zone`, `:spawning_pid`.

  Journal target opts (e.g. `server:`) may be passed as the third argument.
  """
  @spec put_run_state(RunState.t(), map() | keyword(), keyword()) :: :ok | {:error, term()}
  def put_run_state(%RunState{} = state, meta \\ %{}, opts \\ []) do
    RunJournal.put_run_state(state, meta, opts)
  end

  @doc """
  Atomically admit a run_id and publish the initial lifecycle snapshot.

  See `RunJournal.admit_and_put_run_state/3`. Option `:admission` is
  `:fresh` (default) or `:resume`. Journal target opts may include `server:`.
  """
  @spec admit_and_put_run_state(RunState.t(), map() | keyword(), keyword()) ::
          :ok | {:error, term()}
  def admit_and_put_run_state(%RunState{} = state, meta \\ %{}, opts \\ []) do
    RunJournal.admit_and_put_run_state(state, meta, opts)
  end

  @doc "Refresh heartbeat / last_ets_sync for a running pipeline."
  @spec touch_heartbeat(String.t(), keyword()) :: :ok | {:error, term()}
  def touch_heartbeat(run_id, opts \\ []) when is_binary(run_id) do
    RunJournal.touch_heartbeat(run_id, nil, opts)
  end

  @doc "Mark a pipeline interrupted (eligible for recovery)."
  @spec mark_interrupted(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_interrupted(run_id, opts \\ []), do: RunJournal.mark_interrupted(run_id, opts)

  @doc """
  Mark a pipeline as abandoned.

  Used by RecoveryCoordinator and Session/task cancel cleanup.
  Optional journal target opts (e.g. `server:`) select a non-default journal.
  """
  @spec mark_abandoned(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_abandoned(run_id, opts \\ []), do: RunJournal.mark_abandoned(run_id, opts)

  @doc "Mark a pipeline as recovering (resume in progress). Prefer claim_for_recovery/2."
  @spec mark_recovering(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_recovering(run_id, opts \\ []), do: RunJournal.mark_recovering(run_id, opts)

  @doc "Mark recovery/execution failed with a bounded reason."
  @spec mark_failed(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def mark_failed(run_id, reason, opts \\ []), do: RunJournal.mark_failed(run_id, reason, opts)

  @doc """
  Atomic nonterminal → terminal transition via RunJournal.

  See `RunJournal.finalize/5`. Returns transitioned vs already_terminal
  (same status) or `{:error, {:terminal_conflict, existing, requested}}`.
  """
  @spec finalize(
          String.t(),
          atom(),
          term(),
          non_neg_integer() | nil,
          map() | keyword(),
          keyword()
        ) ::
          {:ok, :transitioned | :already_terminal, Record.t()} | {:error, term()}
  def finalize(run_id, status, reason, duration_ms, metadata \\ %{}, opts \\ [])
      when is_binary(run_id) and is_atom(status) do
    RunJournal.finalize(run_id, status, reason, duration_ms, metadata, opts)
  end

  @doc """
  Atomically claim an interrupted pipeline for recovery.

  Only `:interrupted` records are claimable — consistent with public resume.
  Returns `{:ok, public_map}` or `{:error, reason}`.

  Optional journal target opts (e.g. `server:`) select a non-default journal.
  """
  @spec claim_for_recovery(String.t(), node(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim_for_recovery(run_id, claiming_node \\ Kernel.node(), opts \\ []) do
    case RunJournal.claim_for_recovery(run_id, claiming_node, opts) do
      {:ok, %Record{} = record} -> {:ok, Adapter.to_public_map(record)}
      {:error, _} = err -> err
    end
  end

  @doc "Typed claim returning `Record`."
  @spec claim_for_recovery_record(String.t(), node(), keyword()) ::
          {:ok, Record.t()} | {:error, term()}
  def claim_for_recovery_record(run_id, claiming_node \\ Kernel.node(), opts \\ []) do
    RunJournal.claim_for_recovery(run_id, claiming_node, opts)
  end

  @doc "Explicit durability diagnostics for operators and tests."
  @spec durability_status(keyword()) :: map()
  def durability_status(opts \\ []), do: RunJournal.durability_status(opts)

  @doc "Delete a lifecycle entry via the journal (tests/ops)."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(run_id, opts \\ []), do: RunJournal.delete(run_id, opts)

  # ===========================================================================
  # Reads
  # ===========================================================================

  @doc """
  List all active pipelines (running, suspended, degraded).

  Applies PID liveness correction and **persists** `:interrupted` when
  the owner process is dead. Interrupted records are not returned here
  but remain visible via `list_interrupted/0` and recovery APIs.
  """
  @spec list_active(keyword()) :: [map()]
  def list_active(opts \\ []) do
    journal_opts = journal_target_opts(opts)

    case RunJournal.list_records(journal_opts) do
      {:ok, records} ->
        records
        |> Enum.map(&Adapter.to_public_map/1)
        |> Enum.filter(fn entry -> entry.status in [:running, :suspended, :degraded] end)
        |> Enum.map(&apply_liveness_check(&1, journal_opts))
        |> Enum.filter(fn entry -> entry.status in [:running, :suspended, :degraded] end)
        |> maybe_filter_principal(opts)
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

      {:error, _} ->
        []
    end
  end

  @doc """
  List interrupted pipelines (crash-orphaned / dead-owner), including
  liveness-corrected records that were persisted as interrupted.

  Dashboard helper: degrades to `[]` on journal unavailability (explicit
  empty, not an outage signal). Recovery must use `list_interrupted_records/1`.
  """
  @spec list_interrupted(keyword()) :: [map()]
  def list_interrupted(opts \\ []) do
    case list_interrupted_records(opts) do
      {:ok, records} -> Enum.map(records, &Adapter.to_public_map/1)
      {:error, _} -> []
    end
  end

  @doc """
  Typed interrupted list for recovery.

  Stays `Record` end-to-end (no public-map churn). Journal unavailability
  is returned as `{:error, :journal_unavailable}` so recovery/mutation
  callers never confuse outage with empty.
  """
  @spec list_interrupted_records(keyword()) ::
          {:ok, [Record.t()]} | {:error, :journal_unavailable | term()}
  def list_interrupted_records(opts \\ []) do
    journal_opts = journal_target_opts(opts)

    case RunJournal.list_records(journal_opts) do
      {:ok, records} ->
        list =
          records
          |> Enum.map(&apply_liveness_check_record(&1, journal_opts))
          |> Enum.filter(fn %Record{status: status} -> status == :interrupted end)
          |> maybe_filter_principal_records(opts)
          |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

        {:ok, list}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  List recently completed/failed/abandoned pipelines.

  Options:
  - `:limit` — max entries to return (default 50)
  - `:server` — optional non-default RunJournal server
  """
  @spec list_recent(keyword()) :: [map()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    journal_opts = journal_target_opts(opts)

    journal_opts
    |> RunJournal.list_raw()
    |> Enum.filter(fn entry -> entry.status in [:completed, :failed, :abandoned] end)
    |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
    |> Enum.take(limit)
    |> maybe_filter_principal(opts)
  end

  @doc """
  Get a specific pipeline run by run_id.

  Applies PID liveness correction (persisted). Returns `nil` if not found.
  Public map is **not** JSON-clean (may contain DateTime/atoms/PID).
  """
  @spec get(String.t(), keyword()) :: map() | nil
  def get(run_id, opts \\ []) when is_binary(run_id) do
    journal_opts = journal_target_opts(opts)

    case RunJournal.get_raw(run_id, journal_opts) do
      nil -> nil
      entry -> apply_liveness_check(entry, journal_opts)
    end
  end

  @doc """
  Typed get for recovery/internal callers.

  Returns `Record`, `nil` when not found, or `{:error, :journal_unavailable}`.
  """
  @spec get_record(String.t(), keyword()) :: Record.t() | nil | {:error, :journal_unavailable}
  def get_record(run_id, opts \\ []) when is_binary(run_id) do
    journal_opts = journal_target_opts(opts)

    case RunJournal.get_record(run_id, journal_opts) do
      {:ok, %Record{} = record} ->
        apply_liveness_check_record(record, journal_opts)

      {:error, :not_found} ->
        nil

      {:error, :journal_unavailable} ->
        {:error, :journal_unavailable}

      {:error, _} ->
        nil
    end
  end

  @doc "Count pipelines by status (after liveness correction)."
  @spec count_by_status(keyword()) :: %{atom() => non_neg_integer()}
  def count_by_status(opts \\ []) do
    journal_opts = journal_target_opts(opts)

    journal_opts
    |> RunJournal.list_raw()
    |> Enum.map(&apply_liveness_check(&1, journal_opts))
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, entries} -> {status, length(entries)} end)
    |> Map.new()
  end

  @doc "Check if a specific run_id exists and is active."
  @spec active?(String.t(), keyword()) :: boolean()
  def active?(run_id, opts \\ []) do
    case get(run_id, opts) do
      %{status: status} -> status in [:running, :suspended, :degraded]
      nil -> false
    end
  end

  @doc """
  List pipelines whose heartbeat is older than `max_age_ms`.

  Accepts optional `now` for deterministic testing and optional journal
  target opts (`server:`).
  """
  @spec list_stale_heartbeats(non_neg_integer()) :: [map()]
  def list_stale_heartbeats(max_age_ms \\ 90_000) do
    list_stale_heartbeats(max_age_ms, DateTime.utc_now())
  end

  @spec list_stale_heartbeats(non_neg_integer(), DateTime.t(), keyword()) :: [map()]
  def list_stale_heartbeats(max_age_ms, %DateTime{} = now, opts \\ []) do
    case list_stale_heartbeat_records(max_age_ms, now, opts) do
      {:ok, records} -> Enum.map(records, &Adapter.to_public_map/1)
      {:error, _} -> []
    end
  end

  @doc "Typed stale-heartbeat list. Returns `{:ok, records}` or journal error."
  @spec list_stale_heartbeat_records(non_neg_integer(), DateTime.t(), keyword()) ::
          {:ok, [Record.t()]} | {:error, term()}
  def list_stale_heartbeat_records(max_age_ms, %DateTime{} = now, opts \\ []) do
    cutoff = DateTime.add(now, -max_age_ms, :millisecond)
    journal_opts = journal_target_opts(opts)

    case RunJournal.list_records(journal_opts) do
      {:ok, records} ->
        list =
          records
          |> Enum.map(&apply_liveness_check_record(&1, journal_opts))
          |> Enum.filter(fn %Record{} = entry ->
            entry.status == :running and
              entry.last_heartbeat != nil and
              DateTime.compare(entry.last_heartbeat, cutoff) == :lt
          end)

        {:ok, list}

      {:error, _} = err ->
        err
    end
  end

  @doc "List running/interrupted entries owned by a node (for nodedown recovery)."
  @spec list_by_owner(node() | String.t(), keyword()) :: [map()]
  def list_by_owner(node_name, opts \\ []) do
    list_by_owner_records(node_name, opts)
    |> Enum.map(&Adapter.to_public_map/1)
  end

  @doc "Typed list by owner."
  @spec list_by_owner_records(node() | String.t(), keyword()) :: [Record.t()]
  def list_by_owner_records(node_name, opts \\ []) do
    node_str = to_string(node_name)
    journal_opts = journal_target_opts(opts)

    case RunJournal.list_records(journal_opts) do
      {:ok, records} ->
        records
        |> Enum.map(&apply_liveness_check_record(&1, journal_opts))
        |> Enum.filter(fn %Record{} = entry ->
          entry.status in [:running, :interrupted] and
            to_string(entry.owner_node) == node_str
        end)

      {:error, _} ->
        []
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
  # PID liveness correction (persists only on proven :dead)
  # ===========================================================================

  # Journal target keys that select a non-default RunJournal server.
  # Principal filters and other read options stay outside this set.
  defp journal_target_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:server])
  end

  defp journal_target_opts(_), do: []

  defp apply_liveness_check_record(%Record{} = record, journal_opts) do
    public = apply_liveness_check(Adapter.to_public_map(record), journal_opts)

    # Prefer reloading from journal after persist so we stay Record-typed
    # without inventing fields from a partial public map.
    if public.status == :interrupted and record.status == :running do
      case RunJournal.get_record(record.run_id, journal_opts) do
        {:ok, %Record{} = updated} -> updated
        _ -> %Record{record | status: :interrupted}
      end
    else
      record
    end
  end

  defp apply_liveness_check(%{status: :running, spawning_pid: pid} = entry, journal_opts)
       when is_pid(pid) do
    case process_liveness(pid) do
      :alive ->
        entry

      :dead ->
        case RunJournal.persist_interrupted(entry.run_id, journal_opts) do
          %{} = updated -> updated
          nil -> %{entry | status: :interrupted}
        end

      :unknown ->
        # Partition / RPC failure — do not persist interruption.
        entry
    end
  end

  defp apply_liveness_check(entry, _journal_opts), do: entry

  @doc false
  @spec process_liveness(pid()) :: :alive | :dead | :unknown
  def process_liveness(pid) when is_pid(pid) do
    if node(pid) == Kernel.node() do
      if Process.alive?(pid), do: :alive, else: :dead
    else
      try do
        case :rpc.call(node(pid), Process, :alive?, [pid], 2_000) do
          true -> :alive
          false -> :dead
          {:badrpc, _} -> :unknown
          _ -> :unknown
        end
      catch
        :exit, _ -> :unknown
        :throw, _ -> :unknown
        _, _ -> :unknown
      end
    end
  end

  def process_liveness(_), do: :dead

  # Trust-zone filtering placeholder — granular policy / trust zone (not tiers).
  defp maybe_filter_principal(entries, opts) do
    case Keyword.get(opts, :principal_id) do
      nil -> entries
      _principal_id -> entries
    end
  end

  defp maybe_filter_principal_records(records, opts) do
    case Keyword.get(opts, :principal_id) do
      nil -> records
      _principal_id -> records
    end
  end
end
