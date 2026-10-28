defmodule Arbor.Persistence.PackageAdoptionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{Filter, Record}
  alias Arbor.Persistence
  alias Arbor.Persistence.Contracts
  alias Arbor.Persistence.Host.Application, as: HostApplication

  @moduletag :fast

  @apps [
    :arbor_persistence,
    :arbor_persistence_sql,
    :arbor_persistence_eventstore,
    :arbor_persistence_host
  ]
  @host_contracts %{
    record: Record,
    revision: Arbor.Contracts.Persistence.Revision,
    filter: Filter,
    append_operation: Arbor.Contracts.Persistence.AppendOperation
  }
  @standalone_contracts %{
    record: Contracts.Record,
    revision: Contracts.Revision,
    filter: Contracts.Filter,
    append_operation: Contracts.AppendOperation
  }
  @backends [
    {Arbor.Persistence.Store.Agent, :persistence_adoption_store_agent},
    {Arbor.Persistence.Store.ETS, :persistence_adoption_store_ets},
    {Arbor.Persistence.QueryableStore.Agent, :persistence_adoption_query_agent},
    {Arbor.Persistence.QueryableStore.ETS, :persistence_adoption_query_ets}
  ]

  setup do
    previous = Application.fetch_env(:arbor_persistence, :contract_modules)
    Application.put_env(:arbor_persistence, :contract_modules, @host_contracts)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_persistence, :contract_modules, value)
        :error -> Application.delete_env(:arbor_persistence, :contract_modules)
      end
    end)

    :ok
  end

  test "each persistence module has one composed application owner" do
    for app <- @apps do
      assert Application.load(app) in [:ok, {:error, {:already_loaded, app}}]
    end

    sets = Enum.map(@apps, &MapSet.new(Application.spec(&1, :modules)))
    total = Enum.sum(Enum.map(sets, &MapSet.size/1))
    combined = Enum.reduce(sets, MapSet.new(), &MapSet.union/2)
    assert total == MapSet.size(combined)

    for {app, modules} <- [
          {:arbor_persistence,
           [Arbor.Persistence.Core, Contracts.Record, Arbor.Persistence.BufferedStore]},
          {:arbor_persistence_sql,
           [
             Arbor.Persistence.SQL.Repo,
             Arbor.Persistence.EventLog.Ecto,
             Arbor.Persistence.SQLiteBusyTimeout
           ]},
          {:arbor_persistence_eventstore,
           [Arbor.Persistence.Ecto.EventLog, Arbor.Persistence.Ecto.EventStore]},
          {:arbor_persistence_host,
           [
             Persistence,
             Arbor.Persistence.Repo,
             HostApplication,
             Arbor.Persistence.Host.Config,
             Arbor.Persistence.DatabaseCase
           ]}
        ],
        module <- modules do
      assert module in Application.spec(app, :modules)
      assert Application.get_application(module) == app
    end
  end

  test "generic applications do not acquire host lifetimes or a second Repo" do
    refute match?({_, _}, Application.spec(:arbor_persistence, :mod))
    refute match?({_, _}, Application.spec(:arbor_persistence_sql, :mod))
    refute Process.whereis(Arbor.Persistence.SQL.Repo)
    assert Application.get_application(Arbor.Persistence.Repo) == :arbor_persistence_host

    for dependency <- Application.spec(:arbor_persistence, :applications) do
      refute String.starts_with?(Atom.to_string(dependency), "arbor_")
    end

    for adapter <- [:arbor_persistence_sql, :arbor_persistence_eventstore] do
      assert :arbor_persistence in Application.spec(adapter, :applications)
    end
  end

  test "security regression: host startup refuses missing or foreign contract bindings" do
    owner = Process.whereis(Arbor.Persistence.Supervisor)

    for invalid <- [nil, %{}, @standalone_contracts, Map.delete(@host_contracts, :revision)] do
      Application.put_env(:arbor_persistence, :contract_modules, invalid)

      assert {:error, :invalid_persistence_contract_configuration} =
               HostApplication.start(:normal, [])

      assert Process.whereis(Arbor.Persistence.Supervisor) == owner
    end

    Application.delete_env(:arbor_persistence, :contract_modules)

    assert {:error, :invalid_persistence_contract_configuration} =
             HostApplication.start(:normal, [])
  end

  for {backend, name} <- @backends do
    @backend backend
    @store name

    test "security regression: #{inspect(backend)} preserves host Record identity and ABA fences" do
      backend = @backend
      opts = [name: @store]
      refute GenServer.whereis(@store)
      start_supervised!({backend, opts})

      seed = Record.new("slot", %{value: 1}, id: "host-adoption:first")
      assert :ok = backend.put("slot", seed, opts)
      assert {:ok, %Record{} = first} = backend.get("slot", opts)
      assert {first.id, first.generation, first.revision} == {seed.id, 1, 1}

      replacement = Record.update(first, %{value: 2})

      assert {:ok, %Record{} = updated} =
               backend.compare_and_swap("slot", {:value, first}, replacement, opts)

      assert {updated.id, updated.generation, updated.revision} == {seed.id, 1, 2}
      assert {:ok, ^updated} = backend.get("slot", opts)
      assert :ok = backend.delete("slot", opts)
      assert {:error, :not_found} = backend.get("slot", opts)

      # Reuse the logical ID so only the incarnation fence distinguishes
      # this record from a stale generation-1 expectation.
      reincarnated = Record.new("slot", %{value: 3}, id: seed.id)
      assert :ok = backend.put("slot", reincarnated, opts)
      assert {:ok, %Record{} = current} = backend.get("slot", opts)
      assert {current.id, current.generation, current.revision} == {reincarnated.id, 2, 1}

      assert {:error, :conflict} =
               backend.compare_and_swap(
                 "slot",
                 {:value, first},
                 Record.update(current, %{value: 4}),
                 opts
               )

      assert {:error, :conflict} = backend.compare_and_delete("slot", first, opts)
      assert {:ok, ^current} = backend.get("slot", opts)
    end

    test "security regression: #{inspect(backend)} pins host contracts through config changes" do
      backend = @backend
      opts = [name: @store]
      refute GenServer.whereis(@store)
      start_supervised!({backend, opts})

      seed = Record.new("slot", %{value: 1}, id: "host-adoption:pinned")
      assert :ok = backend.put("slot", seed, opts)
      assert {:ok, %Record{} = first} = backend.get("slot", opts)
      Application.put_env(:arbor_persistence, :contract_modules, @standalone_contracts)

      assert {:error, :key_mismatch} =
               backend.put("slot", Record.new("foreign-key", %{value: 99}), opts)

      assert {:ok, %Record{} = current} = backend.get("slot", opts)
      assert current == first

      assert {:ok, %Record{} = updated} =
               backend.compare_and_swap(
                 "slot",
                 {:value, current},
                 Record.update(current, %{value: 2}),
                 opts
               )

      assert {updated.id, updated.generation, updated.revision} == {seed.id, 1, 2}
      assert {:ok, ^updated} = backend.get("slot", opts)
    end
  end
end
