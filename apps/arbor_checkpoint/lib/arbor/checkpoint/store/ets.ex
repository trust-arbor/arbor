defmodule Arbor.Checkpoint.Store.ETS do
  @moduledoc """
  ETS-based checkpoint store backend.

  Stores checkpoints in an ETS table. Suitable for testing,
  single-node applications, and development environments.

  ## Usage

      {:ok, _pid} = Arbor.Checkpoint.Store.ETS.start_link()
      Arbor.Checkpoint.save("id", state, Arbor.Checkpoint.Store.ETS)
      {:ok, state} = Arbor.Checkpoint.load("id", Arbor.Checkpoint.Store.ETS)

  ## Options

  - `:name` - Name for the GenServer (default: `Arbor.Checkpoint.Store.ETS`)
  - `:table_name` - Name for the ETS table (default: `:arbor_checkpoints`)
  """

  use GenServer

  @behaviour Arbor.Checkpoint.Store

  @default_table :arbor_checkpoints
  @default_name __MODULE__

  # ============================================================================
  # Store Behaviour
  # ============================================================================

  @impl Arbor.Checkpoint.Store
  def put(id, checkpoint, _opts) do
    GenServer.call(@default_name, {:put, id, checkpoint})
  end

  @impl Arbor.Checkpoint.Store
  def get(id, _opts) do
    GenServer.call(@default_name, {:get, id})
  end

  @impl Arbor.Checkpoint.Store
  def delete(id, _opts) do
    GenServer.call(@default_name, {:delete, id})
  end

  @impl Arbor.Checkpoint.Store
  def list(_opts) do
    GenServer.call(@default_name, :list)
  end

  @impl Arbor.Checkpoint.Store
  def exists?(id, _opts) do
    GenServer.call(@default_name, {:exists?, id})
  end

  # ============================================================================
  # Additional Client API
  # ============================================================================

  @doc "Start the ETS store GenServer."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Stop the store and clear all checkpoints."
  def stop(name \\ @default_name) do
    GenServer.stop(name)
  end

  @doc "Clear all checkpoints from storage."
  def clear(name \\ @default_name) do
    GenServer.call(name, :clear)
  end

  @doc "Get count of stored checkpoints."
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
