defmodule Arbor.Shell.AppleContainerUnitRecoveryReconciler do
  @moduledoc """
  Imperative shell for Apple Container unit-intent recovery reconciliation.

  Interprets pure `AppleContainerUnitRecoveryReconcilerCore` effects: loads the
  unit journal, starts temporary `AppleContainerUnitRecoveryWorker` children
  under the dedicated recovery DynamicSupervisor, matches exact worker
  receipts, and notifies only the registered drain coordinator after
  authoritative journal re-reads prove absence.

  Coordinator request idempotency spans both pending work and a pure-core
  bounded FIFO settled-request ledger (see
  `AppleContainerUnitRecoveryReconcilerCore`). Exact caller/ref pairs replay
  as `:ok` with no journal reread, worker start, or duplicate notification
  while retained in that finite window; conflicting receipt-ref reuse fails
  closed. New `recover_entry` admissions still require a journal presence
  proof; known settled/pending refs skip that proof.

  Production admission is sealed (`:production` only). Runtime execution never
  imports PortSession, UnitWorker, or DrainCoordinator implementation modules —
  the coordinator module atom is used solely for registered-caller authorization.
  """

  use GenServer

  alias Arbor.Shell.AppleContainerUnitJournal
  alias Arbor.Shell.AppleContainerUnitJournalCore, as: JournalCore
  alias Arbor.Shell.AppleContainerUnitRecoveryReconcilerCore, as: Core
  alias Arbor.Shell.AppleContainerUnitRecoveryWorker
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutablePolicy.Executable

  @name __MODULE__
  @worker_supervisor Arbor.Shell.AppleContainerUnitRecoveryWorkerSupervisor
  @coordinator_module Arbor.Shell.AppleContainerUnitDrainCoordinator
  @runtime_path "/usr/local/bin/container"

  @required_journal_callbacks [{:recovery_entries, 1}]

  @type production_args :: :production

  @type test_only_args :: {:test_only, keyword()}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start the production reconciler (named `#{inspect(__MODULE__)}`).

  Hardcodes the unit journal, ExecutablePolicy resolution of
  `#{@runtime_path}`, the recovery worker DynamicSupervisor, and
  `AppleContainerUnitRecoveryWorker.production_child_args/4`.
  """
  @spec start_link(production_args() | test_only_args()) :: GenServer.on_start()
  def start_link(:production) do
    GenServer.start_link(__MODULE__, :production, name: @name)
  end

  def start_link({:test_only, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      name = Keyword.get(opts, :name, @name)
      GenServer.start_link(__MODULE__, {:test_only, opts}, name: name)
    else
      {:error, :invalid_recovery_reconciler_start}
    end
  end

  def start_link(_other), do: {:error, :invalid_recovery_reconciler_start}

  @doc false
  def child_spec(:production) do
    %{
      id: @name,
      start: {__MODULE__, :start_link, [:production]},
      type: :worker,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  def child_spec(_other) do
    raise ArgumentError,
          "AppleContainerUnitRecoveryReconciler.child_spec/1 requires sealed :production"
  end

  @doc false
  @spec start_for_test(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_for_test(opts \\ []) when is_list(opts) do
    start_link({:test_only, opts})
  end

  @doc """
  Coordinator-only targeted recovery of one exact journal record.

  Returns only acceptance/error. On success the reconciler eventually sends
  exactly one:

      {:apple_container_unit_recovery_entry_complete, reconciler_pid, unit_name, receipt_ref}

  to the requesting coordinator process after an authoritative journal re-read
  proves that exact record absent. Never includes token or execution_id.

  Exact caller/receipt_ref/identity pairs are idempotent while pending and
  while retained in the finite settled-request ledger after completion.
  Conflicting reuse of a receipt ref fails closed with
  `{:error, :conflicting_request_ref}`.
  """
  @spec recover_entry(term(), reference(), GenServer.server()) :: :ok | {:error, term()}
  def recover_entry(record, receipt_ref, server \\ @name)

  def recover_entry(record, receipt_ref, server)
      when is_reference(receipt_ref) do
    call(server, {:recover_entry, record, receipt_ref})
  end

  def recover_entry(_record, _receipt_ref, _server), do: {:error, :invalid_recover_entry}

  @doc """
  Coordinator-only full-journal recovery sweep.

  Returns only acceptance/error. On success eventually sends exactly one:

      {:apple_container_unit_recovery_all_complete, reconciler_pid, receipt_ref}

  after an authoritative re-read proves the journal empty and no recovery
  workers remain.

  Exact caller/receipt_ref pairs are idempotent while pending and while
  retained in the finite settled-request ledger after completion.
  """
  @spec recover_all(reference(), GenServer.server()) :: :ok | {:error, term()}
  def recover_all(receipt_ref, server \\ @name)

  def recover_all(receipt_ref, server) when is_reference(receipt_ref) do
    call(server, {:recover_all, receipt_ref})
  end

  def recover_all(_receipt_ref, _server), do: {:error, :invalid_recover_all}

  @doc """
  Bounded public status. Exposes only phase-like state and counts — never
  records, tokens, execution IDs, refs, PIDs, or module seams.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ @name) do
    case call(server, :status) do
      {:ok, status} when is_map(status) -> status
      _other -> %{"phase" => "unavailable", "worker_count" => 0}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(:production) do
    Process.flag(:trap_exit, true)

    state = %{
      mode: :production,
      core: nil,
      journal: AppleContainerUnitJournal,
      journal_server: AppleContainerUnitJournal,
      worker_supervisor: @worker_supervisor,
      worker_module: AppleContainerUnitRecoveryWorker,
      worker_launcher: nil,
      executable_resolver: &production_resolve_executable/0,
      coordinator_module: @coordinator_module,
      timers: %{},
      monitors: %{}
    }

    {:ok, core, effects} = Core.new()
    {:ok, %{state | core: core}, {:continue, {:effects, effects}}}
  end

  def init({:test_only, opts}) when is_list(opts) do
    Process.flag(:trap_exit, true)

    journal = Keyword.get(opts, :journal)
    journal_server = Keyword.get(opts, :journal_server, journal)
    worker_supervisor = Keyword.get(opts, :worker_supervisor)
    worker_launcher = Keyword.get(opts, :worker_launcher)
    executable = Keyword.get(opts, :executable)
    coordinator_module = Keyword.get(opts, :coordinator_module, @coordinator_module)

    with :ok <- validate_journal_module(journal),
         :ok <- validate_journal_server(journal_server),
         :ok <- validate_worker_supervisor(worker_supervisor),
         :ok <- validate_worker_launcher(worker_launcher),
         :ok <- validate_executable(executable),
         :ok <- validate_coordinator_module(coordinator_module) do
      state = %{
        mode: :test_only,
        core: nil,
        journal: journal,
        journal_server: journal_server,
        worker_supervisor: worker_supervisor,
        worker_module: Keyword.get(opts, :worker_module, AppleContainerUnitRecoveryWorker),
        worker_launcher: worker_launcher,
        executable_resolver: fn -> {:ok, executable} end,
        coordinator_module: coordinator_module,
        timers: %{},
        monitors: %{}
      }

      {:ok, core, effects} = Core.new()
      {:ok, %{state | core: core}, {:continue, {:effects, effects}}}
    else
      {:error, reason} ->
        {:stop, {:recovery_reconciler_start_failed, bound_reason(reason)}}
    end
  end

  def init(_other), do: {:stop, :invalid_recovery_reconciler_start}

  @impl true
  def handle_continue({:effects, effects}, state) when is_list(effects) do
    dispatch_effects(state, effects)
  end

  def handle_continue(:load_journal, state) do
    load_and_apply_journal(state)
  end

  def handle_continue(:verify_settlements, state) do
    verify_and_apply(state)
  end

  def handle_continue(other, state) do
    {:stop, {:invalid_continuation, bound_reason(other)}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      case Core.show(state.core) do
        %{} = shown -> shown
        _ -> %{"phase" => "unavailable", "worker_count" => 0}
      end

    {:reply, {:ok, status}, state}
  end

  def handle_call({:recover_entry, record, receipt_ref}, {caller_pid, _tag}, state)
      when is_pid(caller_pid) and is_reference(receipt_ref) do
    with :ok <- authorize_coordinator(caller_pid, state),
         {:ok, normalized} <- validate_entry_record(record),
         :ok <- require_ready(state),
         :ok <- maybe_require_journal_presence(state, receipt_ref, normalized) do
      case Core.request_recover_entry(state.core, normalized, caller_pid, receipt_ref) do
        {:ok, core, effects} ->
          state = %{state | core: core}

          case dispatch_effects(state, effects) do
            {:noreply, next} ->
              {:reply, :ok, next}

            {:noreply, next, cont} ->
              {:reply, :ok, next, cont}

            {:stop, reason, next} ->
              {:stop, reason, {:error, :reconciler_stopping}, next}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recover_entry, _record, _receipt_ref}, _from, state) do
    {:reply, {:error, :invalid_recover_entry}, state}
  end

  def handle_call({:recover_all, receipt_ref}, {caller_pid, _tag}, state)
      when is_pid(caller_pid) and is_reference(receipt_ref) do
    with :ok <- authorize_coordinator(caller_pid, state),
         :ok <- require_ready(state) do
      case Core.request_recover_all(state.core, caller_pid, receipt_ref) do
        {:ok, core, effects} ->
          state = %{state | core: core}

          case dispatch_effects(state, effects) do
            {:noreply, next} ->
              {:reply, :ok, next}

            {:noreply, next, cont} ->
              {:reply, :ok, next, cont}

            {:stop, reason, next} ->
              {:stop, reason, {:error, :reconciler_stopping}, next}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recover_all, _receipt_ref}, _from, state) do
    {:reply, {:error, :invalid_recover_all}, state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_recovery_reconciler_request}, state}
  end

  @impl true
  def handle_info({:timeout, timer_ref, action}, state) when is_reference(timer_ref) do
    case Map.pop(state.timers, timer_ref) do
      {nil, _timers} ->
        # Unknown/stale timer ref — ignore without journal IO or launch.
        {:noreply, state}

      {^action, timers} ->
        state = %{state | timers: timers}
        handle_timer_action(state, action)

      {_other, timers} ->
        # Payload mismatch — fail closed on the timer without side effects.
        {:noreply, %{state | timers: timers}}
    end
  end

  def handle_info(
        {:apple_container_unit_recovered, worker_pid, unit_name, receipt_ref},
        state
      )
      when is_pid(worker_pid) and is_binary(unit_name) and is_reference(receipt_ref) do
    case Core.apply_worker_receipt(state.core, worker_pid, unit_name, receipt_ref) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core}, effects)

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, pid, _reason}, state)
      when is_reference(mon_ref) and is_pid(pid) do
    state = drop_monitor(state, mon_ref, pid)

    case Core.apply_worker_down(state.core, pid) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core}, effects)

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_all_timers(state)
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redact_state(state))
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  def format_status(status), do: status

  # ---------------------------------------------------------------------------
  # Effect dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_effects(state, []), do: {:noreply, state}

  defp dispatch_effects(state, [effect | rest]) do
    case apply_effect(state, effect) do
      {:noreply, next} ->
        dispatch_effects(next, rest)

      {:noreply, next, {:continue, cont}} ->
        if rest == [] do
          {:noreply, next, {:continue, cont}}
        else
          case dispatch_effects(next, rest) do
            {:noreply, after_rest} ->
              {:noreply, after_rest, {:continue, cont}}

            {:noreply, after_rest, {:continue, later}} ->
              {:noreply, after_rest, {:continue, later}}

            {:stop, reason, after_rest} ->
              {:stop, reason, after_rest}
          end
        end

      {:effects, next, more} when is_list(more) ->
        dispatch_effects(next, more ++ rest)

      {:stop, reason, next} ->
        {:stop, reason, next}
    end
  end

  defp apply_effect(state, {:load_journal}) do
    {:noreply, state, {:continue, :load_journal}}
  end

  defp apply_effect(state, {:verify_settlements}) do
    {:noreply, state, {:continue, :verify_settlements}}
  end

  defp apply_effect(state, {:retry_after, delay_ms, action, generation})
       when is_integer(delay_ms) and delay_ms >= 0 and is_integer(generation) and generation >= 0 do
    if valid_retry_action?(action) do
      payload = {:retry, generation, action}
      timer_ref = :erlang.start_timer(delay_ms, self(), payload)
      timers = Map.put(state.timers, timer_ref, payload)
      {:noreply, %{state | timers: timers}}
    else
      {:stop, {:unexpected_reconciler_effect, :invalid_retry_action}, state}
    end
  end

  defp apply_effect(state, {:restart_worker_after, delay_ms, record, generation})
       when is_integer(delay_ms) and delay_ms >= 0 and is_map(record) and is_integer(generation) and
              generation >= 0 do
    # Timer carries generation + identity only. Firing never launches directly —
    # consume_retry re-emits {:start_worker, ...} which re-authorizes via core.
    payload = {:retry, generation, {:start_worker, record}}
    timer_ref = :erlang.start_timer(delay_ms, self(), payload)
    timers = Map.put(state.timers, timer_ref, payload)
    {:noreply, %{state | timers: timers}}
  end

  defp apply_effect(state, {:start_worker, record}) when is_map(record) do
    # Never invoke the launcher from a raw start request. Re-read the journal
    # and require exact-identity authorization through the pure core.
    authorize_and_maybe_launch(state, record)
  end

  defp apply_effect(state, {:launch_worker, record}) when is_map(record) do
    # Only effect that may invoke the impure launcher — emitted solely by
    # Core.authorize_launch/3 after a fresh authoritative snapshot.
    start_worker_for_record(state, record)
  end

  defp apply_effect(state, {:notify_entry_complete, caller_pid, unit_name, receipt_ref})
       when is_pid(caller_pid) and is_binary(unit_name) and is_reference(receipt_ref) do
    send(
      caller_pid,
      {:apple_container_unit_recovery_entry_complete, self(), unit_name, receipt_ref}
    )

    {:noreply, state}
  end

  defp apply_effect(state, {:notify_all_complete, caller_pid, receipt_ref})
       when is_pid(caller_pid) and is_reference(receipt_ref) do
    send(caller_pid, {:apple_container_unit_recovery_all_complete, self(), receipt_ref})
    {:noreply, state}
  end

  defp apply_effect(state, other) do
    {:stop, {:unexpected_reconciler_effect, bound_reason(other)}, state}
  end

  defp handle_timer_action(state, {:retry, generation, action})
       when is_integer(generation) and generation >= 0 do
    case Core.consume_retry(state.core, generation, action) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core}, effects)

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  defp handle_timer_action(state, _other), do: {:noreply, state}

  defp valid_retry_action?(action) when action in [:load_journal, :verify_settlements], do: true
  defp valid_retry_action?({:start_worker, record}) when is_map(record), do: true
  defp valid_retry_action?(_), do: false

  defp authorize_and_maybe_launch(state, record) do
    case invoke_recovery_entries(state) do
      {:ok, entries} when is_list(entries) ->
        case Core.authorize_launch(state.core, record, entries) do
          {:ok, core, effects} ->
            dispatch_effects(%{state | core: core}, effects)

          {:error, reason} ->
            apply_start_failed(state, record, reason)
        end

      {:error, reason} ->
        # Journal unavailable at launch boundary — retain admission and retry
        # via the core's unavailable path (never launch blindly).
        apply_journal_unavailable(state, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Journal
  # ---------------------------------------------------------------------------

  defp load_and_apply_journal(state) do
    case invoke_recovery_entries(state) do
      {:ok, entries} when is_list(entries) ->
        case Core.apply_journal_ok(state.core, entries) do
          {:ok, core, effects} ->
            dispatch_effects(%{state | core: core}, effects)

          {:error, reason} ->
            # Malformed entries: treat as journal unavailable and retry.
            apply_journal_unavailable(state, reason)
        end

      {:error, reason} ->
        apply_journal_unavailable(state, reason)
    end
  end

  defp verify_and_apply(state) do
    case invoke_recovery_entries(state) do
      {:ok, entries} when is_list(entries) ->
        case Core.apply_verify_result(state.core, entries) do
          {:ok, core, effects} ->
            dispatch_effects(%{state | core: core}, effects)

          {:error, reason} ->
            apply_journal_unavailable(state, reason)
        end

      {:error, reason} ->
        # Never notify from receipt alone — retain and retry.
        apply_journal_unavailable(state, reason)
    end
  end

  defp apply_journal_unavailable(state, reason) do
    case Core.apply_journal_error(state.core, reason) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core}, effects)

      {:error, _core_reason} ->
        {:noreply, state}
    end
  end

  defp invoke_recovery_entries(state) do
    case state.journal.recovery_entries(state.journal_server) do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :unexpected_journal_result}
    end
  catch
    :exit, _reason ->
      {:error, :journal_call_failed}

    :error, _reason ->
      {:error, :journal_call_failed}

    :throw, _reason ->
      {:error, :journal_call_failed}
  end

  # Pending and settled exact/conflict rows are decided purely in the core.
  # Skip journal presence for known receipt refs so settled exact replay needs
  # no journal reread and never fails as :journal_entry_absent.
  defp maybe_require_journal_presence(state, receipt_ref, record) do
    if Core.known_request_ref?(state.core, receipt_ref) do
      :ok
    else
      verify_journal_contains_exact(state, record)
    end
  end

  defp verify_journal_contains_exact(state, record) do
    case invoke_recovery_entries(state) do
      {:ok, entries} ->
        case find_exact_entry(entries, record) do
          :ok ->
            :ok

          {:error, :identity_mismatch} ->
            {:error, :identity_mismatch}

          {:error, :not_present} ->
            {:error, :journal_entry_absent}
        end

      {:error, reason} ->
        {:error, {:journal_unavailable, bound_reason(reason)}}
    end
  end

  defp find_exact_entry(entries, record) when is_list(entries) do
    Enum.reduce_while(entries, {:error, :not_present}, fn entry, acc ->
      case normalize_entry(entry) do
        {:ok, other} ->
          cond do
            other.unit_name == record.unit_name and other.token == record.token and
              other.execution_id == record.execution_id and
                other.reserved_at_ms == record.reserved_at_ms ->
              {:halt, :ok}

            other.unit_name == record.unit_name ->
              {:halt, {:error, :identity_mismatch}}

            true ->
              {:cont, acc}
          end

        {:error, _reason} ->
          {:cont, acc}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Workers
  # ---------------------------------------------------------------------------

  defp start_worker_for_record(state, record) do
    receipt_ref = make_ref()

    case do_start_worker(state, record, receipt_ref) do
      {:ok, worker_pid} when is_pid(worker_pid) ->
        mon_ref = Process.monitor(worker_pid)
        state = put_monitor(state, mon_ref, worker_pid)

        case Core.worker_started(state.core, record, worker_pid, receipt_ref) do
          {:ok, core, effects} ->
            dispatch_effects(%{state | core: core}, effects)

          {:error, reason} ->
            # Unexpected core rejection after start — stop the orphan worker.
            _ = DynamicSupervisor.terminate_child(state.worker_supervisor, worker_pid)
            apply_start_failed(state, record, reason)
        end

      {:error, reason} ->
        apply_start_failed(state, record, reason)
    end
  end

  defp apply_start_failed(state, record, _reason) do
    case Core.worker_start_failed(state.core, record) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core}, effects)

      {:error, _core_reason} ->
        {:noreply, state}
    end
  end

  defp do_start_worker(%{mode: :production} = state, record, receipt_ref) do
    with {:ok, executable} <- state.executable_resolver.(),
         {:ok, args} <-
           AppleContainerUnitRecoveryWorker.production_child_args(
             wire_entry(record),
             executable,
             self(),
             receipt_ref
           ) do
      DynamicSupervisor.start_child(
        state.worker_supervisor,
        {AppleContainerUnitRecoveryWorker, args}
      )
    end
  end

  defp do_start_worker(%{mode: :test_only} = state, record, receipt_ref) do
    launcher = state.worker_launcher

    case launcher.(wire_entry(record), self(), receipt_ref, state.worker_supervisor) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_worker_launcher_result, bound_reason(other)}}
    end
  catch
    :exit, reason ->
      {:error, {:worker_launcher_exit, bound_reason(reason)}}

    :error, reason ->
      {:error, {:worker_launcher_error, bound_reason(reason)}}

    :throw, reason ->
      {:error, {:worker_launcher_throw, bound_reason(reason)}}
  end

  defp wire_entry(%{
         unit_name: unit_name,
         execution_id: execution_id,
         token: token,
         reserved_at_ms: reserved_at_ms
       }) do
    %{
      "unit_name" => unit_name,
      "execution_id" => execution_id,
      "token" => token,
      "reserved_at_ms" => reserved_at_ms
    }
  end

  defp production_resolve_executable do
    case ExecutablePolicy.resolve(@runtime_path) do
      {:ok, %Executable{path: @runtime_path} = executable} ->
        {:ok, executable}

      {:ok, %Executable{}} ->
        {:error, :invalid_recovery_executable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization / admission
  # ---------------------------------------------------------------------------

  defp authorize_coordinator(caller_pid, state) when is_pid(caller_pid) do
    case Process.whereis(state.coordinator_module) do
      ^caller_pid ->
        :ok

      _other ->
        {:error, :unauthorized_recovery_caller}
    end
  end

  defp require_ready(state) do
    if Core.ready?(state.core) do
      :ok
    else
      {:error, :reconciler_not_ready}
    end
  end

  defp validate_entry_record(record) do
    normalize_entry(record)
  end

  defp normalize_entry(entry) when is_map(entry) do
    snapshot = %{
      "schema_version" => 1,
      "generation" => 1,
      "active" => [entry]
    }

    case JournalCore.new(snapshot) do
      {:ok, journal} ->
        case JournalCore.recovery_entries(journal) do
          [normalized] when is_map(normalized) ->
            {:ok, normalized}

          _other ->
            {:error, :invalid_journal_entry}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_entry(_), do: {:error, :invalid_journal_entry}

  defp validate_journal_module(journal) when is_atom(journal) and not is_nil(journal) do
    case Code.ensure_loaded(journal) do
      {:module, ^journal} ->
        if Enum.all?(@required_journal_callbacks, fn {fun, arity} ->
             function_exported?(journal, fun, arity)
           end) do
          :ok
        else
          {:error, :invalid_journal_module}
        end

      _ ->
        {:error, :invalid_journal_module}
    end
  end

  defp validate_journal_module(_), do: {:error, :invalid_journal_module}

  defp validate_journal_server(server) when is_atom(server) or is_pid(server), do: :ok
  defp validate_journal_server({:global, _}), do: :ok
  defp validate_journal_server({:via, mod, _}) when is_atom(mod), do: :ok
  defp validate_journal_server(_), do: {:error, :invalid_journal_server}

  defp validate_worker_supervisor(name) when is_atom(name) and not is_nil(name), do: :ok
  defp validate_worker_supervisor(pid) when is_pid(pid), do: :ok
  defp validate_worker_supervisor(_), do: {:error, :invalid_worker_supervisor}

  defp validate_worker_launcher(launcher) when is_function(launcher, 4), do: :ok
  defp validate_worker_launcher(_), do: {:error, :invalid_worker_launcher}

  defp validate_executable(%Executable{path: @runtime_path}), do: :ok
  defp validate_executable(%Executable{}), do: {:error, :invalid_recovery_executable}
  defp validate_executable(_), do: {:error, :invalid_recovery_executable}

  defp validate_coordinator_module(mod) when is_atom(mod) and not is_nil(mod), do: :ok
  defp validate_coordinator_module(_), do: {:error, :invalid_coordinator_module}

  # ---------------------------------------------------------------------------
  # Monitors / timers
  # ---------------------------------------------------------------------------

  defp put_monitor(state, mon_ref, pid) do
    %{state | monitors: Map.put(state.monitors, mon_ref, pid)}
  end

  defp drop_monitor(state, mon_ref, _pid) do
    %{state | monitors: Map.delete(state.monitors, mon_ref)}
  end

  defp cancel_all_timers(state) do
    Enum.each(state.timers, fn {timer_ref, _action} ->
      _ = :erlang.cancel_timer(timer_ref)

      receive do
        {:timeout, ^timer_ref, _} -> :ok
      after
        0 -> :ok
      end
    end)

    :ok
  end

  defp call(server, request) do
    GenServer.call(server, request, 5_000)
  catch
    :exit, _reason ->
      {:error, :recovery_reconciler_unavailable}
  end

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  defp redact_state(state) when is_map(state) do
    phase =
      case state do
        %{core: core} when is_map(core) ->
          case Core.show(core) do
            %{"phase" => p} -> p
            _ -> "unknown"
          end

        _ ->
          "unknown"
      end

    worker_count =
      case state do
        %{core: %{workers: workers}} when is_map(workers) -> map_size(workers)
        _ -> 0
      end

    %{
      phase: phase,
      worker_count: worker_count,
      mode: Map.get(state, :mode),
      core: :redacted,
      journal: :redacted,
      journal_server: :redacted,
      worker_supervisor: :redacted,
      worker_module: :redacted,
      worker_launcher: :redacted,
      executable_resolver: :redacted,
      coordinator_module: :redacted,
      timers: :redacted,
      monitors: :redacted
    }
  end

  defp redact_state(_), do: :redacted

  defp redact_status_field(status, field) when is_map(status) do
    if Map.has_key?(status, field) do
      Map.put(status, field, :redacted)
    else
      status
    end
  end

  defp bound_reason(reason) when is_atom(reason), do: reason
  defp bound_reason(reason) when is_binary(reason), do: :redacted

  defp bound_reason({tag, detail}) when is_atom(tag) do
    {tag, bound_reason(detail)}
  end

  defp bound_reason(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.take(4)
    |> Enum.map(&bound_reason/1)
    |> List.to_tuple()
  end

  defp bound_reason(_), do: :redacted
end
