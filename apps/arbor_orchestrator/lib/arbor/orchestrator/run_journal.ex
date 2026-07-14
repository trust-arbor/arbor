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

  ## Distributed claims (L1/L2 honesty)

  Local GenServer claims are atomic. There is **no** durable CAS/fencing
  primitive yet (L4). Records owned or sourced by another node, or with
  ambiguous ownership after rehydrate, fail closed on claim until L4 adds
  a fenced backend claim.
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Orchestrator.RunLifecycle.Adapter
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

  @doc "Put a full lifecycle record (durable-first when backed, then hot)."
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
  `:recovering` and `owner_node` is set. Durable claim writes are
  durable-first: backend failure returns error and leaves the record
  interrupted (retryable after storage recovers).
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

  Never reports application-restart durability for ETS-only, Agent, or
  asynchronous buffering backends. `durable: true` only when the configured
  class is `:application_restart` or `:node_restart` and the backend is healthy.
  """
  @spec durability_status(keyword()) :: map()
  def durability_status(opts \\ []) do
    call_server(opts, :durability_status)
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
    {reply, state} =
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
    {reply, state} =
      case lookup_record(state.table, run_id) do
        nil ->
          {{:error, :not_found}, state}

        %Record{} = record ->
          case record.status do
            :interrupted ->
              case claim_eligibility(record, claiming_node, state) do
                :ok ->
                  updated = %Record{
                    record
                    | owner_node: claiming_node,
                      status: :recovering
                  }

                  case write_record(updated, state) do
                    {:ok, new_state} ->
                      {{:ok, updated}, new_state}

                    {{:error, reason}, new_state} ->
                      # Backend-first: prior interrupted record still in hot table.
                      {{:error, reason}, new_state}
                  end

                {:error, reason} ->
                  {{:error, reason}, state}
              end

            other ->
              {{:error, {:invalid_status, other}}, state}
          end
      end

    {:reply, reply, state}
  end

  def handle_call(:durability_status, _from, state) do
    {:reply, build_durability_status(state), state}
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
  # hot view when the backend cannot be listed/read.
  defp reload_from_durable(state) do
    case durable_list_keys(state) do
      {:ok, keys} when is_list(keys) ->
        Enum.reduce_while(keys, {:ok, state}, fn key, {:ok, st} ->
          case durable_get(key, st) do
            {:ok, data} when is_map(data) ->
              record = boot_normalize(Adapter.from_durable_map(data), st.local_node)
              hot_insert(st.table, record)
              {:cont, {:ok, st}}

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
  end

  # Boot-normalize rehydrated rows. Do **not** rewrite in-flight rows owned or
  # sourced by another potentially-live node — leave them for L4 fenced recovery.
  # Only normalize records proven local (or ownerless/dead-local).
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

  defp remote_ownership?(%Record{} = record, local_node) do
    local = to_string(local_node)

    owner_remote? =
      not is_nil(record.owner_node) and to_string(record.owner_node) != local

    source_remote? =
      not is_nil(record.source_node) and to_string(record.source_node) != local

    owner_remote? or source_remote?
  end

  # Local GenServer claim only — no cross-node CAS. Fail closed for remote or
  # ambiguous ownership until L4 adds a fenced backend claim.
  #
  # When a durable backend is configured, also reject source/owner-ambiguous
  # rows (including empty owner with remote source). Local ETS-only rows may
  # remain locally claimable.
  defp claim_eligibility(%Record{} = record, claiming_node, state) do
    local = to_string(state.local_node)
    claimer = to_string(claiming_node)
    backed? = state.durable_mode in [:backed, :degraded] and not is_nil(state.backend)

    cond do
      # Another node already owns the claim slot.
      not is_nil(record.owner_node) and to_string(record.owner_node) != claimer ->
        {:error, :remote_or_foreign_claim}

      # Source belongs to another node and owner is empty → always fail closed.
      is_nil(record.owner_node) and not is_nil(record.source_node) and
        to_string(record.source_node) != local and to_string(record.source_node) != claimer ->
        {:error, :ambiguous_remote_row}

      # Backed store: fail closed when owner/source metadata is ambiguous
      # (missing both, or source differs from local without owner proof).
      backed? and is_nil(record.owner_node) and is_nil(record.source_node) ->
        {:error, :ambiguous_remote_row}

      backed? and not is_nil(record.source_node) and to_string(record.source_node) != local and
          is_nil(record.owner_node) ->
        {:error, :ambiguous_remote_row}

      # Claiming from a non-local node through this journal is not fenced.
      claimer != local ->
        {:error, :cross_node_claim_unfenced}

      true ->
        :ok
    end
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
          started_at: from_state.started_at || preserved.started_at
      }
      |> Adapter.merge_meta(meta)

    write_record(record, state)
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
  end

  defp durable_list_keys(_), do: {:ok, []}

  defp durable_get(key, %{backend: backend, store_name: store_name} = state)
       when not is_nil(backend) do
    backend_opts = Map.get(state, :backend_opts, [])

    case Arbor.Persistence.get(store_name, backend, key, backend_opts) do
      {:ok, %PersistenceRecord{data: data}} when is_map(data) ->
        {:ok, data}

      {:ok, %{__struct__: PersistenceRecord, data: data}} when is_map(data) ->
        {:ok, data}

      {:ok, %{"data" => data}} when is_map(data) ->
        {:ok, data}

      {:ok, data} when is_map(data) ->
        if Map.has_key?(data, "run_id") or Map.has_key?(data, :run_id) do
          {:ok, data}
        else
          case Map.get(data, :data) || Map.get(data, "data") do
            inner when is_map(inner) -> {:ok, inner}
            _ -> {:ok, data}
          end
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        # Surface transport/backend outages distinctly from missing keys.
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

  defp durable_get(_key, _state), do: {:error, :not_found}

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

    %{
      mode: mode,
      durable: durable?,
      durability_class: class,
      backend: state.backend && inspect(state.backend),
      store: state.store_name,
      last_error: state.last_write_error || state.durable_error,
      # Explicit: no cross-node CAS / fencing in L1/L2.
      fenced_claim: false,
      cross_node_atomic_recovery: false
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
