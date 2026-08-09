defmodule Arbor.Agent.Orchestration.TaskControlRecoveryPersistenceTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.Orchestration.{
    TaskControlLease,
    TaskControlRecoveryPersistence,
    TaskStore
  }

  alias Arbor.Contracts.Persistence.{Record, Store}
  alias Arbor.Persistence.BufferedStore

  defmodule StrictRecordStorage do
    @moduledoc false
    @table __MODULE__

    def reset! do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _table -> :ets.delete_all_objects(@table)
      end

      :ok
    end

    def put(collection, key, persisted) do
      true = :ets.insert(@table, {{collection, key}, persisted})
      :ok
    end

    def get(collection, key) do
      case :ets.lookup(@table, {collection, key}) do
        [{{^collection, ^key}, persisted}] -> {:ok, persisted}
        [] -> {:error, :not_found}
      end
    end

    def delete(collection, key) do
      true = :ets.delete(@table, {collection, key})
      :ok
    end

    def list(collection) do
      @table
      |> :ets.select([{{{collection, :"$1"}, :_}, [], [:"$1"]}])
      |> Enum.sort()
      |> then(&{:ok, &1})
    end
  end

  defmodule StrictRecordBackend do
    @moduledoc false
    @behaviour Store

    alias Arbor.Agent.Orchestration.TaskControlRecoveryPersistenceTest.StrictRecordStorage
    alias Arbor.Contracts.Persistence.Record

    @impl true
    def put(key, %Record{key: key} = record, opts) do
      StrictRecordStorage.put(Keyword.fetch!(opts, :name), key, record)
    end

    def put(_key, %Record{}, _opts), do: {:error, :key_mismatch}
    def put(_key, _raw, _opts), do: {:error, :record_required}

    @impl true
    def get(key, opts), do: StrictRecordStorage.get(Keyword.fetch!(opts, :name), key)

    @impl true
    def delete(key, opts), do: StrictRecordStorage.delete(Keyword.fetch!(opts, :name), key)

    @impl true
    def list(opts), do: StrictRecordStorage.list(Keyword.fetch!(opts, :name))

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule ProcessLifetimeRecordBackend do
    @moduledoc false
    @behaviour Store

    alias Arbor.Agent.Orchestration.TaskControlRecoveryPersistenceTest.StrictRecordBackend

    @impl true
    def put(key, value, opts), do: StrictRecordBackend.put(key, value, opts)

    @impl true
    def get(key, opts), do: StrictRecordBackend.get(key, opts)

    @impl true
    def delete(key, opts), do: StrictRecordBackend.delete(key, opts)

    @impl true
    def list(opts), do: StrictRecordBackend.list(opts)

    @impl true
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule HangRunner do
    @moduledoc false

    def run(_agent_id, _task, _opts) do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end

  setup do
    StrictRecordStorage.reset!()
    :ok
  end

  test "production persistence boundary regression: TaskStore writes a Record and reads a scalar marker" do
    recovery_store = start_record_store(StrictRecordBackend)
    store = start_task_store(recovery_store)

    assert wait_until(fn -> TaskStore.recovery_ready?(name: store) end)

    assert {:ok, %{task_id: task_id, reservation_token: token}} =
             TaskStore.reserve(name: store)

    assert :ok = TaskStore.commit_recovery_marker(task_id, token, name: store)

    assert {:ok, %Record{key: ^task_id, data: marker}} =
             StrictRecordStorage.get(recovery_store, task_id)

    assert marker["task_id"] == task_id
    assert {:ok, ^marker} = TaskControlLease.marker_normalize(marker)

    assert {:ok, ^marker} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_get(
               recovery_store,
               task_id
             )
  end

  test "authoritative read fails closed unless physical key, Record key, and marker task id agree" do
    recovery_store = start_record_store(StrictRecordBackend)
    physical_key = "task_expected"
    {:ok, marker} = TaskControlLease.marker_new(physical_key, DateTime.utc_now())
    :ok = StrictRecordStorage.put(recovery_store, physical_key, Record.new("task_other", marker))

    assert {:error, :invalid_task_control_recovery_record} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_get(
               recovery_store,
               physical_key
             )

    {:ok, mismatched_marker} = TaskControlLease.marker_new("task_other", DateTime.utc_now())

    :ok =
      StrictRecordStorage.put(
        recovery_store,
        physical_key,
        Record.new(physical_key, mismatched_marker)
      )

    assert {:error, :invalid_task_control_recovery_record} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_get(
               recovery_store,
               physical_key
             )
  end

  test "authoritative reads fail closed for malformed Records, raw values, and invalid inventories" do
    recovery_store = start_record_store(StrictRecordBackend)
    key = "task_malformed"
    {:ok, marker} = TaskControlLease.marker_new(key, DateTime.utc_now())
    malformed = Record.new(key, Map.put(marker, "unexpected", true))
    :ok = StrictRecordStorage.put(recovery_store, key, malformed)

    assert {:error, :invalid_task_control_recovery_record} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_get(recovery_store, key)

    :ok = StrictRecordStorage.put(recovery_store, key, marker)

    assert {:error, :invalid_task_control_recovery_record} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_get(recovery_store, key)

    :ok = StrictRecordStorage.put(recovery_store, "invalid/key", Record.new("invalid/key", %{}))

    assert {:error, :invalid_task_control_recovery_record} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_list(recovery_store)
  end

  test "authority attestation accepts node-restart authority and rejects process-lifetime authority" do
    durable_store = start_record_store(StrictRecordBackend)
    assert :ok = TaskControlRecoveryPersistence.attest_authority(durable_store)

    weak_store = start_record_store(ProcessLifetimeRecordBackend)

    assert {:error, :task_control_recovery_authority_not_durable} =
             TaskControlRecoveryPersistence.attest_authority(weak_store)

    assert {:error, :task_control_recovery_authority_not_durable} =
             TaskControlRecoveryPersistence.buffered_store_authoritative_list(weak_store)
  end

  test "security regression: production TaskStore never becomes ready with process-lifetime authority" do
    weak_store = start_record_store(ProcessLifetimeRecordBackend)

    task_store =
      start_task_store(weak_store,
        recovery_facade: production_recovery_facade(),
        recovery_force_ready: false
      )

    refute wait_until(fn -> TaskStore.recovery_ready?(name: task_store) end, 50)
    assert {:error, :recovery_not_ready} = TaskStore.reserve(name: task_store)
  end

  defp start_record_store(backend) do
    store_name = unique_name(:recovery_store)

    start_supervised!(
      {BufferedStore,
       name: store_name,
       backend: backend,
       write_mode: :sync,
       ack_mode: :backend,
       collection: store_name},
      id: store_name
    )

    store_name
  end

  defp start_task_store(recovery_store, opts \\ []) do
    supervisor_name = unique_name(:recovery_sup)
    store_name = unique_name(:task_store)
    supervisor = start_supervised!({Task.Supervisor, name: supervisor_name})
    recovery_facade = Keyword.get(opts, :recovery_facade, TaskControlRecoveryPersistence)
    recovery_force_ready = Keyword.get(opts, :recovery_force_ready, true)

    start_supervised!(
      {TaskStore,
       name: store_name,
       task_supervisor: supervisor,
       cleanup_supervisor: supervisor,
       recovery_force_ready: recovery_force_ready,
       task_control_recovery_facade: recovery_facade,
       task_control_recovery_store: recovery_store,
       recovery_retry_base_ms: 5,
       recovery_retry_max_ms: 10,
       runner: HangRunner},
      id: store_name
    )
  end

  # Lets this one causal regression run on the exact parent, where the
  # production boundary was Arbor.Persistence directly and the adapter module
  # did not yet exist. Candidate runs use the actual new production adapter.
  defp production_recovery_facade do
    candidate =
      Module.concat(Arbor.Agent.Orchestration, "TaskControlRecoveryPersistence")

    if Code.ensure_loaded?(candidate), do: candidate, else: Arbor.Persistence
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end
end
