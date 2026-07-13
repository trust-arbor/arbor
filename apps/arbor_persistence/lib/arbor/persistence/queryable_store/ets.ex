defmodule Arbor.Persistence.QueryableStore.ETS do
  @moduledoc """
  ETS-backed implementation of the QueryableStore behaviour.

  Uses a GenServer to own a named ETS table. Records are stored as
  `{key, %Record{} | {:tombstone, generation}}` tuples. Query operations use
  `Filter.matches?/2` to scan live records in-memory.

      children = [
        {Arbor.Persistence.QueryableStore.ETS, name: :my_queryable_store}
      ]

  Durability class: `:process_lifetime`. Linearizable CAS and generation+revision
  advancement are GenServer-serialized. Delete leaves a generation tombstone.
  """

  use GenServer

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Filter
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Store.Revision

  # --- Client API ---

  @impl true
  def put(key, record, opts) do
    if Revision.key_mismatch?(key, record) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:put, key, record})
    end
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    case :ets.lookup(table, key) do
      [{^key, entry}] ->
        case Revision.live_value(entry) do
          {:ok, record} -> {:ok, record}
          :not_found -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    keys =
      :ets.foldl(
        fn {k, v}, acc ->
          if match?({:ok, _}, Revision.live_value(v)), do: [k | acc], else: acc
        end,
        [],
        table
      )

    {:ok, keys}
  end

  @impl true
  def exists?(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    case :ets.lookup(table, key) do
      [{^key, entry}] -> match?({:ok, _}, Revision.live_value(entry))
      [] -> false
    end
  end

  @impl true
  def query(%Filter{} = filter, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    records =
      :ets.foldl(
        fn {_k, entry}, acc ->
          case Revision.live_value(entry) do
            {:ok, record} -> [record | acc]
            :not_found -> acc
          end
        end,
        [],
        table
      )
      |> then(&Filter.apply(filter, &1))

    {:ok, records}
  end

  @impl true
  def count(%Filter{} = filter, opts) do
    {:ok, records} = query(filter, opts)
    {:ok, length(records)}
  end

  @impl true
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

  @impl true
  def compare_and_swap(key, expected, replacement, opts) do
    if Revision.cas_operands_key_mismatch?(key, expected, replacement) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:compare_and_swap, key, expected, replacement})
    end
  end

  @impl true
  def durability_class(_opts), do: :process_lifetime

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
    current =
      case :ets.lookup(table, key) do
        [{^key, v}] -> v
        [] -> :absent
      end

    case Revision.apply_put(current, record) do
      {:ok, stored} ->
        :ets.insert(table, {key, stored})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, key}, _from, %{table: table} = state) do
    case :ets.lookup(table, key) do
      [{^key, entry}] ->
        case Revision.to_tombstone(entry) do
          :absent -> :ets.delete(table, key)
          tombstone -> :ets.insert(table, {key, tombstone})
        end

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call(:table, _from, %{table: table} = state) do
    {:reply, table, state}
  end

  def handle_call(
        {:compare_and_swap, key, :not_found, replacement},
        _from,
        %{table: table} = state
      ) do
    reply =
      case :ets.lookup(table, key) do
        [] ->
          stored = Revision.advance_cas_insert(replacement)
          true = :ets.insert_new(table, {key, stored})
          {:ok, stored}

        [{^key, {:tombstone, prev_gen}}] ->
          stored = Revision.advance_cas_insert_from_tombstone(prev_gen, replacement)
          :ets.insert(table, {key, stored})
          {:ok, stored}

        [{^key, _live}] ->
          {:error, :conflict}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:compare_and_swap, key, {:value, expected}, replacement},
        _from,
        %{table: table} = state
      ) do
    reply =
      case :ets.lookup(table, key) do
        [{^key, current}] ->
          if Revision.cas_matches?(current, expected) do
            case cas_store(current, replacement) do
              {:ok, stored} ->
                true = :ets.insert(table, {key, stored})
                {:ok, stored}

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:error, :conflict}
          end

        [] ->
          {:error, :conflict}
      end

    {:reply, reply, state}
  end

  defp cas_store(%Record{} = current, %Record{} = replacement) do
    Revision.advance_cas_update(current, replacement)
  end

  defp cas_store(_current, replacement) when not is_struct(replacement, Record) do
    {:ok, replacement}
  end

  defp cas_store(_current, _replacement), do: {:error, :conflict}
end
