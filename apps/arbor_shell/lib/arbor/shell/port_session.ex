defmodule Arbor.Shell.PortSession do
  @moduledoc """
  A supervised GenServer managing a long-running Port process with streaming output.

  PortSession provides BEAM-supervised execution of shell commands with:
  - Real-time output streaming to subscribers
  - Direct OS-process hard kill plus Port cleanup
  - Timeout handling with automatic termination
  - Signal emission for observability

  ## Messages sent to subscribers

  - `{:port_data, session_id, chunk}` — output chunk received
  - `{:port_exit, session_id, exit_code, full_output}` — process exited
  - `{:port_output_limit, session_id, metadata}` — byte ceiling killed the process

  ## Usage

      {:ok, pid} = PortSession.start_link("echo hello", stream_to: self())

      # Receive streaming output
      receive do
        {:port_data, _id, chunk} -> IO.write(chunk)
        {:port_exit, _id, 0, output} -> IO.puts("Done: \#{output}")
      end
  """

  use GenServer

  alias Arbor.Identifiers
  alias Arbor.Shell.{Executor, Sandbox}
  alias Arbor.Signals

  require Logger

  @type status :: :running | :completed | :timed_out | :killed

  defstruct [
    :id,
    :port,
    :command,
    :start_time,
    :timeout,
    :timer_ref,
    :exit_code,
    :max_output_bytes,
    status: :running,
    subscribers: MapSet.new(),
    output_acc: [],
    output_bytes: 0,
    output_truncated: false,
    output_limit_exceeded: false
  ]

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start a PortSession under the PortSessionSupervisor.

  ## Options

  - `:stream_to` - PID or list of PIDs to receive output messages
  - `:timeout` - Timeout in ms (default: 30_000, use `:infinity` for no timeout)
  - `:max_output_bytes` - Hard retained and delivered byte ceiling
  - `:cwd` - Working directory
  - `:env` - Environment variables map
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(command, opts \\ []) do
    GenServer.start_link(__MODULE__, {command, opts})
  end

  @doc """
  Start a PortSession under the DynamicSupervisor.
  """
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

  @doc """
  Add an output subscriber. The subscriber will receive
  `{:port_data, id, chunk}` and `{:port_exit, id, exit_code, output}` messages.
  """
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(session, pid) do
    GenServer.call(session, {:subscribe, pid})
  end

  @doc """
  Send input data to the port's stdin.
  """
  @spec send_input(GenServer.server(), iodata()) :: :ok | {:error, :not_running}
  def send_input(session, data) do
    GenServer.call(session, {:send_input, data})
  end

  @doc """
  Gracefully stop the port (sends SIGTERM via Port.close).
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(session, timeout \\ 5_000) do
    GenServer.call(session, :stop, timeout)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Hard kill — same as stop but with immediate intent.
  """
  @spec kill(GenServer.server()) :: :ok
  def kill(session) do
    GenServer.cast(session, :kill)
  end

  @doc """
  Get the accumulated output and current state.
  """
  @spec get_result(GenServer.server()) :: {:ok, map()}
  def get_result(session) do
    GenServer.call(session, :get_result)
  end

  @doc """
  Get the session ID.
  """
  @spec get_id(GenServer.server()) :: String.t()
  def get_id(session) do
    GenServer.call(session, :get_id)
  end

  # For DynamicSupervisor child_spec — accepts the {command, opts} tuple
  def child_spec({command, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [command, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def child_spec({:direct, executable, args, display_command, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link_direct, [executable, args, display_command, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl GenServer
  def init({:direct, executable, args, display_command, opts}) do
    id = Identifiers.generate_id("port_")
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_output_bytes = Executor.normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes))
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    subscribers = subscriber_set(opts)
    port_opts = build_direct_port_opts(args, cwd, env)

    try do
      port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)
      timer_ref = timeout_timer(timeout)

      state = %__MODULE__{
        id: id,
        port: port,
        command: display_command,
        subscribers: subscribers,
        start_time: System.monotonic_time(:millisecond),
        timeout: timeout,
        timer_ref: timer_ref,
        max_output_bytes: max_output_bytes
      }

      emit_signal(:session_started, state)
      {:ok, state}
    catch
      :error, reason ->
        {:stop, {:port_open_failed, reason}}
    end
  end

  def init({command, opts}) do
    id = Identifiers.generate_id("port_")
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_output_bytes = Executor.normalize_max_output_bytes(Keyword.get(opts, :max_output_bytes))
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})

    subscribers = subscriber_set(opts)

    port_opts = build_port_opts(command, cwd, env)

    try do
      {executable, _args} = resolve_command(command)
      port = Port.open({:spawn_executable, to_charlist(executable)}, port_opts)

      timer_ref = timeout_timer(timeout)

      state = %__MODULE__{
        id: id,
        port: port,
        command: command,
        subscribers: subscribers,
        start_time: System.monotonic_time(:millisecond),
        timeout: timeout,
        timer_ref: timer_ref,
        max_output_bytes: max_output_bytes
      }

      emit_signal(:session_started, state)

      {:ok, state}
    catch
      :error, reason ->
        {:stop, {:port_open_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl GenServer
  def handle_call({:send_input, data}, _from, %{status: :running, port: port} = state) do
    Port.command(port, data)
    {:reply, :ok, state}
  end

  def handle_call({:send_input, _data}, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    new_state = do_close_port(state, :killed)
    {:stop, :normal, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:get_result, _from, state) do
    result = %{
      id: state.id,
      status: state.status,
      exit_code: state.exit_code,
      output: output_binary(state),
      output_bytes: state.output_bytes,
      max_output_bytes: state.max_output_bytes,
      output_truncated: state.output_truncated,
      output_limit_exceeded: state.output_limit_exceeded,
      timed_out: state.status == :timed_out,
      killed: state.status == :killed,
      duration_ms: duration_ms(state),
      command: state.command
    }

    {:reply, {:ok, result}, state}
  end

  @impl GenServer
  def handle_call(:get_id, _from, state) do
    {:reply, state.id, state}
  end

  @impl GenServer
  def handle_cast(:kill, state) do
    new_state = do_close_port(state, :killed)
    {:stop, :normal, new_state}
  end

  @impl GenServer
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    handle_output_chunk(state, chunk)
  end

  @impl GenServer
  def handle_info({port, {:exit_status, exit_code}}, %{port: port} = state) do
    cancel_timer(state.timer_ref)

    output = output_binary(state)

    # Notify subscribers
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:port_exit, state.id, exit_code, output})
    end)

    new_state = %{state | exit_code: exit_code, status: :completed, port: nil}
    emit_signal(:session_completed, new_state)

    # Stay alive briefly so callers can retrieve results via get_result/get_id,
    # then self-terminate. Without this, fast commands exit before callers
    # can query the GenServer.
    Process.send_after(self(), :self_terminate, 5_000)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.warning("PortSession timed out",
      session_id: state.id,
      command: truncate(state.command, 100),
      timeout_ms: state.timeout
    )

    output = output_binary(state)

    # Notify subscribers of timeout
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:port_exit, state.id, 137, output})
    end)

    new_state = do_close_port(state, :timed_out)
    emit_signal(:session_killed, new_state, :timeout)

    {:stop, :normal, new_state}
  end

  @impl GenServer
  def handle_info(:self_terminate, state) do
    {:stop, :normal, state}
  end

  # Handle port closed externally
  @impl GenServer
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    cancel_timer(state.timer_ref)
    {:stop, :normal, %{state | port: nil, status: :killed}}
  end

  # Ignore stale messages from already-closed ports
  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Ensure port is closed on any termination
    if state.port && Port.info(state.port) do
      Executor.kill_port(state.port)
    end

    :ok
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp handle_output_chunk(state, chunk) when is_binary(chunk) do
    room = state.max_output_bytes - state.output_bytes
    chunk_bytes = byte_size(chunk)
    retained_bytes = min(max(room, 0), chunk_bytes)

    retained =
      if retained_bytes > 0 do
        # Byte-oriented on purpose: process output is not guaranteed UTF-8.
        binary_part(chunk, 0, retained_bytes)
      else
        <<>>
      end

    if retained_bytes > 0 do
      Enum.each(state.subscribers, fn pid ->
        send(pid, {:port_data, state.id, retained})
      end)
    end

    state = %{
      state
      | output_acc:
          if(retained_bytes > 0, do: [retained | state.output_acc], else: state.output_acc),
        output_bytes: state.output_bytes + retained_bytes
    }

    if chunk_bytes > room do
      finish_output_limit(state)
    else
      {:noreply, state}
    end
  end

  defp finish_output_limit(state) do
    output = output_binary(state)

    new_state =
      state
      |> do_close_port(:killed)
      |> Map.put(:output_truncated, true)
      |> Map.put(:output_limit_exceeded, true)

    metadata = %{
      status: :killed,
      exit_code: 137,
      timed_out: false,
      killed: true,
      output_truncated: true,
      output_limit_exceeded: true,
      output_bytes: byte_size(output),
      max_output_bytes: state.max_output_bytes
    }

    Enum.each(state.subscribers, fn pid ->
      send(pid, {:port_output_limit, state.id, metadata})
      send(pid, {:port_exit, state.id, 137, output})
    end)

    emit_signal(:session_killed, new_state, :output_limit)
    Process.send_after(self(), :self_terminate, 5_000)
    {:noreply, new_state}
  end

  defp subscriber_set(opts) do
    case Keyword.get(opts, :stream_to) do
      nil -> MapSet.new()
      pid when is_pid(pid) -> MapSet.new([pid])
      pids when is_list(pids) -> MapSet.new(pids)
    end
  end

  defp timeout_timer(:infinity), do: nil
  defp timeout_timer(ms) when is_integer(ms), do: Process.send_after(self(), :timeout, ms)

  defp resolve_command(command) do
    {cmd, args} = Sandbox.parse_command(command)

    case Sandbox.resolve_executable(cmd) do
      {:ok, path} -> {path, args}
      {:error, :executable_not_found} -> raise "Executable not found: #{cmd}"
    end
  end

  defp build_port_opts(command, cwd, env) do
    {_cmd, args} = Sandbox.parse_command(command)

    build_direct_port_opts(args, cwd, env)
  end

  defp build_direct_port_opts(args, cwd, env) do
    opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: Enum.map(args, &to_charlist/1)
    ]

    opts =
      if cwd do
        [{:cd, to_charlist(cwd)} | opts]
      else
        opts
      end

    if is_map(env) && map_size(env) > 0 do
      env_list =
        Enum.map(env, fn
          {k, false} -> {to_charlist(k), false}
          {k, v} -> {to_charlist(k), to_charlist(v)}
        end)

      [{:env, env_list} | opts]
    else
      opts
    end
  end

  defp do_close_port(%{port: nil} = state, status) do
    cancel_timer(state.timer_ref)
    %{state | status: status}
  end

  defp do_close_port(%{port: port} = state, status) do
    cancel_timer(state.timer_ref)
    Executor.kill_port(port)
    %{state | port: nil, status: status, exit_code: state.exit_code || 137}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp output_binary(%{output_acc: acc}) do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp duration_ms(%{start_time: start}) do
    System.monotonic_time(:millisecond) - start
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end

  # Signal emission

  defp emit_signal(:session_started, state) do
    Signals.emit(:shell, :session_started, %{
      session_id: state.id,
      command: truncate(state.command, 200)
    })
  end

  defp emit_signal(:session_completed, state) do
    Signals.emit(:shell, :session_completed, %{
      session_id: state.id,
      exit_code: state.exit_code,
      duration_ms: duration_ms(state)
    })
  end

  defp emit_signal(:session_killed, state, reason) do
    Signals.emit(:shell, :session_killed, %{
      session_id: state.id,
      reason: reason,
      duration_ms: duration_ms(state)
    })
  end
end
