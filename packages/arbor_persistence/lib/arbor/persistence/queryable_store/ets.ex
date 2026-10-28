defmodule Arbor.Persistence.QueryableStore.ETS do
  @moduledoc """
  ETS-backed implementation of the QueryableStore behaviour.

  Uses a GenServer to own a named ETS table. Records are stored as
  `{key, %Record{} | {:tombstone, generation}}` tuples. Query operations use
  `Filter.matches?/2` to scan live records in-memory.

      children = [
        {Arbor.Persistence.QueryableStore.ETS, name: :my_queryable_store}
      ]

  Durability class: `:process_lifetime`. Linearizable CAS, generation+revision
  advancement, and bounded authoritative snapshots are GenServer-serialized.
  Delete leaves a generation tombstone.
  """

  use GenServer

  @behaviour Arbor.Persistence.Contracts.Store

  alias Arbor.Persistence.ContractProviders

  alias Arbor.Persistence.{Filter, Revision}

  # --- Client API ---

  @impl true
  def put(key, record, opts) do
    if Revision.key_mismatch?(key, record) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)
      ContractProviders.server_call(ContractProviders.owner_ref(name), {:put, key, record})
    end
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = ContractProviders.server_call(ContractProviders.owner_ref(name), :table)

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
    ContractProviders.server_call(ContractProviders.owner_ref(name), {:delete, key})
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, limit} <- Revision.authoritative_list_limit(opts) do
      case limit do
        nil ->
          table = ContractProviders.server_call(ContractProviders.owner_ref(name), :table)

          keys =
            :ets.foldl(
              fn {k, v}, acc ->
                if match?({:ok, _}, Revision.live_value(v)), do: [k | acc], else: acc
              end,
              [],
              table
            )

          {:ok, keys}

        limit ->
          ContractProviders.server_call(ContractProviders.owner_ref(name), {:bounded_list, limit})
      end
    end
  end

  @impl true
  def exists?(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = ContractProviders.server_call(ContractProviders.owner_ref(name), :table)

    case :ets.lookup(table, key) do
      [{^key, entry}] -> match?({:ok, _}, Revision.live_value(entry))
      [] -> false
    end
  end

  @impl true
  def query(filter, opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, limit} <- Revision.authoritative_list_limit(opts) do
      case limit do
        nil ->
          table = ContractProviders.server_call(ContractProviders.owner_ref(name), :table)
          query_table(table, filter, nil)

        limit ->
          ContractProviders.server_call(
            ContractProviders.owner_ref(name),
            {:authoritative_query, filter, limit}
          )
      end
    end
  end

  @impl true
  def count(filter, opts) do
    {:ok, records} = query(filter, opts)
    {:ok, length(records)}
  end

  @impl true
  def aggregate(filter, field, operation, opts)
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

      ContractProviders.server_call(
        ContractProviders.owner_ref(name),
        {:compare_and_swap, key, expected, replacement}
      )
    end
  end

  @impl true
  def compare_and_delete(key, expected, opts) do
    if Revision.key_mismatch?(key, expected) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)

      ContractProviders.server_call(
        ContractProviders.owner_ref(name),
        {:compare_and_delete, key, expected}
      )
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
    ContractProviders.pin!()
    name = Keyword.get(opts, :name, __MODULE__)
    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"#{name}_ets"
    table = :ets.new(table_name, [:set, :protected, read_concurrency: true])
    ContractProviders.register_table(table)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(message, from, state) do
    case validate_record_mutation(message) do
      :ok -> do_handle_call(message, from, state)
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp validate_record_mutation({operation, key, value})
       when operation in [
              :put,
              :acknowledged_put,
              :compare_and_delete,
              :acknowledged_compare_and_delete
            ] do
    if Revision.key_mismatch?(key, value), do: {:error, :key_mismatch}, else: :ok
  end

  defp validate_record_mutation({operation, key, expected, replacement})
       when operation in [:compare_and_swap, :acknowledged_compare_and_swap] do
    if Revision.cas_operands_key_mismatch?(key, expected, replacement),
      do: {:error, :key_mismatch},
      else: :ok
  end

  defp validate_record_mutation(_message), do: :ok

  defp do_handle_call(:contract_context, _from, state) do
    table =
      case Map.get(state, :table) do
        nil -> nil
        table when is_atom(table) -> :ets.whereis(table)
        table -> table
      end

    {:reply, %{contracts: ContractProviders.current!(), table: table}, state}
  end

  defp do_handle_call({:put, key, record}, _from, %{table: table} = state) do
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

  defp do_handle_call({:delete, key}, _from, %{table: table} = state) do
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

  defp do_handle_call(:table, _from, %{table: table} = state) do
    {:reply, table, state}
  end

  defp do_handle_call({:bounded_list, limit}, _from, %{table: table} = state) do
    match_spec = [{{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]

    reply =
      case :ets.select(table, match_spec, 256) do
        :"$end_of_table" -> {:ok, []}
        {entries, continuation} -> bounded_ets_keys(entries, continuation, limit, [], 0)
      end

    {:reply, reply, state}
  end

  defp do_handle_call({:authoritative_query, filter, limit}, _from, %{table: table} = state) do
    {:reply, safe_authoritative_query(table, filter, limit), state}
  end

  defp do_handle_call(
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

  defp do_handle_call(
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

  defp do_handle_call({:compare_and_delete, key, expected}, _from, %{table: table} = state) do
    reply =
      case :ets.lookup(table, key) do
        [{^key, current}] ->
          if Revision.cas_matches?(current, expected) do
            case Revision.to_tombstone(current) do
              :absent -> :ets.delete(table, key)
              tombstone -> :ets.insert(table, {key, tombstone})
            end

            :ok
          else
            {:error, :conflict}
          end

        _ ->
          {:error, :conflict}
      end

    {:reply, reply, state}
  end

  defp cas_store(current, replacement) do
    cond do
      ContractProviders.record?(current) and ContractProviders.record?(replacement) ->
        Revision.advance_cas_update(current, replacement)

      not ContractProviders.record?(replacement) ->
        {:ok, replacement}

      true ->
        {:error, :conflict}
    end
  end

  defp query_table(table, filter, limit) do
    if is_integer(limit) and :ets.info(table, :size) > limit do
      {:error, :inventory_limit_exceeded}
    else
      records =
        :ets.foldl(
          fn {_key, entry}, acc ->
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
  end

  defp safe_authoritative_query(table, filter, limit) do
    query_table(table, filter, limit)
  rescue
    _ -> {:error, :invalid_query}
  catch
    _, _ -> {:error, :invalid_query}
  end

  defp bounded_ets_keys(entries, continuation, limit, keys, visited) do
    with {:ok, keys, visited} <- bounded_ets_chunk(entries, limit, keys, visited) do
      case continuation do
        :"$end_of_table" ->
          {:ok, keys}

        continuation ->
          case :ets.select(continuation) do
            :"$end_of_table" ->
              {:ok, keys}

            {next, next_continuation} ->
              bounded_ets_keys(next, next_continuation, limit, keys, visited)
          end
      end
    end
  end

  defp bounded_ets_chunk([], _limit, keys, visited), do: {:ok, keys, visited}

  defp bounded_ets_chunk([{key, entry} | rest], limit, keys, visited) do
    if visited >= limit do
      {:error, :inventory_limit_exceeded}
    else
      keys = if match?({:ok, _}, Revision.live_value(entry)), do: [key | keys], else: keys
      bounded_ets_chunk(rest, limit, keys, visited + 1)
    end
  end

  # Bind client validation to the resource owner that will perform the operation.
  defoverridable put: 3,
                 get: 2,
                 delete: 2,
                 list: 1,
                 exists?: 2,
                 compare_and_swap: 4,
                 compare_and_delete: 3,
                 query: 2,
                 count: 2,
                 aggregate: 4

  @impl true
  def put(key, value, opts) do
    ContractProviders.with_store(opts, fn ->
      super(key, value, opts)
    end)
  end

  @impl true
  def get(key, opts) do
    ContractProviders.with_store(opts, fn ->
      super(key, opts)
    end)
  end

  @impl true
  def delete(key, opts) do
    ContractProviders.with_store(opts, fn ->
      super(key, opts)
    end)
  end

  @impl true
  def list(opts) do
    ContractProviders.with_store(opts, fn ->
      super(opts)
    end)
  end

  @impl true
  def exists?(key, opts) do
    ContractProviders.with_store(opts, fn ->
      super(key, opts)
    end)
  end

  @impl true
  def compare_and_swap(key, expected, replacement, opts) do
    ContractProviders.with_store(opts, fn ->
      super(key, expected, replacement, opts)
    end)
  end

  @impl true
  def compare_and_delete(key, expected, opts) do
    ContractProviders.with_store(opts, fn ->
      super(key, expected, opts)
    end)
  end

  @impl true
  def query(filter, opts) do
    ContractProviders.with_store(opts, fn ->
      if ContractProviders.filter?(filter),
        do: super(filter, opts),
        else: {:error, :invalid_filter}
    end)
  end

  @impl true
  def count(filter, opts) do
    ContractProviders.with_store(opts, fn ->
      if ContractProviders.filter?(filter),
        do: super(filter, opts),
        else: {:error, :invalid_filter}
    end)
  end

  @impl true
  def aggregate(filter, field, operation, opts) do
    ContractProviders.with_store(opts, fn ->
      if ContractProviders.filter?(filter),
        do: super(filter, field, operation, opts),
        else: {:error, :invalid_filter}
    end)
  end
end
