defmodule Arbor.Persistence.ContractProvidersTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.{
    BufferedStore,
    ContractProviders,
    Core,
    EventLog,
    QueryableStore,
    Store
  }

  alias Arbor.Persistence.Contracts.{AppendOperation, Filter, Record}

  defmodule Lookalike do
    defstruct [:id, :key, :data, :metadata, :generation, :revision, :inserted_at, :updated_at]
  end

  defmodule BadStructProvider do
    def __struct__, do: %Lookalike{}
    defdelegate new(key), to: Record
    defdelegate new(key, data), to: Record
    defdelegate new(key, data, opts), to: Record
    defdelegate update(record, data), to: Record
    defdelegate update(record, data, opts), to: Record
  end

  defmodule SwitchingAppendOperation do
    def __struct__ do
      if Process.get({__MODULE__, :switch_configuration}) do
        Application.put_env(:arbor_persistence, :contract_modules, nil)
      end

      %{
        __struct__: __MODULE__,
        operation_id: nil,
        stream_id: nil,
        event_ids: [],
        fingerprints: %{}
      }
    end

    def new(attrs) do
      count_key = {__MODULE__, :construction_count}
      Process.put(count_key, Process.get(count_key, 0) + 1)

      with {:ok, operation} <- AppendOperation.new(attrs) do
        {:ok, Map.put(operation, :__struct__, __MODULE__)}
      end
    end
  end

  setup do
    previous = Application.fetch_env(:arbor_persistence, :contract_modules)
    Application.delete_env(:arbor_persistence, :contract_modules)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_persistence, :contract_modules, value)
        :error -> Application.delete_env(:arbor_persistence, :contract_modules)
      end
    end)

    :ok
  end

  test "complete owned defaults and exact struct identities" do
    assert {:ok, contracts} = ContractProviders.capture()
    assert contracts.record == Record
    assert contracts.filter == Filter
    assert ContractProviders.record?(Record.new("key"), contracts)
    assert ContractProviders.filter?(Filter.new(), contracts)
    refute ContractProviders.record?(%Lookalike{key: "key"}, contracts)
    refute ContractProviders.record?(%{key: "key", generation: 1, revision: 1}, contracts)
    refute ContractProviders.filter?(%{conditions: [], limit: 1}, contracts)
  end

  test "operation validation keeps one exact provider snapshot during configuration changes" do
    assert {:ok, defaults} = ContractProviders.capture()

    assert {:ok, operation} =
             SwitchingAppendOperation.new(
               operation_id: "append_provider_snapshot",
               stream_id: "provider_snapshot",
               event_ids: ["event_provider_snapshot"],
               fingerprints: %{"event_provider_snapshot" => String.duplicate("a", 64)}
             )

    Application.put_env(
      :arbor_persistence,
      :contract_modules,
      Map.put(defaults, :append_operation, SwitchingAppendOperation)
    )

    Process.put({SwitchingAppendOperation, :switch_configuration}, true)
    Process.put({SwitchingAppendOperation, :construction_count}, 0)
    assert {:ok, ^operation} = EventLog.validate_operation(operation)
    assert Process.get({SwitchingAppendOperation, :construction_count}) == 1
    assert {:error, :invalid_contract_provider} = ContractProviders.capture()

    assert {:ok, foreign_operation} = AppendOperation.new(Map.from_struct(operation))

    Application.put_env(
      :arbor_persistence,
      :contract_modules,
      Map.put(defaults, :append_operation, SwitchingAppendOperation)
    )

    assert {:error, :invalid_append_operation} = EventLog.validate_operation(foreign_operation)
    assert Process.get({SwitchingAppendOperation, :construction_count}) == 1
  end

  test "malformed or partial provider sets fail before a resource is created" do
    assert {:ok, defaults} = ContractProviders.capture()

    for invalid <- [
          nil,
          false,
          [],
          %{},
          Map.delete(defaults, :revision),
          Map.put(defaults, :record, nil),
          Map.put(defaults, :record, BadStructProvider)
        ] do
      Application.put_env(:arbor_persistence, :contract_modules, invalid)
      assert {:error, :invalid_contract_provider} = ContractProviders.capture()
      name = unique_name(:invalid_contract_store)
      assert {:error, _} = start_supervised({Store.ETS, name: name})
      assert Process.whereis(name) == nil
      assert :ets.whereis(name) == :undefined
    end
  end

  for backend <- [Store.Agent, Store.ETS, QueryableStore.Agent, QueryableStore.ETS] do
    test "#{inspect(backend)} retains generation and CAS identity across config changes" do
      backend = unquote(backend)
      name = unique_name(:pinned_contract_store)
      start_supervised!({backend, name: name})
      assert :ok = backend.put("key", Record.new("key", %{value: 1}), name: name)
      assert {:ok, %Record{generation: 1, revision: 1} = first} = backend.get("key", name: name)

      Application.put_env(:arbor_persistence, :contract_modules, nil)
      assert {:error, :invalid_contract_provider} = ContractProviders.capture()
      assert :ok = backend.put("key", Record.update(first, %{value: 2}), name: name)
      assert {:ok, %Record{generation: 1, revision: 2} = second} = backend.get("key", name: name)
      assert second.id == first.id

      assert {:error, :conflict} =
               backend.compare_and_swap(
                 "key",
                 {:value, first},
                 Record.update(first, %{stale: true}),
                 name: name
               )

      assert {:error, :key_mismatch} =
               backend.put("different", Record.update(second, %{wrong_key: true}), name: name)

      assert {:ok, ^second} = backend.get("key", name: name)
      assert {:error, :not_found} = backend.get("different", name: name)
      assert {:error, :invalid_contract_provider} = ContractProviders.capture()
    end
  end

  for {backend, field, expected} <- [
        {BufferedStore, :value, 2},
        {QueryableStore.Agent, :revision, 1},
        {QueryableStore.ETS, :revision, 1}
      ] do
    test "Core query admission uses the existing #{inspect(backend)} owner's Filter" do
      backend = unquote(backend)
      name = unique_name(:pinned_filter_store)
      start_supervised!({backend, name: name})
      assert :ok = Core.put(name, backend, "key", Record.new("key", %{value: 2}))
      assert {:ok, stored} = Core.get(name, backend, "key")
      filter = Filter.new()
      Application.put_env(:arbor_persistence, :contract_modules, nil)

      assert {:ok, [^stored]} = Core.query(name, backend, filter)
      assert {:ok, 1} = Core.count(name, backend, filter)

      assert {:ok, unquote(expected)} =
               Core.aggregate(name, backend, filter, unquote(field), :sum)

      assert {:error, :invalid_filter} = Core.query(name, backend, Map.from_struct(filter))
      assert {:error, :invalid_contract_provider} = ContractProviders.capture()
    end
  end

  test "BufferedStore pins its authoritative ephemeral record interpretation" do
    name = unique_name(:pinned_buffered_store)
    start_supervised!({BufferedStore, name: name})

    assert {:ok, %Record{} = first} =
             BufferedStore.acknowledged_put("key", Record.new("key", %{value: 1}), name: name)

    Application.put_env(:arbor_persistence, :contract_modules, nil)

    assert {:ok, %Record{revision: 2} = second} =
             BufferedStore.acknowledged_compare_and_swap(
               "key",
               {:value, first},
               Record.update(first, %{value: 2}),
               name: name
             )

    assert second.id == first.id
    assert second.generation == first.generation

    assert {:error, :conflict} =
             BufferedStore.acknowledged_compare_and_swap(
               "key",
               {:value, first},
               Record.update(first, %{stale: true}),
               name: name
             )

    assert {:ok, ^second} = BufferedStore.authoritative_get("key", name: name)
  end

  defp unique_name(prefix) do
    # A bounded number of test-owned names, never an external identifier.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
