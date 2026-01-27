defmodule Arbor.Checkpoint.Test.StatefulModule do
  @moduledoc """
  A test module that implements the Checkpoint behaviour.
  """
  @behaviour Arbor.Checkpoint

  @impl Arbor.Checkpoint
  def extract_checkpoint_data(state) do
    %{
      counter: state.counter,
      important_data: state.important_data
    }
  end

  @impl Arbor.Checkpoint
  def restore_from_checkpoint(checkpoint_data, initial_state) do
    initial_state
    |> Map.put(:counter, checkpoint_data.counter)
    |> Map.put(:important_data, checkpoint_data.important_data)
    |> Map.put(:restored_at, System.system_time(:millisecond))
  end
end

defmodule Arbor.Checkpoint.Test.NoCheckpointModule do
  @moduledoc """
  A test module that does NOT implement the Checkpoint behaviour.
  """

  def some_function, do: :ok
end

defmodule Arbor.Checkpoint.Test.FailingRestoreModule do
  @moduledoc """
  A test module that raises during restore.
  """
  @behaviour Arbor.Checkpoint

  @impl Arbor.Checkpoint
  def extract_checkpoint_data(state), do: state

  @impl Arbor.Checkpoint
  def restore_from_checkpoint(_checkpoint_data, _initial_state) do
    raise "Restore failed!"
  end
end

defmodule Arbor.Checkpoint.Test.DelayedStorage do
  @moduledoc """
  A storage backend that simulates eventual consistency by
  returning :not_found for the first N attempts.
  """
  @behaviour Arbor.Checkpoint.Storage

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

  @impl Arbor.Checkpoint.Storage
  def put(id, checkpoint) do
    Agent.update(__MODULE__, fn state ->
      %{state | data: Map.put(state.data, id, checkpoint), attempts: Map.put(state.attempts, id, 0)}
    end)

    :ok
  end

  @impl Arbor.Checkpoint.Storage
  def get(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      attempts = Map.get(state.attempts, id, 0)
      new_attempts = attempts + 1
      new_state = %{state | attempts: Map.put(state.attempts, id, new_attempts)}

      if attempts < state.failures_before_success do
        {{:error, :not_found}, new_state}
      else
        case Map.fetch(state.data, id) do
          {:ok, checkpoint} -> {{:ok, checkpoint}, new_state}
          :error -> {{:error, :not_found}, new_state}
        end
      end
    end)
  end

  @impl Arbor.Checkpoint.Storage
  def delete(id) do
    Agent.update(__MODULE__, fn state ->
      %{state | data: Map.delete(state.data, id)}
    end)

    :ok
  end

  @impl Arbor.Checkpoint.Storage
  def list do
    ids = Agent.get(__MODULE__, fn state -> Map.keys(state.data) end)
    {:ok, ids}
  end

  def get_attempt_count(id) do
    Agent.get(__MODULE__, fn state -> Map.get(state.attempts, id, 0) end)
  end
end

defmodule Arbor.Checkpoint.Test.FailingStorage do
  @moduledoc """
  A storage backend that always fails.
  """
  @behaviour Arbor.Checkpoint.Storage

  @impl Arbor.Checkpoint.Storage
  def put(_id, _checkpoint), do: {:error, :storage_unavailable}

  @impl Arbor.Checkpoint.Storage
  def get(_id), do: {:error, :storage_unavailable}

  @impl Arbor.Checkpoint.Storage
  def delete(_id), do: {:error, :storage_unavailable}

  @impl Arbor.Checkpoint.Storage
  def list, do: {:error, :storage_unavailable}
end
