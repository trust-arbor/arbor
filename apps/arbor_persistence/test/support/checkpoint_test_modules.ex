defmodule Arbor.Persistence.Checkpoint.Test.StatefulModule do
  @moduledoc """
  A test module that implements the Checkpoint behaviour.
  """
  @behaviour Arbor.Persistence.Checkpoint

  @impl Arbor.Persistence.Checkpoint
  def extract_checkpoint_data(state) do
    %{
      counter: state.counter,
      important_data: state.important_data
    }
  end

  @impl Arbor.Persistence.Checkpoint
  def restore_from_checkpoint(checkpoint_data, initial_state) do
    initial_state
    |> Map.put(:counter, checkpoint_data.counter)
    |> Map.put(:important_data, checkpoint_data.important_data)
    |> Map.put(:restored_at, System.system_time(:millisecond))
  end
end

defmodule Arbor.Persistence.Checkpoint.Test.NoCheckpointModule do
  @moduledoc """
  A test module that does NOT implement the Checkpoint behaviour.
  """

  def some_function, do: :ok
end

defmodule Arbor.Persistence.Checkpoint.Test.FailingRestoreModule do
  @moduledoc """
  A test module that raises during restore.
  """
  @behaviour Arbor.Persistence.Checkpoint

  @impl Arbor.Persistence.Checkpoint
  def extract_checkpoint_data(state), do: state

  @impl Arbor.Persistence.Checkpoint
  def restore_from_checkpoint(_checkpoint_data, _initial_state) do
    raise "Restore failed!"
  end
end

defmodule Arbor.Persistence.Checkpoint.Test.DelayedStorage do
  @moduledoc """
  A storage backend that simulates eventual consistency by
  returning :not_found for the first N attempts.
  """
  @behaviour Arbor.Contracts.Persistence.Store

  use Agent

  def start_link(opts \\ []) do
    failures_before_success = Keyword.get(opts, :failures, 2)
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn -> %{data: %{}, attempts: %{}, failures_before_success: failures_before_success} end,
      name: name
    )
  end

  def stop(name \\ __MODULE__), do: Agent.stop(name)

  @impl true
  def put(id, checkpoint, _opts \\ []) do
    Agent.update(__MODULE__, fn state ->
      %{state | data: Map.put(state.data, id, checkpoint), attempts: Map.put(state.attempts, id, 0)}
    end)

    :ok
  end

  @impl true
  def get(id, _opts \\ []) do
    Agent.get_and_update(__MODULE__, fn state ->
      attempts = Map.get(state.attempts, id, 0)
      new_attempts = attempts + 1
      new_state = %{state | attempts: Map.put(state.attempts, id, new_attempts)}
      result = fetch_with_delay(state.data, id, attempts, state.failures_before_success)
      {result, new_state}
    end)
  end

  defp fetch_with_delay(_data, _id, attempts, failures_before_success)
       when attempts < failures_before_success do
    {:error, :not_found}
  end

  defp fetch_with_delay(data, id, _attempts, _failures_before_success) do
    case Map.fetch(data, id) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def delete(id, _opts \\ []) do
    Agent.update(__MODULE__, fn state ->
      %{state | data: Map.delete(state.data, id)}
    end)

    :ok
  end

  @impl true
  def list(_opts \\ []) do
    ids = Agent.get(__MODULE__, fn state -> Map.keys(state.data) end)
    {:ok, ids}
  end

  def get_attempt_count(id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.attempts, id, 0) end)
  end
end

defmodule Arbor.Persistence.Checkpoint.Test.FailingStorage do
  @moduledoc """
  A storage backend that always fails.
  """
  @behaviour Arbor.Contracts.Persistence.Store

  @impl true
  def put(_id, _checkpoint, _opts \\ []), do: {:error, :storage_unavailable}

  @impl true
  def get(_id, _opts \\ []), do: {:error, :storage_unavailable}

  @impl true
  def delete(_id, _opts \\ []), do: {:error, :storage_unavailable}

  @impl true
  def list(_opts \\ []), do: {:error, :storage_unavailable}
end
