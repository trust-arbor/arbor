defmodule Arbor.Shell.AppleContainerUnitWorker do
  @moduledoc false

  # Temporary supervised Apple Container unit owner (Phase 6).
  #
  # Drives every lifecycle transition through AppleContainerUnitCore. Runs
  # structured argv via AppleContainerUnitRuntime (PortSession) — never shell
  # text. Holds Core terminals privately until durable journal completion, then
  # publishes once to ExecutionRegistry / controller. Never publishes or
  # completes the journal before positive unit absence when create was
  # attempted. Owned by AppleContainerExecutor via execute_spawn_capable/3.
  #
  # Terminal publication is two-stage: hold a bounded terminal, call the stored
  # production AppleContainerUnitJournal.complete/3 with the exact journal
  # record unit_name + token, and only on `:ok` publish registry/controller
  # once. Completion errors without an accepted drain retry forever with
  # bounded exponential delay; accepted drain + safe containment + failed
  # completion emits the drain receipt and stops without publication so the
  # durable row remains for the Reconciler.
  #
  # Drain protocol (`request_drain/3`): a sibling drain coordinator (not the
  # parent supervisor EXIT — OTP consumes parent exit into terminate/2 and does
  # not deliver it to handle_info) calls this GenServer with an exact receipt
  # ref. Caller identity is taken only from the GenServer `from` tuple. The
  # worker requests cancellation once through the ordinary async UnitCore /
  # PortSession lifecycle, stays nonterminal through cleanup retries, and emits
  # `{:apple_container_unit_drained, worker_pid, execution_id, receipt_ref}` only
  # when (a) create was never attempted or (b) UnitCore reached terminal after
  # exact positive absence. terminate/2 is final defense only.
  #
  # Production `start/4` linearizes through AppleContainerUnitDrainCoordinator
  # so every admitted worker is present before a drain snapshot. A fixed
  # pre-begin timer expires waiting workers that never receive exact begin,
  # closing orphaned start replies without caller-configurable policy.

  use GenServer

  alias Arbor.Shell.AppleContainerExecutionCore
  alias Arbor.Shell.AppleContainerPlanCore
  alias Arbor.Shell.AppleContainerUnitCore, as: UnitCore
  alias Arbor.Shell.AppleContainerUnitDrainCoordinator
  alias Arbor.Shell.AppleContainerUnitJournal
  alias Arbor.Shell.AppleContainerUnitJournalCore, as: JournalCore
  alias Arbor.Shell.AppleContainerUnitRuntime
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutionRegistry
  alias Arbor.Shell.SpawnCapableTimeout

  @supervisor Arbor.Shell.AppleContainerUnitSupervisor
  @coordinator AppleContainerUnitDrainCoordinator
  # Production journal owner — hardcoded; never a configurable production callback.
  @journal AppleContainerUnitJournal
  @runtime_path "/usr/local/bin/container"
  @display_command "container unit"
  @cleanup_attempt_timeout_ms 30_000
  # Fixed production wait for exact begin after admission (not caller policy).
  @pre_begin_timeout_ms 30_000
  @max_pre_begin_timeout_ms 60_000
  @default_call_timeout_ms 5_000
  @max_call_timeout_ms 60_000
  @max_reason_bytes 512
  # Secondary controller notification only — registry keeps the full primary result.
  @max_secondary_notification_bytes 512
  @journal_retry_initial_ms 50
  @journal_retry_max_ms 2_000

  @required_runtime_callbacks [
    {:start_command, 5},
    {:kill, 1},
    {:get_id, 1},
    {:get_result, 1},
    {:monotonic_ms, 0}
  ]

  @required_journal_callbacks [
    {:complete, 2}
  ]

  @type start_args :: %{
          required(:spec) => map(),
          required(:executable) => ExecutablePolicy.Executable.t(),
          required(:execution_id) => String.t(),
          required(:start_ref) => reference(),
          required(:controller_pid) => pid(),
          required(:journal_record) => JournalCore.record(),
          required(:operation_deadline) => integer(),
          required(:ownership_caller) => pid() | {:registered, atom()},
          optional(:runtime) => module(),
          optional(:pre_begin_timeout_ms) => pos_integer(),
          optional(:journal_module) => module()
        }

  # ---------------------------------------------------------------------------
  # Supervision
  # ---------------------------------------------------------------------------

  @doc false
  @spec supervisor_child_spec() :: Supervisor.child_spec()
  def supervisor_child_spec do
    %{
      id: @supervisor,
      start:
        {DynamicSupervisor, :start_link,
         [[name: @supervisor, strategy: :one_for_one, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc false
  @spec supervisor_name() :: atom()
  def supervisor_name, do: @supervisor

  @doc false
  def child_spec(args) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker,
      shutdown: :infinity
    }
  end

  @doc false
  @spec start_link(start_args()) :: GenServer.on_start()
  def start_link(args) when is_map(args) do
    GenServer.start_link(__MODULE__, args)
  end

  # ---------------------------------------------------------------------------
  # Production / test start seams
  # ---------------------------------------------------------------------------

  @doc """
  Start a waiting unit owner under the dedicated unit supervisor.

  Production starts admit only through `AppleContainerUnitDrainCoordinator`,
  which derives the controller from its GenServer `from` tuple — never from a
  caller-supplied owner pid. The controller must register the execution,
  `adopt/2` this worker, then call `begin/3` with the exact opaque ref.
  """
  @spec start(
          AppleContainerExecutionCore.execution_spec(),
          ExecutablePolicy.Executable.t(),
          String.t(),
          reference()
        ) :: {:ok, pid()} | {:error, term()}
  def start(spec, executable, execution_id, start_ref)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) do
    # Never fall back to a direct DynamicSupervisor start.
    AppleContainerUnitDrainCoordinator.start_unit(
      spec,
      executable,
      execution_id,
      start_ref
    )
  end

  def start(_spec, _executable, _execution_id, _start_ref),
    do: {:error, :invalid_unit_start}

  @doc false
  @spec start_under_coordinator(
          AppleContainerExecutionCore.execution_spec(),
          ExecutablePolicy.Executable.t(),
          String.t(),
          reference(),
          pid()
        ) :: {:ok, pid()} | {:error, term()}
  def start_under_coordinator(spec, executable, execution_id, start_ref, controller_pid)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) and
             is_pid(controller_pid) do
    # Legacy non-durable seam: validate ordinary inputs then fail closed so no
    # production path can admit a unit without journal + absolute deadline.
    with :ok <- validate_spec(spec),
         :ok <- validate_executable(executable),
         :ok <- validate_execution_id(execution_id) do
      {:error, :durable_unit_admission_required}
    end
  end

  def start_under_coordinator(_spec, _executable, _execution_id, _start_ref, _controller_pid),
    do: {:error, :invalid_unit_start}

  @doc false
  @spec start_under_coordinator_durable(
          AppleContainerExecutionCore.execution_spec(),
          ExecutablePolicy.Executable.t(),
          String.t(),
          reference(),
          pid(),
          map(),
          integer()
        ) :: {:ok, pid()} | {:error, term()}
  def start_under_coordinator_durable(
        spec,
        executable,
        execution_id,
        start_ref,
        controller_pid,
        journal_record,
        operation_deadline
      )
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) and
             is_pid(controller_pid) and is_map(journal_record) and is_integer(operation_deadline) do
    case Process.whereis(@coordinator) do
      pid when is_pid(pid) and pid == self() ->
        # Ownership follows the registered DrainCoordinator authority across
        # coordinator restarts; it never belongs to the facade/action controller.
        # Production hardcodes @journal for the terminal-publication slice.
        start_waiting(
          spec,
          executable,
          execution_id,
          start_ref,
          controller_pid,
          AppleContainerUnitRuntime,
          @pre_begin_timeout_ms,
          journal_record,
          operation_deadline,
          {:registered, @coordinator}
        )

      _other ->
        {:error, :coordinator_start_required}
    end
  end

  def start_under_coordinator_durable(
        _spec,
        _executable,
        _execution_id,
        _start_ref,
        _controller_pid,
        _journal_record,
        _operation_deadline
      ),
      do: {:error, :invalid_unit_start}

  @doc false
  @spec start_for_test(
          AppleContainerExecutionCore.execution_spec(),
          ExecutablePolicy.Executable.t(),
          String.t(),
          reference(),
          keyword()
        ) :: {:ok, pid()} | {:error, term()}
  def start_for_test(spec, executable, execution_id, start_ref, opts)

  def start_for_test(spec, executable, execution_id, start_ref, opts)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) and is_list(opts) do
    if Keyword.keyword?(opts) do
      runtime = Keyword.get(opts, :runtime, AppleContainerUnitRuntime)
      pre_begin_timeout_ms = Keyword.get(opts, :pre_begin_timeout_ms, @pre_begin_timeout_ms)
      # Test-only journal injection. Production paths hardcode @journal.
      journal_module = Keyword.get(opts, :journal_module, @journal)

      with :ok <- require_admission_opts(opts),
           {:ok, journal_record} <- fetch_admission_opt(opts, :journal_record),
           {:ok, operation_deadline} <- fetch_admission_opt(opts, :operation_deadline),
           {:ok, ownership_caller} <- fetch_admission_opt(opts, :ownership_caller),
           :ok <- validate_runtime_module(runtime),
           :ok <- validate_journal_module(journal_module),
           :ok <- validate_pre_begin_timeout(pre_begin_timeout_ms),
           :ok <- validate_ownership_caller(ownership_caller) do
        start_waiting(
          spec,
          executable,
          execution_id,
          start_ref,
          self(),
          runtime,
          pre_begin_timeout_ms,
          journal_record,
          operation_deadline,
          ownership_caller,
          journal_module
        )
      end
    else
      {:error, :invalid_unit_start_options}
    end
  end

  def start_for_test(_spec, _executable, _execution_id, _start_ref, _opts),
    do: {:error, :invalid_unit_start}

  @doc false
  @spec begin(pid(), reference(), pos_integer()) :: :ok | {:error, term()}
  def begin(worker, start_ref, timeout \\ @default_call_timeout_ms)

  def begin(worker, start_ref, timeout)
      when is_pid(worker) and is_reference(start_ref) and is_integer(timeout) and timeout > 0 and
             timeout <= @max_call_timeout_ms do
    GenServer.call(worker, {:begin, start_ref}, timeout)
  end

  def begin(_worker, _start_ref, _timeout), do: {:error, :invalid_begin}

  @doc false
  @spec request_drain(pid(), reference(), pos_integer()) :: :ok | {:error, term()}
  def request_drain(worker, receipt_ref, timeout \\ @default_call_timeout_ms)

  def request_drain(worker, receipt_ref, timeout)
      when is_pid(worker) and is_reference(receipt_ref) and is_integer(timeout) and timeout > 0 and
             timeout <= @max_call_timeout_ms do
    GenServer.call(worker, {:request_drain, receipt_ref}, timeout)
  end

  def request_drain(_worker, _receipt_ref, _timeout), do: {:error, :invalid_drain}

  @doc false
  @spec ownership_info(pid(), map(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def ownership_info(worker, exact_record, timeout \\ @default_call_timeout_ms)

  def ownership_info(worker, exact_record, timeout)
      when is_pid(worker) and is_map(exact_record) and is_integer(timeout) and timeout > 0 and
             timeout <= @max_call_timeout_ms do
    GenServer.call(worker, {:ownership_info, exact_record}, timeout)
  catch
    :exit, _reason ->
      {:error, :ownership_denied}
  end

  def ownership_info(_worker, _exact_record, _timeout), do: {:error, :invalid_ownership_info}

  # Non-authoritative reconstruction hint for a restarted DrainCoordinator.
  # Same ownership authority as ownership_info/3, but returns only
  # %{execution_id: execution_id}. Callers must still ownership_info/3 with the
  # full exact journal record before monitor/adoption.
  @doc false
  @spec ownership_hint(pid(), pos_integer()) ::
          {:ok, %{execution_id: String.t()}} | {:error, term()}
  def ownership_hint(worker, timeout \\ @default_call_timeout_ms)

  def ownership_hint(worker, timeout)
      when is_pid(worker) and is_integer(timeout) and timeout > 0 and
             timeout <= @max_call_timeout_ms do
    GenServer.call(worker, :ownership_hint, timeout)
  catch
    :exit, _reason ->
      {:error, :ownership_denied}
  end

  def ownership_hint(_worker, _timeout), do: {:error, :invalid_ownership_hint}

  defp start_waiting(
         spec,
         executable,
         execution_id,
         start_ref,
         controller_pid,
         runtime,
         pre_begin_timeout_ms,
         journal_record,
         operation_deadline,
         ownership_caller,
         journal_module \\ @journal
       ) do
    with :ok <- validate_spec(spec),
         :ok <- validate_executable(executable),
         :ok <- validate_execution_id(execution_id),
         :ok <- validate_runtime_module(runtime),
         :ok <- validate_journal_module(journal_module),
         :ok <- validate_pre_begin_timeout(pre_begin_timeout_ms),
         :ok <- validate_ownership_caller(ownership_caller),
         {:ok, record} <- validate_journal_record(journal_record, execution_id, spec),
         {:ok, deadline} <- validate_operation_deadline(operation_deadline, runtime, spec),
         {:ok, capped_pre_begin} <-
           cap_pre_begin_timeout(pre_begin_timeout_ms, deadline, runtime) do
      args = %{
        spec: spec,
        executable: executable,
        execution_id: execution_id,
        start_ref: start_ref,
        controller_pid: controller_pid,
        runtime: runtime,
        pre_begin_timeout_ms: capped_pre_begin,
        journal_record: record,
        operation_deadline: deadline,
        ownership_caller: ownership_caller,
        # Production always passes @journal; tests may inject via start_for_test.
        journal_module: journal_module
      }

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, args}) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(args) when is_map(args) do
    Process.flag(:trap_exit, true)

    controller = Map.fetch!(args, :controller_pid)
    start_ref = Map.fetch!(args, :start_ref)
    execution_id = Map.fetch!(args, :execution_id)
    spec = Map.fetch!(args, :spec)
    executable = Map.fetch!(args, :executable)
    runtime = Map.get(args, :runtime, AppleContainerUnitRuntime)
    pre_begin_timeout_ms = Map.fetch!(args, :pre_begin_timeout_ms)
    journal_record = Map.fetch!(args, :journal_record)
    operation_deadline = Map.fetch!(args, :operation_deadline)
    ownership_caller = Map.fetch!(args, :ownership_caller)
    journal_module = Map.get(args, :journal_module, @journal)

    pre_begin_timer =
      :erlang.start_timer(pre_begin_timeout_ms, self(), :pre_begin_timeout)

    state = %{
      status: :waiting,
      execution_id: execution_id,
      start_ref: start_ref,
      controller_pid: controller,
      controller_ref: Process.monitor(controller),
      ownership_caller: ownership_caller,
      journal_record: journal_record,
      journal_module: journal_module,
      spec: spec,
      executable: executable,
      runtime: runtime,
      # Absolute monotonic deadline fixed at admission — never recomputed at begin.
      operation_deadline: operation_deadline,
      core: nil,
      active_phase: nil,
      active_session: nil,
      active_session_id: nil,
      active_session_ref: nil,
      pending_result: false,
      cancel_requested: false,
      cancel_applied: false,
      drain_receipt: nil,
      cleanup_timer: nil,
      cleanup_timer_effect: nil,
      pre_begin_timer: pre_begin_timer,
      terminal_published: false,
      terminal: nil,
      # Private held terminal before durable journal completion + publication.
      held_terminal: nil,
      journal_retry_timer: nil,
      journal_retry_token: nil,
      journal_retry_ms: @journal_retry_initial_ms,
      journal_complete_status: nil,
      journal_complete_reason: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:begin, start_ref}, _from, %{status: :waiting, start_ref: start_ref} = state)
      when is_reference(start_ref) do
    # Exact waiting ref is an accepted begin. Synchronous Core terminals
    # (e.g. preflight list_containment_failure) enter the journal gate before
    # registry/controller publication; accepted begin itself is not invalid.
    state = cancel_pre_begin_timer(state)

    case begin_lifecycle(state) do
      {:ok, started} ->
        {:reply, :ok, started}

      {:noreply, next} ->
        # Sync terminal held while journal completion retries.
        {:reply, :ok, next}

      {:stop, reason, stopped} ->
        {:stop, reason, :ok, stopped}
    end
  end

  def handle_call({:begin, _wrong_or_replayed}, _from, state) do
    # Wrong or replayed ref runs nothing.
    {:reply, {:error, :invalid_begin_ref}, state}
  end

  def handle_call({:ownership_info, exact_record}, {caller_pid, _tag}, state)
      when is_map(exact_record) and is_pid(caller_pid) do
    case authorize_ownership_info(state, caller_pid, exact_record) do
      {:ok, info} ->
        {:reply, {:ok, info}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ownership_info, _invalid}, _from, state) do
    {:reply, {:error, :ownership_denied}, state}
  end

  def handle_call(:ownership_hint, {caller_pid, _tag}, state) when is_pid(caller_pid) do
    case authorize_ownership_hint(state, caller_pid) do
      {:ok, hint} ->
        {:reply, {:ok, hint}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:ownership_hint, _from, state) do
    {:reply, {:error, :ownership_denied}, state}
  end

  def handle_call({:request_drain, receipt_ref}, {caller_pid, _tag}, state)
      when is_reference(receipt_ref) and is_pid(caller_pid) do
    case accept_drain_request(state, caller_pid, receipt_ref) do
      {:ok, next} ->
        {:reply, :ok, next}

      {:noreply, next} ->
        {:reply, :ok, next}

      {:stop, reason, next} ->
        {:stop, reason, :ok, next}

      {:error, reason, next} ->
        {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:request_drain, _invalid}, _from, state) do
    {:reply, {:error, :invalid_drain_ref}, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  @impl true
  def handle_info({:cancel_shell_execution, id}, %{execution_id: id} = state) do
    handle_cancel(state)
  end

  def handle_info({:cancel_shell_execution, _other}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{controller_ref: ref, controller_pid: pid} = state
      ) do
    state = %{state | controller_ref: nil, controller_pid: nil}
    handle_cancel(state)
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{active_session_ref: ref, active_session: pid} = state
      ) do
    case handle_session_down(state, reason) do
      {:noreply, next} -> maybe_apply_deferred_cancel(next)
      other -> other
    end
  end

  def handle_info({:port_exit, session_id, _exit_code, _output}, state) do
    if state.active_session_id == session_id and state.pending_result do
      after_session_result(state)
    else
      {:noreply, state}
    end
  end

  def handle_info({:port_data, _session_id, _chunk}, state), do: {:noreply, state}

  def handle_info({:port_output_limit, session_id, _metadata}, state) do
    if state.active_session_id == session_id and state.pending_result do
      # Limit is already reflected in the PortSession result; wait for exit.
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:timeout, timer_ref, effect},
        %{cleanup_timer: timer_ref, cleanup_timer_effect: effect} = state
      )
      when is_reference(timer_ref) do
    state = %{state | cleanup_timer: nil, cleanup_timer_effect: nil}
    dispatch_effects(state, [effect])
  end

  def handle_info(
        {:timeout, timer_ref, {:journal_complete_retry, token}},
        %{journal_retry_timer: timer_ref, journal_retry_token: token} = state
      )
      when is_reference(timer_ref) and is_reference(token) do
    # Exact stored timer ref + opaque per-attempt token only.
    state = %{state | journal_retry_timer: nil, journal_retry_token: nil}
    attempt_journal_completion_gate(state)
  end

  def handle_info(
        {:timeout, timer_ref, :pre_begin_timeout},
        %{pre_begin_timer: timer_ref, status: :waiting} = state
      )
      when is_reference(timer_ref) do
    # Exact begin never arrived — stop safely before create.
    state = %{state | pre_begin_timer: nil}
    handle_cancel(state)
  end

  def handle_info(
        {:timeout, timer_ref, :pre_begin_timeout},
        %{pre_begin_timer: timer_ref} = state
      )
      when is_reference(timer_ref) do
    # Already past waiting (e.g. race with begin) — clear only.
    {:noreply, %{state | pre_begin_timer: nil}}
  end

  def handle_info({:timeout, _other_ref, _payload}, state) do
    # Stale, forged, or foreign timer — ignore (including wrong retry tokens).
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, _reason}, state) do
    # OTP consumes a supervised GenServer's parent exit into terminate/2; it is
    # not a reachable coordinated-cleanup path. Drain is explicit via
    # request_drain/3. Linked-session EXIT messages are ignored here.
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final defense only — coordinated cleanup is request_drain / cancel, not
    # a finite terminate loop. Do not weaken positive-absence gating here.
    state = cancel_pre_begin_timer(state)
    state = cancel_cleanup_timer(state)
    _ = cancel_journal_retry_timer(state)
    _ = kill_active_session(state)
    :ok
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
    |> Map.put(:state, redact_state(state))
  end

  def format_status(status), do: status

  # ---------------------------------------------------------------------------
  # Begin / lifecycle
  # ---------------------------------------------------------------------------

  defp begin_lifecycle(state) do
    now = state.runtime.monotonic_ms()
    deadline = state.operation_deadline

    # Admission-fixed absolute deadline only — never recompute now + timeout_ms.
    if not is_integer(deadline) or now >= deadline do
      # Pre-create path: zero runtime commands, same as pre-begin cancel.
      hold_terminal_for_gate(state, {:error, :preflight_cancelled})
    else
      case UnitCore.new(state.spec.plan) do
        {:ok, core, effects} ->
          state = %{
            state
            | status: :running,
              start_ref: nil,
              core: core
          }

          case dispatch_effects(state, effects) do
            {:noreply, next} -> {:ok, next}
            {:stop, reason, next} -> {:stop, reason, next}
          end

        {:error, reason} ->
          hold_terminal_for_gate(state, {:error, reason})
      end
    end
  end

  defp dispatch_effects(state, effects) when is_list(effects) do
    Enum.reduce_while(effects, {:noreply, state}, fn effect, {:noreply, acc} ->
      case apply_effect(acc, effect) do
        {:noreply, next} -> {:cont, {:noreply, next}}
        {:stop, reason, next} -> {:halt, {:stop, reason, next}}
      end
    end)
  end

  defp apply_effect(state, {:terminal, terminal}) do
    hold_terminal_for_gate(state, terminal)
  end

  defp apply_effect(state, {:retry_after, delay_ms, next_effect})
       when is_integer(delay_ms) and delay_ms >= 0 do
    state = cancel_cleanup_timer(state)
    timer_ref = :erlang.start_timer(delay_ms, self(), next_effect)

    {:noreply, %{state | cleanup_timer: timer_ref, cleanup_timer_effect: next_effect}}
  end

  defp apply_effect(state, {:run, phase, argv}) when is_atom(phase) and is_list(argv) do
    if state.pending_result do
      # Do not advance core while an active PortSession result is pending.
      {:noreply, state}
    else
      launch_phase(state, phase, argv)
    end
  end

  defp apply_effect(state, _other), do: {:noreply, state}

  defp launch_phase(state, phase, argv) do
    with :ok <- require_no_pending(state),
         {:ok, args} <- strip_runtime_prefix(argv, state.executable),
         {:ok, timeout_ms} <- phase_timeout(state, phase),
         {:ok, max_output} <- phase_max_output(state, phase),
         {:ok, resource_profile} <- launch_resource_profile(state) do
      # Profile is a distinct trusted argument — never a raw ceiling override in opts.
      opts = [
        cwd: "/",
        clear_env: true,
        env: %{},
        stream_to: self(),
        timeout: timeout_ms,
        max_output_bytes: max_output
      ]

      case state.runtime.start_command(
             state.executable,
             args,
             @display_command,
             resource_profile,
             opts
           ) do
        {:ok, session} ->
          session_id =
            case state.runtime.get_id(session) do
              id when is_binary(id) -> id
              _ -> nil
            end

          ref = Process.monitor(session)

          {:noreply,
           %{
             state
             | active_phase: phase,
               active_session: session,
               active_session_id: session_id,
               active_session_ref: ref,
               pending_result: true
           }}

        {:error, _reason} ->
          # Every expected phase launch failure reduces through UnitCore.
          handle_phase_launch_failure(state, phase, :launch_error)
      end
    else
      {:error, :operation_deadline_exceeded} ->
        handle_phase_launch_failure(state, phase, :deadline)

      {:error, _reason} ->
        handle_phase_launch_failure(state, phase, :launch_error)
    end
  end

  # Exact admitted durable plan profile only — fail closed on unknown/malformed.
  defp launch_resource_profile(%{spec: %{plan: plan}}) when is_map(plan) do
    fetch_spec_resource_profile(plan)
  end

  defp launch_resource_profile(_state), do: {:error, :invalid_resource_profile}

  defp require_no_pending(%{pending_result: true}), do: {:error, :session_result_pending}
  defp require_no_pending(_), do: :ok

  defp strip_runtime_prefix([path | rest], %ExecutablePolicy.Executable{path: path})
       when is_binary(path) do
    {:ok, rest}
  end

  defp strip_runtime_prefix(_argv, _executable), do: {:error, :argv_executable_mismatch}

  defp phase_timeout(state, phase) when phase in [:force_stop, :delete] do
    _ = state
    {:ok, @cleanup_attempt_timeout_ms}
  end

  defp phase_timeout(state, :verify_absent) do
    # Cleanup verify uses cleanup timeout; preflight uses operation remaining.
    if state.core && state.core.stage == :cleanup do
      {:ok, @cleanup_attempt_timeout_ms}
    else
      remaining = remaining_operation_ms(state)
      if remaining > 0, do: {:ok, remaining}, else: {:error, :operation_deadline_exceeded}
    end
  end

  defp phase_timeout(state, phase) when phase in [:create, :start] do
    remaining = remaining_operation_ms(state)

    if remaining > 0 do
      {:ok, remaining}
    else
      {:error, :operation_deadline_exceeded}
    end
  end

  defp remaining_operation_ms(%{operation_deadline: deadline, runtime: runtime})
       when is_integer(deadline) do
    max(deadline - runtime.monotonic_ms(), 0)
  end

  defp remaining_operation_ms(_), do: 0

  defp phase_max_output(state, :start) do
    hard = UnitCore.phase_output_limit(:start)
    requested = Map.get(state.spec, :max_output_bytes, hard)
    {:ok, min(requested, hard)}
  end

  defp phase_max_output(_state, phase) do
    {:ok, UnitCore.phase_output_limit(phase)}
  end

  # ---------------------------------------------------------------------------
  # Session completion / failure
  # ---------------------------------------------------------------------------

  defp after_session_result(state) do
    case complete_active_session(state) do
      {:noreply, next} ->
        maybe_apply_deferred_cancel(next)

      {:stop, reason, next} ->
        {:stop, reason, next}
    end
  end

  defp complete_active_session(state) do
    session = state.active_session
    phase = state.active_phase

    projected =
      case fetch_projected_result(state, session) do
        {:ok, result} -> result
        {:error, _} -> containment_failure_result()
      end

    state = clear_active_session(state)
    apply_core_result(state, phase, projected)
  end

  defp maybe_apply_deferred_cancel(
         %{
           cancel_requested: true,
           cancel_applied: false,
           pending_result: false,
           core: core
         } = state
       )
       when is_map(core) do
    if core.stage == :terminal do
      {:noreply, state}
    else
      # Apply UnitCore.cancel exactly once even when already in cleanup, so a
      # retained candidate is marked cancelled and cleanup restarts safely.
      case UnitCore.cancel(core) do
        {:ok, core, effects} ->
          dispatch_effects(%{state | core: core, cancel_applied: true}, effects)

        {:error, :lifecycle_already_terminal} ->
          {:noreply, %{state | cancel_applied: true}}

        {:error, reason} ->
          hold_terminal_for_gate(state, {:error, reason})
      end
    end
  end

  defp maybe_apply_deferred_cancel(state), do: {:noreply, state}

  defp fetch_projected_result(state, session) when is_pid(session) do
    case state.runtime.get_result(session) do
      {:ok, raw} when is_map(raw) -> {:ok, project_port_result(raw)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_port_result, other}}
    end
  end

  defp fetch_projected_result(_state, _session), do: {:error, :missing_session}

  defp project_port_result(raw) when is_map(raw) do
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

  defp timed_out_result do
    %{
      exit_code: 137,
      stdout: "",
      stderr: "",
      timed_out: true,
      cancelled: false,
      killed: true,
      output_truncated: false,
      output_limit_exceeded: false,
      duration_ms: 0
    }
  end

  defp apply_core_result(state, phase, result) do
    case UnitCore.apply_result(state.core, phase, result) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core}, effects)

      {:error, reason} ->
        # Unexpected phase/result after create: force cleanup path via cancel.
        if state.core && state.core.create_attempted do
          apply_cancel_once(%{state | cancel_requested: true}, reason)
        else
          hold_terminal_for_gate(state, {:error, reason})
        end
    end
  end

  defp handle_session_down(state, _reason) do
    if state.pending_result do
      phase = state.active_phase
      state = clear_active_session(state)
      apply_core_result(state, phase, containment_failure_result())
    else
      {:noreply, clear_active_session(state)}
    end
  end

  # Every expected phase launch/session failure (including preflight) reduces
  # through UnitCore as containment_failure or timed_out — never publish raw
  # runtime reasons.
  defp handle_phase_launch_failure(state, phase, :deadline) do
    apply_synthetic_phase_result(state, phase, timed_out_result())
  end

  defp handle_phase_launch_failure(state, phase, _kind) do
    apply_synthetic_phase_result(state, phase, containment_failure_result())
  end

  defp apply_synthetic_phase_result(state, phase, result) do
    expected = expected_phase(state.core)

    cond do
      is_nil(state.core) ->
        hold_terminal_for_gate(state, {:error, :unit_error})

      expected == phase ->
        apply_core_result(state, phase, result)

      state.core.stage in [:preflight, :create, :start, :cleanup] ->
        apply_core_result(state, expected || phase, result)

      true ->
        apply_cancel_once(%{state | cancel_requested: true}, :unit_error)
    end
  end

  defp expected_phase(%{stage: :preflight}), do: :verify_absent
  defp expected_phase(%{stage: :create}), do: :create
  defp expected_phase(%{stage: :start}), do: :start
  defp expected_phase(%{stage: :cleanup, cleanup_step: step}) when is_atom(step), do: step
  defp expected_phase(_), do: nil

  # ---------------------------------------------------------------------------
  # Cancellation / drain
  # ---------------------------------------------------------------------------

  defp accept_drain_request(state, caller_pid, receipt_ref) do
    case state.drain_receipt do
      {^caller_pid, ^receipt_ref} ->
        # Same caller + exact ref is idempotent.
        {:ok, state}

      {_other_caller, _other_ref} ->
        {:error, :drain_already_requested, state}

      nil ->
        if state.terminal_published do
          {:error, :already_terminal, state}
        else
          state = %{state | drain_receipt: {caller_pid, receipt_ref}}

          cond do
            not is_nil(state.held_terminal) ->
              # Already holding a private terminal — re-enter the journal gate
              # without overwriting it with cancellation.
              attempt_journal_completion_gate(state)

            true ->
              case handle_cancel(state) do
                {:noreply, next} ->
                  {:ok, next}

                {:stop, reason, next} ->
                  {:stop, reason, next}
              end
          end
        end
    end
  end

  defp handle_cancel(state) do
    state
    |> cancel_pre_begin_timer()
    |> do_handle_cancel()
  end

  defp do_handle_cancel(%{status: :waiting} = state) do
    # Preflight not begun — no create attempted.
    hold_terminal_for_gate(state, {:error, :preflight_cancelled})
  end

  defp do_handle_cancel(%{terminal_published: true} = state), do: {:noreply, state}

  defp do_handle_cancel(%{held_terminal: held} = state) when not is_nil(held) do
    # Private held terminal must not be overwritten by later cancellation.
    {:noreply, %{state | cancel_requested: true}}
  end

  defp do_handle_cancel(%{pending_result: true} = state) do
    # Request PortSession cancellation and wait for its terminal cleanup before
    # advancing core. Never change Core phase while an old result is pending.
    _ = request_session_cancel(state)
    {:noreply, %{state | cancel_requested: true}}
  end

  defp do_handle_cancel(%{cancel_applied: true} = state) do
    {:noreply, %{state | cancel_requested: true}}
  end

  defp do_handle_cancel(%{core: core} = state) when is_map(core) do
    state = cancel_cleanup_timer(state)
    apply_cancel_once(%{state | cancel_requested: true}, :cancelled)
  end

  defp do_handle_cancel(state) do
    hold_terminal_for_gate(state, {:error, :cancelled})
  end

  defp apply_cancel_once(%{cancel_applied: true} = state, _fallback_reason) do
    {:noreply, state}
  end

  defp apply_cancel_once(%{held_terminal: held} = state, _fallback_reason)
       when not is_nil(held) do
    {:noreply, %{state | cancel_applied: true, cancel_requested: true}}
  end

  defp apply_cancel_once(%{core: core} = state, fallback_reason) when is_map(core) do
    state = cancel_cleanup_timer(state)

    case UnitCore.cancel(core) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core, cancel_applied: true}, effects)

      {:error, :lifecycle_already_terminal} ->
        # Core is already terminal — hold its terminal if not yet held.
        state = %{state | cancel_applied: true}

        case Map.get(core, :terminal) do
          nil ->
            hold_terminal_for_gate(state, {:error, fallback_reason})

          terminal ->
            hold_terminal_for_gate(%{state | core: core}, terminal)
        end

      {:error, reason} ->
        hold_terminal_for_gate(state, {:error, reason || fallback_reason})
    end
  end

  defp apply_cancel_once(state, fallback_reason) do
    hold_terminal_for_gate(state, {:error, fallback_reason})
  end

  # Called only after successful journal completion + publication.
  # Drain-without-publication (failed complete + accepted drain) is handled in
  # handle_journal_complete_failure and must never claim completion/publication.
  defp stop_after_terminal(state) do
    cond do
      state.terminal_published != true ->
        # Failed journal calls must not fall through to direct stop.
        {:noreply, state}

      is_nil(state.drain_receipt) ->
        {:stop, :normal, state}

      drain_emission_allowed?(state) ->
        state = emit_drain_receipt(state)
        {:stop, :normal, state}

      true ->
        # Drain requested after create without Core absence proof — never emit.
        {:noreply, state}
    end
  end

  defp drain_emission_allowed?(%{core: nil}), do: true

  defp drain_emission_allowed?(%{core: %{create_attempted: false}}), do: true

  # Any valid UnitCore terminal after create_attempted (success or error)
  # implies positive structured absence was proven by UnitCore.
  defp drain_emission_allowed?(%{
         core: %{create_attempted: true, stage: :terminal, terminal: terminal}
       })
       when not is_nil(terminal),
       do: true

  defp drain_emission_allowed?(_), do: false

  defp emit_drain_receipt(
         %{drain_receipt: {caller_pid, receipt_ref}, execution_id: execution_id} = state
       )
       when is_pid(caller_pid) and is_reference(receipt_ref) and is_binary(execution_id) do
    if Process.alive?(caller_pid) do
      send(
        caller_pid,
        {:apple_container_unit_drained, self(), execution_id, receipt_ref}
      )
    end

    %{state | drain_receipt: :sent}
  end

  defp emit_drain_receipt(state), do: state

  defp request_session_cancel(%{active_session: session, runtime: runtime, active_session_id: id})
       when is_pid(session) do
    if is_binary(id) do
      send(session, {:cancel_shell_execution, id})
    else
      runtime.kill(session)
    end

    :ok
  end

  defp request_session_cancel(_), do: :ok

  # ---------------------------------------------------------------------------
  # Active session helpers
  # ---------------------------------------------------------------------------

  defp clear_active_session(state) do
    if is_reference(state.active_session_ref) do
      Process.demonitor(state.active_session_ref, [:flush])
    end

    %{
      state
      | active_phase: nil,
        active_session: nil,
        active_session_id: nil,
        active_session_ref: nil,
        pending_result: false
    }
  end

  defp kill_active_session(%{active_session: session, runtime: runtime}) when is_pid(session) do
    runtime.kill(session)
    :ok
  end

  defp kill_active_session(_), do: :ok

  defp cancel_cleanup_timer(%{cleanup_timer: timer_ref} = state) when is_reference(timer_ref) do
    _ = :erlang.cancel_timer(timer_ref)

    # Non-blockingly flush the exact tokenized timeout if already delivered.
    receive do
      {:timeout, ^timer_ref, _effect} -> :ok
    after
      0 -> :ok
    end

    %{state | cleanup_timer: nil, cleanup_timer_effect: nil}
  end

  defp cancel_cleanup_timer(state), do: state

  defp cancel_pre_begin_timer(%{pre_begin_timer: timer_ref} = state)
       when is_reference(timer_ref) do
    _ = :erlang.cancel_timer(timer_ref)

    receive do
      {:timeout, ^timer_ref, :pre_begin_timeout} -> :ok
    after
      0 -> :ok
    end

    %{state | pre_begin_timer: nil}
  end

  defp cancel_pre_begin_timer(state), do: state

  defp cancel_journal_retry_timer(%{journal_retry_timer: timer_ref} = state)
       when is_reference(timer_ref) do
    _ = :erlang.cancel_timer(timer_ref)

    receive do
      {:timeout, ^timer_ref, {:journal_complete_retry, _token}} -> :ok
    after
      0 -> :ok
    end

    %{state | journal_retry_timer: nil, journal_retry_token: nil}
  end

  defp cancel_journal_retry_timer(state), do: state

  # ---------------------------------------------------------------------------
  # Durable journal completion gate + registry publish
  # ---------------------------------------------------------------------------

  # Hold a bounded terminal privately, complete the durable journal, then
  # publish registry/controller exactly once. Never publish before journal :ok.
  defp hold_terminal_for_gate(state, terminal) do
    cond do
      state.terminal_published == true ->
        stop_after_terminal(state)

      not is_nil(state.held_terminal) ->
        # Never overwrite a held terminal (e.g. later cancel).
        attempt_journal_completion_gate(state)

      true ->
        held = prepare_held_terminal(state, terminal)

        state = %{
          state
          | held_terminal: held,
            terminal: held,
            status: :journal_completing
        }

        attempt_journal_completion_gate(state)
    end
  end

  defp prepare_held_terminal(state, {:ok, result}) when is_map(result) do
    {:ok, sanitize_result(result, state)}
  end

  defp prepare_held_terminal(_state, {:error, reason}) do
    {:error, bound_reason(reason)}
  end

  defp prepare_held_terminal(_state, reason) do
    {:error, bound_reason(reason)}
  end

  defp attempt_journal_completion_gate(state) do
    cond do
      state.terminal_published == true ->
        stop_after_terminal(state)

      is_nil(state.held_terminal) ->
        {:noreply, state}

      not journal_completion_allowed?(state) ->
        # Raw post-create nonterminal Core: never complete, publish, or drain.
        state = cancel_journal_retry_timer(state)

        %{
          state
          | journal_complete_status: :blocked,
            journal_complete_reason: :completion_not_allowed
        }
        |> then(&{:noreply, &1})

      true ->
        case invoke_journal_complete(state) do
          :ok ->
            state = cancel_journal_retry_timer(state)
            state = publish_held_terminal(state)
            stop_after_terminal(state)

          {:error, reason} ->
            handle_journal_complete_failure(state, reason)
        end
    end
  end

  # Allow complete only when create was never attempted, or Core is terminal
  # after create_attempted (UnitCore guarantees that follows positive absence).
  defp journal_completion_allowed?(%{core: nil}), do: true

  defp journal_completion_allowed?(%{core: %{create_attempted: false}}), do: true

  defp journal_completion_allowed?(%{core: %{create_attempted: true, stage: :terminal}}),
    do: true

  defp journal_completion_allowed?(_), do: false

  defp invoke_journal_complete(state) do
    record = state.journal_record
    unit_name = Map.get(record, :unit_name)
    token = Map.get(record, :token)
    journal = state.journal_module

    if is_binary(unit_name) and is_binary(token) and is_atom(journal) do
      try do
        case journal.complete(unit_name, token) do
          :ok ->
            :ok

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
    else
      {:error, :invalid_journal_record}
    end
  end

  defp handle_journal_complete_failure(state, reason) do
    bound = bound_reason(reason)

    state = %{
      state
      | journal_complete_status: :error,
        journal_complete_reason: bound
    }

    if match?({_pid, _ref}, state.drain_receipt) and drain_emission_allowed?(state) do
      # Accepted drain + safe containment + failed completion: emit receipt and
      # stop WITHOUT registry/controller publication or completion claim. Leave
      # the durable journal row for the Reconciler.
      state = cancel_journal_retry_timer(state)
      state = emit_drain_receipt(state)
      {:stop, :normal, state}
    else
      schedule_journal_retry(state)
    end
  end

  defp schedule_journal_retry(state) do
    state = cancel_journal_retry_timer(state)
    delay = state.journal_retry_ms || @journal_retry_initial_ms
    # Opaque per-attempt token; timer payload carries neither journal record
    # nor token nor raw terminal result.
    attempt_token = make_ref()
    timer_ref = :erlang.start_timer(delay, self(), {:journal_complete_retry, attempt_token})
    next_delay = min(delay * 2, @journal_retry_max_ms)

    {:noreply,
     %{
       state
       | journal_retry_timer: timer_ref,
         journal_retry_token: attempt_token,
         journal_retry_ms: next_delay
     }}
  end

  defp publish_held_terminal(state) do
    if state.terminal_published do
      state
    else
      case state.held_terminal do
        {:ok, sanitized} = terminal when is_map(sanitized) ->
          # Registry projection is secondary: absence-proven terminals and drain
          # receipts must still complete when the registry is gone or exits.
          _ =
            best_effort_registry_publish(fn ->
              ExecutionRegistry.finish(state.execution_id, sanitized)
            end)

          notify_controller(state, {:ok, sanitized})

          %{
            state
            | terminal_published: true,
              terminal: terminal,
              status: :terminal,
              journal_complete_status: :ok,
              journal_complete_reason: nil
          }

        {:error, bound} = terminal ->
          _ =
            best_effort_registry_publish(fn ->
              ExecutionRegistry.fail(state.execution_id, bound)
            end)

          notify_controller(state, terminal)

          %{
            state
            | terminal_published: true,
              terminal: terminal,
              status: :terminal,
              journal_complete_status: :ok,
              journal_complete_reason: nil
          }

        _other ->
          state
      end
    end
  end

  # ExecutionRegistry is a best-effort projection only. Catch exits/errors so a
  # missing or restarting registry never aborts controller notification, terminal
  # state transition, drain receipt emission, or normal worker stop.
  defp best_effort_registry_publish(fun) when is_function(fun, 0) do
    try do
      fun.()
    catch
      :exit, _reason -> :registry_unavailable
      :error, _reason -> :registry_unavailable
      :throw, _reason -> :registry_unavailable
    end
  end

  defp notify_controller(%{controller_pid: pid, execution_id: id}, terminal) when is_pid(pid) do
    if Process.alive?(pid) do
      send(pid, {:apple_container_unit_terminal, id, secondary_notification(terminal)})
    end

    :ok
  end

  defp notify_controller(_state, _terminal), do: :ok

  # Full primary result for ExecutionRegistry (bounded by execution spec / UnitCore).
  defp sanitize_result(result, state) when is_map(result) do
    max_stdout = registry_stdout_limit(state)

    result
    |> Map.take([
      :exit_code,
      :stdout,
      :stderr,
      :duration_ms,
      :timed_out,
      :cancelled,
      :killed,
      :output_truncated,
      :output_limit_exceeded,
      :containment_failure
    ])
    |> Map.update(:stdout, "", &bound_binary(&1, max_stdout))
    |> Map.put(:stderr, "")
  end

  defp registry_stdout_limit(state) do
    hard = UnitCore.phase_output_limit(:start)
    requested = Map.get(state.spec || %{}, :max_output_bytes, hard)
    min(requested, hard)
  end

  # Secondary notification only — never carry full candidate stdout.
  defp secondary_notification({:ok, result}) when is_map(result) do
    {:ok,
     %{
       exit_code: Map.get(result, :exit_code, 0),
       stdout: bound_binary(Map.get(result, :stdout, ""), @max_secondary_notification_bytes),
       stderr: "",
       duration_ms: Map.get(result, :duration_ms, 0),
       timed_out: Map.get(result, :timed_out) == true,
       cancelled: Map.get(result, :cancelled) == true,
       killed: Map.get(result, :killed) == true,
       output_truncated: Map.get(result, :output_truncated) == true,
       output_limit_exceeded: Map.get(result, :output_limit_exceeded) == true
     }
     |> maybe_put_containment(Map.get(result, :containment_failure) == true)}
  end

  defp secondary_notification({:error, reason}), do: {:error, bound_reason(reason)}
  defp secondary_notification(other), do: {:error, bound_reason(other)}

  defp bound_reason(reason) when is_atom(reason), do: reason

  defp bound_reason(reason) when is_binary(reason) do
    if byte_size(reason) <= @max_reason_bytes, do: reason, else: :unit_error
  end

  defp bound_reason(reason) when is_tuple(reason) and tuple_size(reason) <= 4 do
    if Enum.all?(Tuple.to_list(reason), &(is_atom(&1) or is_integer(&1))) do
      reason
    else
      :unit_error
    end
  end

  defp bound_reason(_), do: :unit_error

  defp bound_binary(bin, max) when is_binary(bin) and is_integer(max) do
    if byte_size(bin) <= max, do: bin, else: binary_part(bin, 0, max)
  end

  defp bound_binary(_, _), do: ""

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  # Re-check timeout against the plan's admitted resource_profile so durable
  # reconstruction cannot settle an intensive budget under a standard plan.
  defp validate_spec(%{plan: plan, timeout_ms: timeout_ms, max_output_bytes: max_output_bytes})
       when is_map(plan) and is_integer(timeout_ms) and
              is_integer(max_output_bytes) and max_output_bytes > 0 do
    with {:ok, profile} <- fetch_spec_resource_profile(plan),
         :ok <- SpawnCapableTimeout.validate_timeout_ms(timeout_ms, profile) do
      :ok
    else
      _ -> {:error, :invalid_execution_spec}
    end
  end

  defp validate_spec(_), do: {:error, :invalid_execution_spec}

  defp fetch_spec_resource_profile(plan) when is_map(plan) do
    case {Map.fetch(plan, :resource_profile), Map.fetch(plan, "resource_profile")} do
      {{:ok, profile}, :error} ->
        # Durable normalizer: admits atoms and JSON-clean "standard"/"intensive".
        AppleContainerPlanCore.normalize_durable_resource_profile(profile)

      {:error, {:ok, profile}} ->
        AppleContainerPlanCore.normalize_durable_resource_profile(profile)

      {:error, :error} ->
        {:ok, AppleContainerPlanCore.default_resource_profile()}

      _other ->
        {:error, :invalid_resource_profile}
    end
  end

  defp validate_executable(%ExecutablePolicy.Executable{path: @runtime_path}), do: :ok

  defp validate_executable(%ExecutablePolicy.Executable{}),
    do: {:error, :invalid_runtime_executable}

  defp validate_executable(_), do: {:error, :invalid_runtime_executable}

  defp validate_execution_id(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 256 do
    if String.valid?(id) and not String.contains?(id, ["/", "\\", "\0"]) do
      :ok
    else
      {:error, :invalid_execution_id}
    end
  end

  defp validate_execution_id(_), do: {:error, :invalid_execution_id}

  defp validate_pre_begin_timeout(ms)
       when is_integer(ms) and ms > 0 and ms <= @max_pre_begin_timeout_ms do
    :ok
  end

  defp validate_pre_begin_timeout(_), do: {:error, :invalid_pre_begin_timeout}

  defp validate_ownership_caller(pid) when is_pid(pid), do: :ok

  defp validate_ownership_caller({:registered, name}) when is_atom(name) do
    if Process.whereis(name) == self() do
      :ok
    else
      {:error, :invalid_ownership_caller}
    end
  end

  defp validate_ownership_caller(_), do: {:error, :invalid_ownership_caller}

  defp require_admission_opts(opts) when is_list(opts) do
    required = [:journal_record, :operation_deadline, :ownership_caller]

    if Enum.all?(required, &Keyword.has_key?(opts, &1)) do
      :ok
    else
      {:error, :durable_unit_admission_required}
    end
  end

  defp fetch_admission_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :durable_unit_admission_required}
    end
  end

  defp validate_journal_record(record, execution_id, %{plan: plan})
       when is_map(record) and is_binary(execution_id) and is_map(plan) do
    unit_name = Map.get(plan, :unit_name)

    with true <- is_binary(unit_name) and unit_name != "",
         {:ok, empty} <- JournalCore.new(),
         {:ok, journal, _effects} <- JournalCore.reserve(empty, record),
         entries when is_list(entries) <- JournalCore.recovery_entries(journal),
         [normalized] <- entries do
      cond do
        normalized.execution_id != execution_id ->
          {:error, :journal_record_mismatch}

        normalized.unit_name != unit_name ->
          {:error, :journal_record_mismatch}

        true ->
          {:ok, normalized}
      end
    else
      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_journal_record}
    end
  end

  defp validate_journal_record(_record, _execution_id, _spec),
    do: {:error, :invalid_journal_record}

  defp validate_operation_deadline(deadline, runtime, %{timeout_ms: timeout_ms})
       when is_integer(deadline) and is_atom(runtime) and is_integer(timeout_ms) and
              timeout_ms > 0 do
    now = runtime.monotonic_ms()

    if is_integer(now) do
      remaining = deadline - now

      # Strictly future and no farther than the execution spec timeout.
      if remaining > 0 and remaining <= timeout_ms do
        {:ok, deadline}
      else
        {:error, :invalid_operation_deadline}
      end
    else
      {:error, :invalid_operation_deadline}
    end
  end

  defp validate_operation_deadline(_deadline, _runtime, _spec),
    do: {:error, :invalid_operation_deadline}

  defp cap_pre_begin_timeout(pre_begin_timeout_ms, deadline, runtime) do
    now = runtime.monotonic_ms()

    if is_integer(now) and deadline > now do
      {:ok, min(pre_begin_timeout_ms, deadline - now)}
    else
      {:error, :invalid_operation_deadline}
    end
  end

  defp authorize_ownership_info(state, caller_pid, exact_record) do
    stored = Map.get(state, :journal_record)
    ownership = Map.get(state, :ownership_caller)

    with true <- authorized_ownership_caller?(ownership, caller_pid),
         true <- is_map(stored),
         {:ok, empty} <- JournalCore.new(),
         {:ok, journal, _effects} <- JournalCore.reserve(empty, exact_record),
         entries when is_list(entries) <- JournalCore.recovery_entries(journal),
         [normalized] <- entries,
         true <- normalized == stored do
      {:ok,
       %{
         journal_record: stored,
         controller_pid: Map.get(state, :controller_pid),
         execution_id: Map.get(state, :execution_id)
       }}
    else
      _ ->
        {:error, :ownership_denied}
    end
  end

  # Same caller authority as ownership_info, but no full-record gate and only
  # the execution_id is projected — never journal/token/controller/ownership.
  defp authorize_ownership_hint(state, caller_pid) do
    ownership = Map.get(state, :ownership_caller)
    execution_id = Map.get(state, :execution_id)

    if authorized_ownership_caller?(ownership, caller_pid) and is_binary(execution_id) and
         execution_id != "" do
      {:ok, %{execution_id: execution_id}}
    else
      {:error, :ownership_denied}
    end
  end

  defp authorized_ownership_caller?(ownership, caller_pid) when is_pid(ownership),
    do: caller_pid == ownership

  defp authorized_ownership_caller?({:registered, name}, caller_pid) when is_atom(name),
    do: Process.whereis(name) == caller_pid

  defp authorized_ownership_caller?(_ownership, _caller_pid), do: false

  defp validate_runtime_module(AppleContainerUnitRuntime), do: :ok

  defp validate_runtime_module(runtime) when is_atom(runtime) do
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

  defp validate_journal_module(@journal), do: :ok

  defp validate_journal_module(journal) when is_atom(journal) do
    case Code.ensure_loaded(journal) do
      {:module, ^journal} ->
        if Enum.any?(@required_journal_callbacks, fn {fun, arity} ->
             function_exported?(journal, fun, arity) or
               function_exported?(journal, fun, arity + 1)
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

  # ---------------------------------------------------------------------------
  # Redaction
  # ---------------------------------------------------------------------------

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      execution_id: Map.get(state, :execution_id),
      terminal_published: Map.get(state, :terminal_published) == true,
      cancel_requested: Map.get(state, :cancel_requested) == true,
      cancel_applied: Map.get(state, :cancel_applied) == true,
      drain_requested: match?({_pid, _ref}, Map.get(state, :drain_receipt)),
      pending_result: Map.get(state, :pending_result) == true,
      active_phase: Map.get(state, :active_phase),
      # Authority-bearing / sensitive fields always redacted.
      plan: :redacted,
      argv: :redacted,
      projections: :redacted,
      executable: :redacted,
      start_ref: :redacted,
      controller_pid: :redacted,
      controller_ref: :redacted,
      ownership_caller: :redacted,
      ownership: :redacted,
      journal_record: :redacted,
      journal_module: :redacted,
      token: :redacted,
      active_session: :redacted,
      active_session_id: :redacted,
      active_session_ref: :redacted,
      cleanup_timer: :redacted,
      cleanup_timer_effect: :redacted,
      pre_begin_timer: :redacted,
      operation_deadline: :redacted,
      drain_receipt: :redacted,
      spec: :redacted,
      core: :redacted,
      terminal: :redacted,
      held_terminal: :redacted,
      journal_retry_timer: :redacted,
      journal_retry_token: :redacted,
      journal_retry_ms: :redacted,
      journal_complete_status: :redacted,
      journal_complete_reason: :redacted,
      runtime: :redacted,
      paths: :redacted,
      output: :redacted,
      message: :redacted,
      reason: :redacted,
      log: :redacted
    }
  end

  defp redact_state(_), do: :redacted
end
