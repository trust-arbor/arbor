defmodule Arbor.Shell.AppleContainerUnitWorker do
  @moduledoc false

  # Temporary supervised Apple Container unit owner (Phase 6).
  #
  # Drives every lifecycle transition through AppleContainerUnitCore. Runs
  # structured argv via AppleContainerUnitRuntime (PortSession) — never shell
  # text. Publishes nothing to ExecutionRegistry until positive unit absence is
  # proven. Production spawn facade remains fail-closed.
  #
  # Supervisor shutdown (`shutdown: :infinity`) requests cancellation once and
  # keeps this GenServer alive through PortSession cleanup, UnitCore retry_after
  # loops, and final list absence. Stop only after UnitCore reaches terminal.

  use GenServer

  alias Arbor.Shell.AppleContainerExecutionCore
  alias Arbor.Shell.AppleContainerUnitCore, as: UnitCore
  alias Arbor.Shell.AppleContainerUnitRuntime
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.ExecutionRegistry

  @supervisor Arbor.Shell.AppleContainerUnitSupervisor
  @runtime_path "/usr/local/bin/container"
  @display_command "container unit"
  @cleanup_attempt_timeout_ms 30_000
  @max_reason_bytes 512
  # Secondary controller notification only — registry keeps the full primary result.
  @max_secondary_notification_bytes 512

  @required_runtime_callbacks [
    {:start_command, 4},
    {:kill, 1},
    {:get_id, 1},
    {:get_result, 1},
    {:monotonic_ms, 0}
  ]

  @type start_args :: %{
          required(:spec) => map(),
          required(:executable) => ExecutablePolicy.Executable.t(),
          required(:execution_id) => String.t(),
          required(:start_ref) => reference(),
          required(:controller_pid) => pid(),
          optional(:runtime) => module()
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

  Captures the controller from `self()` — never accepts a caller-supplied owner
  pid. The controller must register the execution, `adopt/2` this worker, then
  call `begin/3` with the exact opaque ref.
  """
  @spec start(
          AppleContainerExecutionCore.execution_spec(),
          ExecutablePolicy.Executable.t(),
          String.t(),
          reference()
        ) :: {:ok, pid()} | {:error, term()}
  def start(spec, executable, execution_id, start_ref)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) do
    start_waiting(spec, executable, execution_id, start_ref, self(), AppleContainerUnitRuntime)
  end

  def start(_spec, _executable, _execution_id, _start_ref),
    do: {:error, :invalid_unit_start}

  @doc false
  @spec start_for_test(
          AppleContainerExecutionCore.execution_spec(),
          ExecutablePolicy.Executable.t(),
          String.t(),
          reference(),
          keyword()
        ) :: {:ok, pid()} | {:error, term()}
  def start_for_test(spec, executable, execution_id, start_ref, opts \\ [])

  def start_for_test(spec, executable, execution_id, start_ref, opts)
      when is_map(spec) and is_binary(execution_id) and is_reference(start_ref) and is_list(opts) do
    if Keyword.keyword?(opts) do
      runtime = Keyword.get(opts, :runtime, AppleContainerUnitRuntime)

      with :ok <- validate_runtime_module(runtime) do
        start_waiting(spec, executable, execution_id, start_ref, self(), runtime)
      end
    else
      {:error, :invalid_unit_start_options}
    end
  end

  def start_for_test(_spec, _executable, _execution_id, _start_ref, _opts),
    do: {:error, :invalid_unit_start}

  @doc false
  @spec begin(pid(), reference(), timeout()) :: :ok | {:error, term()}
  def begin(worker, start_ref, timeout \\ 5_000)
      when is_pid(worker) and is_reference(start_ref) and
             (is_integer(timeout) or timeout == :infinity) do
    GenServer.call(worker, {:begin, start_ref}, timeout)
  end

  def begin(_worker, _start_ref, _timeout), do: {:error, :invalid_begin}

  defp start_waiting(spec, executable, execution_id, start_ref, controller_pid, runtime) do
    with :ok <- validate_spec(spec),
         :ok <- validate_executable(executable),
         :ok <- validate_execution_id(execution_id),
         :ok <- validate_runtime_module(runtime) do
      args = %{
        spec: spec,
        executable: executable,
        execution_id: execution_id,
        start_ref: start_ref,
        controller_pid: controller_pid,
        runtime: runtime
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

    state = %{
      status: :waiting,
      execution_id: execution_id,
      start_ref: start_ref,
      controller_pid: controller,
      controller_ref: Process.monitor(controller),
      spec: spec,
      executable: executable,
      runtime: runtime,
      operation_deadline: nil,
      core: nil,
      active_phase: nil,
      active_session: nil,
      active_session_id: nil,
      active_session_ref: nil,
      pending_result: false,
      cancel_requested: false,
      cancel_applied: false,
      shutdown_requested: false,
      shutdown_reason: nil,
      cleanup_timer: nil,
      cleanup_timer_effect: nil,
      terminal_published: false,
      terminal: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:begin, start_ref}, _from, %{status: :waiting, start_ref: start_ref} = state)
      when is_reference(start_ref) do
    case begin_lifecycle(state) do
      {:ok, started} ->
        {:reply, :ok, started}

      {:stop, reason, stopped} ->
        {:stop, reason, reply_for_stop(stopped), stopped}
    end
  end

  def handle_call({:begin, _wrong_or_replayed}, _from, state) do
    # Wrong or replayed ref runs nothing.
    {:reply, {:error, :invalid_begin_ref}, state}
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

  def handle_info({:timeout, _other_ref, _effect}, state) do
    # Stale or foreign timer — ignore.
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, reason}, state) do
    # Parent supervisor shutdown: keep authority until UnitCore terminal.
    # shutdown: :infinity exists so this worker can finish asynchronous cleanup.
    state = request_shutdown_cleanup(state, reason)
    continue_or_stop_after_shutdown(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Final defense only — normal cleanup is the async EXIT/cancel path.
    _ = cancel_cleanup_timer(state)
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
    deadline = now + state.spec.timeout_ms

    case UnitCore.new(state.spec.plan) do
      {:ok, core, effects} ->
        state = %{
          state
          | status: :running,
            start_ref: nil,
            operation_deadline: deadline,
            core: core
        }

        case dispatch_effects(state, effects) do
          {:noreply, next} -> {:ok, next}
          {:stop, reason, next} -> {:stop, reason, next}
        end

      {:error, reason} ->
        state = publish_error(state, reason)
        {:stop, :normal, state}
    end
  end

  defp reply_for_stop(%{terminal: {:error, reason}}), do: {:error, reason}
  defp reply_for_stop(%{terminal: {:ok, _}}), do: :ok
  defp reply_for_stop(_), do: :ok

  defp dispatch_effects(state, effects) when is_list(effects) do
    Enum.reduce_while(effects, {:noreply, state}, fn effect, {:noreply, acc} ->
      case apply_effect(acc, effect) do
        {:noreply, next} -> {:cont, {:noreply, next}}
        {:stop, reason, next} -> {:halt, {:stop, reason, next}}
      end
    end)
  end

  defp apply_effect(state, {:terminal, terminal}) do
    state = publish_terminal(state, terminal)
    {:stop, stop_reason(state), state}
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

  defp stop_reason(%{shutdown_requested: true, shutdown_reason: reason})
       when reason != nil,
       do: reason

  defp stop_reason(_), do: :normal

  defp launch_phase(state, phase, argv) do
    with :ok <- require_no_pending(state),
         {:ok, args} <- strip_runtime_prefix(argv, state.executable),
         {:ok, timeout_ms} <- phase_timeout(state, phase),
         {:ok, max_output} <- phase_max_output(state, phase) do
      opts = [
        cwd: "/",
        clear_env: true,
        env: %{},
        stream_to: self(),
        timeout: timeout_ms,
        max_output_bytes: max_output
      ]

      case state.runtime.start_command(state.executable, args, @display_command, opts) do
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
          state = publish_error(state, reason)
          {:stop, stop_reason(state), state}
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
          state = publish_error(state, reason)
          {:stop, stop_reason(state), state}
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
        state = publish_error(state, :unit_error)
        {:stop, stop_reason(state), state}

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
  # Cancellation / shutdown
  # ---------------------------------------------------------------------------

  defp handle_cancel(%{status: :waiting} = state) do
    # Preflight not begun — no create attempted.
    state = publish_error(state, :preflight_cancelled)
    {:stop, stop_reason(state), state}
  end

  defp handle_cancel(%{terminal_published: true} = state), do: {:noreply, state}

  defp handle_cancel(%{pending_result: true} = state) do
    # Request PortSession cancellation and wait for its terminal cleanup before
    # advancing core. Never change Core phase while an old result is pending.
    _ = request_session_cancel(state)
    {:noreply, %{state | cancel_requested: true}}
  end

  defp handle_cancel(%{cancel_applied: true} = state) do
    {:noreply, %{state | cancel_requested: true}}
  end

  defp handle_cancel(%{core: core} = state) when is_map(core) do
    state = cancel_cleanup_timer(state)
    apply_cancel_once(%{state | cancel_requested: true}, :cancelled)
  end

  defp handle_cancel(state) do
    state = publish_error(state, :cancelled)
    {:stop, stop_reason(state), state}
  end

  defp apply_cancel_once(%{cancel_applied: true} = state, _fallback_reason) do
    {:noreply, state}
  end

  defp apply_cancel_once(%{core: core} = state, fallback_reason) when is_map(core) do
    state = cancel_cleanup_timer(state)

    case UnitCore.cancel(core) do
      {:ok, core, effects} ->
        dispatch_effects(%{state | core: core, cancel_applied: true}, effects)

      {:error, :lifecycle_already_terminal} ->
        {:noreply, %{state | cancel_applied: true}}

      {:error, reason} ->
        state = publish_error(state, reason || fallback_reason)
        {:stop, stop_reason(state), state}
    end
  end

  defp apply_cancel_once(state, fallback_reason) do
    state = publish_error(state, fallback_reason)
    {:stop, stop_reason(state), state}
  end

  defp request_shutdown_cleanup(%{shutdown_requested: true} = state, _reason), do: state

  defp request_shutdown_cleanup(%{terminal_published: true} = state, reason) do
    %{state | shutdown_requested: true, shutdown_reason: reason}
  end

  defp request_shutdown_cleanup(%{status: :waiting} = state, reason) do
    state = %{state | shutdown_requested: true, shutdown_reason: reason}
    state = publish_error(state, :preflight_cancelled)
    state
  end

  defp request_shutdown_cleanup(state, reason) do
    state = %{state | shutdown_requested: true, shutdown_reason: reason, cancel_requested: true}

    cond do
      state.pending_result ->
        _ = request_session_cancel(state)
        state

      state.cancel_applied ->
        state

      is_map(state.core) and state.core.stage != :terminal ->
        case UnitCore.cancel(state.core) do
          {:ok, core, effects} ->
            # Dispatch effects asynchronously (no sync drain). May start sessions
            # or schedule retry_after; GenServer stays alive until terminal.
            case dispatch_effects(
                   %{state | core: core, cancel_applied: true},
                   effects
                 ) do
              {:noreply, next} -> next
              {:stop, _stop_reason, next} -> next
            end

          {:error, :lifecycle_already_terminal} ->
            %{state | cancel_applied: true}

          {:error, err} ->
            publish_error(state, err)
        end

      true ->
        state
    end
  end

  defp continue_or_stop_after_shutdown(%{terminal_published: true} = state) do
    {:stop, stop_reason(state), state}
  end

  defp continue_or_stop_after_shutdown(state) do
    # Keep the GenServer alive for PortSession completion, retry_after, and
    # final absence proof. Stop only when UnitCore reaches terminal.
    {:noreply, state}
  end

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

  # ---------------------------------------------------------------------------
  # Registry publish / secondary notification
  # ---------------------------------------------------------------------------

  defp publish_terminal(state, {:ok, result} = _terminal) when is_map(result) do
    if state.terminal_published do
      state
    else
      sanitized = sanitize_result(result, state)
      _ = ExecutionRegistry.finish(state.execution_id, sanitized)
      notify_controller(state, {:ok, sanitized})
      %{state | terminal_published: true, terminal: {:ok, sanitized}, status: :terminal}
    end
  end

  defp publish_terminal(state, {:error, reason} = terminal) do
    publish_error(state, reason, terminal)
  end

  defp publish_error(state, reason, terminal \\ nil) do
    if state.terminal_published do
      state
    else
      bound = bound_reason(reason)
      _ = ExecutionRegistry.fail(state.execution_id, bound)
      terminal = terminal || {:error, bound}
      notify_controller(state, terminal)
      %{state | terminal_published: true, terminal: terminal, status: :terminal}
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

  defp validate_spec(%{plan: plan, timeout_ms: timeout_ms, max_output_bytes: max_output_bytes})
       when is_map(plan) and is_integer(timeout_ms) and timeout_ms > 0 and
              is_integer(max_output_bytes) and max_output_bytes > 0 do
    :ok
  end

  defp validate_spec(_), do: {:error, :invalid_execution_spec}

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
      shutdown_requested: Map.get(state, :shutdown_requested) == true,
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
      active_session: :redacted,
      active_session_id: :redacted,
      active_session_ref: :redacted,
      cleanup_timer: :redacted,
      cleanup_timer_effect: :redacted,
      operation_deadline: :redacted,
      shutdown_reason: :redacted,
      spec: :redacted,
      core: :redacted,
      terminal: :redacted,
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
