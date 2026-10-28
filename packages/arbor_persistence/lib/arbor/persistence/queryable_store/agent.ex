defmodule Arbor.Persistence.QueryableStore.Agent do
  @moduledoc """
  Agent-backed implementation of the QueryableStore behaviour.

  Lightweight alternative to ETS for small datasets or testing.

      children = [
        {Arbor.Persistence.QueryableStore.Agent, name: :my_queryable_store}
      ]

  Durability class: `:process_lifetime`. Supports linearizable CAS via
  `Agent.get_and_update/2`. Advances structured `Record` `generation`+`revision`
  on every successful put and CAS; delete leaves a generation tombstone.
  """

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

      ContractProviders.agent_get_and_update(ContractProviders.owner_ref(name), fn map ->
        current = Map.get(map, key, :absent)

        case Revision.apply_put(current, record) do
          {:ok, stored} -> {:ok, Map.put(map, key, stored)}
          {:error, reason} -> {{:error, reason}, map}
        end
      end)
    end
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)

    case ContractProviders.agent_get(
           ContractProviders.owner_ref(name),
           &Map.get(&1, key, :absent)
         ) do
      :absent ->
        {:error, :not_found}

      entry ->
        case Revision.live_value(entry) do
          {:ok, record} -> {:ok, record}
          :not_found -> {:error, :not_found}
        end
    end
  end

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)

    ContractProviders.agent_update(ContractProviders.owner_ref(name), fn map ->
      case Map.fetch(map, key) do
        :error ->
          map

        {:ok, entry} ->
          case Revision.to_tombstone(entry) do
            :absent -> Map.delete(map, key)
            tombstone -> Map.put(map, key, tombstone)
          end
      end
    end)

    :ok
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, limit} <- Revision.authoritative_list_limit(opts) do
      case limit do
        nil ->
          keys =
            ContractProviders.agent_get(ContractProviders.owner_ref(name), fn map ->
              map
              |> Enum.filter(fn {_k, v} -> match?({:ok, _}, Revision.live_value(v)) end)
              |> Enum.map(fn {k, _} -> k end)
            end)

          {:ok, keys}

        limit ->
          ContractProviders.agent_get(ContractProviders.owner_ref(name), &bounded_keys(&1, limit))
      end
    end
  end

  @impl true
  def exists?(key, opts) do
    name = Keyword.fetch!(opts, :name)

    ContractProviders.agent_get(ContractProviders.owner_ref(name), fn map ->
      case Map.fetch(map, key) do
        {:ok, entry} -> match?({:ok, _}, Revision.live_value(entry))
        :error -> false
      end
    end)
  end

  @impl true
  def query(filter, opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, limit} <- Revision.authoritative_list_limit(opts) do
      ContractProviders.agent_get(ContractProviders.owner_ref(name), fn map ->
        if is_integer(limit) and map_size(map) > limit do
          {:error, :inventory_limit_exceeded}
        else
          records =
            map
            |> Map.values()
            |> Enum.flat_map(fn entry ->
              case Revision.live_value(entry) do
                {:ok, value} -> [value]
                :not_found -> []
              end
            end)
            |> then(&Filter.apply(filter, &1))

          {:ok, records}
        end
      end)
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

      ContractProviders.agent_get_and_update(ContractProviders.owner_ref(name), fn map ->
        do_cas(map, key, expected, replacement)
      end)
    end
  end

  @impl true
  def compare_and_delete(key, expected, opts) do
    if Revision.key_mismatch?(key, expected) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)

      ContractProviders.agent_get_and_update(ContractProviders.owner_ref(name), fn map ->
        case Map.fetch(map, key) do
          {:ok, current} ->
            if Revision.cas_matches?(current, expected) do
              case Revision.to_tombstone(current) do
                :absent -> {:ok, Map.delete(map, key)}
                tombstone -> {:ok, Map.put(map, key, tombstone)}
              end
            else
              {{:error, :conflict}, map}
            end

          :error ->
            {{:error, :conflict}, map}
        end
      end)
    end
  end

  @impl true
  def durability_class(_opts), do: :process_lifetime

  # --- Lifecycle ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.start_link(
      fn ->
        ContractProviders.pin!()
        %{}
      end,
      name: name
    )
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  defp do_cas(map, key, :not_found, replacement) do
    case Map.fetch(map, key) do
      :error ->
        stored = Revision.advance_cas_insert(replacement)
        {{:ok, stored}, Map.put(map, key, stored)}

      {:ok, {:tombstone, prev_gen}} ->
        stored = Revision.advance_cas_insert_from_tombstone(prev_gen, replacement)
        {{:ok, stored}, Map.put(map, key, stored)}

      {:ok, _live} ->
        {{:error, :conflict}, map}
    end
  end

  defp do_cas(map, key, {:value, expected}, replacement) do
    case Map.fetch(map, key) do
      :error ->
        {{:error, :conflict}, map}

      {:ok, current} ->
        if Revision.cas_matches?(current, expected) do
          case cas_store(current, replacement) do
            {:ok, stored} -> {{:ok, stored}, Map.put(map, key, stored)}
            {:error, reason} -> {{:error, reason}, map}
          end
        else
          {{:error, :conflict}, map}
        end
    end
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

  defp bounded_keys(map, limit) do
    map
    |> Enum.reduce_while({:ok, [], 0}, fn {key, entry}, {:ok, keys, visited} ->
      if visited >= limit do
        {:halt, {:error, :inventory_limit_exceeded}}
      else
        keys = if match?({:ok, _}, Revision.live_value(entry)), do: [key | keys], else: keys
        {:cont, {:ok, keys, visited + 1}}
      end
    end)
    |> case do
      {:ok, keys, _visited} -> {:ok, keys}
      {:error, _reason} = error -> error
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
    ContractProviders.with_agent(opts, fn ->
      super(key, value, opts)
    end)
  end

  @impl true
  def get(key, opts) do
    ContractProviders.with_agent(opts, fn ->
      super(key, opts)
    end)
  end

  @impl true
  def delete(key, opts) do
    ContractProviders.with_agent(opts, fn ->
      super(key, opts)
    end)
  end

  @impl true
  def list(opts) do
    ContractProviders.with_agent(opts, fn ->
      super(opts)
    end)
  end

  @impl true
  def exists?(key, opts) do
    ContractProviders.with_agent(opts, fn ->
      super(key, opts)
    end)
  end

  @impl true
  def compare_and_swap(key, expected, replacement, opts) do
    ContractProviders.with_agent(opts, fn ->
      super(key, expected, replacement, opts)
    end)
  end

  @impl true
  def compare_and_delete(key, expected, opts) do
    ContractProviders.with_agent(opts, fn ->
      super(key, expected, opts)
    end)
  end

  @impl true
  def query(filter, opts) do
    ContractProviders.with_agent(opts, fn ->
      if ContractProviders.filter?(filter),
        do: super(filter, opts),
        else: {:error, :invalid_filter}
    end)
  end

  @impl true
  def count(filter, opts) do
    ContractProviders.with_agent(opts, fn ->
      if ContractProviders.filter?(filter),
        do: super(filter, opts),
        else: {:error, :invalid_filter}
    end)
  end

  @impl true
  def aggregate(filter, field, operation, opts) do
    ContractProviders.with_agent(opts, fn ->
      if ContractProviders.filter?(filter),
        do: super(filter, field, operation, opts),
        else: {:error, :invalid_filter}
    end)
  end
end
