defmodule Arbor.Persistence.EventLog.EctoProtocolMigrationSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog

  @moduletag :database
  @moduletag :integration

  @protocol_migration 20_260_712_000_004
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

    on_exit(fn ->
      Postgrex.query!(admin, "DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")
      GenServer.stop(admin)
    end)

    {:ok, admin: admin, schema: schema}
  end

  setup %{schema: schema} do
    ProtocolRepo.query!("DELETE FROM event_log_operations")
    ProtocolRepo.query!("DELETE FROM events")
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
