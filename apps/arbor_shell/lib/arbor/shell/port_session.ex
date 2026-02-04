defmodule Arbor.Shell.PortSession do
  @moduledoc """
  A supervised GenServer managing a long-running Port process with streaming output.

  PortSession provides BEAM-supervised execution of shell commands with:
  - Real-time output streaming to subscribers
  - Proper process cleanup (Port.close sends SIGTERM to child process group)
  - Timeout handling with automatic termination
  - Signal emission for observability

  ## Messages sent to subscribers

  - `{:port_data, session_id, chunk}` — output chunk received
  - `{:port_exit, session_id, exit_code, full_output}` — process exited

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
    status: :running,
    subscribers: MapSet.new(),
    output_acc: []
  ]

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start a PortSession under the PortSessionSupervisor.

  ## Options

  - `:stream_to` - PID or list of PIDs to receive output messages
  - `:timeout` - Timeout in ms (default: 30_000, use `:infinity` for no timeout)
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

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl GenServer
  def init({command, opts}) do
    id = Identifiers.generate_id("port_")
    timeout = Keyword.get(opts, :timeout, 30_000)
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})

    # Build initial subscriber set
    subscribers =
      case Keyword.get(opts, :stream_to) do
        nil -> MapSet.new()
        pid when is_pid(pid) -> MapSet.new([pid])
        pids when is_list(pids) -> MapSet.new(pids)
      end

    port_opts = build_port_opts(cwd, env)

    try do
      port = Port.open({:spawn, command}, port_opts)

      # Set up timeout timer
      timer_ref =
        case timeout do
          :infinity -> nil
          ms when is_integer(ms) -> Process.send_after(self(), :timeout, ms)
        end

      state = %__MODULE__{
        id: id,
        port: port,
        command: command,
        subscribers: subscribers,
        start_time: System.monotonic_time(:millisecond),
        timeout: timeout,
        timer_ref: timer_ref
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
    # Forward to subscribers
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:port_data, state.id, chunk})
    end)

    # Accumulate output
    {:noreply, %{state | output_acc: [chunk | state.output_acc]}}
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
      catch_port_close(state.port)
    end

    :ok
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp build_port_opts(cwd, env) do
    opts = [:binary, :exit_status, :use_stdio, :stderr_to_stdout]

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
    catch_port_close(port)
    %{state | port: nil, status: status, exit_code: state.exit_code || 137}
  end

  defp catch_port_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
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
