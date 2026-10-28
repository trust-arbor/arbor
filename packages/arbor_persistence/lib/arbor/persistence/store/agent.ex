defmodule Arbor.Persistence.Store.Agent do
  @moduledoc """
  Agent-backed implementation of the Store behaviour.

  Lightweight alternative to ETS for small datasets or testing.

      children = [
        {Arbor.Persistence.Store.Agent, name: :my_store}
      ]

  Durability class: `:process_lifetime`. Supports linearizable CAS and
  compare-and-delete via `Agent.get_and_update/2`.

  Structured `Record` values keep logical `Record.id` separate from the store
  key, require `Record.key == store key`, advance backend-owned
  `generation`+`revision`, and leave generation tombstones on delete so
  delete/reinsert cannot revive a stale CAS. Ordinary unversioned values use
  term-equality CAS only (not ABA-safe across delete/reinsert).
  """

  @behaviour Arbor.Persistence.Contracts.Store

  alias Arbor.Persistence.ContractProviders

  alias Arbor.Persistence.Revision

  # --- Client API (Store behaviour) ---

  @impl true
  def put(key, value, opts) do
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      name = Keyword.fetch!(opts, :name)

      ContractProviders.agent_get_and_update(ContractProviders.owner_ref(name), fn map ->
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

    case ContractProviders.agent_get(
           ContractProviders.owner_ref(name),
           &Map.get(&1, key, :absent)
         ) do
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

    keys =
      ContractProviders.agent_get(ContractProviders.owner_ref(name), fn map ->
        map
        |> Enum.filter(fn {_k, v} -> match?({:ok, _}, Revision.live_value(v)) end)
        |> Enum.map(fn {k, _} -> k end)
      end)

    {:ok, keys}
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
end
