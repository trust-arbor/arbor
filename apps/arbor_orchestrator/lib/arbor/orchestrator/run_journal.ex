defmodule Arbor.Orchestrator.RunJournal do
  @moduledoc """
  Orchestrator-owned shell for current pipeline-run lifecycle metadata.

  Owns the hot lifecycle ETS table exclusively (created in `init/1`,
  **`:private`**, dies with this process). The table stores
  `%RunLifecycle.Record{}` values directly. Public maps are produced only
  at public facade boundaries (`get_raw/2`, `list_raw/1`, PipelineStatus).

  All reads and writes go through this GenServer — Engine, Recovery,
  facade, Mix tasks, and tests must not touch the table directly.
  `LegacyJobAdapter` is the only module that may touch `JobRegistry`.

  ## Durability (honest classes)

  A non-nil backend is **not** automatically durable. RunJournal reports an
  explicit reviewed `durability_class`:

  - `:volatile` — private ETS only (default; dies with this process)
  - `:process_lifetime` — backend exists but only for the store process lifetime
    (ETS-backed stores, Agent, async buffers). **Not** a crash-durable automatic
    recovery store; process death loses this class of data.
  - `:application_restart` — survives journal restart against the same live
    backend process (must be declared via backend `durability_class/1`
    capability intersection; never inferred for ETS/Agent/buffer, no force flag)
  - `:node_restart` — survives full node restart (L4 durable backends only)

  Default is volatile/non-durable. Writes are backend-first when a backend is
  configured; backend failure leaves the prior hot record unchanged and
  returns `{:error, {:durable_write_failed, reason}}`. Process-lifetime and
  asynchronous wrappers must never be described or treated as crash-durable
  automatic recovery stores.

  ## Atomic terminal transition

  Prefer `finalize/5` for nonterminal → terminal transitions. It reads the
  latest stored record, preserves progress, transitions once, and returns
  `:transitioned` vs `:already_terminal` (same status) or
  `{:error, {:terminal_conflict, existing, requested}}` when a different
  terminal status is requested. Mutations and recovery-sensitive reads
  surface journal unavailability as `{:error, :journal_unavailable}`
  rather than `[]` / `nil` / `:ok`.

  ## Distributed claims (L4B fenced recovery)

  Local GenServer claims remain atomic for unfenced backends (including
  healthy `:application_restart` without linearizable CAS). When
  `durability_status/0` reports `fenced_claim: true` (healthy crash-durable
  backend that exports public `compare_and_swap/4`), claims CAS the
  canonical structured `PersistenceRecord` (generation + revision) so
  concurrent journals sharing the backend elect exactly one winner.

  `cross_node_atomic_recovery: true` only when that fenced path is active
  and the effective durability class is `:node_restart`. Remote-source or
  remote-owned interrupted rows are claimable only on that path. Callers
  cannot claim on behalf of an arbitrary remote node — `claiming_node`
  must be this journal's local node. Unstructured/unversioned durable
  values and CAS anomalies fail closed.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.RunLifecycle.Adapter
  alias Arbor.Orchestrator.RunLifecycle.EffectEnvelope
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Orchestrator.RunState.Core, as: RunState

  @default_ets_table :arbor_pipeline_runs
  @default_store_name :arbor_pipeline_run_lifecycle
  @default_collection "pipeline_run_lifecycle"

  @terminal_statuses [:completed, :failed, :abandoned]
  @finalize_statuses [:completed, :failed, :abandoned, :interrupted]
  # In-flight statuses that lose their live owner across journal restart and
  # must rehydrate as claimable :interrupted (never permanently unclaimable).
  @ownerless_inflight_statuses [:running, :recovering, :suspended, :degraded, :delegated]

  # ---------------------------------------------------------------------------
  # Public API — server resolution
  # ---------------------------------------------------------------------------

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Put a full lifecycle record (backend-first when configured, then hot)."
  @spec put(Record.t() | map(), keyword()) :: :ok | {:error, term()}
  def put(record_or_map, opts \\ [])

  def put(%Record{} = record, opts) do
    call_server(opts, {:put, record})
  end

  def put(map, opts) when is_map(map) do
    put(Adapter.from_lifecycle_map(map), opts)
  end

  @doc "Put from process-local RunState + optional recovery metadata."
  @spec put_run_state(RunState.t(), map() | keyword(), keyword()) :: :ok | {:error, term()}
  def put_run_state(%RunState{} = state, meta \\ %{}, opts \\ []) do
    call_server(opts, {:put_run_state, state, meta})
  end

  @doc """
  Atomically admit a run_id and publish the initial lifecycle snapshot.

  Fresh admission and the first lifecycle publication share one owner-side
  critical section so concurrent `Engine.run/2` callers cannot both observe
  absence and overwrite each other (TOCTOU).

  ## Admission modes (`:admission` option)

  - `:fresh` (default) — reserve an **absent** run_id and publish. Concurrent
    losers receive `{:error, {:run_id_in_use, status}}` or
    `{:error, {:already_terminal, status}}` without mutating the winner.
  - `:resume` — require an existing `:recovering` claim and matching
    `execution_principal` (when stored), then publish while preserving the
    latest progress. Validation failures leave the stored record unchanged.

  Mid-run progress updates continue to use `put_run_state/3` (terminal-safe).
  """
  @spec admit_and_put_run_state(RunState.t(), map() | keyword(), keyword()) ::
          :ok | {:error, term()}
  def admit_and_put_run_state(%RunState{} = state, meta \\ %{}, opts \\ []) do
    admission = Keyword.get(opts, :admission, :fresh)
    call_server(opts, {:admit_and_put_run_state, state, meta, admission})
  end

  @spec touch_heartbeat(String.t(), DateTime.t() | nil, keyword()) :: :ok | {:error, term()}
  def touch_heartbeat(run_id, now \\ nil, opts \\ []) when is_binary(run_id) do
    call_server(opts, {:touch_heartbeat, run_id, now || DateTime.utc_now()})
  end

  @doc """
  Mark a pipeline interrupted (eligible for recovery).

  Local / application-restart interruption uses backend-first put under the
  journal lock. Remote-owner takeover on a `cross_node_atomic_recovery`
  backend publishes interrupted via generation+revision CAS so a concurrent
  survivor cannot overwrite another journal's recovering claim with an
  ordinary put. CAS conflicts refresh hot state from durable authority and
  return a typed error (coordinator must not enqueue losers).
  """
  @spec mark_interrupted(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_interrupted(run_id, opts \\ []) when is_binary(run_id) do
    call_server(opts, {:mark_interrupted, run_id})
  end

  @spec mark_abandoned(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_abandoned(run_id, opts \\ []) when is_binary(run_id) do
    call_server(opts, {:mark_abandoned, run_id})
  end

  @spec mark_recovering(String.t(), keyword()) :: :ok | {:error, term()}
  def mark_recovering(run_id, opts \\ []) when is_binary(run_id) do
    call_server(opts, {:mark_recovering, run_id})
  end

  @spec mark_failed(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def mark_failed(run_id, reason, opts \\ []) when is_binary(run_id) do
    call_server(opts, {:mark_failed, run_id, reason})
  end

  @doc """
  Atomically claim an `:interrupted` pipeline for recovery.

  Only interrupted records are claimable. On success status becomes
  `:recovering` and `owner_node` is set to this journal's local node
  (`claiming_node` must match that local node).

  Unfenced backends use backend-first put under the local GenServer lock.
  Fenced backends (`fenced_claim: true`) obtain the canonical structured
  `PersistenceRecord` and CAS generation+revision; a conflict refreshes
  hot state from durable authority without fabricating local ownership.
  """
  @spec claim_for_recovery(String.t(), node(), keyword()) ::
          {:ok, Record.t()} | {:error, term()}
  def claim_for_recovery(run_id, claiming_node \\ Kernel.node(), opts \\ [])
      when is_binary(run_id) do
    call_server(opts, {:claim_for_recovery, run_id, claiming_node})
  end

  @doc """
  Atomic nonterminal → terminal lifecycle transition.

  Reads the latest stored `Record`, preserves progress
  (`completed_count` / `completed_nodes` / `node_durations`), transitions
  once, and returns:

  - `{:ok, :transitioned, record}` — new terminal state published
  - `{:ok, :already_terminal, record}` — already in the **same** terminal status
  - `{:error, {:terminal_conflict, existing, requested}}` — already terminal
    with a **different** status (no mutation)
  - `{:error, reason}` — not found, unavailable, or durable failure

  `status` must be one of `:completed`, `:failed`, `:abandoned`, `:interrupted`.
  Optional `metadata` may supply progress / recovery fields used when they
  are *ahead of* the stored record (otherwise stored progress wins).
  Nil meta values never erase retained recovery pointers.
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
    call_server(opts, {:finalize, run_id, status, reason, duration_ms, metadata})
  end

  @doc """
  Explicit durability/backend diagnostics.

  Writes are backend-first when a backend is configured. Never reports
  crash durability for the default volatile/process-lifetime classes
  (ETS-only, Agent, async buffers). `durable: true` only when the
  configured class is `:application_restart` or `:node_restart` and the
  backend is healthy.
  """
  @spec durability_status(keyword()) :: map()
  def durability_status(opts \\ []) do
    call_server(opts, :durability_status)
  end

  @doc """
  Runtime refresh: upsert durable lifecycle rows into the hot journal.

  Uses the configured durable backend as authority and merges each decoded
  row into the private hot table **without boot-time normalization**. In
  particular, a local `:running` row is not rewritten to `:interrupted`
  merely because it is refreshed while the app is running.

  Runtime-only `spawning_pid` is preserved only when the durable owner and
  status still match the same local hot ownership. Remote rows and
  ownership/status changes clear the PID. Hot rows absent from one durable
  list result are **not** deleted.

  Backend/list/decode failures fail closed: return a bounded typed error,
  mark durability degraded, and leave hot state unchanged for that attempt
  (no partial upsert batch).

  Returns `{:ok, %{upserted: n}}` on success. Journals without a backend
  return `{:ok, %{upserted: 0}}`.
  """
  @spec refresh_from_durable(keyword()) ::
          {:ok, %{upserted: non_neg_integer()}} | {:error, term()}
  def refresh_from_durable(opts \\ []) do
    call_server(opts, :refresh_from_durable)
  end

  @doc """
  Import durable JSON-clean maps into the hot store (ops/tests).

  Running entries are normalized to `:interrupted` with runtime-only PID cleared.
  Prefer the real restart path (stop journal, restart against same backend)
  for durability proofs.
  """
  @spec import_durable_records([map()], keyword()) :: :ok | {:error, term()}
  def import_durable_records(maps, opts \\ []) when is_list(maps) do
    call_server(opts, {:import_durable, maps})
  end

  @doc """
  Public/runtime map view (non-JSON; may contain DateTime/atoms/PID).

  Returns `nil` when missing. On journal unavailability returns `nil`
  (diagnostics only — recovery must use `get_record/2`).
  """
  @spec get_raw(String.t(), keyword()) :: map() | nil
  def get_raw(run_id, opts \\ []) when is_binary(run_id) do
    case get_record(run_id, opts) do
      {:ok, %Record{} = record} -> Adapter.to_public_map(record)
      {:error, :not_found} -> nil
      {:error, :journal_unavailable} -> nil
      {:error, _} -> nil
    end
  end

  @doc """
  Typed internal get.

  Returns `{:ok, record}`, `{:error, :not_found}`, or
  `{:error, :journal_unavailable}` — never confuses outage with missing.
  """
  @spec get_record(String.t(), keyword()) ::
          {:ok, Record.t()}
          | {:error, :not_found}
          | {:error, :journal_unavailable}
          | {:error, term()}
  def get_record(run_id, opts \\ []) when is_binary(run_id) do
    case call_server(opts, {:get, run_id}) do
      %Record{} = record -> {:ok, record}
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Public/runtime map list (non-JSON). Returns `[]` on unavailability for
  dashboard diagnostics only.
  """
  @spec list_raw(keyword()) :: [map()]
  def list_raw(opts \\ []) do
    case list_records(opts) do
      {:ok, records} -> Enum.map(records, &Adapter.to_public_map/1)
      {:error, _} -> []
    end
  end

  @doc """
  Typed internal list.

  Returns `{:ok, records}` or `{:error, :journal_unavailable}`.
  """
  @spec list_records(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  def list_records(opts \\ []) do
    case call_server(opts, :list) do
      list when is_list(list) -> {:ok, list}
      {:error, _} = err -> err
    end
  end

  @doc "Persist a liveness correction to :interrupted (same source as visibility)."
  @spec persist_interrupted(String.t(), keyword()) :: map() | nil
  def persist_interrupted(run_id, opts \\ []) when is_binary(run_id) do
    case mark_interrupted(run_id, opts) do
      :ok -> get_raw(run_id, opts)
      {:error, _} -> get_raw(run_id, opts)
    end
  end

  @doc "Delete a hot entry (and durable key when backend configured). For tests/ops."
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(run_id, opts \\ []) when is_binary(run_id) do
    call_server(opts, {:delete, run_id})
  end

  @doc """
  Prepare a pending effect envelope for a run (owner API).

  When `current_effect` is `nil` or `settled`, increments `effect_generation`
  and writes a pending envelope via the backend-first `write_record` path.

  Returns:

  - `{:ok, :prepared, effect}` — new pending envelope written
  - `{:ok, :already_prepared, effect}` — exact retry of the same pending envelope
  - `{:error, reason}` — missing run, conflict, generation ceiling, malformed
    attrs, journal unavailable, or durable write failure (hot state unchanged)
  """
  @spec prepare_effect(String.t(), map(), keyword()) ::
          {:ok, :prepared | :already_prepared, map()} | {:error, term()}
  def prepare_effect(run_id, attrs, opts \\ [])
      when is_binary(run_id) and is_map(attrs) do
    call_server(opts, {:prepare_effect, run_id, attrs})
  end

  @doc """
  Record a completed effect receipt (owner API).

  Requires the current effect to be pending with the exact `generation` and
  `execution_id`. Writes a completed envelope; does not clear evidence.

  Returns:

  - `{:ok, :recorded, effect}` — receipt written
  - `{:ok, :already_recorded, effect}` — exact retry of the same receipt
  - `{:error, reason}` — conflict, missing run, malformed attrs, or durable failure
  """
  @spec record_effect_receipt(String.t(), pos_integer(), String.t(), map(), keyword()) ::
          {:ok, :recorded | :already_recorded, map()} | {:error, term()}
  def record_effect_receipt(run_id, generation, execution_id, attrs, opts \\ [])
      when is_binary(run_id) and is_integer(generation) and is_binary(execution_id) and
             is_map(attrs) do
    call_server(opts, {:record_effect_receipt, run_id, generation, execution_id, attrs})
  end

  @doc """
  Settle a completed effect (owner API).

  Requires the current effect to be completed with the exact `generation` and
  `execution_id`. Marks it settled without clearing receipt evidence. A later
  `prepare_effect/3` may replace only a settled effect and increments generation.
  """
  @spec settle_effect(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, :settled | :already_settled, map()} | {:error, term()}
  def settle_effect(run_id, generation, execution_id, opts \\ [])
      when is_binary(run_id) and is_integer(generation) and is_binary(execution_id) do
    call_server(opts, {:settle_effect, run_id, generation, execution_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    ets_table_name = Keyword.get(opts, :ets_table, @default_ets_table)
    table = create_hot_table!(ets_table_name)

    backend = Keyword.get(opts, :backend)
    store_name = Keyword.get(opts, :store_name, @default_store_name)
    collection = Keyword.get(opts, :collection, @default_collection)
    # Call options for the Persistence facade (name is injected by the facade).
    # Distinct from :store_child_opts, which are only for supervisor start_link.
    backend_opts = Keyword.get(opts, :backend_opts, [])

    durability_class = resolve_durability_class(backend, store_name, backend_opts, opts)

    durable_mode =
      if is_nil(backend) do
        :ets_only
      else
        :backed
      end

    state = %{
      table: table,
      ets_table_name: ets_table_name,
      durable_mode: durable_mode,
      durability_class: durability_class,
      backend: backend,
      store_name: store_name,
      collection: collection,
      backend_opts: backend_opts,
      durable_error: nil,
      last_write_error: nil,
      local_node: Keyword.get(opts, :local_node, Kernel.node())
    }

    # Configured backends are a separate supervisor child. Probe via the
    # Persistence facade and fail closed if the backend is not observable —
    # never start a journal with a silently empty hot view when backed.
    with :ok <- maybe_ensure_backend_ready(backend, store_name, backend_opts),
         {:ok, state} <- maybe_reload_from_durable(state) do
      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:put, %Record{} = record}, _from, state) do
    {reply, state} = write_record(record, state)
    {:reply, reply, state}
  end

  def handle_call({:put_run_state, %RunState{} = run_state, meta}, _from, state) do
    meta = normalize_meta(meta)

    case lookup_record(state.table, run_state.run_id) do
      %Record{status: status} = existing when status in @terminal_statuses ->
        # Never overwrite a terminal record with a nonterminal RunState snapshot.
        {:reply, {:error, {:already_terminal, existing.status}}, state}

      existing ->
        {reply, state} = put_run_state_unlocked(run_state, meta, existing, state)
        {:reply, reply, state}
    end
  end

  def handle_call(
        {:admit_and_put_run_state, %RunState{} = run_state, meta, admission},
        _from,
        state
      ) do
    meta = normalize_meta(meta)

    case admission do
      :fresh ->
        {reply, state} = admit_fresh_unlocked(run_state, meta, state)
        {:reply, reply, state}

      :resume ->
        {reply, state} = admit_resume_unlocked(run_state, meta, state)
        {:reply, reply, state}

      other ->
        {:reply, {:error, {:invalid_admission, other}}, state}
    end
  end

  def handle_call({:mark_interrupted, run_id}, _from, state) do
    {reply, state} = do_mark_interrupted(run_id, state)
    {:reply, reply, state}
  end

  def handle_call({:mark_abandoned, run_id}, _from, state) do
    now = DateTime.utc_now()

    {reply, state} =
      update_record(run_id, state, fn %Record{} = record ->
        if record.status in @terminal_statuses do
          record
        else
          %Record{
            record
            | status: :abandoned,
              current_node: nil,
              finished_at: record.finished_at || now
          }
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:mark_recovering, run_id}, _from, state) do
    # Non-claim path retained for diagnostics; prefer claim_for_recovery.
    {reply, state} =
      update_record(run_id, state, fn %Record{} = record ->
        if record.status in [:interrupted, :recovering] do
          %Record{record | status: :recovering}
        else
          record
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:mark_failed, run_id, reason}, _from, state) do
    now = DateTime.utc_now()
    bounded_reason = Adapter.bound_failure_reason(reason)

    {reply, state} =
      update_record(run_id, state, fn %Record{} = record ->
        if record.status in @terminal_statuses do
          record
        else
          %Record{
            record
            | status: :failed,
              failure_reason: bounded_reason,
              finished_at: record.finished_at || now,
              current_node: nil
          }
        end
      end)

    {:reply, reply, state}
  end

  def handle_call({:finalize, run_id, status, reason, duration_ms, metadata}, _from, state) do
    if status not in @finalize_statuses do
      {:reply, {:error, {:invalid_finalize_status, status}}, state}
    else
      meta = normalize_meta(metadata)

      case lookup_record(state.table, run_id) do
        nil ->
          seed = seed_record_from_meta(run_id, meta)
          finalized = apply_terminal(seed, status, reason, duration_ms, meta)

          case write_record(finalized, state) do
            {:ok, new_state} ->
              {:reply, {:ok, :transitioned, finalized}, new_state}

            {{:error, reason}, new_state} ->
              {:reply, {:error, reason}, new_state}
          end

        %Record{status: existing_status} = record when existing_status in @terminal_statuses ->
          if existing_status == status do
            {:reply, {:ok, :already_terminal, record}, state}
          else
            {:reply, {:error, {:terminal_conflict, existing_status, status}}, state}
          end

        %Record{} = record ->
          finalized = apply_terminal(record, status, reason, duration_ms, meta)

          case write_record(finalized, state) do
            {:ok, new_state} ->
              {:reply, {:ok, :transitioned, finalized}, new_state}

            {{:error, reason}, new_state} ->
              # Durable-first: hot unchanged — still nonterminal.
              {:reply, {:error, reason}, new_state}
          end
      end
    end
  end

  def handle_call({:claim_for_recovery, run_id, claiming_node}, _from, state) do
    {reply, state} = do_claim_for_recovery(run_id, claiming_node, state)
    {:reply, reply, state}
  end

  def handle_call(:durability_status, _from, state) do
    {:reply, build_durability_status(state), state}
  end

  def handle_call(:refresh_from_durable, _from, state) do
    {reply, state} = do_refresh_from_durable(state)
    {:reply, reply, state}
  end

  def handle_call({:import_durable, maps}, _from, state) do
    {state, errors} =
      Enum.reduce(maps, {state, []}, fn data, {st, errs} when is_map(data) ->
        record = boot_normalize(Adapter.from_durable_map(data))

        case write_record(record, st) do
          {:ok, st2} -> {st2, errs}
          {{:error, reason}, st2} -> {st2, [reason | errs]}
        end
      end)

    reply =
      case errors do
        [] -> :ok
        [reason | _] -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:touch_heartbeat, run_id, now}, _from, state) do
    {reply, state} =
      update_record(run_id, state, fn %Record{} = record ->
        %Record{record | last_heartbeat: now, last_ets_sync: now}
      end)

    {:reply, reply, state}
  end

  def handle_call({:get, run_id}, _from, state) do
    {:reply, lookup_record(state.table, run_id), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, list_all_records(state.table), state}
  end

  def handle_call({:delete, run_id}, _from, state) do
    # Durable-first: backend outage must not look like successful delete / not_found.
    case maybe_durable_delete(run_id, state) do
      {:ok, state} ->
        true = :ets.delete(state.table, run_id)
        {:reply, :ok, state}

      {:error, reason, state} ->
        {:reply, {:error, {:durable_delete_failed, reason}}, state}
    end
  end

  def handle_call({:prepare_effect, run_id, attrs}, _from, state) do
    {reply, state} = do_prepare_effect(run_id, attrs, state)
    {:reply, reply, state}
  end

  def handle_call({:record_effect_receipt, run_id, generation, execution_id, attrs}, _from, state) do
    {reply, state} = do_record_effect_receipt(run_id, generation, execution_id, attrs, state)
    {:reply, reply, state}
  end

  def handle_call({:settle_effect, run_id, generation, execution_id}, _from, state) do
    {reply, state} = do_settle_effect(run_id, generation, execution_id, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    # Hot table is process-owned — ETS cleanup is automatic on process death.
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp call_server(opts, request) do
    server = Keyword.get(opts, :server, __MODULE__)

    try do
      GenServer.call(server, request)
    catch
      :exit, {:noproc, _} ->
        unavailable_reply(request)

      :exit, reason ->
        case request do
          :durability_status ->
            %{
              mode: :unavailable,
              durable: false,
              durability_class: :volatile,
              backend: nil,
              store: @default_store_name,
              last_error: reason,
              fenced_claim: false,
              cross_node_atomic_recovery: false
            }

          _ ->
            {:error, :journal_unavailable}
        end
    end
  end

  defp unavailable_reply(:durability_status) do
    %{
      mode: :unavailable,
      durable: false,
      durability_class: :volatile,
      backend: nil,
      store: @default_store_name,
      last_error: :journal_unavailable,
      fenced_claim: false,
      cross_node_atomic_recovery: false
    }
  end

  defp unavailable_reply(_request), do: {:error, :journal_unavailable}

  defp create_hot_table!(name) when is_atom(name) do
    case :ets.info(name) do
      :undefined ->
        :ets.new(name, [
          :set,
          :private,
          :named_table,
          read_concurrency: true
        ])

      _info ->
        raise ArgumentError,
              "lifecycle ETS table #{inspect(name)} already exists; " <>
                "RunJournal must own a private table that dies with it"
    end
  end

  defp create_hot_table!(_), do: :ets.new(:run_journal_hot, [:set, :private])

  defp maybe_ensure_backend_ready(nil, _store_name, _backend_opts), do: :ok

  defp maybe_ensure_backend_ready(backend, store_name, backend_opts) when is_atom(backend) do
    # A configured backend must be observable or startup fails closed.
    case probe_backend(backend, store_name, backend_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:durable_backend_not_ready, backend, store_name, reason}}
    end
  end

  defp maybe_ensure_backend_ready(backend, store_name, _backend_opts) do
    {:error, {:invalid_durable_backend, backend, store_name}}
  end

  # Observe the separately supervised backend through the Persistence facade only.
  defp probe_backend(backend, store_name, backend_opts) do
    case Arbor.Persistence.list(store_name, backend, backend_opts) do
      {:ok, keys} when is_list(keys) ->
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_list_result, other}}
    end
  rescue
    e ->
      {:error, {:backend_probe_raised, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:backend_probe_exit, reason}}
  end

  defp maybe_reload_from_durable(%{durable_mode: :backed} = state) do
    reload_from_durable(state)
  end

  defp maybe_reload_from_durable(state), do: {:ok, state}

  # Fail closed on rehydrate: never start durable mode with a silently empty
  # hot view when the backend cannot be listed/read. Identity binding (listed
  # key / envelope key / payload run_id) is required before any hot insert.
  #
  # Local/dead-owner in-flight → :interrupted normalization is **backend-first**:
  # the durable row is corrected before hot publish so runtime refresh cannot
  # re-import a stale :running status after boot. Remote-owner rows are never
  # rewritten (L4 fenced recovery).
  defp reload_from_durable(state) do
    case durable_list_keys(state) do
      {:ok, keys} when is_list(keys) ->
        Enum.reduce_while(keys, {:ok, state}, fn key, {:ok, st} ->
          case durable_fetch_raw(key, st) do
            {:ok, raw} ->
              case bind_and_decode_lifecycle_row(key, raw, st.local_node, :boot) do
                {:ok, record} ->
                  case publish_boot_normalized_row(key, raw, record, st) do
                    {:ok, published, st2} ->
                      hot_insert(st2.table, published)
                      {:cont, {:ok, st2}}

                    {:error, reason, _st2} ->
                      # Fail closed: never publish a fabricated hot-only interrupt.
                      {:halt, {:error, bound_rehydrate_error(key, reason)}}
                  end

                {:error, reason} ->
                  # Fail closed: never drop/normalize corrupt or miskeyed rows.
                  {:halt, {:error, bound_rehydrate_error(key, reason)}}
              end

            {:error, :not_found} ->
              {:cont, {:ok, st}}

            {:error, reason} ->
              {:halt, {:error, {:durable_rehydrate_failed, key, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:durable_rehydrate_list_failed, reason}}
    end
  rescue
    e ->
      {:error, {:durable_rehydrate_raised, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:durable_rehydrate_exit, reason}}

    :throw, reason ->
      {:error, {:durable_rehydrate_throw, bound_effect_reason(reason)}}
  end

  # Runtime refresh (L4B2): durable is authority for row content, but unlike
  # boot rehydrate we do **not** rewrite in-flight statuses to :interrupted
  # and we never delete hot rows missing from a single list snapshot.
  # Collect + validate the full batch first so a mid-batch failure cannot leave
  # a partial upsert view of durable authority.
  defp do_refresh_from_durable(%{backend: nil} = state) do
    {{:ok, %{upserted: 0}}, state}
  end

  defp do_refresh_from_durable(%{durable_mode: :ets_only} = state) do
    {{:ok, %{upserted: 0}}, state}
  end

  defp do_refresh_from_durable(state) do
    case collect_runtime_refresh_batch(state) do
      {:ok, records} ->
        Enum.each(records, fn %Record{} = record ->
          hot_insert(state.table, record)
        end)

        healthy = %{
          state
          | durable_error: nil,
            last_write_error: nil,
            durable_mode: :backed
        }

        {{:ok, %{upserted: length(records)}}, healthy}

      {:error, reason} ->
        bound = bound_runtime_refresh_error(reason)

        degraded = %{
          state
          | durable_error: bound,
            last_write_error: bound,
            durable_mode: :degraded
        }

        {{:error, bound}, degraded}
    end
  rescue
    e ->
      bound = bound_runtime_refresh_error({:refresh_raised, Exception.message(e)})

      degraded = %{
        state
        | durable_error: bound,
          last_write_error: bound,
          durable_mode: :degraded
      }

      {{:error, bound}, degraded}
  catch
    :exit, reason ->
      bound = bound_runtime_refresh_error({:refresh_exit, reason})

      degraded = %{
        state
        | durable_error: bound,
          last_write_error: bound,
          durable_mode: :degraded
      }

      {{:error, bound}, degraded}

    :throw, reason ->
      bound = bound_runtime_refresh_error({:refresh_throw, reason})

      degraded = %{
        state
        | durable_error: bound,
          last_write_error: bound,
          durable_mode: :degraded
      }

      {{:error, bound}, degraded}
  end

  defp collect_runtime_refresh_batch(state) do
    case durable_list_keys(state) do
      {:ok, keys} when is_list(keys) ->
        Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
          case durable_fetch_raw(key, state) do
            {:ok, raw} ->
              case bind_and_decode_lifecycle_row(key, raw, state.local_node, :runtime) do
                {:ok, %Record{} = decoded} ->
                  hot = lookup_record(state.table, decoded.run_id)
                  merged = maybe_preserve_local_spawning_pid(decoded, hot, state.local_node)
                  {:cont, {:ok, [merged | acc]}}

                {:error, reason} ->
                  # Fail closed before any hot write — no partial batch upsert.
                  {:halt, {:error, bound_rehydrate_error(key, reason)}}
              end

            {:error, :not_found} ->
              # List/get race — skip missing key; never delete hot for absence.
              {:cont, {:ok, acc}}

            {:error, reason} ->
              {:halt, {:error, {:durable_refresh_failed, bound_refresh_key(key), reason}}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, {:durable_refresh_list_failed, reason}}
    end
  end

  # Preserve runtime PID only when durable *owner* (authoritative) and status still
  # match the same local hot ownership. source_node is origin provenance only —
  # a remote source with local owner after takeover must not clear a live PID.
  defp maybe_preserve_local_spawning_pid(%Record{} = decoded, hot, local_node) do
    case hot do
      %Record{spawning_pid: pid} = existing when is_pid(pid) ->
        local = to_string(local_node)
        hot_owner = existing.owner_node && to_string(existing.owner_node)
        durable_owner = decoded.owner_node && to_string(decoded.owner_node)

        same_local_ownership? =
          hot_owner != nil and
            hot_owner == local and
            durable_owner == local and
            decoded.status == existing.status

        if same_local_ownership? do
          %Record{decoded | spawning_pid: pid}
        else
          decoded
        end

      _ ->
        decoded
    end
  end

  defp bound_runtime_refresh_error(reason) do
    case reason do
      {:durable_refresh_list_failed, detail} ->
        {:durable_refresh_list_failed, bound_effect_reason(detail)}

      {:durable_refresh_failed, key, detail} ->
        {:durable_refresh_failed, bound_refresh_key(key), bound_effect_reason(detail)}

      {:durable_rehydrate_invalid_effect, key, detail} ->
        {:durable_refresh_invalid_effect, bound_refresh_key(key), bound_effect_reason(detail)}

      {:durable_rehydrate_identity_mismatch, key, detail} ->
        {:durable_refresh_identity_mismatch, bound_refresh_key(key), detail}

      {:durable_rehydrate_failed, key, detail} ->
        {:durable_refresh_failed, bound_refresh_key(key), bound_effect_reason(detail)}

      {:refresh_raised, msg} when is_binary(msg) ->
        {:durable_refresh_raised, bound_effect_reason(msg)}

      {:refresh_exit, detail} ->
        {:durable_refresh_exit, bound_effect_reason(detail)}

      {:refresh_throw, detail} ->
        {:durable_refresh_throw, bound_effect_reason(detail)}

      other ->
        bound_effect_reason(other)
    end
  end

  defp bound_refresh_key(key) do
    cond do
      is_binary(key) and byte_size(key) <= 256 -> key
      is_binary(key) -> binary_part(key, 0, 256)
      true -> "unknown"
    end
  end

  # Shared durable read validation for boot rehydrate and runtime refresh:
  # listed key K, structured envelope key, and decoded lifecycle run_id must
  # all match exactly. Legacy raw maps are accepted only when payload run_id == K.
  defp bind_and_decode_lifecycle_row(listed_key, raw, local_node, mode)
       when is_binary(listed_key) and mode in [:boot, :runtime] do
    with {:ok, envelope_key, payload} <- unwrap_durable_payload(listed_key, raw),
         :ok <- require_exact_key(listed_key, envelope_key, :envelope_key_mismatch),
         record = Adapter.from_durable_map(payload),
         {:ok, %Record{} = validated} <- Adapter.validate_and_normalize_record(record),
         :ok <- require_exact_key(listed_key, validated.run_id, :run_id_key_mismatch) do
      cleared = %Record{validated | spawning_pid: nil}

      case mode do
        :boot -> {:ok, boot_normalize(cleared, local_node)}
        :runtime -> {:ok, cleared}
      end
    else
      {:error, _} = err -> err
    end
  end

  defp bind_and_decode_lifecycle_row(_listed_key, _raw, _local_node, _mode),
    do: {:error, :invalid_listed_key}

  defp unwrap_durable_payload(_listed_key, %PersistenceRecord{key: env_key, data: data})
       when is_map(data) and is_binary(env_key) do
    {:ok, env_key, data}
  end

  defp unwrap_durable_payload(_listed_key, %PersistenceRecord{}) do
    {:error, :unstructured_durable_record}
  end

  defp unwrap_durable_payload(listed_key, data) when is_map(data) do
    cond do
      # Serialized structured envelope: %{"key" => ..., "data" => lifecycle_map}
      (Map.has_key?(data, "key") or Map.has_key?(data, :key)) and
          is_map(Map.get(data, "data") || Map.get(data, :data)) ->
        env_key = Map.get(data, "key") || Map.get(data, :key)
        inner = Map.get(data, "data") || Map.get(data, :data)

        if is_binary(env_key) do
          {:ok, env_key, inner}
        else
          {:error, :invalid_envelope_key}
        end

      # Legacy raw lifecycle map: envelope key is the listed key only when
      # payload run_id will also match (checked after decode).
      Map.has_key?(data, "run_id") or Map.has_key?(data, :run_id) ->
        {:ok, listed_key, data}

      true ->
        case Map.get(data, :data) || Map.get(data, "data") do
          inner when is_map(inner) ->
            {:ok, listed_key, inner}

          _ ->
            {:error, :unstructured_durable_record}
        end
    end
  end

  defp unwrap_durable_payload(_listed_key, _raw), do: {:error, :unstructured_durable_record}

  defp require_exact_key(expected, actual, _tag) when expected == actual, do: :ok
  defp require_exact_key(_expected, _actual, tag), do: {:error, tag}

  defp bound_rehydrate_error(key, reason) do
    bounded_key =
      cond do
        is_binary(key) and byte_size(key) <= 256 -> key
        is_binary(key) -> binary_part(key, 0, 256)
        true -> "unknown"
      end

    case reason do
      {:invalid_current_effect, detail} ->
        {:durable_rehydrate_invalid_effect, bounded_key, bound_effect_reason(detail)}

      {:invalid_effect_generation, detail} ->
        {:durable_rehydrate_invalid_effect, bounded_key, bound_effect_reason(detail)}

      :envelope_key_mismatch ->
        {:durable_rehydrate_identity_mismatch, bounded_key, :envelope_key_mismatch}

      :run_id_key_mismatch ->
        {:durable_rehydrate_identity_mismatch, bounded_key, :run_id_key_mismatch}

      other ->
        {:durable_rehydrate_failed, bounded_key, bound_effect_reason(other)}
    end
  end

  defp bound_effect_reason(reason) when is_atom(reason), do: reason

  defp bound_effect_reason({a, b}) when is_atom(a) and is_atom(b), do: {a, b}

  defp bound_effect_reason(reason) when is_binary(reason) do
    if byte_size(reason) <= 128, do: reason, else: binary_part(reason, 0, 128)
  end

  defp bound_effect_reason(_), do: :invalid_effect

  # Boot-normalize rehydrated rows. Do **not** rewrite in-flight rows owned or
  # sourced by another potentially-live node — leave them for L4 fenced recovery.
  # Only normalize records proven local (or ownerless/dead-local).
  #
  # Status rewrites must be published durable-first via
  # `publish_boot_normalized_row/4` before hot insert.
  defp boot_normalize(%Record{} = record, local_node) do
    record = %Record{record | spawning_pid: nil}

    cond do
      record.status not in @ownerless_inflight_statuses ->
        record

      remote_ownership?(record, local_node) ->
        # Preserve owner/source metadata for L4; do not claim or rewrite status.
        record

      true ->
        # Local/dead-owner rehydrate: claimable interrupted. Stamp source_node to
        # local when missing so backed journals do not treat the row as ambiguous.
        %Record{
          record
          | status: :interrupted,
            current_node: nil,
            owner_node: nil,
            source_node: record.source_node || local_node
        }
    end
  end

  # Import path (tests/ops) uses the local-node view.
  defp boot_normalize(%Record{} = record) do
    boot_normalize(record, Kernel.node())
  end

  # When boot_normalize rewrote a local/dead-owner in-flight row to
  # :interrupted, persist that correction before hot publish. Remote rows and
  # rows that did not change status are left durable-as-is.
  defp publish_boot_normalized_row(key, raw, %Record{} = normalized, state)
       when is_binary(key) do
    case bind_and_decode_lifecycle_row(key, raw, state.local_node, :runtime) do
      {:ok, %Record{} = original} ->
        cond do
          remote_ownership?(original, state.local_node) ->
            # Never ordinary-put or CAS-rewrite remote ownership at boot.
            {:ok, normalized, state}

          not needs_durable_boot_interrupt?(original, normalized) ->
            {:ok, normalized, state}

          true ->
            durable_publish_boot_interrupt(key, raw, original, normalized, state)
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp needs_durable_boot_interrupt?(%Record{} = original, %Record{} = normalized) do
    original.status in @ownerless_inflight_statuses and
      normalized.status == :interrupted and
      original.status != :interrupted
  end

  # Backend-first local interrupt at boot. Prefer structured PersistenceRecord
  # CAS when available so a concurrent durable update cannot be last-write-wins
  # overwritten. Legacy/raw maps and non-CAS backends use ordinary put only for
  # proven-local rows. Conflicts refresh durable authority or fail closed —
  # never fabricate a hot-only normalized row.
  defp durable_publish_boot_interrupt(
         key,
         raw,
         %Record{} = original,
         %Record{} = interrupted,
         state
       ) do
    if remote_ownership?(original, state.local_node) do
      {:error, :boot_normalize_remote_rewrite_refused, state}
    else
      case try_boot_interrupt_write(key, raw, interrupted, state) do
        {:ok, %Record{} = stored, new_state} ->
          {:ok, stored, new_state}

        {:error, :conflict, new_state} ->
          resolve_boot_interrupt_conflict(key, new_state)

        {:error, reason, new_state} ->
          {:error, reason, new_state}
      end
    end
  end

  defp try_boot_interrupt_write(key, raw, %Record{} = interrupted, state) do
    case structured_cas_expected(raw, key, state) do
      {:ok, %PersistenceRecord{} = expected} ->
        cas_lifecycle_update(expected, interrupted, state, :interrupt)

      :not_structured ->
        # Legacy/raw or unfenced backend: local ordinary put only.
        case write_record(interrupted, state) do
          {:ok, new_state} ->
            {:ok, interrupted, new_state}

          {{:error, reason}, new_state} ->
            {:error, reason, new_state}
        end
    end
  end

  # Structured versioned PersistenceRecord + CAS-capable backend → fence the
  # boot interrupt. Otherwise fall back to ordinary put for local rows only.
  defp structured_cas_expected(
         %PersistenceRecord{generation: gen, revision: rev, key: env_key} = record,
         key,
         state
       )
       when is_integer(gen) and gen >= 1 and is_integer(rev) and rev >= 1 and is_binary(env_key) and
              env_key == key do
    backend = state.backend

    if not is_nil(backend) and Arbor.Persistence.supports_compare_and_swap?(backend) do
      {:ok, record}
    else
      :not_structured
    end
  end

  defp structured_cas_expected(_raw, _key, _state), do: :not_structured

  # After a CAS conflict, durable authority wins. Accept the refreshed row when
  # it no longer needs a local boot interrupt; otherwise fail closed rather than
  # last-write-wins a fabricated normalized status.
  defp resolve_boot_interrupt_conflict(key, state) do
    case durable_fetch_raw(key, state) do
      {:ok, raw} ->
        case bind_and_decode_lifecycle_row(key, raw, state.local_node, :runtime) do
          {:ok, %Record{} = durable} ->
            if needs_local_boot_interrupt?(durable, state.local_node) do
              # Still local in-flight after concurrent write — one CAS/put retry
              # against the new expected, then fail closed.
              interrupted = boot_normalize(durable, state.local_node)

              case try_boot_interrupt_write(key, raw, interrupted, state) do
                {:ok, %Record{} = stored, new_state} ->
                  {:ok, stored, new_state}

                {:error, :conflict, new_state} ->
                  {:error, :boot_interrupt_conflict, new_state}

                {:error, reason, new_state} ->
                  {:error, reason, new_state}
              end
            else
              # Already interrupted / recovering / terminal / remote — use durable.
              {:ok, durable, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp needs_local_boot_interrupt?(%Record{} = record, local_node) do
    record.status in @ownerless_inflight_statuses and
      not remote_ownership?(record, local_node)
  end

  # owner_node is authoritative when present. source_node is origin provenance
  # only and decides remote-ness solely when owner_node is nil (e.g. post-claim
  # interrupted rows may keep a remote source while owner is local).
  defp remote_ownership?(%Record{} = record, local_node) do
    local = to_string(local_node)

    cond do
      not is_nil(record.owner_node) ->
        to_string(record.owner_node) != local

      not is_nil(record.source_node) ->
        to_string(record.source_node) != local

      true ->
        false
    end
  end

  # Claim eligibility for interrupted rows.
  #
  # - claiming_node must always be this journal's local node (no claim-on-behalf).
  # - Unfenced / application-restart paths fail closed for remote owner/source.
  # - node_restart + CAS (`cross_node_atomic_recovery`) may claim remote-source
  #   or remote-owned interrupted rows via durable fencing.
  # - Backed rows missing both owner and source remain ambiguous forever.
  defp claim_eligibility(%Record{} = record, claiming_node, state) do
    local = to_string(state.local_node)
    claimer = to_string(claiming_node)
    backed? = state.durable_mode in [:backed, :degraded] and not is_nil(state.backend)
    cross_node? = cross_node_atomic_recovery_enabled?(state)

    cond do
      # Never allow a caller to claim as an arbitrary remote node.
      claimer != local ->
        {:error, :cross_node_claim_unfenced}

      # Foreign owner: only the distributed fenced path may take over.
      not is_nil(record.owner_node) and to_string(record.owner_node) != claimer and
          not cross_node? ->
        {:error, :remote_or_foreign_claim}

      # Remote source with empty owner — fail closed unless distributed fencing.
      is_nil(record.owner_node) and not is_nil(record.source_node) and
        to_string(record.source_node) != local and to_string(record.source_node) != claimer and
          not cross_node? ->
        {:error, :ambiguous_remote_row}

      # Backed store with no ownership provenance at all remains ambiguous.
      backed? and is_nil(record.owner_node) and is_nil(record.source_node) ->
        {:error, :ambiguous_remote_row}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # mark_interrupted — local put vs remote-owner CAS takeover
  # ---------------------------------------------------------------------------

  defp do_mark_interrupted(run_id, state) do
    case lookup_record(state.table, run_id) do
      nil ->
        {{:error, :not_found}, state}

      %Record{} = record ->
        if fenced_remote_interrupt?(record, state) do
          fenced_mark_interrupted(run_id, state)
        else
          local_mark_interrupted(run_id, state)
        end
    end
  end

  # Remote-owner in-flight rows on node_restart+CAS must not use ordinary put:
  # a stale put can overwrite a concurrent recovering claim.
  defp fenced_remote_interrupt?(%Record{} = record, state) do
    cross_node_atomic_recovery_enabled?(state) and
      remote_takeover_record?(record, state.local_node)
  end

  # Owner is authoritative when present. Ownerless rows retain source provenance;
  # a remote source must still take the CAS path so stale hot state cannot use an
  # ordinary put to revert a recovering durable row.
  defp remote_takeover_record?(%Record{owner_node: nil, source_node: nil}, _local_node),
    do: false

  defp remote_takeover_record?(%Record{owner_node: nil, source_node: source}, local_node) do
    to_string(source) != to_string(local_node)
  end

  defp remote_takeover_record?(%Record{owner_node: owner}, local_node) do
    to_string(owner) != to_string(local_node)
  end

  defp local_mark_interrupted(run_id, state) do
    update_record(run_id, state, fn %Record{} = record ->
      if record.status in [:running, :degraded, :suspended, :recovering] do
        %Record{
          record
          | status: :interrupted,
            current_node: nil,
            owner_node: nil
        }
      else
        record
      end
    end)
  end

  # CAS in-flight remote-owned rows to interrupted. Never overwrite recovering
  # or terminal durable authority with an ordinary interrupt put.
  defp fenced_mark_interrupted(run_id, state) do
    case durable_get_structured_record(run_id, state) do
      {:ok, %PersistenceRecord{} = expected} ->
        case decode_lifecycle_from_persistence(expected) do
          {:ok, %Record{} = durable} ->
            cond do
              durable.status in [:running, :degraded, :suspended] and
                  remote_takeover_record?(durable, state.local_node) ->
                interrupted = %Record{
                  durable
                  | status: :interrupted,
                    current_node: nil,
                    owner_node: nil
                }

                case cas_lifecycle_update(expected, interrupted, state, :interrupt) do
                  {:ok, %Record{} = stored, new_state} ->
                    hot_insert(new_state.table, stored)
                    {:ok, new_state}

                  {:error, :conflict, new_state} ->
                    refresh_hot_after_fence_conflict(run_id, new_state, :interrupt_conflict)

                  {:error, reason, new_state} ->
                    {{:error, reason}, new_state}
                end

              true ->
                # Already interrupted/recovering/terminal or ownership changed —
                # refresh hot; never clobber durable with a stale interrupt put.
                hot_insert(state.table, durable)
                {{:error, :interrupt_conflict}, state}
            end

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp do_claim_for_recovery(run_id, claiming_node, state) do
    case lookup_record(state.table, run_id) do
      nil ->
        {{:error, :not_found}, state}

      %Record{} = record ->
        case record.status do
          :interrupted ->
            case claim_eligibility(record, claiming_node, state) do
              :ok ->
                if fenced_claim_enabled?(state) do
                  fenced_claim_for_recovery(record, claiming_node, state)
                else
                  local_claim_for_recovery(record, claiming_node, state)
                end

              {:error, reason} ->
                {{:error, reason}, state}
            end

          other ->
            {{:error, {:invalid_status, other}}, state}
        end
    end
  end

  defp local_claim_for_recovery(%Record{} = record, claiming_node, state) do
    updated = %Record{record | owner_node: claiming_node, status: :recovering}

    case write_record(updated, state) do
      {:ok, new_state} ->
        {{:ok, updated}, new_state}

      {{:error, reason}, new_state} ->
        # Backend-first: prior interrupted record still in hot table.
        {{:error, reason}, new_state}
    end
  end

  # Fenced claim: durable structured PersistenceRecord is the authority.
  # CAS generation+revision elects exactly one concurrent winner.
  defp fenced_claim_for_recovery(%Record{} = hot_record, claiming_node, state) do
    run_id = hot_record.run_id

    case durable_get_structured_record(run_id, state) do
      {:ok, %PersistenceRecord{} = expected} ->
        case decode_lifecycle_from_persistence(expected) do
          {:ok, %Record{status: :interrupted} = durable_lifecycle} ->
            case claim_eligibility(durable_lifecycle, claiming_node, state) do
              :ok ->
                claimed = %Record{
                  durable_lifecycle
                  | owner_node: claiming_node,
                    status: :recovering
                }

                case cas_lifecycle_update(expected, claimed, state, :claim) do
                  {:ok, %Record{} = stored_lifecycle, new_state} ->
                    hot_insert(new_state.table, stored_lifecycle)
                    {{:ok, stored_lifecycle}, new_state}

                  {:error, :conflict, new_state} ->
                    refresh_hot_after_fence_conflict(run_id, new_state, :claim_conflict)

                  {:error, reason, new_state} ->
                    {{:error, reason}, new_state}
                end

              {:error, reason} ->
                # Durable authority disagrees with hot eligibility — refresh hot.
                hot_insert(state.table, durable_lifecycle)
                {{:error, reason}, state}
            end

          {:ok, %Record{status: other} = durable_lifecycle} ->
            hot_insert(state.table, durable_lifecycle)
            {{:error, {:invalid_status, other}}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp cas_lifecycle_update(%PersistenceRecord{} = expected, %Record{} = next, state, kind)
       when kind in [:claim, :interrupt] do
    case Adapter.to_durable_map(next) do
      {:ok, payload} ->
        replacement =
          PersistenceRecord.new(expected.key, payload,
            metadata: expected.metadata || %{"collection" => state.collection}
          )

        backend_opts = Map.get(state, :backend_opts, [])

        case Arbor.Persistence.compare_and_swap(
               state.store_name,
               state.backend,
               expected.key,
               {:value, expected},
               replacement,
               backend_opts
             ) do
          {:ok, %PersistenceRecord{} = stored} ->
            case decode_lifecycle_from_persistence(stored) do
              {:ok, %Record{} = lifecycle} ->
                {:ok, lifecycle,
                 %{state | last_write_error: nil, durable_error: nil, durable_mode: :backed}}

              {:error, reason} ->
                {:error, {:durable_decode_failed, reason}, state}
            end

          {:error, :conflict} ->
            {:error, :conflict, state}

          {:error, :unsupported} ->
            {:error, :fenced_claim_unsupported, state}

          {:error, reason} ->
            Logger.warning(
              "[RunJournal] fenced #{kind} CAS failed for #{next.run_id}: #{inspect(reason)}"
            )

            {:error, {:durable_write_failed, reason},
             %{
               state
               | last_write_error: reason,
                 durable_error: reason,
                 durable_mode: :degraded
             }}

          other ->
            {:error, {:unexpected_cas_result, other}, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  rescue
    e ->
      reason = Exception.message(e)

      {:error, {:durable_write_failed, reason},
       %{
         state
         | last_write_error: reason,
           durable_error: reason,
           durable_mode: :degraded
       }}
  catch
    :exit, reason ->
      {:error, {:durable_write_failed, reason},
       %{
         state
         | last_write_error: reason,
           durable_error: reason,
           durable_mode: :degraded
       }}
  end

  defp refresh_hot_after_fence_conflict(run_id, state, error_tag)
       when error_tag in [:claim_conflict, :interrupt_conflict] do
    case durable_get_structured_record(run_id, state) do
      {:ok, %PersistenceRecord{} = pr} ->
        case decode_lifecycle_from_persistence(pr) do
          {:ok, %Record{} = lifecycle} ->
            hot_insert(state.table, lifecycle)
            {{:error, error_tag}, state}

          {:error, reason} ->
            {{:error, {error_tag, reason}}, state}
        end

      {:error, reason} ->
        {{:error, {error_tag, reason}}, state}
    end
  end

  # Structured Record CAS requires a versioned PersistenceRecord. Legacy plain
  # maps / gen0 placeholders are not distributed-fenced current records.
  defp durable_get_structured_record(key, %{backend: backend, store_name: store_name} = state)
       when not is_nil(backend) do
    backend_opts = Map.get(state, :backend_opts, [])

    case Arbor.Persistence.get(store_name, backend, key, backend_opts) do
      {:ok, %PersistenceRecord{generation: gen, revision: rev} = record}
      when is_integer(gen) and gen >= 1 and is_integer(rev) and rev >= 1 ->
        if is_binary(record.key) and record.key == key do
          {:ok, record}
        else
          {:error, :unstructured_durable_record}
        end

      {:ok, %PersistenceRecord{}} ->
        {:error, :unfenced_durable_record}

      {:ok, _other} ->
        {:error, :unstructured_durable_record}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:durable_unavailable, reason}}

      other ->
        {:error, {:unexpected_durable_value, other}}
    end
  rescue
    e ->
      {:error, {:durable_unavailable, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:durable_unavailable, reason}}
  end

  defp durable_get_structured_record(_key, _state), do: {:error, :not_found}

  defp decode_lifecycle_from_persistence(%PersistenceRecord{data: data}) when is_map(data) do
    record = Adapter.from_durable_map(data)

    case Adapter.validate_and_normalize_record(record) do
      {:ok, %Record{} = validated} ->
        # Runtime-only PID must not re-enter hot state from durable authority.
        {:ok, %Record{validated | spawning_pid: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_lifecycle_from_persistence(_), do: {:error, :unstructured_durable_record}

  defp fenced_claim_enabled?(state) do
    class = Map.get(state, :durability_class, :volatile)
    backend = state.backend

    durable_class?(class) and healthy_backend?(state) and not is_nil(backend) and
      Arbor.Persistence.supports_compare_and_swap?(backend)
  end

  defp cross_node_atomic_recovery_enabled?(state) do
    fenced_claim_enabled?(state) and Map.get(state, :durability_class) == :node_restart
  end

  # Fresh admission + first publish in one owner critical section.
  defp admit_fresh_unlocked(%RunState{} = run_state, meta, state) do
    case lookup_record(state.table, run_state.run_id) do
      nil ->
        put_run_state_unlocked(run_state, meta, nil, state)

      %Record{status: status} when status in @terminal_statuses ->
        {{:error, {:already_terminal, status}}, state}

      %Record{status: status} ->
        # Loser: do not mutate winner identity/progress.
        {{:error, {:run_id_in_use, status}}, state}
    end
  end

  # Resume/recovery publication revalidates claim + principal at the owner,
  # never relying solely on an earlier Engine read.
  defp admit_resume_unlocked(%RunState{} = run_state, meta, state) do
    case lookup_record(state.table, run_state.run_id) do
      nil ->
        {{:error, :not_found}, state}

      %Record{status: status} when status in @terminal_statuses ->
        {{:error, {:already_terminal, status}}, state}

      %Record{status: status} when status != :recovering ->
        {{:error, {:invalid_resume_status, status}}, state}

      %Record{status: :recovering} = existing ->
        case match_execution_principal(existing, meta) do
          :ok ->
            put_run_state_unlocked(run_state, meta, existing, state)

          {:error, _} = err ->
            {err, state}
        end
    end
  end

  defp match_execution_principal(%Record{} = existing, meta) when is_map(meta) do
    stored = existing.execution_principal
    incoming = Map.get(meta, :execution_principal)

    cond do
      is_binary(stored) and stored != "" and is_binary(incoming) and stored == incoming ->
        :ok

      is_binary(stored) and stored != "" ->
        {:error, :execution_principal_mismatch}

      true ->
        # Legacy rows without a stored principal: resume still requires
        # checkpoint HMAC / identity separately; do not invent a principal.
        :ok
    end
  end

  defp put_run_state_unlocked(%RunState{} = run_state, meta, existing, state) do
    preserved =
      if existing do
        existing
      else
        %Record{run_id: run_state.run_id, pipeline_id: run_state.run_id}
      end

    %Record{} = from_state = Adapter.from_run_state(run_state, meta)

    # Prefer the richer progress between process-local state and journal.
    progress = prefer_progress(from_state, preserved)

    record =
      %Record{
        from_state
        | completed_count: progress.completed_count,
          completed_nodes: progress.completed_nodes,
          node_durations: progress.node_durations,
          current_node: from_state.current_node || preserved.current_node,
          graph_hash: from_state.graph_hash || preserved.graph_hash,
          dot_source_path: from_state.dot_source_path || preserved.dot_source_path,
          logs_root: from_state.logs_root || preserved.logs_root,
          execution_principal: from_state.execution_principal || preserved.execution_principal,
          origin_trust_zone: from_state.origin_trust_zone || preserved.origin_trust_zone,
          owner_node: from_state.owner_node || preserved.owner_node,
          source_node: from_state.source_node || preserved.source_node,
          started_at: from_state.started_at || preserved.started_at,
          # Effect evidence is journal-owned — never reset from RunState (always 0/nil).
          effect_generation: preserved.effect_generation || 0,
          current_effect: preserved.current_effect
      }
      |> Adapter.merge_meta(meta)

    write_record(record, state)
  end

  # ---------------------------------------------------------------------------
  # Effect owner operations (backend-first via write_record/2 when configured)
  # ---------------------------------------------------------------------------

  defp do_prepare_effect(run_id, attrs, state) do
    case lookup_record(state.table, run_id) do
      nil ->
        {{:error, :not_found}, state}

      %Record{} = record ->
        case record.current_effect do
          nil ->
            prepare_new_effect(record, attrs, state)

          %{"status" => "settled"} ->
            prepare_new_effect(record, attrs, state)

          %{"status" => "pending"} = pending ->
            case normalize_effect_attrs(attrs) do
              {:ok, normalized} ->
                case apply_owner_prepare_fields(
                       normalized,
                       record.run_id,
                       record.effect_generation
                     ) do
                  {:ok, match_attrs} ->
                    if EffectEnvelope.matches_prepare_attrs?(
                         pending,
                         match_attrs,
                         record.effect_generation
                       ) do
                      {{:ok, :already_prepared, pending}, state}
                    else
                      {{:error, {:effect_conflict, :pending}}, state}
                    end

                  {:error, reason} ->
                    {{:error, {:invalid_effect_attrs, reason}}, state}
                end

              {:error, reason} ->
                {{:error, {:invalid_effect_attrs, reason}}, state}
            end

          %{"status" => "completed"} ->
            {{:error, {:effect_conflict, :completed}}, state}

          other when is_map(other) ->
            {{:error, {:effect_conflict, :invalid_status}}, state}

          _ ->
            {{:error, {:invalid_current_effect, :invalid_type}}, state}
        end
    end
  end

  defp prepare_new_effect(%Record{} = record, attrs, state) do
    next_gen = (record.effect_generation || 0) + 1
    max_gen = EffectEnvelope.max_generation()

    cond do
      next_gen > max_gen ->
        {{:error, {:effect_generation_ceiling, max_gen}}, state}

      true ->
        case normalize_effect_attrs(attrs) do
          {:ok, normalized} ->
            case apply_owner_prepare_fields(normalized, record.run_id, next_gen) do
              {:ok, prepare_attrs} ->
                case EffectEnvelope.new_pending(prepare_attrs) do
                  {:ok, effect} ->
                    updated = %Record{
                      record
                      | effect_generation: next_gen,
                        current_effect: effect
                    }

                    case write_record(updated, state) do
                      {:ok, new_state} ->
                        {{:ok, :prepared, effect}, new_state}

                      {{:error, reason}, new_state} ->
                        {{:error, reason}, new_state}
                    end

                  {:error, reason} ->
                    {{:error, {:invalid_effect_attrs, reason}}, state}
                end

              {:error, reason} ->
                {{:error, {:invalid_effect_attrs, reason}}, state}
            end

          {:error, reason} ->
            {{:error, {:invalid_effect_attrs, reason}}, state}
        end
    end
  end

  defp do_record_effect_receipt(run_id, generation, execution_id, attrs, state) do
    case lookup_record(state.table, run_id) do
      nil ->
        {{:error, :not_found}, state}

      %Record{current_effect: nil} ->
        {{:error, {:effect_conflict, :missing}}, state}

      %Record{current_effect: effect} = record when is_map(effect) ->
        status = effect["status"]

        cond do
          not valid_generation?(generation) ->
            {{:error, {:invalid_effect_attrs, :invalid_generation}}, state}

          status == "pending" and
              exact_pending_identity?(record, effect, generation, execution_id) ->
            case normalize_effect_attrs(attrs) do
              {:ok, normalized} ->
                case EffectEnvelope.complete(effect, normalized) do
                  {:ok, completed} ->
                    updated = %Record{record | current_effect: completed}

                    case write_record(updated, state) do
                      {:ok, new_state} ->
                        {{:ok, :recorded, completed}, new_state}

                      {{:error, reason}, new_state} ->
                        {{:error, reason}, new_state}
                    end

                  {:error, reason} ->
                    {{:error, {:invalid_effect_attrs, reason}}, state}
                end

              {:error, reason} ->
                {{:error, {:invalid_effect_attrs, reason}}, state}
            end

          status in ["completed", "settled"] ->
            case normalize_effect_attrs(attrs) do
              {:ok, normalized} ->
                # Reject malformed/extra receipt attrs before identity match so
                # retries cannot launder unknowns into :already_recorded.
                case EffectEnvelope.validate_receipt_attrs(normalized) do
                  :ok ->
                    if EffectEnvelope.matches_receipt?(
                         effect,
                         generation,
                         execution_id,
                         normalized
                       ) do
                      {{:ok, :already_recorded, effect}, state}
                    else
                      conflict =
                        case status do
                          "completed" -> :completed
                          "settled" -> :settled
                        end

                      {{:error, {:effect_conflict, conflict}}, state}
                    end

                  {:error, reason} ->
                    {{:error, {:invalid_effect_attrs, reason}}, state}
                end

              {:error, reason} ->
                {{:error, {:invalid_effect_attrs, reason}}, state}
            end

          true ->
            {{:error, {:effect_conflict, :stale_or_mismatch}}, state}
        end

      %Record{} ->
        {{:error, {:invalid_current_effect, :invalid_type}}, state}
    end
  end

  defp do_settle_effect(run_id, generation, execution_id, state) do
    case lookup_record(state.table, run_id) do
      nil ->
        {{:error, :not_found}, state}

      %Record{current_effect: nil} ->
        {{:error, {:effect_conflict, :missing}}, state}

      %Record{current_effect: effect} = record when is_map(effect) ->
        status = effect["status"]

        cond do
          not valid_generation?(generation) ->
            {{:error, {:invalid_effect_attrs, :invalid_generation}}, state}

          status == "completed" and
              exact_pending_identity?(record, effect, generation, execution_id) ->
            case EffectEnvelope.settle(effect) do
              {:ok, settled} ->
                updated = %Record{record | current_effect: settled}

                case write_record(updated, state) do
                  {:ok, new_state} ->
                    {{:ok, :settled, settled}, new_state}

                  {{:error, reason}, new_state} ->
                    {{:error, reason}, new_state}
                end

              {:error, reason} ->
                {{:error, {:invalid_current_effect, reason}}, state}
            end

          status == "settled" and
              exact_pending_identity?(record, effect, generation, execution_id) ->
            {{:ok, :already_settled, effect}, state}

          status == "pending" ->
            {{:error, {:effect_conflict, :pending}}, state}

          true ->
            {{:error, {:effect_conflict, :stale_or_mismatch}}, state}
        end

      %Record{} ->
        {{:error, {:invalid_current_effect, :invalid_type}}, state}
    end
  end

  defp exact_pending_identity?(%Record{} = record, effect, generation, execution_id)
       when is_map(effect) and is_integer(generation) and is_binary(execution_id) do
    record.effect_generation == generation and
      effect["generation"] == generation and
      effect["execution_id"] == execution_id and
      effect["run_id"] == record.run_id
  end

  defp exact_pending_identity?(_, _, _, _), do: false

  defp valid_generation?(n) when is_integer(n) and n >= 1 and n <= 9_007_199_254_740_991,
    do: true

  defp valid_generation?(_), do: false

  # Closed full-envelope key ceiling (pending 10 + receipt 3) — O(1) before scans.
  @max_effect_attr_keys 13

  # Normalize caller attrs to string keys; reject atom/string aliases and
  # non-map/non-string-key inputs before envelope construction. Never drops
  # malformed keys — non-atom/non-binary keys fail closed.
  defp normalize_effect_attrs(attrs) when is_map(attrs) do
    cond do
      map_size(attrs) > @max_effect_attr_keys ->
        {:error, {:oversized, :map}}

      true ->
        keys = Map.keys(attrs)

        cond do
          Enum.any?(keys, fn
            k when is_atom(k) -> Map.has_key?(attrs, Atom.to_string(k))
            _ -> false
          end) ->
            {:error, :atom_string_key_alias}

          Enum.any?(keys, &(not is_binary(&1) and not is_atom(&1))) ->
            {:error, :non_string_keys}

          true ->
            normalized =
              Enum.reduce(attrs, %{}, fn
                {k, v}, acc when is_binary(k) -> Map.put(acc, k, v)
                {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), v)
              end)

            {:ok, normalized}
        end
    end
  end

  defp normalize_effect_attrs(_), do: {:error, :invalid_type}

  # Owner-assigned fields: generation/status/schema cannot be overridden by the
  # caller. Missing run_id is filled; explicit mismatched run_id fails.
  defp apply_owner_prepare_fields(attrs, run_id, generation)
       when is_map(attrs) and is_binary(run_id) and is_integer(generation) do
    with :ok <- reject_caller_generation_override(attrs, generation),
         :ok <- reject_caller_status_override(attrs),
         :ok <- reject_caller_schema_override(attrs),
         {:ok, with_run_id} <- apply_owner_run_id(attrs, run_id) do
      {:ok, Map.put(with_run_id, "generation", generation)}
    end
  end

  defp reject_caller_generation_override(attrs, generation) do
    case Map.fetch(attrs, "generation") do
      :error -> :ok
      {:ok, ^generation} -> :ok
      {:ok, _} -> {:error, :invalid_generation}
    end
  end

  defp reject_caller_status_override(attrs) do
    case Map.fetch(attrs, "status") do
      :error -> :ok
      {:ok, "pending"} -> :ok
      {:ok, _} -> {:error, :invalid_status}
    end
  end

  defp reject_caller_schema_override(attrs) do
    case Map.fetch(attrs, "schema_version") do
      :error -> :ok
      {:ok, 1} -> :ok
      {:ok, _} -> {:error, :invalid_schema_version}
    end
  end

  defp apply_owner_run_id(attrs, run_id) do
    case Map.fetch(attrs, "run_id") do
      :error ->
        {:ok, Map.put(attrs, "run_id", run_id)}

      {:ok, ^run_id} ->
        {:ok, attrs}

      {:ok, _} ->
        {:error, :invalid_run_id}
    end
  end

  # Backend-first when configured: persist before publishing to the private hot
  # table. On backend failure, leave the prior hot record/claim unchanged.
  # Identity validation rejects invalid/oversized invariant fields.
  defp write_record(%Record{} = record, state) do
    now = DateTime.utc_now()

    case Adapter.validate_and_normalize_record(record) do
      {:ok, %Record{} = validated} ->
        validated = %Record{validated | last_ets_sync: validated.last_ets_sync || now}

        case maybe_durable_put(validated, state) do
          {:ok, state} ->
            hot_insert(state.table, validated)
            {:ok, state}

          {:error, reason, state} ->
            {{:error, {:durable_write_failed, reason}}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp update_record(run_id, state, fun) when is_function(fun, 1) do
    case lookup_record(state.table, run_id) do
      nil ->
        # Missing lifecycle mutations must never look like success.
        {{:error, :not_found}, state}

      %Record{} = entry ->
        record = fun.(entry)

        if record == entry do
          {:ok, state}
        else
          write_record(record, state)
        end
    end
  end

  defp apply_terminal(%Record{} = stored, status, reason, duration_ms, meta) do
    now = DateTime.utc_now()
    progress = prefer_progress_from_meta(stored, meta)

    failure_reason =
      if status in [:failed, :interrupted] do
        Adapter.bound_failure_reason(reason || stored.failure_reason)
      else
        stored.failure_reason
      end

    base = %Record{
      stored
      | status: status,
        completed_count: progress.completed_count,
        completed_nodes: progress.completed_nodes,
        node_durations: progress.node_durations,
        current_node: nil,
        duration_ms: duration_ms || stored.duration_ms,
        finished_at: stored.finished_at || now,
        failure_reason: failure_reason,
        owner_node: if(status == :interrupted, do: nil, else: stored.owner_node)
    }

    Adapter.merge_meta(base, meta)
  end

  defp seed_record_from_meta(run_id, meta) do
    %Record{
      run_id: run_id,
      pipeline_id: Map.get(meta, :pipeline_id, run_id),
      graph_id: Map.get(meta, :graph_id),
      status: :running,
      total_nodes: Map.get(meta, :total_nodes, 0) || 0,
      completed_count: Map.get(meta, :completed_count, 0) || 0,
      completed_nodes: Map.get(meta, :completed_nodes, []) || [],
      node_durations: Map.get(meta, :node_durations, %{}) || %{},
      started_at: Map.get(meta, :started_at) || DateTime.utc_now(),
      graph_hash: Map.get(meta, :graph_hash),
      dot_source_path: Map.get(meta, :dot_source_path),
      logs_root: Map.get(meta, :logs_root),
      execution_principal: Map.get(meta, :execution_principal),
      origin_trust_zone: Map.get(meta, :origin_trust_zone),
      spawning_pid: Map.get(meta, :spawning_pid)
    }
  end

  # Preserve richest progress. When completed_count is equal, merge
  # completed_nodes and node_durations deterministically instead of wholesale
  # choosing a single snapshot that can drop richer stored fields.
  defp prefer_progress(%Record{} = a, %Record{} = b) do
    count_a = a.completed_count || 0
    count_b = b.completed_count || 0

    {primary, secondary, count} =
      cond do
        count_a > count_b -> {a, b, count_a}
        count_b > count_a -> {b, a, count_b}
        true -> {a, b, count_a}
      end

    merge_progress(primary, secondary, count)
  end

  defp prefer_progress_from_meta(%Record{} = stored, meta) when is_map(meta) do
    meta_count = Map.get(meta, :completed_count)
    meta_nodes = Map.get(meta, :completed_nodes)
    meta_durs = Map.get(meta, :node_durations)

    meta_as_record = %Record{
      run_id: stored.run_id,
      pipeline_id: stored.pipeline_id,
      completed_count: if(is_integer(meta_count), do: meta_count, else: 0),
      completed_nodes: if(is_list(meta_nodes), do: meta_nodes, else: []),
      node_durations: if(is_map(meta_durs), do: meta_durs, else: %{})
    }

    # Always merge: meta may carry richer nodes/durations even at equal count.
    if is_integer(meta_count) or is_list(meta_nodes) or is_map(meta_durs) do
      prefer_progress(meta_as_record, stored)
    else
      %{
        completed_count: stored.completed_count || 0,
        completed_nodes: stored.completed_nodes || [],
        node_durations: stored.node_durations || %{}
      }
    end
  end

  defp merge_progress(%Record{} = primary, %Record{} = secondary, count) do
    nodes =
      merge_completed_nodes(primary.completed_nodes || [], secondary.completed_nodes || [])

    durs =
      merge_node_durations(primary.node_durations || %{}, secondary.node_durations || %{})

    effective_count = max(count || 0, length(nodes))

    %{
      completed_count: effective_count,
      completed_nodes: nodes,
      node_durations: durs
    }
  end

  defp merge_completed_nodes(a, b) when is_list(a) and is_list(b) do
    cond do
      length(a) > length(b) ->
        merge_node_lists(a, b)

      length(b) > length(a) ->
        merge_node_lists(b, a)

      true ->
        # Equal length — keep primary order, then append missing secondary entries.
        merge_node_lists(a, b)
    end
  end

  defp merge_completed_nodes(a, _) when is_list(a), do: a
  defp merge_completed_nodes(_, b) when is_list(b), do: b
  defp merge_completed_nodes(_, _), do: []

  defp merge_node_lists(primary, secondary) do
    Enum.reduce(secondary, primary, fn node, acc ->
      if node in acc, do: acc, else: acc ++ [node]
    end)
  end

  defp merge_node_durations(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, va, vb ->
      cond do
        is_integer(va) and is_integer(vb) -> max(va, vb)
        is_integer(va) -> va
        is_integer(vb) -> vb
        true -> va
      end
    end)
  end

  defp merge_node_durations(a, _) when is_map(a), do: a
  defp merge_node_durations(_, b) when is_map(b), do: b
  defp merge_node_durations(_, _), do: %{}

  defp maybe_durable_put(%Record{} = record, %{durable_mode: mode} = state)
       when mode in [:backed, :degraded] and not is_nil(state.backend) do
    case Adapter.to_durable_map(record) do
      {:ok, payload} ->
        persistence_record =
          PersistenceRecord.new(record.run_id, payload,
            metadata: %{"collection" => state.collection}
          )

        case Arbor.Persistence.put(
               state.store_name,
               state.backend,
               record.run_id,
               persistence_record,
               state.backend_opts || []
             ) do
          :ok ->
            {:ok, %{state | last_write_error: nil, durable_error: nil, durable_mode: :backed}}

          {:error, reason} ->
            Logger.warning(
              "[RunJournal] durable put failed for #{record.run_id}: #{inspect(reason)}"
            )

            {:error, reason,
             %{
               state
               | last_write_error: reason,
                 durable_error: reason,
                 durable_mode: :degraded
             }}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  rescue
    e ->
      reason = Exception.message(e)

      {:error, reason,
       %{
         state
         | last_write_error: reason,
           durable_error: reason,
           durable_mode: :degraded
       }}
  catch
    :exit, reason ->
      {:error, reason,
       %{
         state
         | last_write_error: reason,
           durable_error: reason,
           durable_mode: :degraded
       }}
  end

  defp maybe_durable_put(_record, state), do: {:ok, state}

  defp maybe_durable_delete(
         run_id,
         %{backend: backend, store_name: store_name, durable_mode: mode} = state
       )
       when not is_nil(backend) and mode in [:backed, :degraded] do
    backend_opts = Map.get(state, :backend_opts, [])

    case Arbor.Persistence.delete(store_name, backend, run_id, backend_opts) do
      :ok ->
        {:ok, %{state | last_write_error: nil, durable_error: nil, durable_mode: :backed}}

      {:error, reason} ->
        Logger.warning("[RunJournal] durable delete failed for #{run_id}: #{inspect(reason)}")

        {:error, reason,
         %{
           state
           | last_write_error: reason,
             durable_error: reason,
             durable_mode: :degraded
         }}
    end
  rescue
    e ->
      reason = Exception.message(e)

      {:error, reason,
       %{
         state
         | last_write_error: reason,
           durable_error: reason,
           durable_mode: :degraded
       }}
  catch
    :exit, reason ->
      {:error, reason,
       %{
         state
         | last_write_error: reason,
           durable_error: reason,
           durable_mode: :degraded
       }}
  end

  defp maybe_durable_delete(_run_id, state), do: {:ok, state}

  defp durable_list_keys(%{backend: backend, store_name: store_name} = state)
       when not is_nil(backend) do
    backend_opts = Map.get(state, :backend_opts, [])

    case Arbor.Persistence.list(store_name, backend, backend_opts) do
      {:ok, keys} when is_list(keys) ->
        {:ok, keys}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_list_result, other}}
    end
  rescue
    e ->
      {:error, {:list_raised, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:list_exit, reason}}

    :throw, reason ->
      {:error, {:list_throw, bound_effect_reason(reason)}}
  end

  defp durable_list_keys(_), do: {:ok, []}

  # Raw backend get (keeps PersistenceRecord envelope for identity binding).
  defp durable_fetch_raw(key, %{backend: backend, store_name: store_name} = state)
       when not is_nil(backend) do
    backend_opts = Map.get(state, :backend_opts, [])

    case Arbor.Persistence.get(store_name, backend, key, backend_opts) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:durable_unavailable, reason}}

      other ->
        {:error, {:unexpected_durable_value, other}}
    end
  rescue
    e ->
      {:error, {:durable_unavailable, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:durable_unavailable, reason}}

    :throw, reason ->
      {:error, {:durable_unavailable, {:throw, bound_effect_reason(reason)}}}
  end

  defp durable_fetch_raw(_key, _state), do: {:error, :not_found}

  defp build_durability_status(state) do
    class = Map.get(state, :durability_class, :volatile)
    durable? = durable_class?(class) and healthy_backend?(state)

    mode =
      cond do
        state.durable_mode == :ets_only ->
          :ets_only

        state.durable_mode == :degraded or not is_nil(state.durable_error) or
            not is_nil(state.last_write_error) ->
          :degraded

        durable? ->
          :durable_declared

        state.durable_mode == :backed ->
          :backed_nondurable

        true ->
          :ets_only
      end

    fenced? = fenced_claim_enabled?(state)

    %{
      mode: mode,
      durable: durable?,
      durability_class: class,
      backend: state.backend && inspect(state.backend),
      store: state.store_name,
      last_error: state.last_write_error || state.durable_error,
      fenced_claim: fenced?,
      cross_node_atomic_recovery: fenced? and class == :node_restart
    }
  end

  defp healthy_backend?(%{durable_mode: :backed, durable_error: nil, last_write_error: nil}),
    do: true

  defp healthy_backend?(_), do: false

  defp durable_class?(class) when class in [:application_restart, :node_restart], do: true
  defp durable_class?(_), do: false

  # Honest durability: no module-name heuristics, no force flags.
  # Capability is code-owned via the public Persistence facade
  # (`durability_class/1` on the Store contract). Optional configured
  # `:durability_class` is a ceiling/intersection only — never elevation:
  #   volatile < process_lifetime < application_restart < node_restart
  # Explicit valid capabilities (including :volatile) are preserved exactly,
  # then intersected with any configured ceiling. Unsupported/malformed
  # capabilities fail closed to :process_lifetime (never elevated).
  @durability_rank %{
    volatile: 0,
    process_lifetime: 1,
    application_restart: 2,
    node_restart: 3
  }

  defp resolve_durability_class(nil, _store_name, _backend_opts, _opts), do: :volatile

  defp resolve_durability_class(backend, store_name, backend_opts, opts) when is_atom(backend) do
    capability = backend_durability_capability(store_name, backend, backend_opts)
    ceiling = Keyword.get(opts, :durability_class)

    case ceiling do
      nil ->
        capability

      class when is_map_key(@durability_rank, class) ->
        intersect_durability_class(capability, class)

      _invalid ->
        # Invalid configured ceiling fails closed: cannot raise capability.
        intersect_durability_class(capability, :process_lifetime)
    end
  end

  defp resolve_durability_class(_, _store_name, _backend_opts, _opts), do: :volatile

  defp backend_durability_capability(store_name, backend, backend_opts)
       when is_atom(backend) do
    case Arbor.Persistence.durability_class(store_name, backend, backend_opts) do
      {:ok, class} when is_map_key(@durability_rank, class) ->
        # Preserve code-owned capability exactly (including :volatile).
        class

      {:ok, _invalid} ->
        :process_lifetime

      {:error, :unsupported} ->
        :process_lifetime

      {:error, _} ->
        :process_lifetime
    end
  end

  defp backend_durability_capability(_store_name, _backend, _backend_opts), do: :process_lifetime

  defp intersect_durability_class(a, b) do
    rank_a = Map.fetch!(@durability_rank, a)
    rank_b = Map.fetch!(@durability_rank, b)

    if rank_a <= rank_b, do: a, else: b
  end

  defp hot_insert(table, %Record{} = record) do
    true = :ets.insert(table, {record.run_id, record})
    :ok
  end

  defp lookup_record(table, run_id) do
    case :ets.lookup(table, run_id) do
      [{^run_id, %Record{} = record}] -> record
      # Compat if an old public map somehow appears during mixed reload
      [{^run_id, entry}] when is_map(entry) -> Adapter.from_lifecycle_map(entry)
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp list_all_records(table) do
    :ets.tab2list(table)
    |> Enum.map(fn
      {_key, %Record{} = record} -> record
      {_key, entry} when is_map(entry) -> Adapter.from_lifecycle_map(entry)
    end)
  rescue
    ArgumentError -> []
  end

  defp normalize_meta(meta) when is_list(meta), do: Map.new(meta)
  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}
end
