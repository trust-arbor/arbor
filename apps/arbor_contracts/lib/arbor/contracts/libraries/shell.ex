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
  Execute a shell command synchronously.
  """
  @callback execute(command :: String.t(), execute_opts()) ::
              {:ok, result()} | {:error, :timeout | :unauthorized | term()}

  @doc """
  Execute a shell command asynchronously.
  """
  @callback execute_async(command :: String.t(), execute_opts()) ::
              {:ok, execution_id()} | {:error, :unauthorized | term()}

  @doc """
  Get the status of an async execution.
  """
  @callback get_status(execution_id()) ::
              {:ok, execution_status()} | {:error, :not_found}

  @doc """
  Get the result of an async execution.
  """
  @callback get_result(execution_id(), opts :: keyword()) ::
              {:ok, result()}
              | {:pending, partial :: result()}
              | {:error, :not_found | :timeout}

  @doc """
  Kill a running async execution.
  """
  @callback kill(execution_id(), opts :: keyword()) ::
              :ok | {:error, :not_found | :not_running}

  @doc """
  List all active executions.
  """
  @callback list_executions(opts :: keyword()) :: {:ok, [map()]}

  @doc """
  Start the shell system.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Check if the shell system is healthy.
  """
  @callback healthy?() :: boolean()

  @optional_callbacks [
    get_status: 1,
    get_result: 2,
    kill: 2,
    list_executions: 1
  ]
end
