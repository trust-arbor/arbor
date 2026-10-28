defmodule Arbor.Persistence.PackageSQLAdoptionSecurityRegressionTest do
  @moduledoc """
  Host contract adoption against a test-owned SQLite Repo. Run this exclusive
  fixture with `--include isolated_repo`; it never uses the configured host Repo
  or historical host migrations.
  """
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{AppendOperation, Filter, Record}
  alias Arbor.Persistence
  alias Arbor.Persistence.{BufferedStore, Contracts, EventLog}
  alias Arbor.Persistence.EventLog.Ecto, as: SQLEventLog
  alias Arbor.Persistence.QueryableStore.Postgres, as: SQLStore

  @moduletag :isolated_repo
  @moduletag :integration
  @moduletag :sqlite

  @host_contracts %{
    record: Record,
    revision: Arbor.Contracts.Persistence.Revision,
    filter: Filter,
    append_operation: AppendOperation
  }
  @standalone_contracts %{
    record: Contracts.Record,
    revision: Contracts.Revision,
    filter: Contracts.Filter,
    append_operation: Contracts.AppendOperation
  }
  @migration_versions [
    20_260_128_000_001,
    20_260_130_000_001,
    20_260_210_000_001,
    20_260_625_000_001,
    20_260_711_000_001,
    20_260_711_000_002,
    20_260_711_000_003,
    20_260_712_000_004,
    20_260_712_000_005,
    20_260_713_000_001,
    20_260_713_000_002
  ]

  defmodule IsolatedRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence_sql,
      adapter: Ecto.Adapters.SQLite3
  end

  setup do
    previous = Application.fetch_env(:arbor_persistence, :contract_modules)
    Application.put_env(:arbor_persistence, :contract_modules, @host_contracts)

    directory =
      Path.join(
        System.tmp_dir!(),
        "arbor-package-sql-adoption-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(directory)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_persistence, :contract_modules, value)
        :error -> Application.delete_env(:arbor_persistence, :contract_modules)
      end

      File.rm_rf!(directory)
    end)

    start_supervised!(
      {IsolatedRepo,
       database: Path.join(directory, "adoption.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       journal_mode: :wal,
       busy_timeout: 5_000,
       custom_pragmas: [recursive_triggers: true]}
    )

    migrations = Application.app_dir(:arbor_persistence_sql, "priv/repo/migrations")

    assert @migration_versions ==
             Ecto.Migrator.run(IsolatedRepo, migrations, :up, all: true, log: false)

    :ok
  end

  test "security regression: direct SQL and host facade retain exact host Record and Filter identities" do
    seed = Record.new("slot", %{"state" => "initial"}, id: "host-sql:logical-id")
    opts = [name: :host_sql_identity, repo: IsolatedRepo]
    filter = Filter.new() |> Filter.where(:state, :eq, "initial")
    assert %Filter{} = filter

    assert :ok = SQLStore.put("slot", seed, opts)
    assert {:ok, %Record{} = stored} = SQLStore.get("slot", opts)
    assert {stored.id, stored.generation, stored.revision} == {seed.id, 1, 1}

    assert {:ok, ^stored} =
             Persistence.get(:host_sql_identity, SQLStore, "slot", repo: IsolatedRepo)

    assert {:ok, [^stored]} = SQLStore.query(filter, opts)

    assert {:ok, [^stored]} =
             Persistence.query(:host_sql_identity, SQLStore, filter, repo: IsolatedRepo)

    assert {:error, :invalid_record} =
             SQLStore.put("slot", Contracts.Record.new("slot", %{}), opts)

    assert {:error, :invalid_filter} = SQLStore.query(Contracts.Filter.new(), opts)
    assert {:ok, ^stored} = SQLStore.get("slot", opts)
  end

  test "security regression: host SQL CAS receipts preserve logical identity, timestamps and generation fences" do
    seed = Record.new("slot", %{"value" => 1}, id: "host-sql:first-incarnation")
    opts = [name: :host_sql_cas, repo: IsolatedRepo]

    assert {:ok, %Record{} = first} =
             Persistence.compare_and_swap(:host_sql_cas, SQLStore, "slot", :not_found, seed,
               repo: IsolatedRepo
             )

    assert {first.id, first.generation, first.revision} == {seed.id, 1, 1}
    assert %DateTime{} = first.inserted_at
    assert %DateTime{} = first.updated_at
    assert {:ok, ^first} = SQLStore.get("slot", opts)

    replacement = Record.new("slot", %{"value" => 2}, id: "host-sql:ignored-update-id")

    assert {:ok, %Record{} = updated} =
             SQLStore.compare_and_swap("slot", {:value, first}, replacement, opts)

    assert {updated.id, updated.generation, updated.revision} == {seed.id, 1, 2}
    assert updated.inserted_at == first.inserted_at
    assert {:ok, ^updated} = Persistence.get(:host_sql_cas, SQLStore, "slot", repo: IsolatedRepo)
    assert :ok = Persistence.delete(:host_sql_cas, SQLStore, "slot", repo: IsolatedRepo)
    assert {:error, :not_found} = SQLStore.get("slot", opts)

    reincarnated = Record.new("slot", %{"value" => 3}, id: "host-sql:second-incarnation")

    assert {:ok, %Record{} = current} =
             SQLStore.compare_and_swap("slot", :not_found, reincarnated, opts)

    assert {current.id, current.generation, current.revision} == {reincarnated.id, 2, 1}
    assert {:ok, ^current} = SQLStore.get("slot", opts)

    assert {:error, :conflict} =
             Persistence.compare_and_swap(
               :host_sql_cas,
               SQLStore,
               "slot",
               {:value, first},
               replacement,
               repo: IsolatedRepo
             )

    assert {:error, :conflict} = SQLStore.compare_and_delete("slot", updated, opts)
    assert {:ok, ^current} = SQLStore.get("slot", opts)
  end

  test "security regression: SQL and host reconciliation require the exact host AppendOperation" do
    for source <- [:direct, :facade] do
      stream = "host-sql-append-#{source}"
      event = Persistence.new_event(stream, "host.adoption", %{"source" => to_string(source)})
      assert {:ok, %AppendOperation{} = operation} = EventLog.build_operation(stream, [event])
      assert {:ok, ^operation} = AppendOperation.new(Map.from_struct(operation))

      result =
        case source do
          :direct ->
            SQLEventLog.append(stream, event, repo: IsolatedRepo)

          :facade ->
            Persistence.append(:host_sql_events, SQLEventLog, stream, event, repo: IsolatedRepo)
        end

      assert {:ok, [committed]} = result
      assert committed.id == event.id
      assert committed.operation_fingerprint == Map.fetch!(operation.fingerprints, event.id)

      assert {:ok, {:committed, [^committed]}} =
               SQLEventLog.reconcile_append(operation, repo: IsolatedRepo)

      assert {:ok, {:committed, [^committed]}} =
               Persistence.reconcile_append(:host_sql_events, SQLEventLog, operation,
                 repo: IsolatedRepo
               )

      assert {:ok, foreign} = Contracts.AppendOperation.new(Map.from_struct(operation))

      assert {:error, :invalid_append_operation} =
               SQLEventLog.reconcile_append(foreign, repo: IsolatedRepo)

      assert {:error, :invalid_append_operation} =
               Persistence.reconcile_append(:host_sql_events, SQLEventLog, foreign,
                 repo: IsolatedRepo
               )

      assert {:ok, [^committed]} =
               Persistence.read_stream(:host_sql_events, SQLEventLog, stream, repo: IsolatedRepo)
    end
  end

  test "security regression: an existing BufferedStore retains host SQL authority after a valid contract switch" do
    name = :host_package_sql_buffered_owner
    collection = "host-package-sql-buffered"
    opts = [name: collection, repo: IsolatedRepo]
    seed = Record.new("slot", %{"value" => 1}, id: "host-sql:buffered-first")
    assert :ok = SQLStore.put("slot", seed, opts)
    assert {:ok, %Record{} = first} = SQLStore.get("slot", opts)

    start_supervised!(
      {BufferedStore,
       name: name,
       backend: SQLStore,
       backend_opts: [repo: IsolatedRepo],
       collection: collection,
       write_mode: :async,
       ack_mode: :cache}
    )

    assert {:ok, ^first} = Persistence.get(name, BufferedStore, "slot")
    assert {:ok, {:backend, :node_restart}} = Persistence.buffered_store_authority_mode(name)
    assert {:ok, :process_lifetime} = Persistence.durability_class(name, BufferedStore)
    refute Persistence.supports_compare_and_swap?(BufferedStore)
    Application.put_env(:arbor_persistence, :contract_modules, @standalone_contracts)

    # The public ETS projection must not replace the SQL source of truth.
    poisoned = Contracts.Record.new("slot", %{"value" => "forged"}, id: "untrusted-projection")
    true = :ets.insert(name, {"slot", poisoned})
    assert {:ok, ^first} = Persistence.buffered_store_authoritative_get(name, "slot")
    assert {:ok, ^first} = Persistence.get(name, BufferedStore, "slot")
    filter = Filter.new() |> Filter.where(:value, :eq, 1)
    assert {:ok, [^first]} = Persistence.query(name, BufferedStore, filter)

    assert {:error, :key_mismatch} =
             Persistence.buffered_store_acknowledged_put(
               name,
               "slot",
               Record.new("wrong-key", %{})
             )

    assert {:ok, %Record{} = updated} =
             Persistence.buffered_store_acknowledged_compare_and_swap(
               name,
               "slot",
               {:value, first},
               Record.update(first, %{"value" => 2})
             )

    assert {updated.id, updated.generation, updated.revision} == {seed.id, 1, 2}
    assert {:ok, ^updated} = Persistence.buffered_store_authoritative_get(name, "slot")
    assert {:ok, ^updated} = Persistence.get(name, BufferedStore, "slot")
    assert {:ok, %Contracts.Record{} = outside_owner} = SQLStore.get("slot", opts)
    assert Map.from_struct(outside_owner) == Map.from_struct(updated)
    assert :ok = Persistence.buffered_store_acknowledged_delete(name, "slot")

    next = Record.new("slot", %{"value" => 3}, id: "host-sql:buffered-second")

    assert {:ok, %Record{} = current} =
             Persistence.buffered_store_acknowledged_put(name, "slot", next)

    assert {current.id, current.generation, current.revision} == {next.id, 2, 1}

    assert {:error, :conflict} =
             Persistence.buffered_store_acknowledged_compare_and_swap(
               name,
               "slot",
               {:value, first},
               Record.update(first, %{"value" => 4})
             )

    assert {:error, :conflict} =
             Persistence.buffered_store_acknowledged_compare_and_delete(name, "slot", updated)

    assert {:ok, ^current} = Persistence.buffered_store_authoritative_get(name, "slot")
    assert {:ok, ^current} = Persistence.get(name, BufferedStore, "slot")
    assert {:ok, {:backend, :node_restart}} = Persistence.buffered_store_authority_mode(name)
    assert {:ok, :process_lifetime} = Persistence.durability_class(name, BufferedStore)

    assert {:error, :unsupported} =
             Persistence.compare_and_swap(name, BufferedStore, "slot", {:value, current}, next)

    assert Application.fetch_env!(:arbor_persistence, :contract_modules) == @standalone_contracts
  end
end
