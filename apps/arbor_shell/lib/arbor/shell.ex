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

  @behaviour Arbor.Contracts.Libraries.Shell

  alias Arbor.Shell.{ExecutionRegistry, Executor, Sandbox}
  alias Arbor.Signals

  @default_sandbox :basic

  # ===========================================================================
  # Public API — short, human-friendly names
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
end
