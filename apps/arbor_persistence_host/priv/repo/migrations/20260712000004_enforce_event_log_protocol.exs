defmodule Arbor.Persistence.Repo.Migrations.EnforceEventLogProtocol do
  @moduledoc """
  Maintenance cutover for EventLog protocol epoch 3.

  PostgreSQL takes ACCESS EXCLUSIVE locks to drain every pre-cutover writer
  before installing the trigger. SQLite migrations already execute under its
  serialized schema-write transaction. After cutover, old binaries may remain
  online, but inserts without operation identity fail at the database boundary.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  @max_position 2_147_483_647
  @protocol_version 3

  def up do
    lock_legacy_writers!()
    flush()
    audit_legacy_events!()

    alter table(:events) do
      add(:operation_id, :string)
      add(:operation_fingerprint, :string)
    end

    create table(:event_log_protocol, primary_key: false) do
      add(:singleton, :boolean, primary_key: true)
      add(:protocol_version, :integer, null: false)
      add(:cutover_at, :utc_datetime_usec, null: false)
    end

    flush()

    if postgres?() do
      install_postgres_constraints!()
      install_postgres_fence_trigger!()

      execute("""
      INSERT INTO #{table_name("event_log_protocol")} (
        singleton, protocol_version, cutover_at
      ) VALUES (TRUE, #{@protocol_version}, clock_timestamp())
      """)
    else
      install_sqlite_fence_triggers!()

      execute("""
      INSERT INTO event_log_protocol (singleton, protocol_version, cutover_at)
      VALUES (1, #{@protocol_version}, STRFTIME('%Y-%m-%d %H:%M:%f', 'now'))
      """)
    end
  end

  def down do
    if postgres?() do
      execute(
        "DROP TRIGGER IF EXISTS events_event_log_protocol_insert ON #{table_name("events")}"
      )

      execute(
        "DROP FUNCTION IF EXISTS #{qualified_name("arbor_event_log_enforce_operation_fence")}()"
      )

      drop_if_exists(constraint(:events, :events_event_number_capacity, prefix: prefix()))

      drop_if_exists(constraint(:events, :events_global_position_capacity, prefix: prefix()))

      drop_if_exists(constraint(:events, :events_operation_identity_shape, prefix: prefix()))
    else
      execute("DROP TRIGGER IF EXISTS events_event_log_protocol_insert")
      execute("DROP TRIGGER IF EXISTS events_event_log_position_update")
    end

    drop(table(:event_log_protocol))

    alter table(:events) do
      remove(:operation_id)
      remove(:operation_fingerprint)
    end
  end

  defp lock_legacy_writers! do
    if postgres?() do
      execute(
        "LOCK TABLE #{table_name("events")}, #{table_name("event_log_operations")} " <>
          "IN ACCESS EXCLUSIVE MODE"
      )
    end
  end

  defp audit_legacy_events! do
    audit_invalid_positions!()
    audit_duplicate_global_positions!()
    audit_duplicate_stream_positions!()
    audit_global_sequence!()
    audit_stream_sequences!()
  end

  defp audit_invalid_positions! do
    result =
      repo().query!("""
      SELECT id, event_number, global_position
      FROM #{table_name("events")}
      WHERE event_number IS NULL
         OR event_number < 1
         OR event_number > #{@max_position}
         OR global_position IS NULL
         OR global_position < 1
         OR global_position > #{@max_position}
      LIMIT 1
      """)

    case result.rows do
      [] ->
        :ok

      [[id, event_number, global_position]] ->
        raise "cannot cut over EventLog protocol: event #{inspect(id)} has invalid positions " <>
                "event_number=#{inspect(event_number)} global_position=#{inspect(global_position)}"
    end
  end

  defp audit_duplicate_global_positions! do
    result =
      repo().query!("""
      SELECT global_position, COUNT(*)
      FROM #{table_name("events")}
      GROUP BY global_position
      HAVING COUNT(*) > 1
      LIMIT 1
      """)

    case result.rows do
      [] ->
        :ok

      [[position, count]] ->
        raise "cannot cut over EventLog protocol: global_position #{position} occurs #{count} times"
    end
  end

  defp audit_duplicate_stream_positions! do
    result =
      repo().query!("""
      SELECT stream_id, event_number, COUNT(*)
      FROM #{table_name("events")}
      GROUP BY stream_id, event_number
      HAVING COUNT(*) > 1
      LIMIT 1
      """)

    case result.rows do
      [] ->
        :ok

      [[stream_id, event_number, count]] ->
        raise "cannot cut over EventLog protocol: stream #{inspect(stream_id)} event_number " <>
                "#{event_number} occurs #{count} times"
    end
  end

  defp audit_global_sequence! do
    result =
      repo().query!("""
      SELECT MIN(global_position), MAX(global_position), COUNT(*), COUNT(DISTINCT global_position)
      FROM #{table_name("events")}
      """)

    case result.rows do
      [[nil, nil, 0, 0]] ->
        :ok

      [[1, maximum, count, count]] when maximum == count ->
        :ok

      [[minimum, maximum, count, distinct_count]] ->
        raise "cannot cut over EventLog protocol: global sequence is inconsistent " <>
                "min=#{inspect(minimum)} max=#{inspect(maximum)} count=#{count} " <>
                "distinct=#{distinct_count}"
    end
  end

  defp audit_stream_sequences! do
    result =
      repo().query!("""
      SELECT stream_id,
             MIN(event_number),
             MAX(event_number),
             COUNT(*),
             COUNT(DISTINCT event_number)
      FROM #{table_name("events")}
      GROUP BY stream_id
      HAVING MIN(event_number) <> 1
          OR MAX(event_number) <> COUNT(*)
          OR COUNT(*) <> COUNT(DISTINCT event_number)
      LIMIT 1
      """)

    case result.rows do
      [] ->
        :ok

      [[stream_id, minimum, maximum, count, distinct_count]] ->
        raise "cannot cut over EventLog protocol: stream #{inspect(stream_id)} sequence is " <>
                "inconsistent min=#{minimum} max=#{maximum} count=#{count} " <>
                "distinct=#{distinct_count}"
    end
  end

  defp install_postgres_constraints! do
    create(
      constraint(:events, :events_event_number_capacity,
        prefix: prefix(),
        check: "event_number >= 1 AND event_number <= #{@max_position}"
      )
    )

    create(
      constraint(:events, :events_global_position_capacity,
        prefix: prefix(),
        check:
          "global_position IS NOT NULL AND global_position >= 1 AND " <>
            "global_position <= #{@max_position}"
      )
    )

    create(
      constraint(:events, :events_operation_identity_shape,
        prefix: prefix(),
        check:
          "(operation_id IS NULL AND operation_fingerprint IS NULL) OR " <>
            "(operation_id IS NOT NULL AND operation_fingerprint ~ '^[0-9a-f]{64}$')"
      )
    )
  end

  defp install_postgres_fence_trigger! do
    execute("""
    CREATE FUNCTION #{qualified_name("arbor_event_log_enforce_operation_fence")}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      fence_status text;
    BEGIN
      IF NEW.operation_id IS NULL
         OR NEW.operation_fingerprint IS NULL
         OR NEW.operation_fingerprint !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'EventLog protocol identity is required after cutover'
          USING ERRCODE = '23514';
      END IF;

      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.operation_id, 1));

      SELECT status
      INTO fence_status
      FROM #{table_name("event_log_operations")}
      WHERE operation_id = NEW.operation_id;

      IF FOUND THEN
        RAISE EXCEPTION 'EventLog operation % is terminal (%)', NEW.operation_id, fence_status
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER events_event_log_protocol_insert
    BEFORE INSERT ON #{table_name("events")}
    FOR EACH ROW
    EXECUTE FUNCTION #{qualified_name("arbor_event_log_enforce_operation_fence")}()
    """)
  end

  defp install_sqlite_fence_triggers! do
    execute("""
    CREATE TRIGGER events_event_log_protocol_insert
    BEFORE INSERT ON events
    FOR EACH ROW
    BEGIN
      SELECT RAISE(ABORT, 'EventLog event_number is outside protocol capacity')
      WHERE NEW.event_number IS NULL
         OR NEW.event_number < 1
         OR NEW.event_number > #{@max_position};

      SELECT RAISE(ABORT, 'EventLog global_position is outside protocol capacity')
      WHERE NEW.global_position IS NULL
         OR NEW.global_position < 1
         OR NEW.global_position > #{@max_position};

      SELECT RAISE(ABORT, 'EventLog protocol identity is required after cutover')
      WHERE NEW.operation_id IS NULL
         OR NEW.operation_fingerprint IS NULL
         OR LENGTH(NEW.operation_fingerprint) <> 64
         OR NEW.operation_fingerprint <> LOWER(NEW.operation_fingerprint)
         OR NEW.operation_fingerprint GLOB '*[^0-9a-f]*';

      SELECT RAISE(ABORT, 'EventLog operation is terminal')
      WHERE EXISTS (
        SELECT 1
        FROM event_log_operations
        WHERE operation_id = NEW.operation_id
      );
    END
    """)

    execute("""
    CREATE TRIGGER events_event_log_position_update
    BEFORE UPDATE OF event_number, global_position ON events
    FOR EACH ROW
    BEGIN
      SELECT RAISE(ABORT, 'EventLog event_number is outside protocol capacity')
      WHERE NEW.event_number IS NULL
         OR NEW.event_number < 1
         OR NEW.event_number > #{@max_position};

      SELECT RAISE(ABORT, 'EventLog global_position is outside protocol capacity')
      WHERE NEW.global_position IS NULL
         OR NEW.global_position < 1
         OR NEW.global_position > #{@max_position};
    END
    """)
  end

  defp table_name(name), do: qualified_name(name)

  defp qualified_name(name) do
    case prefix() do
      nil -> quote_identifier(name)
      schema -> quote_identifier(schema) <> "." <> quote_identifier(name)
    end
  end

  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
