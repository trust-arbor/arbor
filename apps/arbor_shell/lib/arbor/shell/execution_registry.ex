defmodule Arbor.Shell.ExecutionRegistry do
  @moduledoc """
  Registry for tracking shell command executions.

  Tracks both sync and async executions for observability and management.
  """

  use GenServer

  alias Arbor.Identifiers

  @type execution :: %{
          id: String.t(),
          command: String.t(),
          status: :pending | :running | :completed | :failed | :timed_out | :killed,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          result: map() | nil,
          pid: pid() | nil,
          port: port() | nil
        }

  # Client API

  @doc """
  Start the execution registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new execution.
  """
  @spec register(String.t(), keyword()) :: {:ok, String.t()}
  def register(command, opts \\ []) do
    GenServer.call(__MODULE__, {:register, command, opts})
  end

  @doc """
  Update execution status.
  """
  @spec update_status(String.t(), atom(), map()) :: :ok | {:error, :not_found}
  def update_status(execution_id, status, updates \\ %{}) do
    GenServer.call(__MODULE__, {:update_status, execution_id, status, updates})
  end

  @doc """
  Get execution by ID.
  """
  @spec get(String.t()) :: {:ok, execution()} | {:error, :not_found}
  def get(execution_id) do
    GenServer.call(__MODULE__, {:get, execution_id})
  end

  @doc """
  List executions with optional filters.
  """
  @spec list(keyword()) :: {:ok, [execution()]}
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc """
  Remove completed executions older than TTL.
  """
  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ 3600) do
    GenServer.cast(__MODULE__, {:cleanup, ttl_seconds})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup
    schedule_cleanup()
    {:ok, %{executions: %{}}}
  end

  @impl true
  def handle_call({:register, command, opts}, _from, state) do
    id = Identifiers.generate_id("exec_")

    execution = %{
      id: id,
      command: command,
      status: :pending,
      started_at: DateTime.utc_now(),
      completed_at: nil,
      result: nil,
      pid: Keyword.get(opts, :pid),
      port: Keyword.get(opts, :port),
      sandbox: Keyword.get(opts, :sandbox, :basic),
      cwd: Keyword.get(opts, :cwd)
    }

    state = put_in(state, [:executions, id], execution)
    {:reply, {:ok, id}, state}
  end

  @impl true
  def handle_call({:update_status, id, status, updates}, _from, state) do
    case Map.get(state.executions, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      execution ->
        completed_at =
          if status in [:completed, :failed, :timed_out, :killed] do
            DateTime.utc_now()
          else
            execution.completed_at
          end

        execution =
          execution
          |> Map.put(:status, status)
          |> Map.put(:completed_at, completed_at)
          |> Map.merge(updates)

        state = put_in(state, [:executions, id], execution)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:get, id}, _from, state) do
    case Map.get(state.executions, id) do
      nil -> {:reply, {:error, :not_found}, state}
      execution -> {:reply, {:ok, execution}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    status_filter = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 100)

    executions =
      state.executions
      |> Map.values()
      |> maybe_filter_status(status_filter)
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, {:ok, executions}, state}
  end

  @impl true
  def handle_cast({:cleanup, ttl_seconds}, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_seconds, :second)

    executions =
      state.executions
      |> Enum.reject(fn {_id, exec} ->
        exec.status in [:completed, :failed, :timed_out, :killed] and
          exec.completed_at != nil and
          DateTime.compare(exec.completed_at, cutoff) == :lt
      end)
      |> Map.new()

    {:noreply, %{state | executions: executions}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp maybe_filter_status(executions, nil), do: executions

  defp maybe_filter_status(executions, status) do
    Enum.filter(executions, &(&1.status == status))
  end

  defp schedule_cleanup do
    # Cleanup every 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end
end
