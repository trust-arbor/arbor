defmodule Arbor.Persistence.Store.Agent do
  @moduledoc """
  Agent-backed implementation of the Store behaviour.

  Lightweight alternative to ETS for small datasets or testing.

      children = [
        {Arbor.Persistence.Store.Agent, name: :my_store}
      ]
  """

  @behaviour Arbor.Persistence.Store

  # --- Client API (Store behaviour) ---

  @impl Arbor.Persistence.Store
  def put(key, value, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.update(name, &Map.put(&1, key, value))
    :ok
  end

  @impl Arbor.Persistence.Store
  def get(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)

    case Agent.get(name, &Map.get(&1, key, :__not_found__)) do
      :__not_found__ -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl Arbor.Persistence.Store
  def delete(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.update(name, &Map.delete(&1, key))
    :ok
  end

  @impl Arbor.Persistence.Store
  def list(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    {:ok, Agent.get(name, &Map.keys/1)}
  end

  @impl Arbor.Persistence.Store
  def exists?(key, opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.get(name, &Map.has_key?(&1, key))
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
