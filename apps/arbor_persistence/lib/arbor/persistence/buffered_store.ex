defmodule Arbor.Persistence.BufferedStore do
  @moduledoc """
  ETS-cached persistence with pluggable durable backend.

  A GenServer that keeps an ETS table as the authoritative read cache,
  with writes flowing through to a configurable backend implementing
  `Arbor.Contracts.Persistence.Store`.

  ## Design

  - **Reads**: Direct ETS lookup — bypass GenServer for maximum throughput
  - **Writes**: Serialized through GenServer, then ETS + backend
  - **Init**: Loads all data from backend into ETS (backend failure → start empty)
  - **Graceful degradation**: Backend failures are logged but don't crash

  ## Options

      {BufferedStore,
        name:         :my_store,              # required — GenServer + ETS table name
        backend:      QueryableStore.Postgres, # nil = ETS-only
        backend_opts: [repo: Repo],           # extra opts passed to backend calls
        write_mode:   :async,                 # :async | :sync
        collection:   "my_collection"}        # passed as name: to backend

  ## Usage

  Functions accept a `name:` option to target a specific instance:

      BufferedStore.put("key", record, name: :my_store)
      BufferedStore.get("key", name: :my_store)
  """

  use GenServer

  require Logger

  alias Arbor.Contracts.Persistence.{Filter, Record}

  @behaviour Arbor.Contracts.Persistence.Store

  # ===========================================================================
  # Client API — Store behaviour callbacks
  # ===========================================================================

  @impl true
  def put(key, value, opts \\ []) do
    store = store_name!(opts)
    GenServer.call(store, {:put, key, value})
  end

  @impl true
  def get(key, opts \\ []) do
    table = ets_table!(opts)

    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key, opts \\ []) do
    store = store_name!(opts)
    GenServer.call(store, {:delete, key})
  end

  @impl true
  def list(opts \\ []) do
    table = ets_table!(opts)

    keys =
      :ets.foldl(
        fn {key, _value}, acc -> [key | acc] end,
        [],
        table
      )

    {:ok, Enum.sort(keys)}
  end

  @impl true
  def exists?(key, opts \\ []) do
    table = ets_table!(opts)
    :ets.member(table, key)
  end

  @impl true
  def query(%Filter{} = filter, opts \\ []) do
    table = ets_table!(opts)

    records =
      :ets.foldl(
        fn {_key, value}, acc -> [value | acc] end,
        [],
        table
      )

    {:ok, Filter.apply(filter, records)}
  end

  @impl true
  def count(%Filter{} = filter, opts \\ []) do
    case query(filter, opts) do
      {:ok, results} -> {:ok, length(results)}
      error -> error
    end
  end

  @impl true
  def aggregate(%Filter{} = filter, field, operation, opts \\ [])
      when operation in [:sum, :avg, :min, :max] do
    case query(filter, opts) do
      {:ok, results} ->
        values =
          results
          |> Enum.map(&get_numeric_field(&1, field))
          |> Enum.reject(&is_nil/1)

        result =
          case {operation, values} do
            {_, []} -> nil
            {:sum, vals} -> Enum.sum(vals)
            {:avg, vals} -> Enum.sum(vals) / length(vals)
            {:min, vals} -> Enum.min(vals)
            {:max, vals} -> Enum.max(vals)
          end

        {:ok, result}

      error ->
        error
    end
  end

  # ===========================================================================
  # GenServer start
  # ===========================================================================

  @doc """
  Start a BufferedStore instance.

  ## Required Options

  - `:name` — atom name for both GenServer registration and ETS table

  ## Optional

  - `:backend` — module implementing Store behaviour (nil = ETS-only)
  - `:backend_opts` — extra opts merged into backend calls
  - `:write_mode` — `:async` (default) or `:sync`
  - `:collection` — string passed as `name:` to backend (defaults to stringified name)
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    backend = Keyword.get(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    write_mode = Keyword.get(opts, :write_mode, :async)
    collection = Keyword.get(opts, :collection, to_string(name))

    # Create ETS table — public for direct reads from any process
    table =
      :ets.new(name, [:named_table, :public, :set, {:read_concurrency, true}])

    state = %{
      table: table,
      backend: backend,
      backend_opts: backend_opts,
      write_mode: write_mode,
      collection: collection
    }

    load_from_backend(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(state.table, {key, value})
    backend_put(state, key, value)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    backend_delete(state, key)
    {:reply, :ok, state}
  end

  # ===========================================================================
  # Backend operations
  # ===========================================================================

  defp load_from_backend(%{backend: nil}), do: :ok

  defp load_from_backend(%{backend: backend, backend_opts: backend_opts, collection: collection, table: table}) do
    opts = Keyword.merge(backend_opts, name: collection)

    case backend.list(opts) do
      {:ok, keys} ->
        Enum.each(keys, fn key ->
          case backend.get(key, opts) do
            {:ok, value} ->
              :ets.insert(table, {key, value})

            {:error, reason} ->
              Logger.warning("BufferedStore: failed to load key #{key}: #{inspect(reason)}")
          end
        end)

      {:error, reason} ->
        Logger.warning("BufferedStore: failed to list keys from backend: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("BufferedStore: backend load failed: #{inspect(e)}")
  end

  defp backend_put(%{backend: nil}, _key, _value), do: :ok

  defp backend_put(%{backend: backend, backend_opts: backend_opts, collection: collection, write_mode: mode}, key, value) do
    opts = Keyword.merge(backend_opts, name: collection)

    case mode do
      :async ->
        Task.start(fn ->
          do_backend_put(backend, key, value, opts)
        end)

        :ok

      :sync ->
        do_backend_put(backend, key, value, opts)
    end
  end

  defp do_backend_put(backend, key, value, opts) do
    case backend.put(key, value, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("BufferedStore: backend put failed for #{key}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("BufferedStore: backend put error for #{key}: #{inspect(e)}")
      :ok
  end

  defp backend_delete(%{backend: nil}, _key), do: :ok

  defp backend_delete(%{backend: backend, backend_opts: backend_opts, collection: collection, write_mode: mode}, key) do
    opts = Keyword.merge(backend_opts, name: collection)

    case mode do
      :async ->
        Task.start(fn ->
          do_backend_delete(backend, key, opts)
        end)

        :ok

      :sync ->
        do_backend_delete(backend, key, opts)
    end
  end

  defp do_backend_delete(backend, key, opts) do
    case backend.delete(key, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("BufferedStore: backend delete failed for #{key}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("BufferedStore: backend delete error for #{key}: #{inspect(e)}")
      :ok
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp store_name!(opts) do
    Keyword.fetch!(opts, :name)
  end

  defp ets_table!(opts) do
    # The ETS table name is the same as the GenServer name
    Keyword.fetch!(opts, :name)
  end

  defp get_numeric_field(%Record{data: data}, field) do
    get_numeric_value(Map.get(data, field) || Map.get(data, to_string(field)))
  end

  defp get_numeric_field(record, field) when is_map(record) do
    get_numeric_value(Map.get(record, field) || Map.get(record, to_string(field)))
  end

  defp get_numeric_value(nil), do: nil
  defp get_numeric_value(v) when is_number(v), do: v

  defp get_numeric_value(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp get_numeric_value(_), do: nil
end
