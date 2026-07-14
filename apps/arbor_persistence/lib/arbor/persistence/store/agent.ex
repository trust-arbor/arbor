defmodule Arbor.Persistence.Store.Agent do
  @moduledoc """
  Agent-backed implementation of the Store behaviour.

  Lightweight alternative to ETS for small datasets or testing.

      children = [
        {Arbor.Persistence.Store.Agent, name: :my_store}
      ]

  Durability class: `:process_lifetime`. Supports linearizable CAS via
  `Agent.get_and_update/2`.

  Structured `Record` values keep logical `Record.id` separate from the store
  key, require `Record.key == store key`, advance backend-owned
  `generation`+`revision`, and leave generation tombstones on delete so
  delete/reinsert cannot revive a stale CAS. Ordinary unversioned values use
  term-equality CAS only (not ABA-safe across delete/reinsert).
  """

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Store.Revision

  # --- Client API (Store behaviour) ---

  @impl true
  def put(key, value, opts) do
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)

      Agent.get_and_update(name, fn map ->
        current = Map.get(map, key, :absent)

        case Revision.apply_put(current, value) do
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
          {:ok, value} -> {:ok, value}
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
