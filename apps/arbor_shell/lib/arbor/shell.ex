defmodule Arbor.Shell do
  @moduledoc """
  Safe shell command execution for the Arbor platform.

  Arbor.Shell provides a secure interface for executing shell commands with
  sandbox support, timeout handling, and observability through signals.

  ## Quick Start

      {:ok, result} = Arbor.Shell.execute("ls -la", timeout: 5000)
      IO.puts(result.stdout)

  ## Sandbox Modes

  | Mode | Description |
  |------|-------------|
  | `:none` | No restrictions - use with caution |
  | `:basic` | Blocks dangerous commands (rm -rf, sudo, etc.) |
  | `:strict` | Allowlist only - very limited commands |
  | `:container` | Container isolation (future) |

  ## Examples

      # Basic execution
      {:ok, result} = Arbor.Shell.execute("echo hello")

      # With sandbox
      {:ok, result} = Arbor.Shell.execute("ls", sandbox: :strict)

      # With working directory
      {:ok, result} = Arbor.Shell.execute("git status", cwd: "/path/to/repo")

      # With timeout
      {:ok, result} = Arbor.Shell.execute("sleep 10", timeout: 5000)
      result.timed_out  # => true

  ## Signals

  Shell emits signals for observability:

  - `{:shell, :command_started, %{command: ..., execution_id: ...}}`
  - `{:shell, :command_completed, %{execution_id: ..., exit_code: ...}}`
  - `{:shell, :command_failed, %{execution_id: ..., reason: ...}}`
  """

  @behaviour Arbor.Contracts.API.Shell

  alias Arbor.Shell.{ExecutionRegistry, Executor, PortSession, Sandbox}
  alias Arbor.Signals

  @default_sandbox :basic

  # ===========================================================================
  # Public API — Authorized versions (for agent callers)
  # ===========================================================================

  @doc """
  Execute a shell command with authorization check.

  Verifies the agent has the `arbor://shell/exec/{command_name}` capability
  before delegating to `execute/2`. Use this for agent-initiated commands
  where authorization should be enforced.

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `command` - The shell command to execute
  - `opts` - Options passed to `execute/2`

  ## Returns

  - `{:ok, result}` - Command executed successfully
  - `{:error, :unauthorized}` - Agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` - Requires escalation approval
  - `{:error, reason}` - Other execution errors

  ## Examples

      {:ok, result} = Arbor.Shell.authorize_and_execute("agent_001", "ls -la")
      {:error, :unauthorized} = Arbor.Shell.authorize_and_execute("agent_002", "rm -rf /")
  """
  @spec authorize_and_execute(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | :timeout | term()}
  def authorize_and_execute(agent_id, command, opts \\ []) do
    command_name = extract_command_name(command)
    resource = "arbor://shell/exec/#{command_name}"

    case Arbor.Security.authorize(agent_id, resource, :execute) do
      {:ok, :authorized} ->
        execute(command, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Execute an async shell command with authorization check.

  Same as `authorize_and_execute/3` but for async execution.
  """
  @spec authorize_and_execute_async(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
  def authorize_and_execute_async(agent_id, command, opts \\ []) do
    command_name = extract_command_name(command)
    resource = "arbor://shell/exec/#{command_name}"

    case Arbor.Security.authorize(agent_id, resource, :execute) do
      {:ok, :authorized} ->
        execute_async(command, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  # ===========================================================================
  # Public API — short, human-friendly names (unchecked, for system callers)
  # ===========================================================================

  @doc """
  Execute a shell command synchronously.

  ## Options

  - `:timeout` - Timeout in milliseconds (default: 30_000)
  - `:cwd` - Working directory
  - `:env` - Environment variables map
  - `:sandbox` - Sandbox mode: `:none`, `:basic`, `:strict` (default: `:basic`)
  - `:stdin` - Input to send to the process

  ## Examples

      {:ok, result} = Arbor.Shell.execute("echo hello")
      result.exit_code  # => 0
      result.stdout     # => "hello\\n"
  """
  @spec execute(String.t(), keyword()) ::
          {:ok, map()} | {:error, :timeout | :unauthorized | term()}
  def execute(command, opts \\ []),
    do: execute_shell_command_with_options(command, opts)

  @doc """
  Execute a shell command asynchronously.

  Returns an execution ID that can be used to check status and get results.

  ## Examples

      {:ok, exec_id} = Arbor.Shell.execute_async("long-running-command")
      {:ok, result} = Arbor.Shell.get_result(exec_id)
  """
  @spec execute_async(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :unauthorized | term()}
  def execute_async(command, opts \\ []),
    do: execute_shell_command_async_with_options(command, opts)

  @doc "Get the status of an async execution."
  @spec get_status(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_status(execution_id), do: get_execution_status_by_id(execution_id)

  @doc "Get the result of an async execution."
  @spec get_result(String.t(), keyword()) ::
          {:ok, map()} | {:pending, map()} | {:error, :not_found | :timeout}
  def get_result(execution_id, opts \\ []), do: get_execution_result_by_id(execution_id, opts)

  @doc "Kill a running async execution."
  @spec kill(String.t(), keyword()) :: :ok | {:error, :not_found | :not_running}
  def kill(execution_id, opts \\ []), do: kill_running_execution_by_id(execution_id, opts)

  @doc "List all executions."
  @spec list_executions(keyword()) :: {:ok, [map()]}
  def list_executions(opts \\ []), do: list_active_executions_with_filters(opts)

  # ===========================================================================
  # Public API — Streaming (PortSession-backed)
  # ===========================================================================

  @doc """
  Execute a command as a streaming session.

  Starts a supervised PortSession and returns the session ID.
  Output is streamed to the caller specified via `stream_to:` in opts.

  ## Options

  Same as `execute/2`, plus:
  - `:stream_to` - PID or list of PIDs to receive output messages (required)

  ## Subscriber Messages

  - `{:port_data, session_id, chunk}` — output chunk
  - `{:port_exit, session_id, exit_code, full_output}` — process exited

  ## Examples

      {:ok, session_id} = Arbor.Shell.execute_streaming("long-command", stream_to: self())

      receive do
        {:port_data, ^session_id, chunk} -> IO.write(chunk)
        {:port_exit, ^session_id, 0, output} -> IO.puts("Done")
      end
  """
  @spec execute_streaming(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute_streaming(command, opts \\ []) do
    execute_streaming_shell_command(command, opts)
  end

  @doc """
  Stop a streaming session by session ID.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    stop_streaming_session(session_id)
  end

  @doc """
  Execute a streaming command with authorization check.

  Same as `authorize_and_execute/3` but for streaming sessions.
  """
  @spec authorize_and_execute_streaming(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
  def authorize_and_execute_streaming(agent_id, command, opts \\ []) do
    command_name = extract_command_name(command)
    resource = "arbor://shell/exec/#{command_name}"

    case Arbor.Security.authorize(agent_id, resource, :execute) do
      {:ok, :authorized} ->
        execute_streaming(command, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  # ===========================================================================
  # Contract implementations — verbose, AI-readable names
  # ===========================================================================

  @impl true
  def execute_shell_command_with_options(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    with {:ok, :allowed} <- Sandbox.check(command, sandbox),
         {:ok, execution_id} <- register_execution(command, opts) do
      emit_started(command, execution_id, opts)

      case Executor.run(command, opts) do
        {:ok, result} ->
          complete_execution(execution_id, result)
          emit_completed(execution_id, result)
          {:ok, result}

        {:error, reason} ->
          fail_execution(execution_id, reason)
          emit_failed(execution_id, reason)
          {:error, reason}
      end
    else
      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  @impl true
  def execute_shell_command_async_with_options(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    with {:ok, :allowed} <- Sandbox.check(command, sandbox),
         {:ok, execution_id} <- register_execution(command, opts) do
      emit_started(command, execution_id, opts)

      Task.start(fn ->
        case Executor.run(command, opts) do
          {:ok, result} ->
            complete_execution(execution_id, result)
            emit_completed(execution_id, result)

          {:error, reason} ->
            fail_execution(execution_id, reason)
            emit_failed(execution_id, reason)
        end
      end)

      {:ok, execution_id}
    end
  end

  @impl true
  def get_execution_status_by_id(execution_id) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, execution} -> {:ok, execution.status}
      error -> error
    end
  end

  @impl true
  def get_execution_result_by_id(execution_id, opts) do
    wait = Keyword.get(opts, :wait, false)
    timeout = Keyword.get(opts, :timeout, 5000)

    if wait do
      wait_for_result(execution_id, timeout)
    else
      case ExecutionRegistry.get(execution_id) do
        {:ok, %{status: status, result: result}} when status in [:completed, :failed] ->
          {:ok, result}

        {:ok, execution} ->
          {:pending, %{status: execution.status}}

        error ->
          error
      end
    end
  end

  @impl true
  def kill_running_execution_by_id(execution_id, _opts) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, %{status: :running, port: port}} when not is_nil(port) ->
        Executor.kill_port(port)
        ExecutionRegistry.update_status(execution_id, :killed)
        :ok

      {:ok, %{status: status}} when status != :running ->
        {:error, :not_running}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_active_executions_with_filters(opts) do
    ExecutionRegistry.list(opts)
  end

  # Streaming contract implementations

  @impl true
  def execute_streaming_shell_command(command, opts) do
    sandbox = Keyword.get(opts, :sandbox, @default_sandbox)

    case Sandbox.check(command, sandbox) do
      {:ok, :allowed} ->
        session_opts =
          opts
          |> Keyword.take([:timeout, :cwd, :env, :stream_to])
          |> Keyword.put_new(:timeout, 30_000)

        case PortSession.start_supervised(command, session_opts) do
          {:ok, pid} ->
            session_id = PortSession.get_id(pid)

            # Register in the ExecutionRegistry for tracking
            {:ok, exec_id} = register_execution(command, opts)
            ExecutionRegistry.update_status(exec_id, :running, %{port_session_pid: pid})

            emit_started(command, session_id, opts)
            {:ok, session_id}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        emit_blocked(command, reason)
        {:error, reason}
    end
  end

  @impl true
  def stop_streaming_session(session_id) do
    case find_port_session(session_id) do
      {:ok, pid} ->
        PortSession.stop(pid)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  defp find_port_session(session_id) do
    # Search DynamicSupervisor children for the matching session
    children = DynamicSupervisor.which_children(Arbor.Shell.PortSessionSupervisor)

    Enum.find_value(children, :error, fn {_, pid, _, _} ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          if PortSession.get_id(pid) == session_id, do: {:ok, pid}
        catch
          :exit, _ -> nil
        end
      end
    end)
  end

  # System API

  @doc """
  Start the shell system.

  Normally started automatically by the application supervisor.
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Arbor.Shell.Application.start(:normal, opts)
  end

  @doc """
  Check if the shell system is healthy.
  """
  @impl true
  @spec healthy?() :: boolean()
  def healthy? do
    Process.whereis(ExecutionRegistry) != nil
  end

  @doc """
  Get sandbox configuration for a level.
  """
  @spec sandbox_config(atom()) :: map()
  def sandbox_config(level) do
    Sandbox.config(level)
  end

  # Private functions

  defp register_execution(command, opts) do
    ExecutionRegistry.register(command,
      sandbox: Keyword.get(opts, :sandbox, @default_sandbox),
      cwd: Keyword.get(opts, :cwd)
    )
  end

  defp complete_execution(execution_id, result) do
    status = if result.timed_out, do: :timed_out, else: :completed
    ExecutionRegistry.update_status(execution_id, status, %{result: result})
  end

  defp fail_execution(execution_id, reason) do
    ExecutionRegistry.update_status(execution_id, :failed, %{
      result: %{error: reason}
    })
  end

  defp wait_for_result(execution_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_result(execution_id, deadline)
  end

  defp do_wait_for_result(execution_id, deadline) do
    case ExecutionRegistry.get(execution_id) do
      {:ok, %{status: status, result: result}} when status in [:completed, :failed, :timed_out] ->
        {:ok, result}

      {:ok, _} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          do_wait_for_result(execution_id, deadline)
        else
          {:error, :timeout}
        end

      error ->
        error
    end
  end

  # Signal emission

  defp emit_started(command, execution_id, opts) do
    Signals.emit(:shell, :command_started, %{
      command: truncate_command(command),
      execution_id: execution_id,
      sandbox: Keyword.get(opts, :sandbox, @default_sandbox),
      cwd: Keyword.get(opts, :cwd)
    })
  end

  defp emit_completed(execution_id, result) do
    Signals.emit(:shell, :command_completed, %{
      execution_id: execution_id,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      timed_out: result.timed_out
    })
  end

  defp emit_failed(execution_id, reason) do
    Signals.emit(:shell, :command_failed, %{
      execution_id: execution_id,
      reason: inspect(reason)
    })
  end

  defp emit_blocked(command, reason) do
    Signals.emit(:shell, :command_blocked, %{
      command: truncate_command(command),
      reason: inspect(reason)
    })
  end

  defp truncate_command(command) do
    if String.length(command) > 200 do
      String.slice(command, 0, 197) <> "..."
    else
      command
    end
  end

  # Extract the command name (first word) from a shell command string
  defp extract_command_name(command) when is_binary(command) do
    command
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.replace(~r/^.*\//, "")  # Strip path prefix (e.g., /bin/ls -> ls)
  end
end
