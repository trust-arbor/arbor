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

  ## Options

  - `:name` — required, the registered name for the GenServer
  - `:max_entries` — maximum number of entries (default: 100_000).
    When reached, new writes are rejected with `{:error, :store_full}`.
  """

  use GenServer

  require Logger

  @behaviour Arbor.Persistence.Store

  @default_max_entries 100_000
  @warning_threshold 0.8

  # --- Client API (Store behaviour) ---

  @impl Arbor.Persistence.Store
  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:put, key, value})
  end

  @impl Arbor.Persistence.Store
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl Arbor.Persistence.Store
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  @impl Arbor.Persistence.Store
  def list(opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)
    keys = :ets.foldl(fn {k, _v}, acc -> [k | acc] end, [], table)
    {:ok, keys}
  end

  @impl Arbor.Persistence.Store
  def exists?(key, opts) do
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
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"#{name}_ets"
    table = :ets.new(table_name, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table, max_entries: max_entries, warning_logged: false}}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, %{table: table, max_entries: max} = state) do
    size = :ets.info(table, :size)

    if size >= max and not :ets.member(table, key) do
      {:reply, {:error, :store_full}, state}
    else
      :ets.insert(table, {key, value})
      state = maybe_warn_capacity(state, size + 1)
      {:reply, :ok, state}
    end
  end

  def handle_call({:delete, key}, _from, %{table: table} = state) do
    :ets.delete(table, key)
    {:reply, :ok, state}
  end

  def handle_call(:table, _from, %{table: table} = state) do
    {:reply, table, state}
  end

  defp maybe_warn_capacity(%{warning_logged: true} = state, _size), do: state

  defp maybe_warn_capacity(%{max_entries: max} = state, size) do
    threshold = trunc(max * @warning_threshold)

    if size >= threshold do
      Logger.warning("ETS store approaching capacity",
        current_size: size,
        max_entries: max,
        utilization: "#{round(size / max * 100)}%"
      )

      %{state | warning_logged: true}
    else
      state
    end
  end
end
