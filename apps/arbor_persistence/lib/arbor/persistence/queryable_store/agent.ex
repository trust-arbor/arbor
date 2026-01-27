defmodule Arbor.Persistence.QueryableStore.Agent do
  @moduledoc """
  Agent-backed implementation of the QueryableStore behaviour.

  Lightweight alternative to ETS for small datasets or testing.

      children = [
        {Arbor.Persistence.QueryableStore.Agent, name: :my_queryable_store}
      ]
  """

  @behaviour Arbor.Persistence.QueryableStore

  alias Arbor.Persistence.Filter

  # --- Client API ---

  @impl Arbor.Persistence.QueryableStore
  def put(key, record, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.update(name, &Map.put(&1, key, record))
    :ok
  end

  @impl Arbor.Persistence.QueryableStore
  def get(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)

    case Agent.get(name, &Map.get(&1, key, :__not_found__)) do
      :__not_found__ -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl Arbor.Persistence.QueryableStore
  def delete(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.update(name, &Map.delete(&1, key))
    :ok
  end

  @impl Arbor.Persistence.QueryableStore
  def list(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    {:ok, Agent.get(name, &Map.keys/1)}
  end

  @impl Arbor.Persistence.QueryableStore
  def exists?(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.get(name, &Map.has_key?(&1, key))
  end

  @impl Arbor.Persistence.QueryableStore
  def query(%Filter{} = filter, opts \\ []) do
    name = Keyword.fetch!(opts, :name)

    records =
      Agent.get(name, &Map.values/1)
      |> then(&Filter.apply(filter, &1))

    {:ok, records}
  end

  @impl Arbor.Persistence.QueryableStore
  def count(%Filter{} = filter, opts \\ []) do
    {:ok, records} = query(filter, opts)
    {:ok, length(records)}
  end

  @impl Arbor.Persistence.QueryableStore
  def aggregate(%Filter{} = filter, field, operation, opts \\ [])
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
end
