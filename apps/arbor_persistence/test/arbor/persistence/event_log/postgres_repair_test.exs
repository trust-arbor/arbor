defmodule Arbor.Persistence.EventLog.PostgresRepairTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.EventLog.PostgresRepair

  @moduletag :database
  @moduletag :integration

  defmodule RepairRepo do
    use Ecto.Repo,
      otp_app: :arbor_persistence,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    {:ok, admin} = Postgrex.start_link(postgres_opts())
    schema = "event_log_repair_#{System.unique_integer([:positive])}"
    Postgrex.query!(admin, "CREATE SCHEMA #{quote_identifier(schema)}")
    create_tables!(admin, schema)

    start_supervised!(
      {RepairRepo,
       Keyword.merge(postgres_opts(),
         pool_size: 5,
         after_connect: fn connection ->
           Postgrex.query!(connection, "SET search_path TO #{quote_identifier(schema)}", [])
         end
       )}
    )

    on_exit(fn ->
      Postgrex.query!(admin, "DROP SCHEMA IF EXISTS #{quote_identifier(schema)} CASCADE")
      GenServer.stop(admin)
    end)

    {:ok, schema: schema}
  end

  setup do
    RepairRepo.query!("DELETE FROM arbor_event_log_identity_repair_rows")
    RepairRepo.query!("DELETE FROM arbor_event_log_identity_repair_batches")
    RepairRepo.query!("DELETE FROM arbor_event_log_position_repair_rows")
    RepairRepo.query!("DELETE FROM arbor_event_log_position_repair_batches")
    RepairRepo.query!("DELETE FROM events")

    RepairRepo.query!(
      "ALTER TABLE events DROP CONSTRAINT IF EXISTS events_operation_fingerprint_present"
    )

    {:ok, %{}}
  end

  test "audit is idempotent and reports exact duplicate metrics" do
    insert_event!("evt-a", "stream-a", 1, 1, "2026-07-01 00:00:00")
    insert_event!("evt-b", "stream-b", 1, 1, "2026-07-01 00:00:01")
    insert_event!("evt-c", "stream-a", 2, 2, "2026-07-01 00:00:02")

    assert {:ok, audit} = PostgresRepair.audit(RepairRepo)
    assert {:ok, ^audit} = PostgresRepair.audit(RepairRepo)
    assert audit.event_count == 3
    assert audit.min_global_position == 1
    assert audit.max_global_position == 2
    assert audit.distinct_global_positions == 2
    assert audit.duplicate_global_position_groups == 1
    assert audit.duplicate_global_position_excess == 1
    assert audit.duplicate_global_position_max_multiplicity == 2
    assert audit.same_stream_position_collision_groups == 0
    assert audit.stream_sequence_problem_groups == 0
    assert audit.stream_global_position_regressions_or_ties == 0
  end

  test "position repair refuses malformed stream history" do
    insert_event!("evt-a", "stream-a", 1, 4, "2026-07-01 00:00:00")
    insert_event!("evt-b", "stream-a", 2, 3, "2026-07-01 00:00:01")

    assert {:ok, audit} = PostgresRepair.audit(RepairRepo)
    assert audit.stream_global_position_regressions_or_ties == 1

    assert {:error, {:database_error, message}} = PostgresRepair.apply_positions(RepairRepo, 2, 4)
    assert message =~ "malformed EventLog history"

    assert %{rows: [[0]]} =
             RepairRepo.query!("SELECT COUNT(*) FROM arbor_event_log_position_repair_rows")
  end

  test "position repair uses deterministic global_position created_at id ordering" do
    insert_event!("evt-z", "stream-z", 1, 2, "2026-07-01 00:00:02")
    insert_event!("evt-b", "stream-b", 1, 1, "2026-07-01 00:00:01")
    insert_event!("evt-a", "stream-a", 1, 1, "2026-07-01 00:00:01")
    insert_event!("evt-z-2", "stream-z", 2, 3, "2026-07-01 00:00:03")

    assert {:ok, %{batch_id: batch_id}} = PostgresRepair.apply_positions(RepairRepo, 4, 3)

    assert %{rows: [["evt-a", 1], ["evt-b", 2], ["evt-z", 3], ["evt-z-2", 4]]} =
             RepairRepo.query!("SELECT id, global_position FROM events ORDER BY global_position")

    assert %{rows: [["evt-a", 1, 1], ["evt-b", 1, 2], ["evt-z", 2, 3], ["evt-z-2", 3, 4]]} =
             RepairRepo.query!(
               "SELECT event_id, old_global_position, proposed_global_position " <>
                 "FROM arbor_event_log_position_repair_rows WHERE batch_id = $1 ORDER BY proposed_global_position",
               [batch_id]
             )

    assert {:ok, audit} = PostgresRepair.audit(RepairRepo)
    assert audit.event_count == audit.distinct_global_positions
    assert audit.min_global_position == 1
    assert audit.max_global_position == 4
  end

  test "position repair rejects stale confirmation and exact rollback requires matching confirmation" do
    insert_event!("evt-a", "stream-a", 1, 1, "2026-07-01 00:00:00")
    insert_event!("evt-b", "stream-b", 1, 1, "2026-07-01 00:00:01")

    assert {:error, {:database_error, message}} =
             PostgresRepair.apply_positions(RepairRepo, 2, 999)

    assert message =~ "confirmation mismatch"

    assert {:ok, %{batch_id: batch_id}} = PostgresRepair.apply_positions(RepairRepo, 2, 1)

    assert {:error, :rollback_confirmation_mismatch} =
             PostgresRepair.rollback_positions(RepairRepo, batch_id, "wrong-batch")

    assert {:ok, %{batch_id: ^batch_id}} =
             PostgresRepair.rollback_positions(RepairRepo, batch_id, batch_id)

    assert %{rows: [["evt-a", 1], ["evt-b", 1]]} =
             RepairRepo.query!("SELECT id, global_position FROM events ORDER BY id")
  end

  test "identity remediation stages deterministic fingerprints and rejects tampered persisted rows" do
    insert_event!("evt-a", "stream-a", 1, 1, "2026-07-01 00:00:00")

    RepairRepo.query!("""
    ALTER TABLE events
    ADD CONSTRAINT events_operation_fingerprint_present
    CHECK (operation_fingerprint IS NOT NULL) NOT VALID
    """)

    digest = String.duplicate("a", 64)

    assert {:ok, staged} = PostgresRepair.stage_identity(RepairRepo, "identity-tamper", digest, 1)
    assert staged.staged_count == 1
    assert staged.provenance == "legacy_trusted_cutover_snapshot_v1"

    assert %{rows: [[operation_id, fingerprint]]} =
             RepairRepo.query!(
               "SELECT operation_id, operation_fingerprint FROM arbor_event_log_identity_repair_rows"
             )

    assert String.starts_with?(operation_id, "legacy_identity_v1_")
    assert byte_size(operation_id) <= 255
    assert String.match?(fingerprint, ~r/^[0-9a-f]{64}$/)

    RepairRepo.query!("ALTER TABLE events DROP CONSTRAINT events_operation_fingerprint_present")
    RepairRepo.query!("UPDATE events SET data = '{\"tampered\":true}'::jsonb WHERE id = 'evt-a'")

    RepairRepo.query!("""
    ALTER TABLE events
    ADD CONSTRAINT events_operation_fingerprint_present
    CHECK (operation_fingerprint IS NOT NULL) NOT VALID
    """)

    assert {:error, {:database_error, message}} =
             PostgresRepair.apply_staged_identity(RepairRepo, "identity-tamper", 1)

    assert message =~ "identity staging mismatch"

    assert %{rows: [[nil, nil]]} =
             RepairRepo.query!(
               "SELECT operation_id, operation_fingerprint FROM events WHERE id = 'evt-a'"
             )
  end

  test "identity remediation applies a staged trusted cutover snapshot and validates the constraint" do
    insert_event!("evt-a", "stream-a", 1, 1, "2026-07-01 00:00:00")

    RepairRepo.query!("""
    ALTER TABLE events
    ADD CONSTRAINT events_operation_fingerprint_present
    CHECK (operation_fingerprint IS NOT NULL) NOT VALID
    """)

    assert {:ok, %{staged_count: 1}} =
             PostgresRepair.stage_identity(
               RepairRepo,
               "identity-apply",
               String.duplicate("b", 64),
               1
             )

    assert {:ok, %{batch_id: "identity-apply", provenance: "legacy_trusted_cutover_snapshot_v1"}} =
             PostgresRepair.apply_staged_identity(RepairRepo, "identity-apply", 1)

    assert %{rows: [[operation_id, fingerprint, true]]} =
             RepairRepo.query!("""
             SELECT event.operation_id, event.operation_fingerprint, fingerprint_check.convalidated
             FROM events event
             JOIN pg_constraint fingerprint_check
               ON fingerprint_check.conrelid = 'events'::regclass
              AND fingerprint_check.conname = 'events_operation_fingerprint_present'
             WHERE event.id = 'evt-a'
             """)

    assert String.starts_with?(operation_id, "legacy_identity_v1_")
    assert String.match?(fingerprint, ~r/^[0-9a-f]{64}$/)
  end

  defp insert_event!(id, stream_id, event_number, global_position, created_at) do
    created_at = NaiveDateTime.from_iso8601!(created_at)

    RepairRepo.query!(
      """
      INSERT INTO events (
        id, stream_id, event_number, global_position, type, data, metadata,
        event_timestamp, created_at
      ) VALUES ($1, $2, $3, $4, 'repair.test', '{"value":1}'::jsonb, '{}'::jsonb,
                TIMESTAMP '2026-07-01 00:00:00', $5::timestamp)
      """,
      [id, stream_id, event_number, global_position, created_at]
    )
  end

  defp create_tables!(admin, schema) do
    qualified = quote_identifier(schema)

    Postgrex.query!(admin, """
    CREATE TABLE #{qualified}.events (
      id text PRIMARY KEY,
      stream_id text NOT NULL,
      event_number bigint NOT NULL,
      global_position bigint,
      type text NOT NULL,
      data jsonb NOT NULL DEFAULT '{}'::jsonb,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      agent_id text,
      causation_id text,
      correlation_id text,
      event_timestamp timestamp(6) without time zone,
      operation_id text,
      operation_fingerprint text,
      created_at timestamp(6) without time zone NOT NULL
    )
    """)

    Postgrex.query!(admin, "CREATE SEQUENCE #{qualified}.events_global_position_seq")

    Postgrex.query!(admin, """
    CREATE TABLE #{qualified}.arbor_event_log_position_repair_batches (
      batch_id text PRIMARY KEY,
      event_count bigint NOT NULL,
      old_maximum bigint NOT NULL,
      status text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      applied_at timestamptz
    )
    """)

    Postgrex.query!(admin, """
    CREATE TABLE #{qualified}.arbor_event_log_position_repair_rows (
      event_id text PRIMARY KEY,
      batch_id text NOT NULL REFERENCES #{qualified}.arbor_event_log_position_repair_batches(batch_id),
      old_global_position bigint NOT NULL,
      proposed_global_position bigint NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
    """)

    Postgrex.query!(admin, """
    CREATE TABLE #{qualified}.arbor_event_log_identity_repair_batches (
      batch_id text PRIMARY KEY,
      expected_event_count bigint NOT NULL,
      staged_count bigint NOT NULL DEFAULT 0,
      source_backup_digest text NOT NULL,
      provenance_marker text NOT NULL,
      status text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      applied_at timestamptz
    )
    """)

    Postgrex.query!(admin, """
    CREATE TABLE #{qualified}.arbor_event_log_identity_repair_rows (
      event_id text PRIMARY KEY,
      batch_id text NOT NULL REFERENCES #{qualified}.arbor_event_log_identity_repair_batches(batch_id),
      operation_id text NOT NULL,
      operation_fingerprint text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
    """)
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

  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
