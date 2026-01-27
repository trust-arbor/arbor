defmodule Arbor.Contracts.Libraries.Shell do
  @moduledoc """
  Public API contract for the Arbor.Shell library.

  Defines the facade interface for safe shell command execution.

  ## Quick Start

      {:ok, result} = Arbor.Shell.execute("ls -la", timeout: 5000)

  ## Sandbox Modes

  | Mode | Description |
  |------|-------------|
  | `:none` | No sandboxing |
  | `:basic` | Basic restrictions |
  | `:strict` | Strict sandbox |
  | `:container` | Container isolation |
  """

  @type execution_id :: String.t()
  @type exit_code :: non_neg_integer()
  @type sandbox_mode :: :none | :basic | :strict | :container

  @type result :: %{
          exit_code: exit_code(),
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          timed_out: boolean(),
          killed: boolean()
        }

  @type execution_status ::
          :pending
          | :running
          | :completed
          | :failed
          | :timed_out
          | :killed

  @type execute_opts :: [
          timeout: non_neg_integer(),
          cwd: String.t(),
          env: map(),
          sandbox: sandbox_mode(),
          stdin: String.t() | nil,
          security: map() | nil,
          stream_to: pid() | nil
        ]

  @doc """
  Execute a shell command synchronously with the given options.

  Applies sandbox rules, registers the execution, and returns the result.
  """
  @callback execute_shell_command_with_options(command :: String.t(), execute_opts()) ::
              {:ok, result()} | {:error, :timeout | :unauthorized | term()}

  @doc """
  Execute a shell command asynchronously with the given options.

  Returns an execution ID for tracking.
  """
  @callback execute_shell_command_async_with_options(command :: String.t(), execute_opts()) ::
              {:ok, execution_id()} | {:error, :unauthorized | term()}

  @doc """
  Get the execution status by its ID.
  """
  @callback get_execution_status_by_id(execution_id()) ::
              {:ok, execution_status()} | {:error, :not_found}

  @doc """
  Get the execution result by its ID.
  """
  @callback get_execution_result_by_id(execution_id(), opts :: keyword()) ::
              {:ok, result()}
              | {:pending, partial :: result()}
              | {:error, :not_found | :timeout}

  @doc """
  Kill a running execution by its ID.
  """
  @callback kill_running_execution_by_id(execution_id(), opts :: keyword()) ::
              :ok | {:error, :not_found | :not_running}

  @doc """
  List all active executions with optional filters.
  """
  @callback list_active_executions_with_filters(opts :: keyword()) :: {:ok, [map()]}

  @doc """
  Start the shell system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the shell system is healthy.
  """
  @callback healthy?() :: boolean()

  @optional_callbacks [
    get_execution_status_by_id: 1,
    get_execution_result_by_id: 2,
    kill_running_execution_by_id: 2,
    list_active_executions_with_filters: 1
  ]
end
