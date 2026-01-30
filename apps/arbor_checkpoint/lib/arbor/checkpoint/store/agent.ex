defmodule Arbor.Checkpoint.Store.Agent do
  @moduledoc """
  Agent-based checkpoint store backend.

  A simpler alternative to the ETS backend, using an Agent for state.
  Useful for testing scenarios where you want isolated storage per test.

  ## Usage

      {:ok, _pid} = Arbor.Checkpoint.Store.Agent.start_link()
      Arbor.Checkpoint.save("id", state, Arbor.Checkpoint.Store.Agent)
  """

  @behaviour Arbor.Checkpoint.Store

  @default_name __MODULE__

  # ============================================================================
  # Store Behaviour
  # ============================================================================

  @impl Arbor.Checkpoint.Store
  def put(id, checkpoint, _opts) do
    Agent.update(@default_name, &Map.put(&1, id, checkpoint))
    :ok
  end

  @impl Arbor.Checkpoint.Store
  def get(id, _opts) do
    case Agent.get(@default_name, &Map.fetch(&1, id)) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      :error -> {:error, :not_found}
    end
  end

  @impl Arbor.Checkpoint.Store
  def delete(id, _opts) do
    Agent.update(@default_name, &Map.delete(&1, id))
    :ok
  end

  @impl Arbor.Checkpoint.Store
  def list(_opts) do
    ids = Agent.get(@default_name, &Map.keys(&1))
    {:ok, ids}
  end

  @impl Arbor.Checkpoint.Store
  def exists?(id, _opts) do
    Agent.get(@default_name, &Map.has_key?(&1, id))
  end

  # ============================================================================
  # Additional Client API
  # ============================================================================

  @doc "Start the Agent store."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc "Stop the store."
  def stop(name \\ @default_name) do
    Agent.stop(name)
  end

  @doc "Clear all checkpoints."
  def clear(name \\ @default_name) do
    Agent.update(name, fn _ -> %{} end)
    :ok
  end

  @doc "Get count of stored checkpoints."
  def count(name \\ @default_name) do
    Agent.get(name, &map_size(&1))
  end
end
