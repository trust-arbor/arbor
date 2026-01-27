defmodule Arbor.Persistence.Store.ETS do
  @moduledoc """
  ETS-backed implementation of the Store behaviour.

  Uses a GenServer to own a named ETS table of type `:set`.
  Start under your supervision tree:

      children = [
        {Arbor.Persistence.Store.ETS, name: :my_store}
      ]

  Then pass the name in opts:

      Arbor.Persistence.Store.ETS.put("key", value, name: :my_store)
  """

  use GenServer

  @behaviour Arbor.Persistence.Store

  # --- Client API (Store behaviour) ---

  @impl Arbor.Persistence.Store
  def put(key, value, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:put, key, value})
  end

  @impl Arbor.Persistence.Store
  def get(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl Arbor.Persistence.Store
  def delete(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  @impl Arbor.Persistence.Store
  def list(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)
    keys = :ets.foldl(fn {k, _v}, acc -> [k | acc] end, [], table)
    {:ok, keys}
  end

  @impl Arbor.Persistence.Store
  def exists?(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)
    :ets.member(table, key)
  end

  # --- GenServer ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table_name = :"#{name}_ets"
    table = :ets.new(table_name, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, %{table: table} = state) do
    :ets.insert(table, {key, value})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, %{table: table} = state) do
    :ets.delete(table, key)
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, %{table: table} = state) do
    {:reply, table, state}
  end
end
