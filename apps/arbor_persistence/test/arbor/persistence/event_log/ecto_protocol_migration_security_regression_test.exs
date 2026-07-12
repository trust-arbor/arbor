defmodule Arbor.Persistence.EventLog.EctoProtocolMigrationSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog

  @moduletag :database
  @moduletag :integration

  @protocol_migration 20_260_712_000_004
  @r4_protocol_migration 20_260_712_000_005
  @legacy_migration 20_260_711_000_002

  defmodule ProtocolRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule MigrationProbeRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    {:ok, admin} = Postgrex.start_link(postgres_opts())
    schema = "event_log_protocol_#{System.unique_integer([:positive])}"
    Postgrex.query!(admin, "CREATE SCHEMA #{quote_identifier(schema)}")
    create_legacy_tables!(admin, schema, indexes?: true)

    start_supervised!(
      {ProtocolRepo,
       Keyword.merge(postgres_opts(),
         pool_size: 5,
         after_connect: fn conn ->
           Postgrex.query!(conn, "SET search_path TO #{quote_identifier(schema)}", [])
         end
       )}
    )

    migrate_protocol_if_available!(ProtocolRepo, schema)
    migrate_r4_protocol_if_available!(ProtocolRepo, schema)

    on_exit(fn ->
      Postgrex.query!(admin, "DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")
      GenServer.stop(admin)
    end)

    {:ok, admin: admin, schema: schema}
  end

  setup %{schema: schema} do
    ProtocolRepo.query!("DELETE FROM event_log_operations")
    ProtocolRepo.query!("DELETE FROM events")
    reset_protocol_epoch!()
    {:ok, schema: schema}
  end

  test "security regression: an R1 transaction cannot commit after durable absence" do
    parent = self()
    stream_id = "ecto-r1-late-writer"

    event =
      Event.new(stream_id, "arbor.review.ordinary", %{value: 1}, id: "evt_ecto_r1_late_writer")

    assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation(stream_id, [event])

    old_writer =
      Task.async(fn ->
        try do
          ProtocolRepo.transaction(fn ->
            send(parent, :ecto_r1_transaction_open)

            receive do
              :attempt_ecto_r1_insert ->
                ProtocolRepo.query!(
                  """
                  INSERT INTO events (
                    id, stream_id, event_number, global_position, type,
                    data, metadata, event_timestamp, created_at
                  ) VALUES ($1, $2, 1, 1, $3, $4, $5, $6, clock_timestamp())
                  """,
                  [
                    event.id,
                    stream_id,
                    event.type,
                    event.data,
                    event.metadata,
                    event.timestamp
                  ]
                )
            after
              3_000 -> raise "late generic Ecto R1 writer release timed out"
            end
          end)
        rescue
          error -> {:raised, error}
        end
      end)

    assert_receive :ecto_r1_transaction_open, 1_000
    assert {:ok, :absent} = EventLog.reconcile_append(operation, repo: ProtocolRepo)

    send(old_writer.pid, :attempt_ecto_r1_insert)
    assert {:raised, _error} = Task.await(old_writer, 2_000)

    assert %{rows: [[0]]} = ProtocolRepo.query!("SELECT COUNT(*) FROM events")
    assert {:ok, :absent} = EventLog.reconcile_append(operation, repo: ProtocolRepo)
  end

  test "migration rejects 2^31 and malformed legacy positions transactionally", %{
    admin: admin
  } do
    cases = [
      {"overflow-event", 2_147_483_648, 1},
      {"overflow-global", 1, 2_147_483_648},
      {"nonpositive-event", 0, 1},
      {"nonpositive-global", 1, 0},
      {"null-event", nil, 1},
      {"null-global", 1, nil}
    ]

    Enum.each(cases, fn {label, event_number, global_position} ->
      schema = "event_log_bad_#{label}_#{System.unique_integer([:positive])}"
      Postgrex.query!(admin, "CREATE SCHEMA #{quote_identifier(schema)}")
      create_legacy_tables!(admin, schema, indexes?: false)

      Postgrex.query!(
        admin,
        """
        INSERT INTO #{quote_identifier(schema)}.events (
          id, stream_id, event_number, global_position, type, data, metadata,
          event_timestamp, created_at
        ) VALUES ('legacy', 'legacy', $1, $2, 'legacy', '{}'::jsonb, '{}'::jsonb,
                  clock_timestamp(), clock_timestamp())
        """,
        [event_number, global_position]
      )

      assert_raise RuntimeError, ~r/invalid positions/, fn ->
        run_latest_available_migration!(MigrationProbeRepo, schema)
      end

      assert %{rows: [[false]]} =
               Postgrex.query!(
                 admin,
                 """
                 SELECT EXISTS (
                   SELECT 1 FROM information_schema.columns
                   WHERE table_schema = $1
                     AND table_name = 'events'
                     AND column_name = 'operation_id'
                 )
                 """,
                 [schema]
               )

      Postgrex.query!(admin, "DROP SCHEMA #{quote_identifier(schema)} CASCADE")
    end)
  end

  test "migration rejects duplicate and inconsistent legacy sequences", %{admin: admin} do
    cases = [
      {"duplicate-global", [{"a", "a", 1, 1}, {"b", "b", 1, 1}]},
      {"duplicate-stream", [{"a", "a", 1, 1}, {"b", "a", 1, 2}]},
      {"global-gap", [{"a", "a", 1, 1}, {"b", "b", 1, 3}]},
      {"stream-gap", [{"a", "a", 1, 1}, {"b", "a", 3, 2}]}
    ]

    Enum.each(cases, fn {label, rows} ->
      schema = "event_log_bad_#{label}_#{System.unique_integer([:positive])}"
      Postgrex.query!(admin, "CREATE SCHEMA #{quote_identifier(schema)}")
      create_legacy_tables!(admin, schema, indexes?: false)

      Enum.each(rows, fn {id, stream_id, event_number, global_position} ->
        Postgrex.query!(
          admin,
          """
          INSERT INTO #{quote_identifier(schema)}.events (
            id, stream_id, event_number, global_position, type, data, metadata,
            event_timestamp, created_at
          ) VALUES ($1, $2, $3, $4, 'legacy', '{}'::jsonb, '{}'::jsonb,
                    clock_timestamp(), clock_timestamp())
          """,
          [id, stream_id, event_number, global_position]
        )
      end)

      assert_raise RuntimeError, ~r/(occurs|sequence is inconsistent)/, fn ->
        run_latest_available_migration!(MigrationProbeRepo, schema)
      end

      Postgrex.query!(admin, "DROP SCHEMA #{quote_identifier(schema)} CASCADE")
    end)
  end

  @tag timeout: 15_000
  test "security regression: migration up waits behind a runtime append protocol lock", %{
    admin: admin
  } do
    fixture = start_lock_order_fixture!(admin, apply_r4?: false)

    assert_migration_follows_runtime_lock_order!(fixture, :up, :share, :commit)
    assert r4_migration_applied?(admin, fixture.schema)
  end

  @tag timeout: 15_000
  test "security regression: migration down waits behind runtime reconciliation", %{
    admin: admin
  } do
    fixture = start_lock_order_fixture!(admin, apply_r4?: true)

    assert_migration_follows_runtime_lock_order!(fixture, :down, :access_share, :rollback)
    refute r4_migration_applied?(admin, fixture.schema)
  end

  test "security regression: append and reconciliation require one exact protocol epoch" do
    drop_r4_protocol_constraints!()

    on_exit(fn ->
      reset_protocol_epoch!()
      restore_r4_protocol_constraints!()
    end)

    corruptions = [
      missing: fn -> ProtocolRepo.query!("DELETE FROM event_log_protocol") end,
      wrong: fn -> ProtocolRepo.query!("UPDATE event_log_protocol SET protocol_version = 2") end,
      duplicate: fn ->
        ProtocolRepo.query!("INSERT INTO event_log_protocol VALUES (FALSE, 3, clock_timestamp())")
      end
    ]

    Enum.each(corruptions, fn {label, corrupt!} ->
      reset_protocol_epoch!()
      corrupt!.()

      stream_id = "ecto-protocol-#{label}"
      event = Event.new(stream_id, "arbor.review.ordinary", %{state: label})
      assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation(stream_id, [event])

      assert {:error, :event_log_protocol_unavailable} =
               EventLog.append(stream_id, event, repo: ProtocolRepo)

      assert {:error, {:append_indeterminate, ^operation}} =
               EventLog.reconcile_append(operation, repo: ProtocolRepo)

      assert %{rows: [[0]]} = ProtocolRepo.query!("SELECT COUNT(*) FROM events")
      assert %{rows: [[0]]} = ProtocolRepo.query!("SELECT COUNT(*) FROM event_log_operations")
    end)
  end

  test "security regression: database trigger rejects a marked raw writer under a wrong epoch" do
    drop_r4_protocol_constraints!()

    on_exit(fn ->
      reset_protocol_epoch!()
      restore_r4_protocol_constraints!()
    end)

    ProtocolRepo.query!("UPDATE event_log_protocol SET protocol_version = 2")

    event = Event.new("ecto-raw-wrong-epoch", "arbor.review.ordinary", %{value: 1})
    assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation(event.stream_id, [event])

    assert {:error, error} =
             ProtocolRepo.query(
               """
               INSERT INTO events (
                 id, stream_id, event_number, global_position, type, data, metadata,
                 event_timestamp, operation_id, operation_fingerprint, created_at
               ) VALUES ($1, $2, 1, 1, $3, $4, $5, $6, $7, $8, clock_timestamp())
               """,
               [
                 event.id,
                 event.stream_id,
                 event.type,
                 event.data,
                 event.metadata,
                 event.timestamp,
                 operation.operation_id,
                 Map.fetch!(operation.fingerprints, event.id)
               ]
             )

    assert Exception.message(error) =~ "EventLog protocol epoch is unavailable"
    assert %{rows: [[0]]} = ProtocolRepo.query!("SELECT COUNT(*) FROM events")
  end

  test "security regression: legacy NULL fingerprints remain explicit remediation debt" do
    assert %{rows: [[false]]} =
             ProtocolRepo.query!("""
             SELECT convalidated
             FROM pg_constraint
             WHERE conrelid = 'events'::regclass
               AND conname = 'events_operation_fingerprint_present'
             """)

    assert %{rows: [[comment]]} =
             ProtocolRepo.query!("""
             SELECT obj_description(oid, 'pg_constraint')
             FROM pg_constraint
             WHERE conrelid = 'events'::regclass
               AND conname = 'events_operation_fingerprint_present'
             """)

    assert comment =~ "trusted-source remediation"
    assert comment =~ "must not be recomputed"
  end

  defp migrate_protocol_if_available!(repo, schema) do
    migration_file = protocol_migration_file()

    if File.exists?(migration_file) do
      Code.require_file(migration_file)

      Ecto.Migrator.up(
        repo,
        @protocol_migration,
        Arbor.Persistence.Repo.Migrations.EnforceEventLogProtocol,
        prefix: schema,
        log: false
      )
    end
  end

  defp migrate_r4_protocol_if_available!(repo, schema) do
    migration_file = r4_protocol_migration_file()

    if File.exists?(migration_file) do
      Code.require_file(migration_file)

      Ecto.Migrator.up(
        repo,
        @r4_protocol_migration,
        Arbor.Persistence.Repo.Migrations.HardenEventLogProtocolEpoch,
        prefix: schema,
        log: false
      )
    end
  end

  defp start_lock_order_fixture!(admin, opts) do
    schema = "event_log_lock_order_#{System.unique_integer([:positive])}"
    Postgrex.query!(admin, "CREATE SCHEMA #{quote_identifier(schema)}")
    create_legacy_tables!(admin, schema, indexes?: true)

    {:ok, probe} =
      MigrationProbeRepo.start_link(
        Keyword.merge(postgres_opts(),
          pool_size: 2,
          after_connect: fn conn ->
            Postgrex.query!(conn, "SET search_path TO #{quote_identifier(schema)}", [])
          end
        )
      )

    {:ok, runtime_conn} = Postgrex.start_link(postgres_opts())
    Process.unlink(probe)
    Process.unlink(runtime_conn)
    migrate_protocol_if_available!(MigrationProbeRepo, schema)

    if Keyword.fetch!(opts, :apply_r4?) do
      migrate_r4_protocol_if_available!(MigrationProbeRepo, schema)
    end

    on_exit(fn ->
      if Process.alive?(runtime_conn), do: GenServer.stop(runtime_conn)
      if Process.alive?(probe), do: GenServer.stop(probe)
      Postgrex.query!(admin, "DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")
    end)

    %{
      admin: admin,
      runtime_conn: runtime_conn,
      schema: schema,
      task_supervisor: start_supervised!(Task.Supervisor)
    }
  end

  defp assert_migration_follows_runtime_lock_order!(fixture, direction, protocol_mode, outcome) do
    parent = self()
    ref = make_ref()

    runtime_task =
      Task.Supervisor.async_nolink(fixture.task_supervisor, fn ->
        capture_call(fn ->
          Postgrex.transaction(fixture.runtime_conn, fn conn ->
            Postgrex.query!(
              conn,
              "LOCK TABLE #{qualified_table(fixture.schema, "event_log_protocol")} " <>
                "IN #{sql_lock_mode(protocol_mode)} MODE"
            )

            send(parent, {ref, :runtime_protocol_locked})

            receive do
              {^ref, :continue_runtime} -> :ok
            after
              5_000 -> raise "migration lock-order runtime release timed out"
            end

            Postgrex.query!(
              conn,
              "LOCK TABLE #{qualified_table(fixture.schema, "event_log_operations")}, " <>
                "#{qualified_table(fixture.schema, "events")} " <>
                "IN #{runtime_table_lock_mode(outcome)} MODE"
            )

            case outcome do
              :commit -> :runtime_committed
              :rollback -> Postgrex.rollback(conn, :runtime_rolled_back)
            end
          end)
        end)
      end)

    assert_receive {^ref, :runtime_protocol_locked}, 1_000

    migration_task =
      Task.Supervisor.async_nolink(fixture.task_supervisor, fn ->
        capture_call(fn -> run_r4_migration!(direction, fixture.schema) end)
      end)

    try do
      migration_backend_pid =
        wait_for_pending_protocol_lock!(fixture.admin, fixture.schema, 5_000)

      early_event_locks =
        granted_migration_event_locks(
          fixture.admin,
          migration_backend_pid,
          fixture.schema
        )

      send(runtime_task.pid, {ref, :continue_runtime})

      runtime_result = Task.await(runtime_task, 7_000)
      migration_result = Task.await(migration_task, 7_000)

      expected_runtime =
        case outcome do
          :commit -> {:returned, {:ok, :runtime_committed}}
          :rollback -> {:returned, {:error, :runtime_rolled_back}}
        end

      assert {expected_runtime, {:returned, :ok}, []} ==
               {runtime_result, migration_result, early_event_locks}
    after
      send(runtime_task.pid, {ref, :continue_runtime})
      shutdown_if_alive(runtime_task)
      shutdown_if_alive(migration_task)
    end
  end

  defp run_r4_migration!(direction, schema) do
    Code.require_file(r4_protocol_migration_file())

    apply(Ecto.Migrator, direction, [
      MigrationProbeRepo,
      @r4_protocol_migration,
      Arbor.Persistence.Repo.Migrations.HardenEventLogProtocolEpoch,
      [prefix: schema, log: false]
    ])
  end

  defp wait_for_pending_protocol_lock!(conn, schema, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_pending_protocol_lock!(conn, schema, deadline)
  end

  defp do_wait_for_pending_protocol_lock!(conn, schema, deadline) do
    result =
      Postgrex.query!(
        conn,
        """
        SELECT locks.pid
        FROM pg_locks AS locks
        JOIN pg_class AS relations ON relations.oid = locks.relation
        JOIN pg_namespace AS namespaces ON namespaces.oid = relations.relnamespace
        WHERE namespaces.nspname = $1
          AND relations.relname = 'event_log_protocol'
          AND locks.mode = 'AccessExclusiveLock'
          AND locks.granted IS FALSE
        """,
        [schema]
      )

    case result.rows do
      [[backend_pid]] ->
        backend_pid

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_wait_for_pending_protocol_lock!(conn, schema, deadline)
        else
          flunk("migration did not wait for event_log_protocol protection")
        end
    end
  end

  defp granted_migration_event_locks(conn, backend_pid, schema) do
    Postgrex.query!(
      conn,
      """
      SELECT relations.relname, locks.mode
      FROM pg_locks AS locks
      JOIN pg_class AS relations ON relations.oid = locks.relation
      JOIN pg_namespace AS namespaces ON namespaces.oid = relations.relnamespace
      WHERE locks.pid = $1
        AND namespaces.nspname = $2
        AND relations.relname IN ('events', 'event_log_operations')
        AND locks.granted IS TRUE
      ORDER BY relations.relname, locks.mode
      """,
      [backend_pid, schema]
    ).rows
  end

  defp r4_migration_applied?(conn, schema) do
    Postgrex.query!(
      conn,
      "SELECT version FROM #{qualified_table(schema, "schema_migrations")} WHERE version = $1",
      [@r4_protocol_migration]
    ).num_rows == 1
  end

  defp capture_call(fun) do
    {:returned, fun.()}
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {kind, reason}
  end

  defp shutdown_if_alive(task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
  end

  defp sql_lock_mode(:share), do: "SHARE"
  defp sql_lock_mode(:access_share), do: "ACCESS SHARE"
  defp runtime_table_lock_mode(:commit), do: "ROW EXCLUSIVE"
  defp runtime_table_lock_mode(:rollback), do: "ACCESS SHARE"

  defp qualified_table(schema, table) do
    quote_identifier(schema) <> "." <> quote_identifier(table)
  end

  defp run_latest_available_migration!(repo, schema) do
    {:ok, probe} =
      repo.start_link(
        Keyword.merge(postgres_opts(),
          pool_size: 2,
          after_connect: fn conn ->
            Postgrex.query!(conn, "SET search_path TO #{quote_identifier(schema)}", [])
          end
        )
      )

    try do
      protocol_file = protocol_migration_file()

      if File.exists?(protocol_file) do
        Code.require_file(protocol_file)

        Ecto.Migrator.up(
          repo,
          @protocol_migration,
          Arbor.Persistence.Repo.Migrations.EnforceEventLogProtocol,
          prefix: schema,
          log: false
        )
      else
        legacy_file =
          Path.expand(
            "../../../../priv/repo/migrations/20260711000002_enforce_unique_event_global_position.exs",
            __DIR__
          )

        Code.require_file(legacy_file)

        Ecto.Migrator.up(
          repo,
          @legacy_migration,
          Arbor.Persistence.Repo.Migrations.EnforceUniqueEventGlobalPosition,
          prefix: schema,
          log: false
        )
      end
    after
      GenServer.stop(probe)
    end
  end

  defp protocol_migration_file do
    Path.expand(
      "../../../../priv/repo/migrations/20260712000004_enforce_event_log_protocol.exs",
      __DIR__
    )
  end

  defp r4_protocol_migration_file do
    Path.expand(
      "../../../../priv/repo/migrations/20260712000005_harden_event_log_protocol_epoch.exs",
      __DIR__
    )
  end

  defp reset_protocol_epoch! do
    ProtocolRepo.query!("DELETE FROM event_log_protocol")

    ProtocolRepo.query!(
      "INSERT INTO event_log_protocol (singleton, protocol_version, cutover_at) VALUES (TRUE, 3, clock_timestamp())"
    )
  end

  defp drop_r4_protocol_constraints! do
    ProtocolRepo.query!(
      "ALTER TABLE event_log_protocol DROP CONSTRAINT IF EXISTS event_log_protocol_singleton_true"
    )

    ProtocolRepo.query!(
      "ALTER TABLE event_log_protocol DROP CONSTRAINT IF EXISTS event_log_protocol_version_3"
    )
  end

  defp restore_r4_protocol_constraints! do
    if File.exists?(r4_protocol_migration_file()) do
      ProtocolRepo.query!(
        "ALTER TABLE event_log_protocol ADD CONSTRAINT event_log_protocol_singleton_true CHECK (singleton IS TRUE)"
      )

      ProtocolRepo.query!(
        "ALTER TABLE event_log_protocol ADD CONSTRAINT event_log_protocol_version_3 CHECK (protocol_version = 3)"
      )
    end
  end

  defp create_legacy_tables!(conn, schema, opts) do
    quoted_schema = quote_identifier(schema)

    Postgrex.query!(conn, """
    CREATE TABLE #{quoted_schema}.events (
      id varchar(255) PRIMARY KEY,
      stream_id varchar(255) NOT NULL,
      event_number bigint,
      global_position bigint,
      type varchar(255) NOT NULL,
      data jsonb DEFAULT '{}'::jsonb,
      metadata jsonb DEFAULT '{}'::jsonb,
      agent_id varchar(255),
      causation_id varchar(255),
      correlation_id varchar(255),
      event_timestamp timestamp(6) without time zone,
      committed_at timestamp(6) without time zone DEFAULT clock_timestamp(),
      created_at timestamp(6) without time zone NOT NULL DEFAULT clock_timestamp()
    )
    """)

    Postgrex.query!(conn, """
    CREATE TABLE #{quoted_schema}.event_log_operations (
      operation_id varchar(255) PRIMARY KEY,
      stream_id varchar(255) NOT NULL,
      identity jsonb NOT NULL,
      status varchar(255) NOT NULL,
      reason varchar(255),
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL
    )
    """)

    if Keyword.fetch!(opts, :indexes?) do
      Postgrex.query!(conn, """
      CREATE UNIQUE INDEX events_stream_id_event_number_index
      ON #{quoted_schema}.events (stream_id, event_number)
      """)

      Postgrex.query!(conn, """
      CREATE UNIQUE INDEX events_global_position_index
      ON #{quoted_schema}.events (global_position)
      """)
    end
  end

  defp postgres_opts do
    [
      username: System.get_env("POSTGRES_USER", "arbor_dev"),
      password: System.get_env("POSTGRES_PASSWORD", ""),
      database: System.get_env("POSTGRES_DB", "trust_arbor_test"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      prepare: :unnamed
    ]
  end

  defp quote_identifier(identifier),
    do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
