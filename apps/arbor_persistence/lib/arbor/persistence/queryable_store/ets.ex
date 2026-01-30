defmodule Arbor.Persistence.QueryableStore.ETS do
  @moduledoc """
  ETS-backed implementation of the QueryableStore behaviour.

  Uses a GenServer to own a named ETS table. Records are stored as
  `{key, %Record{}}` tuples. Query operations use `Filter.matches?/2`
  to scan the table in-memory.

      children = [
        {Arbor.Persistence.QueryableStore.ETS, name: :my_queryable_store}
      ]
  """

  use GenServer

  @behaviour Arbor.Persistence.QueryableStore

  alias Arbor.Persistence.Filter

  # --- Client API ---

  @impl Arbor.Persistence.QueryableStore
  def put(key, record, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:put, key, record})
  end

  @impl Arbor.Persistence.QueryableStore
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    case :ets.lookup(table, key) do
      [{^key, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  @impl Arbor.Persistence.QueryableStore
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  @impl Arbor.Persistence.QueryableStore
  def list(opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)
    keys = :ets.foldl(fn {k, _v}, acc -> [k | acc] end, [], table)
    {:ok, keys}
  end

  @impl Arbor.Persistence.QueryableStore
  def exists?(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)
    :ets.member(table, key)
  end

  @impl Arbor.Persistence.QueryableStore
  def query(%Filter{} = filter, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    records =
      :ets.foldl(fn {_k, record}, acc -> [record | acc] end, [], table)
      |> then(&Filter.apply(filter, &1))

    {:ok, records}
  end

  @impl Arbor.Persistence.QueryableStore
  def count(%Filter{} = filter, opts) do
    {:ok, records} = query(filter, opts)
    {:ok, length(records)}
  end

  @impl Arbor.Persistence.QueryableStore
  def aggregate(%Filter{} = filter, field, operation, opts)
      when operation in [:sum, :avg, :min, :max] do
    {:ok, records} = query(filter, opts)

    values =
      records
      |> Enum.map(&Map.get(&1, field))
      |> Enum.filter(&is_number/1)

    result =
      case {operation, values} do
        {_, []} -> nil
        {:sum, vs} -> Enum.sum(vs)
        {:avg, vs} -> Enum.sum(vs) / length(vs)
        {:min, vs} -> Enum.min(vs)
        {:max, vs} -> Enum.max(vs)
      end

    {:ok, result}
  end

  # --- GenServer ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"#{name}_ets"
    table = :ets.new(table_name, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:put, key, record}, _from, %{table: table} = state) do
    :ets.insert(table, {key, record})
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
