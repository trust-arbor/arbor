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

  Durability class: `:process_lifetime`. CAS uses GenServer serialization for
  structured Records (generation+revision + tombstones) and `insert_new` /
  `select_replace` for ordinary unversioned term CAS (not ABA-safe across
  delete/reinsert).
  """

  use GenServer

  require Logger

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Store.Revision

  @default_max_entries 100_000
  @warning_threshold 0.8

  # --- Client API (Store behaviour) ---

  @impl true
  def put(key, value, opts) do
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)
      GenServer.call(name, {:put, key, value})
    end
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = GenServer.call(name, :table)

    case :ets.lookup(table, key) do
      [{^key, entry}] ->
        case Revision.live_value(entry) do
          {:ok, value} -> {:ok, value}
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
    member? = :ets.member(table, key)

    if size >= max and not member? do
      {:reply, {:error, :store_full}, state}
    else
      current =
        case :ets.lookup(table, key) do
          [{^key, v}] -> v
          [] -> :absent
        end

      case Revision.apply_put(current, value) do
        {:ok, stored} ->
          :ets.insert(table, {key, stored})
          state = maybe_warn_capacity(state, if(member?, do: size, else: size + 1))
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
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
        {:compare_and_swap, key, expected, replacement},
        _from,
        %{table: table, max_entries: max} = state
      ) do
    case cas(table, key, expected, replacement, max) do
      {:ok, _stored} = ok ->
        state = maybe_warn_capacity(state, :ets.info(table, :size))
        {:reply, ok, state}

      error ->
        {:reply, error, state}
    end
  end

  defp cas(table, key, :not_found, replacement, max) do
    case :ets.lookup(table, key) do
      [] ->
        size = :ets.info(table, :size)

        if size >= max do
          {:error, :store_full}
        else
          stored = Revision.advance_cas_insert(replacement)

          if :ets.insert_new(table, {key, stored}) do
            {:ok, stored}
          else
            {:error, :conflict}
          end
        end

      [{^key, {:tombstone, prev_gen}}] ->
        stored = Revision.advance_cas_insert_from_tombstone(prev_gen, replacement)
        :ets.insert(table, {key, stored})
        {:ok, stored}

      [{^key, _live}] ->
        {:error, :conflict}
    end
  end

  defp cas(table, key, {:value, %Record{} = expected}, replacement, _max) do
    case :ets.lookup(table, key) do
      [{^key, %Record{} = current}] ->
        if Revision.cas_matches?(current, expected) do
          case Revision.advance_cas_update(current, replacement) do
            {:ok, stored} ->
              :ets.insert(table, {key, stored})
              {:ok, stored}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :conflict}
        end

      _ ->
        {:error, :conflict}
    end
  end

  defp cas(table, key, {:value, expected}, replacement, _max)
       when not is_struct(expected, Record) and not is_struct(replacement, Record) do
    # Exact term match via select_replace — no read-then-write race.
    # Body must be `[{:const, new_tuple}]` (not nested 1-tuples).
    # Ordinary unversioned CAS is not ABA-safe across delete/reinsert.
    match_spec = [{{key, expected}, [], [{:const, {key, replacement}}]}]

    case :ets.select_replace(table, match_spec) do
      1 -> {:ok, replacement}
      0 -> {:error, :conflict}
    end
  end

  defp cas(_table, _key, {:value, _expected}, _replacement, _max), do: {:error, :conflict}

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
