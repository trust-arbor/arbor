defmodule Arbor.Shell.PortSession do
  @moduledoc """
  Supervised streaming execution backed by `Arbor.Shell.ProcessGroup`.

  Every session has a finite absolute monotonic deadline. The native owner kills
  the target process group before a timeout, output limit, cancellation, owner
  loss, or direct-child exit is reported to subscribers.
  """

  use GenServer

  alias Arbor.Identifiers
  alias Arbor.Shell.{ExecutablePolicy, ExecutionRegistry, Executor, ProcessGroup, Sandbox}
  alias Arbor.Signals

  @default_timeout 30_000
  @max_stream_timeout 600_000
  @retention_ms 1_000

  defstruct [
    :id,
    :handle,
    :command,
    :executable,
    :args,
    :start_time,
    :deadline,
    :timeout,
    :max_output_bytes,
    :opts,
    :start_ref,
    :tracked,
    status: :starting,
    subscribers: MapSet.new(),
    output_acc: [],
    output_bytes: 0,
    exit_code: nil,
    output_truncated: false,
    output_limit_exceeded: false,
    timed_out: false,
    killed: false,
    cancelled: false
  ]

  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(command, opts \\ []) do
    GenServer.start_link(__MODULE__, {command, opts})
  end

  @spec start_supervised(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_supervised(command, opts \\ []) do
    DynamicSupervisor.start_child(
      Arbor.Shell.PortSessionSupervisor,
      {__MODULE__, {command, opts}}
    )
  end

  @doc false
  @spec start_link_direct(String.t(), [String.t()], String.t(), keyword()) :: GenServer.on_start()
  def start_link_direct(executable, args, display_command, opts) do
    GenServer.start_link(__MODULE__, {:direct, executable, args, display_command, opts})
  end

  @doc false
  @spec start_supervised_direct(String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_supervised_direct(executable, args, display_command, opts \\ []) do
    DynamicSupervisor.start_child(
      Arbor.Shell.PortSessionSupervisor,
      {__MODULE__, {:direct, executable, args, display_command, opts}}
    )
  end

  @doc false
  @spec begin(GenServer.server(), reference(), timeout()) :: :ok | {:error, term()}
  def begin(session, start_ref, timeout) do
    GenServer.call(session, {:begin, start_ref}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :stream_setup_timeout}
    :exit, reason -> {:error, reason}
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(session, pid), do: GenServer.call(session, {:subscribe, pid})

  @spec send_input(GenServer.server(), iodata()) :: :ok | {:error, :not_running | term()}
  def send_input(session, data), do: GenServer.call(session, {:send_input, data})

  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(session, timeout \\ 5_000) do
    GenServer.call(session, :stop, timeout)
  catch
    :exit, _ -> :ok
  end

  @spec kill(GenServer.server()) :: :ok
  def kill(session) do
    send(session, {:cancel_shell_execution, nil})
    :ok
  end

  @spec get_result(GenServer.server()) :: {:ok, map()}
  def get_result(session), do: GenServer.call(session, :get_result)

  @spec get_id(GenServer.server()) :: String.t()
  def get_id(session), do: GenServer.call(session, :get_id)

  def child_spec({command, opts}) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [command, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def child_spec({:direct, executable, args, display_command, opts}) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link_direct, [executable, args, display_command, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({:direct, executable, args, display_command, opts}) do
    init_session(executable, args, display_command, opts)
  end

  def init({command, opts}) do
    {executable, args} = Sandbox.parse_command(command)
    init_session(executable, args, command, opts)
  end

  @impl true
  def handle_call({:begin, start_ref}, _from, %{start_ref: start_ref, status: :starting} = state) do
    case open_and_start(state) do
      {:ok, running} ->
        {:reply, :ok, running}

      {:error, reason, failed} ->
        fail_tracked(failed, reason)
        {:stop, :normal, {:error, reason}, %{failed | status: :failed}}
    end
  end

  def handle_call({:begin, _start_ref}, _from, state) do
    {:reply, {:error, :invalid_stream_start}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:send_input, data}, _from, %{status: :running, handle: handle} = state) do
    {:reply, ProcessGroup.send_input(handle, data), state}
  end

  def handle_call({:send_input, _data}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:stop, _from, state) do
    stopped = cancel_running(state)
    {:stop, :normal, :ok, stopped}
  end

  def handle_call(:get_result, _from, state) do
    {:reply, {:ok, result_projection(state)}, state}
  end

  def handle_call(:get_id, _from, state), do: {:reply, state.id, state}

  @impl true
  def handle_info({:cancel_shell_execution, id}, state) do
    if id in [nil, state.id] do
      cancelled = cancel_running(state)
      {:stop, :normal, cancelled}
    else
      {:noreply, state}
    end
  end

  def handle_info(:self_terminate, state), do: {:stop, :normal, state}

  def handle_info(message, %{handle: %ProcessGroup{} = handle} = state) do
    case ProcessGroup.decode_message(handle, message) do
      {:output, data} ->
        Enum.each(state.subscribers, &send(&1, {:port_data, state.id, data}))

        {:noreply,
         %{
           state
           | output_acc: [data | state.output_acc],
             output_bytes: state.output_bytes + byte_size(data)
         }}

      {:terminal, reason, exit_code} ->
        completed = complete(state, reason, exit_code)
        Process.send_after(self(), :self_terminate, @retention_ms)
        {:noreply, completed}

      {:error, reason} ->
        fail_tracked(state, reason)
        notify_exit(state, 137)
        {:stop, :normal, %{state | status: :failed, handle: nil, exit_code: 137}}

      :ignore ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{status: :running} = state) do
    _ = cancel_running(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp init_session(executable, args, display_command, opts) do
    with {:ok, timeout} <- validate_timeout(Keyword.get(opts, :timeout, @default_timeout)),
         :ok <- validate_subscribers(Keyword.get(opts, :stream_to)) do
      start_time = Keyword.get(opts, :started_at, System.monotonic_time(:millisecond))
      deferred = Keyword.get(opts, :deferred)

      {id, start_ref, tracked} =
        case deferred do
          {execution_id, ref} when is_binary(execution_id) and is_reference(ref) ->
            {execution_id, ref, true}

          _ ->
            {Identifiers.generate_id("port_"), nil, false}
        end

      state = %__MODULE__{
        id: id,
        command: display_command,
        executable: executable,
        args: args,
        start_time: start_time,
        deadline: start_time + timeout,
        timeout: timeout,
        max_output_bytes:
          Executor.normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes)),
        opts: opts,
        subscribers: subscriber_set(opts),
        start_ref: start_ref,
        tracked: tracked
      }

      if deferred do
        {:ok, state}
      else
        case open_and_start(state, opts) do
          {:ok, running} -> {:ok, running}
          {:error, reason, _failed} -> {:stop, reason}
        end
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp open_and_start(state, opts \\ nil) do
    opts = opts || state.opts || []
    remaining = state.deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0,
         {:ok, executable} <- resolve_executable(state.executable),
         {:ok, handle} <-
           ProcessGroup.open(
             executable,
             state.args,
             opts,
             state.start_time,
             state.timeout,
             state.max_output_bytes
           ),
         :ok <- ProcessGroup.start(handle, Keyword.get(opts, :stdin)) do
      running = %{state | handle: handle, status: :running}
      emit_signal(:session_started, running)
      {:ok, running}
    else
      false -> {:error, :stream_setup_timeout, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp complete(state, reason, exit_code) do
    status =
      case reason do
        :normal -> :completed
        :timeout -> :timed_out
        _ -> :killed
      end

    completed = %{
      state
      | status: status,
        handle: nil,
        exit_code: exit_code,
        timed_out: reason == :timeout,
        killed: reason in [:timeout, :output_limit, :cancelled, :containment_failure],
        cancelled: reason == :cancelled,
        output_truncated: reason == :output_limit,
        output_limit_exceeded: reason == :output_limit
    }

    if reason == :output_limit do
      metadata = result_projection(completed)
      Enum.each(completed.subscribers, &send(&1, {:port_output_limit, completed.id, metadata}))
    end

    notify_exit(completed, exit_code)
    finish_tracked(completed)

    if reason == :normal,
      do: emit_signal(:session_completed, completed),
      else: emit_signal(:session_killed, completed, reason)

    completed
  end

  defp cancel_running(%{status: :running, handle: handle} = state) do
    reason =
      case ProcessGroup.terminate(handle, :cancelled) do
        {:ok, terminal_reason} -> terminal_reason
        {:error, _} -> :containment_failure
      end

    complete(state, reason, 137)
  end

  defp cancel_running(%{status: :starting} = state) do
    cancelled = %{
      state
      | status: :killed,
        exit_code: 137,
        killed: true,
        cancelled: true
    }

    finish_tracked(cancelled)
    cancelled
  end

  defp cancel_running(state), do: state

  defp notify_exit(state, exit_code) do
    output = output_binary(state)
    Enum.each(state.subscribers, &send(&1, {:port_exit, state.id, exit_code, output}))
  end

  defp result_projection(state) do
    %{
      id: state.id,
      status: state.status,
      exit_code: state.exit_code,
      output: output_binary(state),
      stdout: output_binary(state),
      stderr: "",
      output_bytes: state.output_bytes,
      max_output_bytes: state.max_output_bytes,
      output_truncated: state.output_truncated,
      output_limit_exceeded: state.output_limit_exceeded,
      timed_out: state.timed_out,
      killed: state.killed,
      cancelled: state.cancelled,
      duration_ms: max(System.monotonic_time(:millisecond) - state.start_time, 0),
      command: state.command
    }
  end

  defp finish_tracked(%{tracked: true, id: id} = state) do
    _ = ExecutionRegistry.finish(id, result_projection(state))
    :ok
  end

  defp finish_tracked(_state), do: :ok

  defp fail_tracked(%{tracked: true, id: id}, reason) do
    _ = ExecutionRegistry.fail(id, reason)
    :ok
  end

  defp fail_tracked(_state, _reason), do: :ok

  @doc false
  @spec validate_timeout(term()) :: {:ok, pos_integer()} | {:error, :invalid_stream_timeout}
  def validate_timeout(timeout)
      when is_integer(timeout) and timeout > 0 and timeout <= @max_stream_timeout,
      do: {:ok, timeout}

  def validate_timeout(_timeout), do: {:error, :invalid_stream_timeout}

  defp validate_subscribers(nil), do: :ok
  defp validate_subscribers(pid) when is_pid(pid), do: :ok

  defp validate_subscribers(pids) when is_list(pids) do
    if Enum.all?(pids, &is_pid/1), do: :ok, else: {:error, :invalid_stream_subscriber}
  end

  defp validate_subscribers(_other), do: {:error, :invalid_stream_subscriber}

  defp resolve_executable(%ExecutablePolicy.Executable{} = executable), do: {:ok, executable}
  defp resolve_executable(executable), do: ExecutablePolicy.resolve(executable)

  defp subscriber_set(opts) do
    case Keyword.get(opts, :stream_to) do
      nil -> MapSet.new()
      pid when is_pid(pid) -> MapSet.new([pid])
      pids when is_list(pids) -> MapSet.new(pids)
    end
  end

  defp output_binary(%{output_acc: acc}), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp emit_signal(:session_started, state) do
    Signals.emit(:shell, :session_started, %{
      session_id: state.id,
      command: truncate(state.command)
    })
  end

  defp emit_signal(:session_completed, state) do
    Signals.emit(:shell, :session_completed, %{
      session_id: state.id,
      exit_code: state.exit_code,
      duration_ms: result_projection(state).duration_ms
    })
  end

  defp emit_signal(:session_killed, state, reason) do
    Signals.emit(:shell, :session_killed, %{
      session_id: state.id,
      reason: reason,
      duration_ms: result_projection(state).duration_ms
    })
  end

  defp truncate(command) when byte_size(command) > 200, do: binary_part(command, 0, 200)
  defp truncate(command), do: command
end
