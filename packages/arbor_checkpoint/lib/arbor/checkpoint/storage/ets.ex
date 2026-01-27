defmodule Arbor.Checkpoint.Storage.ETS do
  @moduledoc """
  ETS-based checkpoint storage backend.

  This backend stores checkpoints in an ETS table, making it suitable for:
  - Testing
  - Single-node applications
  - Development environments

  ## Usage

  Start the storage before use:

      {:ok, _pid} = Arbor.Checkpoint.Storage.ETS.start_link()

      # Or in a supervision tree
      children = [
        Arbor.Checkpoint.Storage.ETS
      ]

  Then use it as a storage backend:

      Arbor.Checkpoint.save("id", state, Arbor.Checkpoint.Storage.ETS)
      {:ok, state} = Arbor.Checkpoint.load("id", Arbor.Checkpoint.Storage.ETS)

  ## Options

  - `:name` - Name for the GenServer (default: `Arbor.Checkpoint.Storage.ETS`)
  - `:table_name` - Name for the ETS table (default: `:arbor_checkpoints`)

  ## Notes

  - Data is lost when the process terminates
  - Not suitable for distributed or persistent storage
  - For production, use a distributed storage backend
  """

  use GenServer

  @behaviour Arbor.Checkpoint.Storage

  @default_table :arbor_checkpoints
  @default_name __MODULE__

  # ============================================================================
  # Client API (Storage Behaviour)
  # ============================================================================

  @impl Arbor.Checkpoint.Storage
  def put(id, checkpoint) do
    GenServer.call(@default_name, {:put, id, checkpoint})
  end

  @impl Arbor.Checkpoint.Storage
  def get(id) do
    GenServer.call(@default_name, {:get, id})
  end

  @impl Arbor.Checkpoint.Storage
  def delete(id) do
    GenServer.call(@default_name, {:delete, id})
  end

  @impl Arbor.Checkpoint.Storage
  def list do
    GenServer.call(@default_name, :list)
  end

  @impl Arbor.Checkpoint.Storage
  def exists?(id) do
    GenServer.call(@default_name, {:exists?, id})
  end

  # ============================================================================
  # Additional Client API
  # ============================================================================

  @doc """
  Start the ETS storage GenServer.

  ## Options
  - `:name` - GenServer name (default: `#{@default_name}`)
  - `:table_name` - ETS table name (default: `:arbor_checkpoints`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stop the storage and clear all checkpoints.
  """
  def stop(name \\ @default_name) do
    GenServer.stop(name)
  end

  @doc """
  Clear all checkpoints from storage.
  """
  def clear(name \\ @default_name) do
    GenServer.call(name, :clear)
  end

  @doc """
  Get count of stored checkpoints.
  """
  def count(name \\ @default_name) do
    GenServer.call(name, :count)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table)
    table = :ets.new(table_name, [:set, :protected, :named_table])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:put, id, checkpoint}, _from, state) do
    true = :ets.insert(state.table, {id, checkpoint})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:get, id}, _from, state) do
    result =
      case :ets.lookup(state.table, id) do
        [{^id, checkpoint}] -> {:ok, checkpoint}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:delete, id}, _from, state) do
    true = :ets.delete(state.table, id)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    ids = :ets.foldl(fn {id, _}, acc -> [id | acc] end, [], state.table)
    {:reply, {:ok, ids}, state}
  end

  @impl GenServer
  def handle_call({:exists?, id}, _from, state) do
    exists = :ets.member(state.table, id)
    {:reply, exists, state}
  end

  @impl GenServer
  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:count, _from, state) do
    count = :ets.info(state.table, :size)
    {:reply, count, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end
end
