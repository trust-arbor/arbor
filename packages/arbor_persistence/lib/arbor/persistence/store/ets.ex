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

  Durability class: `:process_lifetime`. CAS and compare-and-delete use
  GenServer serialization for structured Records (generation+revision +
  tombstones); ordinary unversioned CAS also uses `insert_new` /
  `select_replace` for exact term fencing (not ABA-safe across delete/reinsert).
  """

  use GenServer

  require Logger

  @behaviour Arbor.Persistence.Contracts.Store

  alias Arbor.Persistence.ContractProviders

  alias Arbor.Persistence.Revision

  @default_max_entries 100_000
  @warning_threshold 0.8

  # --- Client API (Store behaviour) ---

  @impl true
  def put(key, value, opts) do
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)
      ContractProviders.server_call(ContractProviders.owner_ref(name), {:put, key, value})
    end
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    table = ContractProviders.server_call(ContractProviders.owner_ref(name), :table)

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
    ContractProviders.server_call(ContractProviders.owner_ref(name), {:delete, key})
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :name)
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
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    # Safe: name is module atom from internal start_link opts, not user input
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"#{name}_ets"
    table = :ets.new(table_name, [:set, :protected, read_concurrency: true])
    ContractProviders.register_table(table)
    {:ok, %{table: table, max_entries: max_entries, warning_logged: false}}
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

  defp do_handle_call({:put, key, value}, _from, %{table: table, max_entries: max} = state) do
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

  defp do_handle_call(
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

  defp cas(table, key, {:value, expected}, replacement, _max) do
    if ContractProviders.record?(expected) do
      cas_record(table, key, expected, replacement)
    else
      if ContractProviders.record?(replacement) do
        {:error, :conflict}
      else
        # Keep exact term fencing for ordinary values, including non-Record structs.
        match_spec = [{{key, expected}, [], [{:const, {key, replacement}}]}]

        case :ets.select_replace(table, match_spec) do
          1 -> {:ok, replacement}
          0 -> {:error, :conflict}
        end
      end
    end
  end

  defp cas_record(table, key, expected, replacement) do
    case :ets.lookup(table, key) do
      [{^key, current}] ->
        if ContractProviders.record?(current) and Revision.cas_matches?(current, expected) do
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

  # Bind client validation to the resource owner that will perform the operation.
  defoverridable put: 3,
                 get: 2,
                 delete: 2,
                 list: 1,
                 exists?: 2,
                 compare_and_swap: 4,
                 compare_and_delete: 3

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
end
