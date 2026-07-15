defmodule Arbor.Shell.AppleContainerUnitDrainCoordinator do
  @moduledoc false

  # Permanent rest_for_one sibling placed after AppleContainerUnitSupervisor.
  #
  # Exhaustive planned application shutdown is owned by
  # `Arbor.Shell.Application.prep_stop/1`, which calls
  # `prepare_durable_shutdown/1` while the supervision tree is still fully
  # alive. The barrier is a **nonblocking GenServer state machine**: the call
  # stores the caller `from`, closes start admission immediately (never
  # reopens), and advances via handle_info ticks plus exact receipt messages.
  # GenServer.reply/2 fires only on positive convergence. This keeps the
  # ordinary GenServer loop free to process sys/parent EXIT so rest_for_one
  # can terminate the coordinator while an earlier sibling is restarting —
  # a blocking receive inside handle_call would recreate the deadlock.
  #
  # Convergence requires exact worker PID+receipt drain settlement, exact
  # Reconciler recover_all PID+ref completion (fresh after turnover), and a
  # fresh empty UnitSupervisor snapshot plus `Journal.recovery_entries ==
  # {:ok, []}` (disabled-journal policy: empty UnitSupervisor only — never
  # infer empty from unavailable/poisoned journal). Worker/reconciler DOWN is
  # a wakeup only, never cleanup proof.
  #
  # `terminate/2` deliberately does **not** run that barrier. Crash-driven
  # rest_for_one turnover must return promptly; durable Journal rows plus
  # replacement startup reconstruction remain responsible for crash recovery.
  #
  # Production unit starts linearize through this process: controller identity
  # is taken only from the GenServer from tuple, an absolute monotonic deadline
  # is fixed before journal reserve, the exact committed journal record is
  # passed into durable worker admission, and the worker is monitored before
  # the start reply. Start calls after shutdown preparation begins are rejected.
  #
  # `await_execution_settled/2` is the nonblocking settlement prerequisite for a
  # future spawn-capable adapter: callers block only on GenServer.reply after a
  # FRESH authoritative convergence proves the exact execution_id no longer has
  # a durable journal row or unresolved/live worker. Missing/failed Journal,
  # Reconciler, or UnitSupervisor is UNKNOWN and keeps waiting. A cached
  # :ready alone never settles — registering a waiter forces a fresh reread.
  # Settlement on the normal path requires reconstruction to reach :ready; on
  # the planned-shutdown path the durable barrier is driven (even with no
  # prep_stop waiter) and barrier success settles all exact execution waiters.
  # Waiters are bounded, mon_ref-keyed, caller-monitored, and redacted.
  #
  # Init/restart begins closed (reconstructing). Admission stays unavailable
  # until reconciler readiness, journal recovery_entries, and the unit
  # supervisor snapshot are all positively observed, every live worker is
  # ownership_info-verified against its exact journal record (hints only select
  # candidates), orphans go through Reconciler.recover_entry, unmatched/
  # unhintable workers go through request_drain, and every retained worker is
  # monitored. Exact pending receipts and known monitors only wake a fresh
  # authoritative re-read; forged messages are ignored. Pending state is
  # reconciled against each successful snapshot so lost receipts cannot
  # deadlock: orphans prune when the exact record is absent, drains prune when
  # the worker PID is absent. Only an explicit {:error, _} start reply is a
  # definite non-admission eligible for Journal.complete; exits/throws preserve
  # the row and re-enter reconstruction.
  #
  # Production dependencies are sealed. Test-only module/server/clock/starter
  # seams exist only behind start_for_test/1.

  use GenServer

  alias Arbor.Shell.AppleContainerUnitDrainCoordinatorCore, as: Core
  alias Arbor.Shell.AppleContainerUnitJournal, as: Journal
  alias Arbor.Shell.AppleContainerUnitRecoveryReconciler, as: Reconciler
  alias Arbor.Shell.AppleContainerUnitRuntime
  alias Arbor.Shell.AppleContainerUnitWorker, as: Worker

  @name __MODULE__
  @unit_supervisor Arbor.Shell.AppleContainerUnitSupervisor
  # Handshake only — acceptance of request_drain, not absence proof.
  @drain_handshake_timeout_ms 5_000
  @ownership_call_timeout_ms 5_000
  @max_execution_id_bytes 256
  # Bounded production start admission call (not absence proof).
  @start_unit_timeout_ms 5_000
  # Bounded wake interval between authoritative reconstruction re-reads.
  @reconstruct_retry_ms 100
  @max_reconstruct_retry_ms 1_000
  # Poll interval only — never a time cap on absence proof / barrier progress.
  @shutdown_barrier_retry_ms 50
  @max_workers 1_024
  @max_pending 1_024
  @max_execution_waiters 1_024
  @max_unit_name_bytes 64
  @max_timeout_ms 300_000

  @allowed_test_keys MapSet.new([
                       :name,
                       :journal,
                       :journal_server,
                       :reconciler,
                       :reconciler_server,
                       :unit_supervisor,
                       :worker_module,
                       :clock,
                       :worker_starter,
                       :snapshot_workers,
                       :reconstruct_retry_ms,
                       :ownership_call_timeout_ms,
                       :drain_handshake_timeout_ms
                     ])

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ [])

  def start_link([]) do
    GenServer.start_link(__MODULE__, :production, name: @name)
  end

  def start_link(:production) do
    GenServer.start_link(__MODULE__, :production, name: @name)
  end

  def start_link(_other), do: {:error, :invalid_drain_coordinator_start}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc false
  @spec start_for_test(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_for_test(opts \\ []) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_test_opts(opts) do
        # Unlinked start so focused tests can kill/stop the coordinator without
        # taking down the ExUnit process through a start_link EXIT signal.
        # Prefer unregistered PID addressing; optional :name is for registered
        # ownership tests only and must be a pre-existing atom (never created).
        case Keyword.fetch(opts, :name) do
          {:ok, name} when is_atom(name) and not is_nil(name) ->
            GenServer.start(__MODULE__, {:test_only, opts}, name: name)

          :error ->
            GenServer.start(__MODULE__, {:test_only, opts})

          _invalid ->
            {:error, :invalid_test_opt}
        end
      end
    else
      {:error, :invalid_drain_coordinator_start}
    end
  end

  @doc false
  @spec start_unit(map(), term(), String.t(), reference()) ::
          {:ok, pid()} | {:error, term()}
  def start_unit(spec, executable, execution_id, start_ref)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) do
    GenServer.call(
      @name,
      {:start_unit, spec, executable, execution_id, start_ref},
      @start_unit_timeout_ms
    )
  catch
    :exit, _reason ->
      {:error, :unit_start_unavailable}
  end

  def start_unit(_spec, _executable, _execution_id, _start_ref),
    do: {:error, :invalid_unit_start}

  @doc false
  # Sealed production planned-shutdown barrier used by Application.prep_stop/1.
  # Serializes in the coordinator, immediately closes start admission (never
  # reopens), and returns only after positive authoritative convergence:
  # successful UnitSupervisor snapshot (missing/failed is never empty), exact
  # worker drain receipts (PID + ref), exact recover_all completion from the
  # resolved Reconciler PID + ref, and fresh empty UnitSupervisor plus
  # Journal.recovery_entries == {:ok, []}. Disabled-journal policy: succeed only
  # after a positive empty UnitSupervisor snapshot. Unavailable/poisoned journal
  # is never treated as empty. Production callers use the registered name; tests
  # may pass a start_for_test/1 PID.
  @spec prepare_durable_shutdown(GenServer.server()) :: :ok | {:error, term()}
  def prepare_durable_shutdown(server \\ @name) do
    GenServer.call(server, :prepare_durable_shutdown, :infinity)
  catch
    :exit, reason ->
      {:error, {:coordinator_unavailable, reason}}
  end

  @doc false
  # Nonblocking settlement wait for one exact execution_id. Returns :ok only
  # after a fresh authoritative observation proves the execution is absent from
  # durable journal rows and live/unresolved workers. Coordinator process
  # turnover surfaces as `{:error, {:coordinator_unavailable, reason}}` so a
  # later facade adapter can retry the replacement — never trust stale evidence.
  @spec await_execution_settled(String.t(), GenServer.server()) ::
          :ok | {:error, term()}
  def await_execution_settled(execution_id, server \\ @name)

  def await_execution_settled(execution_id, server) when is_binary(execution_id) do
    GenServer.call(server, {:await_execution_settled, execution_id}, :infinity)
  catch
    :exit, reason ->
      {:error, {:coordinator_unavailable, reason}}
  end

  def await_execution_settled(_execution_id, _server), do: {:error, :invalid_execution_id}

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(:production) do
    Process.flag(:trap_exit, true)
    # Single immediate reconstruction path — no concurrent timer on init.
    {:ok, base_state(:production, production_deps()), {:continue, :reconstruct}}
  end

  def init({:test_only, opts}) when is_list(opts) do
    Process.flag(:trap_exit, true)

    case build_test_deps(opts) do
      {:ok, deps} ->
        {:ok, base_state(:test_only, deps), {:continue, :reconstruct}}

      {:error, reason} ->
        {:stop, {:drain_coordinator_start_failed, reason}}
    end
  end

  def init(_other), do: {:stop, :invalid_drain_coordinator_start}

  @impl true
  def handle_continue(:reconstruct, state) do
    {:noreply, run_reconstruction(state)}
  end

  def handle_continue(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(
        {:start_unit, spec, executable, execution_id, start_ref},
        {controller_pid, _tag},
        state
      )
      when is_pid(controller_pid) and is_map(spec) and is_binary(execution_id) and
             is_reference(start_ref) do
    case state.phase do
      :ready ->
        admit_start_unit(state, spec, executable, execution_id, start_ref, controller_pid)

      _closed ->
        {:reply, {:error, :unit_start_unavailable}, state}
    end
  end

  def handle_call({:start_unit, _spec, _executable, _execution_id, _start_ref}, _from, state) do
    {:reply, {:error, :invalid_unit_start}, state}
  end

  def handle_call(:prepare_durable_shutdown, from, state) do
    # Nonblocking: store caller, close admission, advance via handle_info.
    # Parent EXIT / concurrent starts keep flowing through the GenServer loop.
    state = enter_shutdown_preparation(state)
    state = %{state | barrier_waiters: [from | state.barrier_waiters]}

    if state.barrier_converged do
      # Re-verify before replying so a prior success cannot skip fresh evidence.
      {:noreply, advance_shutdown_barrier(state)}
    else
      {:noreply, advance_shutdown_barrier(state)}
    end
  end

  def handle_call({:await_execution_settled, execution_id}, from, state)
      when is_binary(execution_id) do
    case register_execution_waiter(state, execution_id, from) do
      {:ok, state} ->
        {:noreply, drive_execution_settlement(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await_execution_settled, _execution_id}, _from, state) do
    {:reply, {:error, :invalid_execution_id}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_call}, state}
  end

  @impl true
  def handle_info({:timeout, timer_ref, {:reconstruct, token}}, state)
      when is_reference(timer_ref) and is_reference(token) do
    case state.reconstruct_timer do
      {^timer_ref, ^token} ->
        {:noreply, run_reconstruction(%{state | reconstruct_timer: nil})}

      _stale_or_forged ->
        # Ignore cancelled, superseded, or forged timer messages.
        {:noreply, state}
    end
  end

  def handle_info({:timeout, timer_ref, {:barrier, token}}, state)
      when is_reference(timer_ref) and is_reference(token) do
    case state.barrier_timer do
      {^timer_ref, ^token} ->
        {:noreply, advance_shutdown_barrier(%{state | barrier_timer: nil})}

      _stale_or_forged ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:apple_container_unit_recovery_entry_complete, reconciler_pid, unit_name, receipt_ref},
        state
      )
      when is_pid(reconciler_pid) and is_binary(unit_name) and is_reference(receipt_ref) do
    case Map.get(state.pending_orphan_receipts, receipt_ref) do
      %{unit_name: ^unit_name} = meta ->
        if expected_reconciler_sender?(state, reconciler_pid) do
          # Exact pending receipt only wakes a fresh re-read — never settles.
          _ = meta

          if shutdown_preparation?(state.phase) do
            {:noreply, advance_shutdown_barrier(state)}
          else
            {:noreply, wake_reconstruction(state)}
          end
        else
          {:noreply, state}
        end

      _unknown ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:apple_container_unit_drained, worker_pid, execution_id, receipt_ref},
        state
      )
      when is_pid(worker_pid) and is_reference(receipt_ref) do
    case Map.get(state.pending_drain, worker_pid) do
      %{receipt_ref: ^receipt_ref} = meta ->
        if valid_execution_id?(execution_id) do
          state = settle_barrier_drain(state, worker_pid, meta)

          if shutdown_preparation?(state.phase) do
            {:noreply, advance_shutdown_barrier(state)}
          else
            {:noreply, wake_reconstruction(state)}
          end
        else
          {:noreply, state}
        end

      _unknown ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:apple_container_unit_recovery_all_complete, reconciler_pid, receipt_ref},
        state
      )
      when is_pid(reconciler_pid) and is_reference(receipt_ref) do
    case state.barrier_recover_all do
      %{reconciler_pid: ^reconciler_pid, receipt_ref: ^receipt_ref} = meta ->
        state = clear_barrier_recover_all(state, meta)
        # Exact completion is necessary but not sufficient — fresh-verify next.
        {:noreply, advance_shutdown_barrier(%{state | barrier_recover_all: :completed})}

      _forged_or_stale ->
        # Wrong PID/ref never settles. Never reopen admission.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, pid, _reason}, state)
      when is_reference(mon_ref) and is_pid(pid) do
    state = handle_down(state, mon_ref, pid)
    {:noreply, state}
  end

  def handle_info(_unrelated, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Crash-driven / rest_for_one termination must return promptly. Planned
    # exhaustive drain lives in Application.prep_stop via prepare_durable_shutdown/1.
    # Barrier / execution waiters observe GenServer.call exit and retry the
    # replacement coordinator — never settle from terminate evidence.
    # Do not wait on earlier siblings (Journal/Recovery/PortSession).
    _ = cancel_barrier_timer(state)
    _ = clear_barrier_recover_all_monitors(state)
    _ = demonitor_execution_waiters(state)
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
    |> Map.put(:state, redact_state(Map.get(status, :state)))
  end

  def format_status(status), do: status

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  defp production_deps do
    %{
      journal: Journal,
      journal_server: Journal,
      reconciler: Reconciler,
      reconciler_server: Reconciler,
      unit_supervisor: @unit_supervisor,
      worker_module: Worker,
      clock: AppleContainerUnitRuntime,
      worker_starter: nil,
      snapshot_workers: nil,
      reconstruct_retry_ms: @reconstruct_retry_ms,
      ownership_call_timeout_ms: @ownership_call_timeout_ms,
      drain_handshake_timeout_ms: @drain_handshake_timeout_ms
    }
  end

  defp base_state(mode, deps) do
    Map.merge(
      %{
        mode: mode,
        phase: :reconstructing,
        monitored: %{},
        pending_orphan_receipts: %{},
        pending_drain: %{},
        reconstruct_timer: nil,
        reconstruct_generation: 0,
        # Nonblocking planned-shutdown barrier (prep_stop ownership).
        barrier_waiters: [],
        barrier_timer: nil,
        barrier_recover_all: nil,
        barrier_converged: false,
        # mon_ref => %{from, execution_id, caller_pid} — settlement waiters.
        execution_waiters: %{}
      },
      deps
    )
  end

  defp build_test_deps(opts) do
    journal = Keyword.get(opts, :journal, Journal)
    reconciler = Keyword.get(opts, :reconciler, Reconciler)
    unit_supervisor = Keyword.get(opts, :unit_supervisor, @unit_supervisor)
    worker_module = Keyword.get(opts, :worker_module, Worker)
    clock = Keyword.get(opts, :clock, AppleContainerUnitRuntime)
    worker_starter = Keyword.get(opts, :worker_starter)
    snapshot_workers = Keyword.get(opts, :snapshot_workers)
    retry_ms = Keyword.get(opts, :reconstruct_retry_ms, @reconstruct_retry_ms)
    ownership_ms = Keyword.get(opts, :ownership_call_timeout_ms, @ownership_call_timeout_ms)
    drain_ms = Keyword.get(opts, :drain_handshake_timeout_ms, @drain_handshake_timeout_ms)

    with :ok <- validate_module_atom(journal, :invalid_journal_module),
         :ok <- validate_module_atom(reconciler, :invalid_reconciler_module),
         :ok <- validate_unit_supervisor(unit_supervisor),
         :ok <- validate_module_atom(worker_module, :invalid_worker_module),
         :ok <- validate_clock(clock),
         :ok <- validate_worker_starter(worker_starter),
         :ok <- validate_snapshot_workers(snapshot_workers),
         :ok <- validate_positive_ms(retry_ms, :invalid_reconstruct_retry_ms),
         :ok <- validate_positive_ms(ownership_ms, :invalid_ownership_call_timeout_ms),
         :ok <- validate_positive_ms(drain_ms, :invalid_drain_handshake_timeout_ms) do
      {:ok,
       %{
         journal: journal,
         journal_server: Keyword.get(opts, :journal_server, journal),
         reconciler: reconciler,
         reconciler_server: Keyword.get(opts, :reconciler_server, reconciler),
         unit_supervisor: unit_supervisor,
         worker_module: worker_module,
         clock: clock,
         worker_starter: worker_starter,
         snapshot_workers: snapshot_workers,
         reconstruct_retry_ms: min(retry_ms, @max_reconstruct_retry_ms),
         ownership_call_timeout_ms: ownership_ms,
         drain_handshake_timeout_ms: drain_ms
       }}
    end
  end

  defp validate_test_opts(opts) do
    keys = Keyword.keys(opts)

    cond do
      length(keys) > 32 ->
        {:error, :too_many_test_opts}

      Enum.any?(keys, &(not MapSet.member?(@allowed_test_keys, &1))) ->
        {:error, :invalid_test_opt}

      true ->
        :ok
    end
  end

  defp validate_module_atom(mod, _reason) when is_atom(mod) and not is_nil(mod), do: :ok
  defp validate_module_atom(_mod, reason), do: {:error, reason}

  defp validate_unit_supervisor(name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_unit_supervisor(pid) when is_pid(pid), do: :ok
  defp validate_unit_supervisor(_), do: {:error, :invalid_unit_supervisor}

  defp validate_clock(mod) when is_atom(mod) and not is_nil(mod), do: :ok
  defp validate_clock(fun) when is_function(fun, 0), do: :ok
  defp validate_clock(_), do: {:error, :invalid_clock}

  defp validate_worker_starter(nil), do: :ok
  defp validate_worker_starter(fun) when is_function(fun, 7), do: :ok
  defp validate_worker_starter(_), do: {:error, :invalid_worker_starter}

  defp validate_snapshot_workers(nil), do: :ok
  defp validate_snapshot_workers(fun) when is_function(fun, 0), do: :ok
  defp validate_snapshot_workers(_), do: {:error, :invalid_snapshot_workers}

  defp validate_positive_ms(ms, _reason)
       when is_integer(ms) and ms > 0 and ms <= @max_timeout_ms,
       do: :ok

  defp validate_positive_ms(_ms, reason), do: {:error, reason}

  # ---------------------------------------------------------------------------
  # Reconstruction
  # ---------------------------------------------------------------------------

  defp run_reconstruction(%{phase: phase} = state) when phase in [:draining, :preparing_shutdown],
    do: state

  defp run_reconstruction(state) do
    state = %{
      state
      | phase: :reconstructing,
        reconstruct_generation: state.reconstruct_generation + 1
    }

    case observe_authoritative_inputs(state) do
      {:ok, records, worker_pids} ->
        state = reconcile_pending_against_snapshot(state, records, worker_pids)
        continue_reconstruction(state, records, worker_pids)

      {:error, _reason} ->
        # Missing supervisor / journal / reconciler is UNKNOWN — never empty/ready.
        # Keep pending; re-issue paths stay open on the next successful snapshot.
        schedule_reconstruct(state)
    end
  end

  defp continue_reconstruction(state, records, worker_pids) do
    {hints, unhintable} = collect_hints(state, worker_pids)

    case Core.reconstruction_plan(records, hints) do
      {:ok, plan} ->
        apply_reconstruction_plan(state, plan, unhintable, MapSet.new(worker_pids), records)

      {:error, _reason} ->
        schedule_reconstruct(state)
    end
  end

  defp observe_authoritative_inputs(state) do
    with :ok <- require_reconciler_ready(state),
         {:ok, records} <- fetch_recovery_entries(state),
         {:ok, workers} <- snapshot_live_workers(state) do
      if length(workers) > @max_workers do
        {:error, :too_many_workers}
      else
        {:ok, records, workers}
      end
    end
  end

  defp require_reconciler_ready(state) do
    status =
      try do
        state.reconciler.status(state.reconciler_server)
      catch
        :exit, _ ->
          %{"phase" => "unavailable"}
      end

    case status do
      %{"phase" => "ready"} ->
        :ok

      %{phase: "ready"} ->
        :ok

      _other ->
        {:error, :reconciler_not_ready}
    end
  end

  defp fetch_recovery_entries(state) do
    try do
      case state.journal.recovery_entries(state.journal_server) do
        {:ok, entries} when is_list(entries) ->
          if length(entries) > @max_workers do
            {:error, :too_many_records}
          else
            {:ok, entries}
          end

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :journal_unavailable}
      end
    catch
      :exit, _ ->
        {:error, :journal_unavailable}
    end
  end

  defp snapshot_live_workers(%{snapshot_workers: fun} = _state) when is_function(fun, 0) do
    case fun.() do
      {:ok, workers} when is_list(workers) ->
        if Enum.all?(workers, &is_pid/1) do
          {:ok, workers}
        else
          {:error, :invalid_worker_snapshot}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :unit_supervisor_unavailable}
    end
  end

  defp snapshot_live_workers(state) do
    supervisor = state.unit_supervisor

    case resolve_supervisor(supervisor) do
      pid when is_pid(pid) ->
        try do
          children = DynamicSupervisor.which_children(supervisor)

          workers =
            Enum.flat_map(children, fn
              {_id, child, _type, _modules} when is_pid(child) ->
                if Process.alive?(child), do: [child], else: []

              _other ->
                []
            end)

          {:ok, workers}
        catch
          :exit, _ ->
            {:error, :unit_supervisor_unavailable}
        end

      _missing ->
        {:error, :unit_supervisor_unavailable}
    end
  end

  defp resolve_supervisor(pid) when is_pid(pid), do: pid
  defp resolve_supervisor(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_supervisor(_), do: nil

  # Lost-receipt convergence: prune pending only when a successful authoritative
  # snapshot proves the corresponding resource is already gone.
  defp reconcile_pending_against_snapshot(state, records, worker_pids) do
    present_identities =
      MapSet.new(Enum.map(records, &record_identity/1))

    present_workers = MapSet.new(worker_pids)

    {orphans, demonitor_orphan_refs} =
      Enum.reduce(state.pending_orphan_receipts, {%{}, []}, fn {ref, meta}, {keep, demons} ->
        identity = record_identity(Map.get(meta, :journal_record) || meta)

        if MapSet.member?(present_identities, identity) do
          {Map.put(keep, ref, meta), demons}
        else
          {keep, demons}
        end
      end)

    {drains, demonitor_drain_refs} =
      Enum.reduce(state.pending_drain, {%{}, []}, fn {worker, meta}, {keep, demons} ->
        if MapSet.member?(present_workers, worker) do
          {Map.put(keep, worker, meta), demons}
        else
          dem =
            if is_reference(Map.get(meta, :mon_ref)), do: [meta.mon_ref | demons], else: demons

          {keep, dem}
        end
      end)

    Enum.each(demonitor_orphan_refs ++ demonitor_drain_refs, fn mon_ref ->
      Process.demonitor(mon_ref, [:flush])
    end)

    %{state | pending_orphan_receipts: orphans, pending_drain: drains}
  end

  defp record_identity(record) when is_map(record) do
    {
      Map.get(record, :unit_name),
      Map.get(record, :execution_id),
      Map.get(record, :token)
    }
  end

  defp record_identity(_), do: {nil, nil, nil}

  defp collect_hints(state, worker_pids) do
    Enum.reduce(worker_pids, {[], []}, fn worker, {hints, unhintable} ->
      cond do
        not is_pid(worker) or not Process.alive?(worker) ->
          {hints, [worker | unhintable]}

        true ->
          case ownership_hint(state, worker) do
            {:ok, %{execution_id: execution_id}} when is_binary(execution_id) ->
              {[
                 %{worker_pid: worker, execution_id: execution_id}
                 | hints
               ], unhintable}

            _denied ->
              {hints, [worker | unhintable]}
          end
      end
    end)
  end

  defp ownership_hint(state, worker) do
    try do
      state.worker_module.ownership_hint(worker, state.ownership_call_timeout_ms)
    catch
      :exit, _ ->
        {:error, :ownership_denied}
    end
  end

  defp ownership_info(state, worker, record) do
    try do
      state.worker_module.ownership_info(worker, record, state.ownership_call_timeout_ms)
    catch
      :exit, _ ->
        {:error, :ownership_denied}
    end
  end

  defp apply_reconstruction_plan(state, plan, unhintable, live_set, records) do
    {verified, failed_workers, failed_records} =
      verify_candidates(state, plan.verification_candidates)

    orphan_records =
      dedupe_records(plan.orphan_records ++ failed_records)

    unmatched_workers =
      Enum.map(plan.unmatched_workers, & &1.worker_pid) ++ unhintable ++ failed_workers

    unmatched_workers =
      unmatched_workers
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(live_set, &1))

    state =
      state
      |> adopt_verified(verified)
      |> issue_orphan_recovery(orphan_records)
      |> issue_unmatched_drains(unmatched_workers)

    if reconstruction_settled?(state, orphan_records, unmatched_workers, verified, live_set) do
      state = %{state | phase: :ready}
      # Fresh observation reached :ready — every live worker is verified against
      # authoritative records, so executions absent from those records settle.
      settle_execution_waiters_absent_from(state, present_execution_ids(records))
    else
      schedule_reconstruct(state)
    end
  end

  defp verify_candidates(state, candidates) do
    Enum.reduce(candidates, {[], [], []}, fn candidate, {ok, bad_workers, bad_records} ->
      worker = candidate.worker_pid
      record = candidate.journal_record

      cond do
        not is_pid(worker) or not Process.alive?(worker) ->
          {ok, [worker | bad_workers], [record | bad_records]}

        true ->
          case ownership_info(state, worker, record) do
            {:ok, info} ->
              if exact_ownership_match?(info, record) do
                {[{worker, record} | ok], bad_workers, bad_records}
              else
                {ok, [worker | bad_workers], [record | bad_records]}
              end

            _denied ->
              {ok, [worker | bad_workers], [record | bad_records]}
          end
      end
    end)
  end

  defp exact_ownership_match?(info, record) when is_map(info) and is_map(record) do
    info_record = Map.get(info, :journal_record)
    info_exec = Map.get(info, :execution_id)
    record_exec = Map.get(record, :execution_id)

    is_map(info_record) and info_record == record and is_binary(info_exec) and
      info_exec == record_exec
  end

  defp exact_ownership_match?(_, _), do: false

  defp adopt_verified(state, verified) do
    Enum.reduce(verified, state, fn {worker, record}, acc ->
      if already_monitored_worker?(acc, worker) do
        acc
      else
        mon_ref = Process.monitor(worker)

        meta = %{
          worker_pid: worker,
          journal_record: record,
          execution_id: Map.get(record, :execution_id)
        }

        %{acc | monitored: Map.put(acc.monitored, mon_ref, meta)}
      end
    end)
  end

  defp already_monitored_worker?(state, worker) do
    Enum.any?(state.monitored, fn {_ref, meta} -> meta.worker_pid == worker end)
  end

  defp issue_orphan_recovery(state, orphan_records) do
    Enum.reduce(orphan_records, state, fn record, acc ->
      identity = record_identity(record)

      if pending_orphan_for_identity?(acc, identity) or
           map_size(acc.pending_orphan_receipts) >= @max_pending do
        acc
      else
        receipt_ref = make_ref()

        case recover_entry(acc, record, receipt_ref) do
          :ok ->
            %{
              acc
              | pending_orphan_receipts:
                  Map.put(acc.pending_orphan_receipts, receipt_ref, %{
                    unit_name: Map.get(record, :unit_name),
                    execution_id: Map.get(record, :execution_id),
                    token: Map.get(record, :token),
                    journal_record: record,
                    identity: identity
                  })
            }

          _error ->
            # Keep closed and retry on the next authoritative cycle.
            acc
        end
      end
    end)
  end

  defp pending_orphan_for_identity?(state, identity) do
    Enum.any?(state.pending_orphan_receipts, fn {_ref, meta} ->
      Map.get(meta, :identity) == identity or
        record_identity(Map.get(meta, :journal_record)) == identity
    end)
  end

  defp recover_entry(state, record, receipt_ref) do
    try do
      state.reconciler.recover_entry(record, receipt_ref, state.reconciler_server)
    catch
      :exit, _ ->
        {:error, :recovery_reconciler_unavailable}
    end
  end

  defp issue_unmatched_drains(state, workers) do
    Enum.reduce(workers, state, fn worker, acc ->
      if Map.has_key?(acc.pending_drain, worker) or map_size(acc.pending_drain) >= @max_pending do
        acc
      else
        receipt_ref = make_ref()

        case request_drain_handshake(acc, worker, receipt_ref) do
          :ok ->
            mon_ref =
              if already_monitored_worker?(acc, worker) do
                nil
              else
                Process.monitor(worker)
              end

            meta = %{
              receipt_ref: receipt_ref,
              accepted: true,
              mon_ref: mon_ref
            }

            %{acc | pending_drain: Map.put(acc.pending_drain, worker, meta)}

          _retryable ->
            # Bounded per-call wait already elapsed inside request_drain; keep
            # closed and re-issue on the next reconstruction cycle.
            acc
        end
      end
    end)
  end

  defp request_drain_handshake(state, worker, receipt_ref) do
    try do
      state.worker_module.request_drain(
        worker,
        receipt_ref,
        state.drain_handshake_timeout_ms
      )
    catch
      :exit, _reason ->
        {:error, :drain_handshake_failed}
    end
  end

  defp reconstruction_settled?(state, orphan_records, unmatched_workers, verified, live_set) do
    orphan_records == [] and unmatched_workers == [] and
      map_size(state.pending_orphan_receipts) == 0 and map_size(state.pending_drain) == 0 and
      all_live_verified_and_monitored?(state, verified, live_set)
  end

  defp all_live_verified_and_monitored?(state, verified, live_set) do
    verified_set = MapSet.new(Enum.map(verified, fn {worker, _record} -> worker end))
    monitored_set = MapSet.new(Enum.map(state.monitored, fn {_ref, meta} -> meta.worker_pid end))

    Enum.all?(live_set, fn worker ->
      Process.alive?(worker) and MapSet.member?(verified_set, worker) and
        MapSet.member?(monitored_set, worker)
    end) and
      Enum.all?(verified_set, fn worker ->
        Process.alive?(worker) and MapSet.member?(monitored_set, worker)
      end)
  end

  defp schedule_reconstruct(state) do
    state = cancel_reconstruct_timer(state)
    token = make_ref()
    timer_ref = :erlang.start_timer(state.reconstruct_retry_ms, self(), {:reconstruct, token})
    %{state | reconstruct_timer: {timer_ref, token}}
  end

  defp wake_reconstruction(state) do
    state =
      state
      |> cancel_reconstruct_timer()
      |> Map.put(:phase, :reconstructing)

    # Preserve pending receipt expectations across a wake so exact later
    # messages remain bound; snapshot reconcile prunes settled work.
    run_reconstruction(state)
  end

  defp cancel_reconstruct_timer(%{reconstruct_timer: {timer_ref, _token}} = state)
       when is_reference(timer_ref) do
    case :erlang.cancel_timer(timer_ref) do
      false ->
        # Timer already delivered or not found — flush only the exact message.
        receive do
          {:timeout, ^timer_ref, {:reconstruct, _token}} -> :ok
        after
          0 -> :ok
        end

      _remaining_ms ->
        :ok
    end

    %{state | reconstruct_timer: nil}
  end

  defp cancel_reconstruct_timer(state), do: %{state | reconstruct_timer: nil}

  defp expected_reconciler_sender?(state, sender_pid) when is_pid(sender_pid) do
    case state.reconciler_server do
      ^sender_pid ->
        true

      name when is_atom(name) ->
        Process.whereis(name) == sender_pid

      _other ->
        false
    end
  end

  defp handle_down(state, mon_ref, pid) do
    case Map.pop(state.execution_waiters, mon_ref) do
      {%{caller_pid: ^pid}, waiters} ->
        # Exact mon_ref + caller PID match only — remove that waiter. Never
        # settle remaining waiters and never treat caller death as absence proof.
        %{state | execution_waiters: waiters}

      {waiter, _waiters} when is_map(waiter) ->
        # mon_ref collision with wrong PID is impossible for Process.monitor;
        # a forged DOWN with a known ref but wrong PID must not remove anyone.
        state

      {nil, _} ->
        handle_down_non_waiter(state, mon_ref, pid)
    end
  end

  defp handle_down_non_waiter(state, mon_ref, pid) do
    # Reconciler monitor for barrier recover_all — DOWN is wakeup only; never
    # settles recover_all. Clear expectation and re-issue with fresh ref.
    case state.barrier_recover_all do
      %{mon_ref: ^mon_ref, reconciler_pid: ^pid} ->
        state = %{state | barrier_recover_all: nil, barrier_converged: false}

        if shutdown_preparation?(state.phase) do
          advance_shutdown_barrier(state)
        else
          state
        end

      _not_recover_all ->
        handle_worker_down(state, mon_ref, pid)
    end
  end

  defp handle_worker_down(state, mon_ref, pid) do
    case Map.pop(state.monitored, mon_ref) do
      {meta, monitored} when is_map(meta) ->
        # Do not settle pending_drain on DOWN — receipt or empty snapshot only.
        state = %{state | monitored: monitored}

        cond do
          shutdown_preparation?(state.phase) ->
            # Barrier: DOWN alone is never success; snapshot drives convergence.
            advance_shutdown_barrier(state)

          true ->
            # Ready or reconstructing: DOWN of an adopted worker is not containment.
            wake_reconstruction(state)
        end

      {nil, _} ->
        # Drain-only monitor (not in monitored adoption map).
        case Map.get(state.pending_drain, pid) do
          %{mon_ref: ^mon_ref} ->
            # Known drain monitor DOWN only wakes; never settles the receipt.
            if shutdown_preparation?(state.phase) do
              advance_shutdown_barrier(state)
            else
              wake_reconstruction(state)
            end

          _unknown ->
            # Forged or unknown DOWN — ignore (no reconstruction wake).
            state
        end
    end
  end

  defp dedupe_records(records) do
    records
    |> Enum.reduce({[], MapSet.new()}, fn record, {acc, seen} ->
      key = record_identity(record)

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[record | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Durable start admission
  # ---------------------------------------------------------------------------

  defp admit_start_unit(state, spec, executable, execution_id, start_ref, controller_pid) do
    with :ok <- validate_execution_id(execution_id),
         {:ok, unit_name} <- fetch_unit_name(spec),
         {:ok, timeout_ms} <- fetch_timeout_ms(spec),
         {:ok, now} <- monotonic_now(state) do
      # Absolute deadline is fixed BEFORE journal reserve.
      deadline = now + timeout_ms

      case reserve_record(state, unit_name, execution_id) do
        {:ok, record} ->
          case start_worker_durable(
                 state,
                 spec,
                 executable,
                 execution_id,
                 start_ref,
                 controller_pid,
                 record,
                 deadline
               ) do
            {:ok, worker} when is_pid(worker) ->
              mon_ref = Process.monitor(worker)

              meta = %{
                worker_pid: worker,
                journal_record: record,
                execution_id: execution_id
              }

              state = %{state | monitored: Map.put(state.monitored, mon_ref, meta)}
              {:reply, {:ok, worker}, state}

            {:error, reason} ->
              # Definite start error — no child admitted. Complete the exact row;
              # completion failure retains the row and re-enters reconstruction.
              state_after = handle_definite_start_failure(state, record, unit_name)
              {:reply, {:error, reason}, state_after}

            {:ambiguous, _detail} ->
              # Exit/throw/non-tuple after possible DynamicSupervisor admission.
              # Preserve the journal row and close into reconstruction.
              state_after = handle_ambiguous_start_failure(state, record)
              {:reply, {:error, :unit_start_indeterminate}, state_after}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_definite_start_failure(state, record, unit_name) do
    token = Map.get(record, :token)

    case complete_record(state, unit_name, token) do
      :ok ->
        state

      _complete_failed ->
        # Retain the durable row and re-enter closed reconstruction with exact recovery.
        handle_ambiguous_start_failure(state, record)
    end
  end

  defp handle_ambiguous_start_failure(state, record) do
    receipt_ref = make_ref()
    identity = record_identity(record)

    pending_orphan_receipts =
      case recover_entry(state, record, receipt_ref) do
        :ok ->
          Map.put(state.pending_orphan_receipts, receipt_ref, %{
            unit_name: Map.get(record, :unit_name),
            execution_id: Map.get(record, :execution_id),
            token: Map.get(record, :token),
            journal_record: record,
            identity: identity
          })

        _rejected ->
          # No receipt can arrive for rejected recovery work. Leave the exact
          # row unclaimed so the next authoritative cycle re-issues it.
          state.pending_orphan_receipts
      end

    state
    |> Map.put(:phase, :reconstructing)
    |> Map.put(:pending_orphan_receipts, pending_orphan_receipts)
    |> schedule_reconstruct()
  end

  defp reserve_record(state, unit_name, execution_id) do
    try do
      case state.journal.reserve_record(unit_name, execution_id, state.journal_server) do
        {:ok, record} when is_map(record) ->
          {:ok, record}

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :journal_reserve_failed}
      end
    catch
      :exit, _ ->
        {:error, :journal_unavailable}
    end
  end

  defp complete_record(state, unit_name, token) do
    try do
      state.journal.complete(unit_name, token, state.journal_server)
    catch
      :exit, _ ->
        {:error, :journal_unavailable}
    end
  end

  defp start_worker_durable(
         state,
         spec,
         executable,
         execution_id,
         start_ref,
         controller_pid,
         record,
         deadline
       ) do
    result =
      if is_function(state.worker_starter, 7) do
        state.worker_starter.(
          spec,
          executable,
          execution_id,
          start_ref,
          controller_pid,
          record,
          deadline
        )
      else
        state.worker_module.start_under_coordinator_durable(
          spec,
          executable,
          execution_id,
          start_ref,
          controller_pid,
          record,
          deadline
        )
      end

    case result do
      {:ok, worker} when is_pid(worker) ->
        {:ok, worker}

      {:error, reason} ->
        # Explicit definite non-admission only.
        {:error, reason}

      other ->
        {:ambiguous, other}
    end
  catch
    kind, reason ->
      # Exit/error/throw is ambiguous: a DynamicSupervisor child may already be live.
      {:ambiguous, {kind, reason}}
  end

  defp fetch_unit_name(%{plan: plan}) when is_map(plan) do
    name = Map.get(plan, :unit_name)

    if is_binary(name) and byte_size(name) > 0 and byte_size(name) <= @max_unit_name_bytes and
         String.valid?(name) do
      {:ok, name}
    else
      {:error, :invalid_unit_name}
    end
  end

  defp fetch_unit_name(_), do: {:error, :invalid_execution_spec}

  defp fetch_timeout_ms(%{timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_timeout_ms do
    {:ok, timeout_ms}
  end

  defp fetch_timeout_ms(_), do: {:error, :invalid_execution_spec}

  defp validate_execution_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_execution_id_bytes do
    if String.valid?(id) and not String.contains?(id, ["/", "\\", <<0>>]) do
      :ok
    else
      {:error, :invalid_execution_id}
    end
  end

  defp validate_execution_id(_), do: {:error, :invalid_execution_id}

  defp monotonic_now(%{clock: fun}) when is_function(fun, 0) do
    case fun.() do
      n when is_integer(n) -> {:ok, n}
      _ -> {:error, :invalid_clock}
    end
  end

  defp monotonic_now(%{clock: mod}) when is_atom(mod) do
    try do
      case mod.monotonic_ms() do
        n when is_integer(n) -> {:ok, n}
        _ -> {:error, :invalid_clock}
      end
    catch
      :exit, _ ->
        {:error, :invalid_clock}

      :error, _ ->
        {:error, :invalid_clock}
    end
  end

  # ---------------------------------------------------------------------------
  # Durable planned-shutdown barrier (nonblocking GenServer state machine)
  # ---------------------------------------------------------------------------

  defp shutdown_preparation?(phase) when phase in [:preparing_shutdown, :draining], do: true
  defp shutdown_preparation?(_), do: false

  defp enter_shutdown_preparation(state) do
    state
    |> cancel_reconstruct_timer()
    |> Map.put(:phase, :preparing_shutdown)
    # A new barrier request reopens progress even after a prior converge if
    # waiters are present; barrier_converged is re-checked via fresh evidence.
    |> Map.put(:barrier_converged, false)
  end

  # Single nonblocking step. Never Process.sleep / selective receive here —
  # parent EXIT and concurrent starts must keep flowing through GenServer.
  # Fail-closed: missing/failed UnitSupervisor or unavailable/poisoned Journal
  # is UNKNOWN and is never treated as empty. Execution settlement waiters reuse
  # this machine during preparing_shutdown even when no prep_stop waiter exists.
  defp advance_shutdown_barrier(state) do
    if barrier_progress_idle?(state) do
      cancel_barrier_timer(state)
    else
      state = cancel_barrier_timer(state)

      case snapshot_live_workers(state) do
        {:ok, workers} when is_list(workers) and workers != [] ->
          state =
            state
            |> ensure_barrier_drains(workers)
            |> attempt_barrier_handshakes()
            # Live workers: receipts settle; DOWN alone never settles.
            |> Map.put(:barrier_recover_all, normalize_recover_all_after_workers(state))
            |> Map.put(:barrier_converged, false)

          schedule_barrier_tick(state)

        {:ok, []} ->
          state = prune_barrier_drains_on_empty_snapshot(state)
          advance_barrier_after_empty_workers(state)

        {:error, _reason} ->
          # Missing/failed supervisor is UNKNOWN — never empty.
          state
          |> Map.put(:barrier_converged, false)
          |> schedule_barrier_tick()
      end
    end
  end

  defp barrier_progress_idle?(state) do
    state.barrier_waiters == [] and map_size(state.execution_waiters) == 0 and
      state.barrier_converged
  end

  defp normalize_recover_all_after_workers(%{barrier_recover_all: :completed}), do: nil
  defp normalize_recover_all_after_workers(%{barrier_recover_all: other}), do: other

  defp advance_barrier_after_empty_workers(state) do
    case journal_shutdown_status(state) do
      :disabled ->
        # Disabled journal: admission was closed and no durable unit can have
        # been admitted. Positive empty UnitSupervisor is sufficient.
        reply_barrier_success(state)

      :empty ->
        advance_barrier_recover_all_path(state)

      {:pending, _entries} ->
        advance_barrier_recover_all_path(state)

      {:unavailable, _reason} ->
        state
        |> Map.put(:barrier_converged, false)
        |> schedule_barrier_tick()
    end
  end

  defp advance_barrier_recover_all_path(state) do
    case state.barrier_recover_all do
      :completed ->
        fresh_verify_and_maybe_reply(state)

      %{reconciler_pid: pid, receipt_ref: ref, mon_ref: mon_ref} = meta
      when is_pid(pid) and is_reference(ref) and is_reference(mon_ref) ->
        # Already waiting on exact completion; tick only re-checks liveness.
        if Process.alive?(pid) do
          schedule_barrier_tick(state)
        else
          state = clear_barrier_recover_all(state, meta)
          state = %{state | barrier_recover_all: nil, barrier_converged: false}
          schedule_barrier_tick(state)
        end

      _none ->
        case issue_barrier_recover_all(state) do
          {:ok, next} ->
            schedule_barrier_tick(next)

          {:retry, next} ->
            schedule_barrier_tick(next)
        end
    end
  end

  defp fresh_verify_and_maybe_reply(state) do
    case snapshot_live_workers(state) do
      {:ok, []} ->
        case journal_shutdown_status(state) do
          :empty ->
            reply_barrier_success(state)

          :disabled ->
            reply_barrier_success(state)

          _not_empty ->
            # Need another recover_all / wait cycle.
            state = %{state | barrier_recover_all: nil, barrier_converged: false}
            schedule_barrier_tick(state)
        end

      {:ok, workers} when is_list(workers) and workers != [] ->
        state = %{state | barrier_recover_all: nil, barrier_converged: false}
        advance_shutdown_barrier(state)

      {:error, _} ->
        state = %{state | barrier_converged: false}
        schedule_barrier_tick(state)
    end
  end

  defp reply_barrier_success(state) do
    waiters = Enum.reverse(state.barrier_waiters)
    Enum.each(waiters, fn from -> GenServer.reply(from, :ok) end)

    state
    |> settle_all_execution_waiters()
    |> cancel_barrier_timer()
    |> Map.put(:barrier_waiters, [])
    |> Map.put(:barrier_converged, true)
    |> Map.put(:barrier_recover_all, nil)
  end

  defp journal_shutdown_status(state) do
    try do
      case state.journal.recovery_entries(state.journal_server) do
        {:ok, []} ->
          :empty

        {:ok, entries} when is_list(entries) ->
          {:pending, entries}

        {:error, :apple_container_unit_journal_disabled} ->
          :disabled

        {:error, reason} ->
          {:unavailable, reason}

        _other ->
          {:unavailable, :journal_unavailable}
      end
    catch
      :exit, _ ->
        {:unavailable, :journal_unavailable}
    end
  end

  # Track exact mon_ref per worker; reuse adoption monitors when present.
  # Never create throwaway untracked monitors.
  defp ensure_barrier_drains(state, workers) do
    Enum.reduce(workers, state, fn worker, acc ->
      if is_pid(worker) do
        case Map.get(acc.pending_drain, worker) do
          %{receipt_ref: ref} = meta when is_reference(ref) ->
            acc = ensure_drain_monitor(acc, worker, meta)
            acc

          _missing ->
            receipt_ref = make_ref()
            meta = %{receipt_ref: receipt_ref, accepted: false, mon_ref: nil}
            acc = %{acc | pending_drain: Map.put(acc.pending_drain, worker, meta)}
            ensure_drain_monitor(acc, worker, meta)
        end
      else
        acc
      end
    end)
  end

  defp ensure_drain_monitor(state, worker, meta) do
    cond do
      is_reference(Map.get(meta, :mon_ref)) ->
        state

      already_monitored_worker?(state, worker) ->
        # Adoption monitor already covers DOWN wakeups — do not double-monitor.
        mon_ref = find_monitored_ref(state, worker)

        meta =
          meta
          |> Map.put(:mon_ref, mon_ref)
          |> Map.put(:owned_monitor, false)

        %{state | pending_drain: Map.put(state.pending_drain, worker, meta)}

      true ->
        mon_ref = Process.monitor(worker)

        meta =
          meta
          |> Map.put(:mon_ref, mon_ref)
          |> Map.put(:owned_monitor, true)

        %{state | pending_drain: Map.put(state.pending_drain, worker, meta)}
    end
  end

  defp find_monitored_ref(state, worker) do
    Enum.find_value(state.monitored, fn
      {mon_ref, %{worker_pid: ^worker}} -> mon_ref
      _ -> nil
    end)
  end

  defp attempt_barrier_handshakes(state) do
    pending =
      Enum.reduce(state.pending_drain, %{}, fn {worker, meta}, acc ->
        if meta.accepted do
          Map.put(acc, worker, meta)
        else
          case request_drain_handshake(state, worker, meta.receipt_ref) do
            :ok ->
              Map.put(acc, worker, %{meta | accepted: true})

            _other ->
              Map.put(acc, worker, meta)
          end
        end
      end)

    %{state | pending_drain: pending}
  end

  defp settle_barrier_drain(state, worker_pid, meta) do
    if Map.get(meta, :owned_monitor) == true and is_reference(Map.get(meta, :mon_ref)) do
      Process.demonitor(meta.mon_ref, [:flush])
    end

    %{
      state
      | pending_drain: Map.delete(state.pending_drain, worker_pid),
        barrier_converged: false
    }
  end

  # Empty UnitSupervisor is positive "no live workers" evidence. Drop drain
  # expectations for workers no longer live and demonitor owned refs only.
  defp prune_barrier_drains_on_empty_snapshot(state) do
    Enum.each(state.pending_drain, fn {_worker, meta} ->
      if Map.get(meta, :owned_monitor) == true and is_reference(Map.get(meta, :mon_ref)) do
        Process.demonitor(meta.mon_ref, [:flush])
      end
    end)

    %{state | pending_drain: %{}}
  end

  defp issue_barrier_recover_all(state) do
    case resolve_reconciler_pid(state) do
      {:ok, reconciler_pid} ->
        mon_ref = Process.monitor(reconciler_pid)
        receipt_ref = make_ref()

        case invoke_recover_all(state, receipt_ref, reconciler_pid) do
          :ok ->
            meta = %{
              reconciler_pid: reconciler_pid,
              mon_ref: mon_ref,
              receipt_ref: receipt_ref
            }

            {:ok, %{state | barrier_recover_all: meta, barrier_converged: false}}

          {:error, _reason} ->
            Process.demonitor(mon_ref, [:flush])
            # Rejection while dependencies recover: retry with replacement + fresh ref.
            {:retry, %{state | barrier_recover_all: nil, barrier_converged: false}}
        end

      {:error, _reason} ->
        {:retry, %{state | barrier_recover_all: nil, barrier_converged: false}}
    end
  end

  defp resolve_reconciler_pid(state) do
    case state.reconciler_server do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :reconciler_unavailable}

      name when is_atom(name) and not is_nil(name) ->
        case Process.whereis(name) do
          pid when is_pid(pid) -> {:ok, pid}
          _missing -> {:error, :reconciler_unavailable}
        end

      {:global, _} = server ->
        case GenServer.whereis(server) do
          pid when is_pid(pid) -> {:ok, pid}
          _missing -> {:error, :reconciler_unavailable}
        end

      {:via, _, _} = server ->
        case GenServer.whereis(server) do
          pid when is_pid(pid) -> {:ok, pid}
          _missing -> {:error, :reconciler_unavailable}
        end

      _other ->
        {:error, :reconciler_unavailable}
    end
  end

  defp invoke_recover_all(state, receipt_ref, reconciler_pid) do
    try do
      state.reconciler.recover_all(receipt_ref, reconciler_pid)
    catch
      :exit, _ ->
        {:error, :recovery_reconciler_unavailable}
    end
  end

  defp clear_barrier_recover_all(state, meta) when is_map(meta) do
    if is_reference(Map.get(meta, :mon_ref)) do
      Process.demonitor(meta.mon_ref, [:flush])
    end

    %{state | barrier_recover_all: nil}
  end

  defp clear_barrier_recover_all(state, _), do: state

  defp clear_barrier_recover_all_monitors(state) do
    case state.barrier_recover_all do
      %{mon_ref: mon_ref} when is_reference(mon_ref) ->
        Process.demonitor(mon_ref, [:flush])

      _ ->
        :ok
    end

    state
  end

  defp schedule_barrier_tick(state) do
    state = cancel_barrier_timer(state)
    token = make_ref()
    timer_ref = :erlang.start_timer(@shutdown_barrier_retry_ms, self(), {:barrier, token})
    %{state | barrier_timer: {timer_ref, token}}
  end

  defp cancel_barrier_timer(%{barrier_timer: {timer_ref, _token}} = state)
       when is_reference(timer_ref) do
    case :erlang.cancel_timer(timer_ref) do
      false ->
        receive do
          {:timeout, ^timer_ref, {:barrier, _token}} -> :ok
        after
          0 -> :ok
        end

      _remaining_ms ->
        :ok
    end

    %{state | barrier_timer: nil}
  end

  defp cancel_barrier_timer(state), do: %{state | barrier_timer: nil}

  defp valid_execution_id?(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_execution_id_bytes do
    String.valid?(id)
  end

  defp valid_execution_id?(_), do: false

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  defp redact_state(state) when is_map(state) do
    %{
      mode: Map.get(state, :mode),
      phase: Map.get(state, :phase),
      monitored_count: map_size(Map.get(state, :monitored) || %{}),
      pending_orphan_count: map_size(Map.get(state, :pending_orphan_receipts) || %{}),
      pending_drain_count: map_size(Map.get(state, :pending_drain) || %{}),
      reconstruct_generation: Map.get(state, :reconstruct_generation),
      barrier_waiter_count: length(Map.get(state, :barrier_waiters) || []),
      barrier_converged: Map.get(state, :barrier_converged),
      execution_waiter_count: map_size(Map.get(state, :execution_waiters) || %{}),
      monitored: :redacted,
      pending_orphan_receipts: :redacted,
      pending_drain: :redacted,
      barrier_waiters: :redacted,
      barrier_timer: :redacted,
      barrier_recover_all: :redacted,
      execution_waiters: :redacted,
      journal: :redacted,
      journal_server: :redacted,
      reconciler: :redacted,
      reconciler_server: :redacted,
      unit_supervisor: :redacted,
      worker_module: :redacted,
      clock: :redacted,
      worker_starter: :redacted,
      snapshot_workers: :redacted,
      reconstruct_timer: :redacted,
      ownership_call_timeout_ms: :redacted,
      drain_handshake_timeout_ms: :redacted,
      reconstruct_retry_ms: :redacted
    }
  end

  defp redact_state(_), do: :redacted

  # ---------------------------------------------------------------------------
  # Exact execution settlement waiters
  # ---------------------------------------------------------------------------

  defp register_execution_waiter(state, execution_id, from) do
    with :ok <- validate_execution_id(execution_id),
         :ok <- check_execution_waiter_capacity(state),
         {:ok, caller_pid} <- caller_pid_from(from) do
      # One Process.monitor per registered waiter — never throwaway/untracked.
      mon_ref = Process.monitor(caller_pid)

      waiter = %{
        from: from,
        execution_id: execution_id,
        caller_pid: caller_pid
      }

      {:ok, %{state | execution_waiters: Map.put(state.execution_waiters, mon_ref, waiter)}}
    end
  end

  defp check_execution_waiter_capacity(state) do
    if map_size(state.execution_waiters) >= @max_execution_waiters do
      {:error, :too_many_execution_waiters}
    else
      :ok
    end
  end

  defp caller_pid_from({pid, _tag}) when is_pid(pid), do: {:ok, pid}
  defp caller_pid_from(_), do: {:error, :invalid_waiter_from}

  # Force progress without blocking the GenServer loop. Cached :ready is never
  # sufficient — every registration drives a fresh authoritative observation.
  defp drive_execution_settlement(state) do
    if shutdown_preparation?(state.phase) do
      state
      |> Map.put(:barrier_converged, false)
      |> advance_shutdown_barrier()
    else
      wake_reconstruction(state)
    end
  end

  defp present_execution_ids(records) when is_list(records) do
    records
    |> Enum.reduce(MapSet.new(), fn record, acc ->
      case Map.get(record, :execution_id) do
        id when is_binary(id) -> MapSet.put(acc, id)
        _ -> acc
      end
    end)
  end

  defp present_execution_ids(_), do: MapSet.new()

  defp settle_execution_waiters_absent_from(state, present_exec_ids)
       when is_map(present_exec_ids) or is_struct(present_exec_ids, MapSet) do
    if map_size(state.execution_waiters) == 0 do
      state
    else
      {remaining, settled} =
        Enum.reduce(state.execution_waiters, {%{}, []}, fn {mon_ref, waiter}, {keep, done} ->
          if MapSet.member?(present_exec_ids, waiter.execution_id) do
            {Map.put(keep, mon_ref, waiter), done}
          else
            {keep, [{mon_ref, waiter} | done]}
          end
        end)

      Enum.each(settled, fn {mon_ref, waiter} ->
        Process.demonitor(mon_ref, [:flush])
        GenServer.reply(waiter.from, :ok)
      end)

      %{state | execution_waiters: remaining}
    end
  end

  defp settle_all_execution_waiters(state) do
    Enum.each(state.execution_waiters, fn {mon_ref, waiter} ->
      Process.demonitor(mon_ref, [:flush])
      GenServer.reply(waiter.from, :ok)
    end)

    %{state | execution_waiters: %{}}
  end

  defp demonitor_execution_waiters(state) do
    Enum.each(Map.get(state, :execution_waiters) || %{}, fn {mon_ref, _waiter} ->
      if is_reference(mon_ref), do: Process.demonitor(mon_ref, [:flush])
    end)

    state
  end
end
