defmodule Arbor.Shell.AppleContainerUnitRecoveryWorker do
  @moduledoc """
  Independent durable-intent recovery worker for Apple Container units.

  Interprets pure `AppleContainerUnitRecoveryCore` effects only: force-stop,
  force-delete, and structured list absence verification, then completes the
  exact journal intent. Does not wire Application supervision, does not touch
  UnitWorker/DrainCoordinator, and does not open the Shell facade.

  Production execution uses `AppleContainerUnitRecoveryRuntime` →
  `Executor.run_bound/3` only — never session-supervised ports.

  Admission is sealed: only explicit tagged tuples reach `start_link/1`.
  Production hardcodes the recovery runtime, unit journal, and journal server.
  """

  use GenServer

  alias Arbor.Shell.AppleContainerUnitCore, as: UnitCore
  alias Arbor.Shell.AppleContainerUnitJournal
  alias Arbor.Shell.AppleContainerUnitJournalCore, as: JournalCore
  alias Arbor.Shell.AppleContainerUnitRecoveryCore, as: RecoveryCore
  alias Arbor.Shell.AppleContainerUnitRecoveryRuntime
  alias Arbor.Shell.ExecutablePolicy.Executable

  @runtime_path "/usr/local/bin/container"
  @attempt_timeout_ms 5_000
  @journal_retry_initial_ms 50
  @journal_retry_max_ms 2_000

  @required_runtime_callbacks [{:run_bound, 3}]
  @required_journal_callbacks [{:complete, 3}]

  @type production_args ::
          {:production, term(), Executable.t(), pid(), reference()}

  @type test_only_args ::
          {:test_only, term(), Executable.t(), pid(), reference(), keyword()}

  @type start_args :: production_args() | test_only_args()

  # ---------------------------------------------------------------------------
  # Supervision / sealed admission
  # ---------------------------------------------------------------------------

  @doc """
  Build a production child argument tuple for a DynamicSupervisor.

  Does not start a process. Validation of the journal entry and pinned
  executable happens at `start_link/1` admission. Runtime and journal modules
  are never accepted from the caller — production hardcodes them.
  """
  @spec production_child_args(term(), Executable.t(), pid(), reference()) ::
          {:ok, production_args()} | {:error, term()}
  def production_child_args(entry, %Executable{} = executable, owner_pid, receipt_ref)
      when is_pid(owner_pid) and is_reference(receipt_ref) do
    {:ok, {:production, entry, executable, owner_pid, receipt_ref}}
  end

  def production_child_args(_entry, _executable, _owner_pid, _receipt_ref),
    do: {:error, :invalid_recovery_start}

  @doc false
  def child_spec({:production, _entry, _executable, _owner_pid, _receipt_ref} = args) do
    temporary_child_spec(args)
  end

  def child_spec(_other) do
    raise ArgumentError,
          "AppleContainerUnitRecoveryWorker.child_spec/1 requires a sealed " <>
            "{:production, ...} tagged tuple"
  end

  defp temporary_child_spec(args) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker,
      # Finite shutdown cannot prove unit absence.
      shutdown: :infinity
    }
  end

  @doc false
  @spec start_link(start_args()) :: GenServer.on_start()
  def start_link({:production, entry, executable, owner_pid, receipt_ref})
      when is_pid(owner_pid) and is_reference(receipt_ref) do
    with {:ok, record} <- validate_entry(entry),
         :ok <- validate_executable(executable) do
      GenServer.start_link(__MODULE__, %{
        record: record,
        executable: executable,
        owner_pid: owner_pid,
        receipt_ref: receipt_ref,
        runtime: AppleContainerUnitRecoveryRuntime,
        journal: AppleContainerUnitJournal,
        journal_server: AppleContainerUnitJournal
      })
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_link({:test_only, entry, executable, owner_pid, receipt_ref, opts})
      when is_pid(owner_pid) and is_reference(receipt_ref) and is_list(opts) do
    if Keyword.keyword?(opts) do
      runtime = Keyword.get(opts, :runtime)
      journal = Keyword.get(opts, :journal)
      journal_server = Keyword.get(opts, :journal_server, journal)

      with {:ok, record} <- validate_entry(entry),
           :ok <- validate_executable(executable),
           :ok <- validate_runtime_module(runtime),
           :ok <- validate_journal_module(journal),
           :ok <- validate_journal_server(journal_server) do
        GenServer.start_link(__MODULE__, %{
          record: record,
          executable: executable,
          owner_pid: owner_pid,
          receipt_ref: receipt_ref,
          runtime: runtime,
          journal: journal,
          journal_server: journal_server
        })
      else
        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_recovery_start_options}
    end
  end

  def start_link(_other), do: {:error, :invalid_recovery_start}

  @doc false
  @spec start_for_test(term(), Executable.t(), pid(), reference(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_for_test(entry, executable, owner_pid, receipt_ref, opts \\ [])

  def start_for_test(entry, %Executable{} = executable, owner_pid, receipt_ref, opts)
      when is_pid(owner_pid) and is_reference(receipt_ref) and is_list(opts) do
    start_link({:test_only, entry, executable, owner_pid, receipt_ref, opts})
  end

  def start_for_test(_entry, _executable, _owner_pid, _receipt_ref, _opts),
    do: {:error, :invalid_recovery_start}

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(args) when is_map(args) do
    Process.flag(:trap_exit, true)

    record = Map.fetch!(args, :record)
    owner_pid = Map.fetch!(args, :owner_pid)

    case RecoveryCore.new(record.unit_name) do
      {:ok, core, effects} ->
        state = %{
          status: :cleanup,
          unit_name: record.unit_name,
          token: record.token,
          execution_id: record.execution_id,
          executable: Map.fetch!(args, :executable),
          owner_pid: owner_pid,
          owner_ref: Process.monitor(owner_pid),
          receipt_ref: Map.fetch!(args, :receipt_ref),
          runtime: Map.fetch!(args, :runtime),
          journal: Map.fetch!(args, :journal),
          journal_server: Map.fetch!(args, :journal_server),
          core: core,
          cleanup_timer: nil,
          cleanup_timer_effect: nil,
          journal_timer: nil,
          journal_retry_ms: @journal_retry_initial_ms,
          receipt_sent: false,
          terminal: nil
        }

        {:ok, state, {:continue, {:effects, effects}}}

      {:error, reason} ->
        {:stop, {:recovery_start_failed, bound_reason(reason)}}
    end
  end

  @impl true
  def handle_continue({:effects, effects}, state) when is_list(effects) do
    dispatch_effects(state, effects)
  end

  def handle_continue(:journal_complete, state) do
    attempt_journal_complete(state)
  end

  def handle_continue(other, state) do
    stop_invariant(state, {:invalid_continuation, bound_reason(other)})
  end

  @impl true
  def handle_info(
        {:timeout, timer_ref, effect},
        %{cleanup_timer: timer_ref, cleanup_timer_effect: effect} = state
      )
      when is_reference(timer_ref) do
    state = %{state | cleanup_timer: nil, cleanup_timer_effect: nil}
    dispatch_effects(state, [effect])
  end

  def handle_info({:timeout, timer_ref, :journal_complete}, %{journal_timer: timer_ref} = state)
      when is_reference(timer_ref) do
    state = %{state | journal_timer: nil}
    attempt_journal_complete(state)
  end

  def handle_info({:timeout, _other_ref, _payload}, state) do
    # Stale or foreign timer — ignore.
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{owner_ref: ref, owner_pid: pid} = state
      ) do
    # Owner death never reinterprets cleanup as complete.
    {:noreply, %{state | owner_pid: nil, owner_ref: nil}}
  end

  def handle_info({:apple_container_unit_recovered, _pid, _name, _ref}, state) do
    # Forged or reflected receipt messages cannot advance state.
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_cleanup_timer(state)
    _ = cancel_journal_timer(state)
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

      {:continue, cont, next} ->
        # Terminal reconcile schedules journal completion via handle_continue.
        if rest == [] do
          {:noreply, next, {:continue, cont}}
        else
          case dispatch_effects(next, rest) do
            {:noreply, after_rest} ->
              {:noreply, after_rest, {:continue, cont}}

            {:noreply, after_rest, {:continue, later}} ->
              # Prefer the later continue (should not stack in practice).
              {:noreply, after_rest, {:continue, later}}

            {:stop, reason, after_rest} ->
              {:stop, reason, after_rest}
          end
        end

      {:effects, next, more} when is_list(more) ->
        dispatch_effects(next, more ++ rest)

      {:stop, reason, next} ->
        {:stop, reason, next}

      other ->
        stop_invariant(state, {:invalid_effect_result, bound_reason(other)})
    end
  end

  defp apply_effect(state, {:run, phase, argv}) when is_atom(phase) and is_list(argv) do
    result = run_phase(state, phase, argv)

    case RecoveryCore.apply_result(state.core, phase, result) do
      {:ok, core, effects} when is_list(effects) ->
        {:effects, %{state | core: core}, effects}

      {:ok, _core, other} ->
        stop_invariant(state, {:invalid_core_effects, bound_reason(other)})

      {:error, reason} ->
        # Invariant violation: stop abnormally without receipt or journal complete.
        stop_invariant(state, {:recovery_core_error, bound_reason(reason)})
    end
  end

  defp apply_effect(state, {:retry_after, delay_ms, next_effect})
       when is_integer(delay_ms) and delay_ms >= 0 do
    state = cancel_cleanup_timer(state)
    timer_ref = :erlang.start_timer(delay_ms, self(), next_effect)

    {:noreply,
     %{
       state
       | status: :cleanup_retry,
         cleanup_timer: timer_ref,
         cleanup_timer_effect: next_effect
     }}
  end

  defp apply_effect(state, {:terminal, :reconciled}) do
    next = %{state | status: :journal_completing, terminal: :reconciled}
    {:continue, :journal_complete, next}
  end

  defp apply_effect(state, other) do
    stop_invariant(state, {:unexpected_effect, bound_reason(other)})
  end

  defp stop_invariant(state, reason) do
    {:stop, {:recovery_invariant_failed, reason}, %{state | status: :recovery_failed}}
  end

  defp run_phase(state, phase, argv) do
    with {:ok, args} <- strip_runtime_prefix(argv, state.executable),
         {:ok, max_output} <- phase_max_output(phase) do
      opts = [
        cwd: "/",
        clear_env: true,
        env: %{},
        timeout: @attempt_timeout_ms,
        max_output_bytes: max_output
      ]

      invoke_runtime(state.runtime, state.executable, args, opts)
    else
      {:error, _reason} ->
        containment_failure_result()
    end
  end

  defp invoke_runtime(runtime, executable, args, opts) do
    case runtime.run_bound(executable, args, opts) do
      {:ok, raw} when is_map(raw) ->
        project_result(raw)

      {:error, _reason} ->
        containment_failure_result()

      _other ->
        containment_failure_result()
    end
  catch
    :exit, _reason ->
      containment_failure_result()

    :error, _reason ->
      containment_failure_result()

    :throw, _reason ->
      containment_failure_result()
  end

  defp strip_runtime_prefix([path | rest], %Executable{path: path}) when is_binary(path) do
    {:ok, rest}
  end

  defp strip_runtime_prefix(_argv, _executable), do: {:error, :argv_executable_mismatch}

  defp phase_max_output(phase) when phase in [:force_stop, :delete, :verify_absent] do
    {:ok, UnitCore.phase_output_limit(phase)}
  end

  defp phase_max_output(_), do: {:error, :unknown_phase}

  defp project_result(raw) when is_map(raw) do
    %{
      exit_code: normalize_exit_code(Map.get(raw, :exit_code)),
      stdout: normalize_stdout(Map.get(raw, :stdout) || Map.get(raw, :output) || ""),
      stderr: "",
      timed_out: Map.get(raw, :timed_out) == true,
      cancelled: Map.get(raw, :cancelled) == true,
      killed: Map.get(raw, :killed) == true,
      output_truncated: Map.get(raw, :output_truncated) == true,
      output_limit_exceeded: Map.get(raw, :output_limit_exceeded) == true,
      duration_ms: normalize_duration(Map.get(raw, :duration_ms))
    }
    |> maybe_put_containment(Map.get(raw, :containment_failure) == true)
  end

  defp maybe_put_containment(map, true), do: Map.put(map, :containment_failure, true)
  defp maybe_put_containment(map, false), do: map

  defp normalize_exit_code(code) when is_integer(code) and code >= 0 and code <= 0xFFFF, do: code
  defp normalize_exit_code(_), do: 137

  defp normalize_stdout(out) when is_binary(out), do: out
  defp normalize_stdout(_), do: ""

  defp normalize_duration(ms) when is_integer(ms) and ms >= 0, do: ms
  defp normalize_duration(_), do: 0

  defp containment_failure_result do
    %{
      exit_code: 137,
      stdout: "",
      stderr: "",
      timed_out: false,
      cancelled: false,
      killed: true,
      output_truncated: false,
      output_limit_exceeded: false,
      containment_failure: true,
      duration_ms: 0
    }
  end

  # ---------------------------------------------------------------------------
  # Journal completion
  # ---------------------------------------------------------------------------

  defp attempt_journal_complete(%{terminal: :reconciled, receipt_sent: false} = state) do
    case invoke_journal_complete(state) do
      :ok ->
        emit_receipt_and_stop(state)

      {:error, reason} ->
        handle_journal_complete_error(state, reason)
    end
  end

  defp attempt_journal_complete(state), do: {:noreply, state}

  defp invoke_journal_complete(state) do
    case state.journal.complete(state.unit_name, state.token, state.journal_server) do
      :ok ->
        :ok

      {:error, reason} ->
        normalize_journal_error(reason)

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

  defp normalize_journal_error(reason)
       when reason in [
              :token_mismatch,
              :unknown_unit_name,
              :invalid_token,
              :invalid_unit_name,
              :invalid_journal_state,
              :journal_invalid_schema
            ],
       do: {:error, reason}

  defp normalize_journal_error(_reason), do: {:error, :journal_call_failed}

  defp handle_journal_complete_error(state, reason) do
    if permanent_journal_error?(reason) do
      # Wrong/replayed token or schema rejection: stop abnormally, no receipt.
      # Reconciler reloads the authoritative journal and restarts or surfaces it.
      {:stop, {:journal_token_rejected, bound_reason(reason)},
       %{state | status: :journal_token_rejected}}
    else
      schedule_journal_retry(%{state | status: :journal_retry})
    end
  end

  defp permanent_journal_error?(reason)
       when reason in [
              :token_mismatch,
              :unknown_unit_name,
              :invalid_token,
              :invalid_unit_name,
              :invalid_journal_state,
              :journal_invalid_schema
            ],
       do: true

  defp permanent_journal_error?(:unexpected_journal_result), do: true
  defp permanent_journal_error?(_), do: false

  defp schedule_journal_retry(state) do
    state = cancel_journal_timer(state)
    delay = state.journal_retry_ms
    timer_ref = :erlang.start_timer(delay, self(), :journal_complete)
    next_delay = min(delay * 2, @journal_retry_max_ms)

    {:noreply,
     %{
       state
       | journal_timer: timer_ref,
         journal_retry_ms: next_delay
     }}
  end

  defp emit_receipt_and_stop(state) do
    if is_pid(state.owner_pid) do
      send(
        state.owner_pid,
        {:apple_container_unit_recovered, self(), state.unit_name, state.receipt_ref}
      )
    end

    {:stop, :normal,
     %{
       state
       | status: :reconciled,
         receipt_sent: true,
         token: nil
     }}
  end

  # ---------------------------------------------------------------------------
  # Timers
  # ---------------------------------------------------------------------------

  defp cancel_cleanup_timer(%{cleanup_timer: timer_ref} = state) when is_reference(timer_ref) do
    _ = :erlang.cancel_timer(timer_ref)

    receive do
      {:timeout, ^timer_ref, _effect} -> :ok
    after
      0 -> :ok
    end

    %{state | cleanup_timer: nil, cleanup_timer_effect: nil}
  end

  defp cancel_cleanup_timer(state), do: state

  defp cancel_journal_timer(%{journal_timer: timer_ref} = state) when is_reference(timer_ref) do
    _ = :erlang.cancel_timer(timer_ref)

    receive do
      {:timeout, ^timer_ref, :journal_complete} -> :ok
    after
      0 -> :ok
    end

    %{state | journal_timer: nil}
  end

  defp cancel_journal_timer(state), do: state

  # ---------------------------------------------------------------------------
  # Admission
  # ---------------------------------------------------------------------------

  defp validate_entry(entry) when is_map(entry) do
    snapshot = %{
      "schema_version" => 1,
      "generation" => 1,
      "active" => [entry]
    }

    case JournalCore.new(snapshot) do
      {:ok, journal} ->
        case JournalCore.recovery_entries(journal) do
          [record] when is_map(record) ->
            {:ok, record}

          _other ->
            {:error, :invalid_journal_entry}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_entry(_), do: {:error, :invalid_journal_entry}

  defp validate_executable(%Executable{path: @runtime_path}), do: :ok
  defp validate_executable(%Executable{}), do: {:error, :invalid_recovery_executable}
  defp validate_executable(_), do: {:error, :invalid_recovery_executable}

  defp validate_runtime_module(runtime) when is_atom(runtime) and not is_nil(runtime) do
    case Code.ensure_loaded(runtime) do
      {:module, ^runtime} ->
        if Enum.all?(@required_runtime_callbacks, fn {fun, arity} ->
             function_exported?(runtime, fun, arity)
           end) do
          :ok
        else
          {:error, :invalid_runtime_module}
        end

      _ ->
        {:error, :invalid_runtime_module}
    end
  end

  defp validate_runtime_module(_), do: {:error, :invalid_runtime_module}

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

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      unit_name: Map.get(state, :unit_name),
      receipt_sent: Map.get(state, :receipt_sent) == true,
      terminal: show_terminal(Map.get(state, :terminal)),
      # Sensitive / authority-bearing fields always redacted.
      token: :redacted,
      execution_id: :redacted,
      executable: :redacted,
      owner_pid: :redacted,
      owner_ref: :redacted,
      receipt_ref: :redacted,
      runtime: :redacted,
      journal: :redacted,
      journal_server: :redacted,
      core: :redacted,
      cleanup_timer: :redacted,
      cleanup_timer_effect: :redacted,
      journal_timer: :redacted,
      journal_retry_ms: :redacted
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

  defp show_terminal(nil), do: nil
  defp show_terminal(:reconciled), do: :reconciled
  defp show_terminal(_), do: :redacted

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
