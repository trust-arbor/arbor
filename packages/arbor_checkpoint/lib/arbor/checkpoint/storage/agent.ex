defmodule Arbor.Checkpoint.Storage.Agent do
  @moduledoc """
  Agent-based checkpoint storage backend.

  A simpler alternative to the ETS backend, using an Agent for state.
  This is useful for testing scenarios where you want isolated storage
  per test.

  ## Usage

      # Start with default name
      {:ok, _pid} = Arbor.Checkpoint.Storage.Agent.start_link()

      # Or with custom name for test isolation
      {:ok, pid} = Arbor.Checkpoint.Storage.Agent.start_link(name: :my_test_storage)

      # Use the module-based API (uses default name)
      Arbor.Checkpoint.save("id", state, Arbor.Checkpoint.Storage.Agent)

      # Or create a wrapper for custom-named storage
      defmodule MyTestStorage do
        def put(id, cp), do: Agent.update(:my_test_storage, &Map.put(&1, id, cp)) && :ok
        def get(id), do: Agent.get(:my_test_storage, &Map.fetch(&1, id)) |> to_result()
        def delete(id), do: Agent.update(:my_test_storage, &Map.delete(&1, id)) && :ok
        def list(), do: {:ok, Agent.get(:my_test_storage, &Map.keys(&1))}
        defp to_result({:ok, v}), do: {:ok, v}
        defp to_result(:error), do: {:error, :not_found}
      end
  """

  @behaviour Arbor.Checkpoint.Storage

  @default_name __MODULE__

  # ============================================================================
  # Client API (Storage Behaviour)
  # ============================================================================

  @impl Arbor.Checkpoint.Storage
  def put(id, checkpoint) do
    Agent.update(@default_name, &Map.put(&1, id, checkpoint))
    :ok
  end

  @impl Arbor.Checkpoint.Storage
  def get(id) do
    case Agent.get(@default_name, &Map.fetch(&1, id)) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      :error -> {:error, :not_found}
    end
  end

  @impl Arbor.Checkpoint.Storage
  def delete(id) do
    Agent.update(@default_name, &Map.delete(&1, id))
    :ok
  end

  @impl Arbor.Checkpoint.Storage
  def list do
    ids = Agent.get(@default_name, &Map.keys(&1))
    {:ok, ids}
  end

  @impl Arbor.Checkpoint.Storage
  def exists?(id) do
    Agent.get(@default_name, &Map.has_key?(&1, id))
  end

  # ============================================================================
  # Additional Client API
  # ============================================================================

  @doc """
  Start the Agent storage.

  ## Options
  - `:name` - Agent name (default: `#{@default_name}`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Stop the storage.
  """
  def stop(name \\ @default_name) do
    Agent.stop(name)
  end

  @doc """
  Clear all checkpoints.
  """
  def clear(name \\ @default_name) do
    Agent.update(name, fn _ -> %{} end)
    :ok
  end

  @doc """
  Get count of stored checkpoints.
  """
  def count(name \\ @default_name) do
    Agent.get(name, &map_size(&1))
  end
end
