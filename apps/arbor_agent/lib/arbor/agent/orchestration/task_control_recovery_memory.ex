defmodule Arbor.Agent.Orchestration.TaskControlRecoveryMemory do
  @moduledoc false
  # In-process acknowledged recovery marker store for tests and local unit
  # paths. Production uses Arbor.Persistence BufferedStore with ack_mode: :backend.
  # API mirrors the Persistence buffered_store_* surface used by TaskStore workers.

  @table :arbor_agent_task_control_recovery_memory

  def ensure! do
    case :ets.whereis(@table) do
      :undefined ->
        _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  def reset! do
    ensure!()
    :ets.delete_all_objects(@table)
    :ok
  end

  def buffered_store_acknowledged_put(_name, key, value) when is_binary(key) do
    ensure!()
    true = :ets.insert(@table, {key, value})
    {:ok, value}
  end

  def buffered_store_acknowledged_put(_name, _key, _value), do: {:error, :invalid_request}

  def buffered_store_acknowledged_delete(_name, key) when is_binary(key) do
    ensure!()

    case :ets.lookup(@table, key) do
      [{^key, _}] ->
        true = :ets.delete(@table, key)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  def buffered_store_acknowledged_delete(_name, _key), do: {:error, :invalid_request}

  def buffered_store_authoritative_get(_name, key) when is_binary(key) do
    ensure!()

    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  def buffered_store_authoritative_get(_name, _key), do: {:error, :invalid_request}

  def buffered_store_authoritative_list(_name) do
    ensure!()
    keys = :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
    {:ok, Enum.sort(keys)}
  end
end
