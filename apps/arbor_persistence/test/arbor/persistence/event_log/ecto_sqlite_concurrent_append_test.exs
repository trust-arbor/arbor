defmodule Arbor.Persistence.EventLog.EctoSQLiteConcurrentAppendTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog

  @moduletag capture_log: true
  @moduletag :integration
  @moduletag :sqlite

  Code.require_file(
    Path.expand(
      "../../../../priv/repo/migrations/20260711000002_enforce_unique_event_global_position.exs",
      __DIR__
    )
  )

  @protocol_migration_file Path.expand(
                             "../../../../priv/repo/migrations/20260712000004_enforce_event_log_protocol.exs",
                             __DIR__
                           )

  if File.exists?(@protocol_migration_file) do
    Code.require_file(@protocol_migration_file)
  end

  defmodule SQLitePoolRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  defmodule ProtocolMigrationRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "arbor-event-log-concurrency-#{System.unique_integer([:positive])}.sqlite3"
      )

    migration_database =
      Path.join(
        System.tmp_dir!(),
        "arbor-event-log-migration-#{System.unique_integer([:positive])}.sqlite3"
      )

    protocol_migration_database =
      Path.join(
        System.tmp_dir!(),
        "arbor-event-log-protocol-migration-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!(
      {SQLitePoolRepo,
       database: database,
       pool: DBConnection.ConnectionPool,
       pool_size: 12,
       busy_timeout: 500,
       journal_mode: :wal,
       queue_target: 100,
       queue_interval: 1_000}
    )

    start_supervised!(
      {MigrationRepo,
       database: migration_database, pool: DBConnection.ConnectionPool, pool_size: 1}
    )

    start_supervised!(
      {ProtocolMigrationRepo,
       database: protocol_migration_database, pool: DBConnection.ConnectionPool, pool_size: 2}
    )

    MigrationRepo.query!("""
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      global_position INTEGER
    )
    """)

    MigrationRepo.query!("""
    CREATE INDEX events_global_position_index ON events (global_position)
    """)

    SQLitePoolRepo.query!("""
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      stream_id TEXT NOT NULL,
      event_number INTEGER NOT NULL,
      global_position INTEGER,
      type TEXT NOT NULL,
      data TEXT DEFAULT '{}',
      metadata TEXT DEFAULT '{}',
      agent_id TEXT,
      causation_id TEXT,
      correlation_id TEXT,
      event_timestamp TEXT,
      committed_at TEXT,
      created_at TEXT NOT NULL
    )
    """)

    create_protocol_legacy_tables!(ProtocolMigrationRepo)

    SQLitePoolRepo.query!("""
    CREATE UNIQUE INDEX events_stream_id_event_number_index
    ON events (stream_id, event_number)
    """)

    SQLitePoolRepo.query!("""
    CREATE UNIQUE INDEX events_global_position_index
    ON events (global_position)
    """)

    SQLitePoolRepo.query!("""
    CREATE TABLE event_log_operations (
      operation_id TEXT PRIMARY KEY,
      stream_id TEXT NOT NULL,
      identity TEXT NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    SQLitePoolRepo.query!("""
    CREATE TRIGGER events_set_committed_at_after_insert
    AFTER INSERT ON events
    FOR EACH ROW
    BEGIN
      UPDATE events
      SET committed_at = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
      WHERE id = NEW.id;
    END
    """)

    if File.exists?(@protocol_migration_file) do
      assert :ok =
               Ecto.Migrator.up(
                 SQLitePoolRepo,
                 20_260_712_000_004,
                 Arbor.Persistence.Repo.Migrations.EnforceEventLogProtocol,
                 log: false
               )
    end

    on_exit(fn ->
      Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)

      Enum.each(
        [migration_database, migration_database <> "-shm", migration_database <> "-wal"],
        &File.rm/1
      )

      Enum.each(
        [
          protocol_migration_database,
          protocol_migration_database <> "-shm",
          protocol_migration_database <> "-wal"
        ],
        &File.rm/1
      )
    end)

    :ok
  end

  setup do
    SQLitePoolRepo.delete_all(Arbor.Persistence.Schemas.EventLogOperation)
    SQLitePoolRepo.delete_all(Arbor.Persistence.Schemas.Event)
    :ok
  end

  test "pooled ordinary appends retry BEGIN IMMEDIATE contention without exits" do
    writer_count = 40
    stream_id = "sqlite-ordinary-#{System.unique_integer([:positive])}"

    task_results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          EventLog.append(
            stream_id,
            Event.new(stream_id, "ordinary", %{writer: writer}),
            repo: SQLitePoolRepo
          )
        end,
        max_concurrency: writer_count,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(task_results, &match?({:ok, {:ok, [_]}}, &1)),
           "ordinary append failure or exit: #{inspect(task_results)}"

    assert {:ok, persisted} = EventLog.read_stream(stream_id, repo: SQLitePoolRepo)
    assert Enum.map(persisted, & &1.event_number) == Enum.to_list(1..writer_count)
  end

  test "pooled exact-version appends retain one-winner CAS" do
    writer_count = 24
    stream_id = "sqlite-cas-#{System.unique_integer([:positive])}"

    task_results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          EventLog.append(
            stream_id,
            Event.new(stream_id, "terminal", %{writer: writer}),
            repo: SQLitePoolRepo,
            expected_version: 0
          )
        end,
        max_concurrency: writer_count,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(task_results, &match?({:ok, _result}, &1)),
           "exact-version append exited: #{inspect(task_results)}"

    append_results = Enum.map(task_results, fn {:ok, result} -> result end)
    assert Enum.count(append_results, &match?({:ok, [_]}, &1)) == 1
    assert Enum.count(append_results, &(&1 == {:error, :version_conflict})) == writer_count - 1
    assert {:ok, 1} = EventLog.stream_version(stream_id, repo: SQLitePoolRepo)
  end

  test "concurrent different-stream appends retain one strict global order" do
    writer_count = 40

    task_results =
      1..writer_count
      |> Task.async_stream(
        fn writer ->
          stream_id = "sqlite-global-#{writer}"

          EventLog.append(
            stream_id,
            Event.new(stream_id, "global", %{writer: writer}),
            repo: SQLitePoolRepo
          )
        end,
        max_concurrency: writer_count,
        ordered: false,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(task_results, &match?({:ok, {:ok, [_]}}, &1)),
           "different-stream append failure or exit: #{inspect(task_results)}"

    assert {:ok, persisted} = EventLog.read_all(repo: SQLitePoolRepo)
    positions = Enum.map(persisted, & &1.global_position)

    assert positions == Enum.to_list(1..writer_count)
    assert length(positions) == length(Enum.uniq(positions))
  end

  test "nonzero busy_timeout cannot overrun the append deadline or commit later" do
    parent = self()

    assert {:ok, %{rows: [[500]]}} = SQLitePoolRepo.query("PRAGMA busy_timeout")

    locker =
      Task.async(fn ->
        SQLitePoolRepo.transaction(
          fn ->
            send(parent, :sqlite_lock_acquired)

            receive do
              :release_sqlite_lock -> :ok
            after
              2_000 -> raise "test lock release timed out"
            end
          end,
          mode: :immediate
        )
      end)

    assert_receive :sqlite_lock_acquired, 1_000
    event = Event.new("sqlite-busy", "ordinary", %{})
    assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation("sqlite-busy", [event])

    try do
      started_at = System.monotonic_time(:millisecond)

      assert EventLog.append("sqlite-busy", event,
               repo: SQLitePoolRepo,
               append_timeout_ms: 40
             ) in [
               {:error, :database_busy},
               {:error, {:append_indeterminate, operation}}
             ]

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 250
    after
      send(locker.pid, :release_sqlite_lock)
    end

    assert {:ok, _result} = Task.yield(locker, 1_000)
    Process.sleep(75)
    assert {:ok, 0} = EventLog.stream_version("sqlite-busy", repo: SQLitePoolRepo)
    assert {:ok, :absent} = EventLog.reconcile_append(operation, repo: SQLitePoolRepo)
  end

  test "migration rejects duplicate legacy global positions instead of renumbering" do
    MigrationRepo.query!("INSERT INTO events (id, global_position) VALUES (?, ?)", [
      "legacy-a",
      7
    ])

    MigrationRepo.query!("INSERT INTO events (id, global_position) VALUES (?, ?)", [
      "legacy-b",
      7
    ])

    assert_raise RuntimeError, ~r/global_position 7 occurs 2 times/, fn ->
      Ecto.Migrator.up(
        MigrationRepo,
        20_260_711_000_002,
        Arbor.Persistence.Repo.Migrations.EnforceUniqueEventGlobalPosition,
        log: false
      )
    end

    MigrationRepo.query!("DELETE FROM events WHERE id = ?", ["legacy-b"])

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               20_260_711_000_002,
               Arbor.Persistence.Repo.Migrations.EnforceUniqueEventGlobalPosition,
               log: false
             )

    assert {:error, error} =
             MigrationRepo.query("INSERT INTO events (id, global_position) VALUES (?, ?)", [
               "legacy-c",
               7
             ])

    assert Exception.message(error) =~ "UNIQUE constraint failed: events.global_position"
  end

  test "post-cutover legacy writer without operation identity fails closed" do
    assert {:error, error} =
             SQLitePoolRepo.query(
               legacy_insert_sql(),
               ["rolling-a", "stream-a", 1, 1]
             )

    assert Exception.message(error) =~ "EventLog protocol identity is required"
  end

  test "protocol migration rejects malformed legacy positions and sequences transactionally" do
    cases = [
      {"overflow-event", [{"a", "a", 2_147_483_648, 1}], ~r/invalid positions/},
      {"overflow-global", [{"a", "a", 1, 2_147_483_648}], ~r/invalid positions/},
      {"nonpositive-event", [{"a", "a", 0, 1}], ~r/invalid positions/},
      {"nonpositive-global", [{"a", "a", 1, 0}], ~r/invalid positions/},
      {"null-event", [{"a", "a", nil, 1}], ~r/invalid positions/},
      {"null-global", [{"a", "a", 1, nil}], ~r/invalid positions/},
      {"duplicate-global", [{"a", "a", 1, 1}, {"b", "b", 1, 1}], ~r/occurs/},
      {"duplicate-stream", [{"a", "a", 1, 1}, {"b", "a", 1, 2}], ~r/occurs/},
      {"global-gap", [{"a", "a", 1, 1}, {"b", "b", 1, 3}], ~r/global sequence is inconsistent/},
      {"stream-gap", [{"a", "a", 1, 1}, {"b", "a", 3, 2}], ~r/sequence is inconsistent/}
    ]

    Enum.each(cases, fn {_label, rows, expected_error} ->
      ProtocolMigrationRepo.query!("DELETE FROM events")

      Enum.each(rows, fn {id, stream_id, event_number, global_position} ->
        ProtocolMigrationRepo.query!(
          """
          INSERT INTO events (
            id, stream_id, event_number, global_position, type, data, metadata, created_at
          ) VALUES (?, ?, ?, ?, 'legacy', '{}', '{}', STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
          """,
          [id, stream_id, event_number, global_position]
        )
      end)

      assert_raise RuntimeError, expected_error, fn ->
        run_latest_protocol_migration!(ProtocolMigrationRepo)
      end

      assert %{rows: []} =
               ProtocolMigrationRepo.query!(
                 "SELECT name FROM pragma_table_info('events') WHERE name = 'operation_id'"
               )
    end)
  end

  defp legacy_insert_sql do
    """
    INSERT INTO events (
      id, stream_id, event_number, global_position, type, data, metadata, created_at
    ) VALUES (?, ?, ?, ?, 'legacy', '{}', '{}', STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
    """
  end

  defp run_latest_protocol_migration!(repo) do
    if File.exists?(@protocol_migration_file) do
      Ecto.Migrator.up(
        repo,
        20_260_712_000_004,
        Arbor.Persistence.Repo.Migrations.EnforceEventLogProtocol,
        log: false
      )
    else
      Ecto.Migrator.up(
        repo,
        20_260_711_000_002,
        Arbor.Persistence.Repo.Migrations.EnforceUniqueEventGlobalPosition,
        log: false
      )
    end
  end

  defp create_protocol_legacy_tables!(repo) do
    repo.query!("""
    CREATE TABLE events (
      id TEXT PRIMARY KEY,
      stream_id TEXT NOT NULL,
      event_number INTEGER,
      global_position INTEGER,
      type TEXT NOT NULL,
      data TEXT DEFAULT '{}',
      metadata TEXT DEFAULT '{}',
      agent_id TEXT,
      causation_id TEXT,
      correlation_id TEXT,
      event_timestamp TEXT,
      committed_at TEXT,
      created_at TEXT NOT NULL
    )
    """)

    repo.query!("""
    CREATE TABLE event_log_operations (
      operation_id TEXT PRIMARY KEY,
      stream_id TEXT NOT NULL,
      identity TEXT NOT NULL,
      status TEXT NOT NULL,
      reason TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end
end
