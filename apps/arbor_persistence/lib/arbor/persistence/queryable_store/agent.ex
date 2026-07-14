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

      Agent.get_and_update(name, fn map ->
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

    case Agent.get(name, &Map.get(&1, key, :absent)) do
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

    Agent.update(name, fn map ->
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

    keys =
      Agent.get(name, fn map ->
        map
        |> Enum.filter(fn {_k, v} -> match?({:ok, _}, Revision.live_value(v)) end)
        |> Enum.map(fn {k, _} -> k end)
      end)

    {:ok, keys}
  end

  @impl true
  def exists?(key, opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.get(name, fn map ->
      case Map.fetch(map, key) do
        {:ok, entry} -> match?({:ok, _}, Revision.live_value(entry))
        :error -> false
      end
    end)
  end

  @impl true
  def query(%Filter{} = filter, opts) do
    name = Keyword.fetch!(opts, :name)

    records =
      Agent.get(name, fn map ->
        map
        |> Map.values()
        |> Enum.flat_map(fn entry ->
          case Revision.live_value(entry) do
            {:ok, value} -> [value]
            :not_found -> []
          end
        end)
      end)
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

      Agent.get_and_update(name, fn map ->
        do_cas(map, key, expected, replacement)
      end)
    end
  end

  @impl true
  def durability_class(_opts), do: :process_lifetime

  # --- Lifecycle ---

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
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

  defp cas_store(%Record{} = current, %Record{} = replacement) do
    Revision.advance_cas_update(current, replacement)
  end

  defp cas_store(_current, replacement) when not is_struct(replacement, Record) do
    {:ok, replacement}
  end

  defp cas_store(_current, _replacement), do: {:error, :conflict}
end
