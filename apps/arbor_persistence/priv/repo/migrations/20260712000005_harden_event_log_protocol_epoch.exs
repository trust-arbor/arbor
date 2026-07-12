defmodule Arbor.Persistence.Repo.Migrations.HardenEventLogProtocolEpoch do
  @moduledoc """
  Hardens the epoch-3 EventLog cutover for already-migrated databases.

  The PostgreSQL lock drains inserts using the R3 trigger before replacing it.
  Both adapters then reject event inserts unless exactly one epoch-3 row is
  present. PostgreSQL constraints prevent the valid singleton from drifting;
  the trigger remains the database-boundary defense for old and raw writers.

  Legacy events with a NULL operation fingerprint are intentionally not
  backfilled from their current payload. PostgreSQL records that remediation
  debt as a NOT VALID constraint: it blocks new NULL fingerprints while
  allowing an operator to restore trusted historical fingerprints and validate
  the constraint afterward.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  @protocol_version 3
  @max_position 2_147_483_647

  def up do
    lock_r3_writers!()
    flush()
    verify_protocol_epoch!()

    if postgres?() do
      install_postgres_protocol_constraints!()
      install_postgres_fingerprint_remediation_constraint!()
      replace_postgres_fence_trigger!()
    else
      replace_sqlite_fence_trigger!()
    end
  end

  def down do
    if postgres?() do
      restore_postgres_r3_fence_trigger!()

      execute(
        "ALTER TABLE #{postgres_table_name("events")} " <>
          "DROP CONSTRAINT IF EXISTS events_operation_fingerprint_present"
      )

      execute(
        "ALTER TABLE #{postgres_table_name("event_log_protocol")} " <>
          "DROP CONSTRAINT IF EXISTS event_log_protocol_singleton_true"
      )

      execute(
        "ALTER TABLE #{postgres_table_name("event_log_protocol")} " <>
          "DROP CONSTRAINT IF EXISTS event_log_protocol_version_3"
      )
    else
      restore_sqlite_r3_fence_trigger!()
    end
  end

  defp lock_r3_writers! do
    if postgres?() do
      execute(
        "LOCK TABLE #{postgres_table_name("events")}, " <>
          "#{postgres_table_name("event_log_operations")}, " <>
          "#{postgres_table_name("event_log_protocol")} IN ACCESS EXCLUSIVE MODE"
      )
    end
  end

  defp verify_protocol_epoch! do
    protocol_table =
      if postgres?(),
        do: postgres_table_name("event_log_protocol"),
        else: table_name("event_log_protocol")

    rows =
      repo()
      |> then(& &1.query!("SELECT singleton, protocol_version FROM #{protocol_table}"))
      |> Map.fetch!(:rows)

    unless rows in [[[true, @protocol_version]], [[1, @protocol_version]]] do
      raise "cannot harden EventLog protocol: expected exactly one epoch-3 cutover row"
    end
  end

  defp install_postgres_protocol_constraints! do
    execute(
      "ALTER TABLE #{postgres_table_name("event_log_protocol")} " <>
        "ADD CONSTRAINT event_log_protocol_singleton_true CHECK (singleton IS TRUE)"
    )

    execute(
      "ALTER TABLE #{postgres_table_name("event_log_protocol")} " <>
        "ADD CONSTRAINT event_log_protocol_version_3 " <>
        "CHECK (protocol_version = #{@protocol_version})"
    )
  end

  defp install_postgres_fingerprint_remediation_constraint! do
    execute(
      "ALTER TABLE #{postgres_table_name("events")} " <>
        "ADD CONSTRAINT events_operation_fingerprint_present " <>
        "CHECK (operation_fingerprint IS NOT NULL) NOT VALID"
    )

    execute("""
    COMMENT ON CONSTRAINT events_operation_fingerprint_present
    ON #{postgres_table_name("events")}
    IS 'Legacy NULL operation fingerprints require trusted-source remediation and must not be recomputed from the current event payload.'
    """)
  end

  defp replace_postgres_fence_trigger! do
    execute(postgres_fence_function(true))
  end

  defp restore_postgres_r3_fence_trigger! do
    execute(postgres_fence_function(false))
  end

  defp postgres_fence_function(verify_epoch?) do
    epoch_declarations =
      if verify_epoch?,
        do: "protocol_rows bigint;\n  matching_protocol_rows bigint;",
        else: ""

    epoch_check =
      if verify_epoch? do
        """
          SELECT COUNT(*),
                 COUNT(*) FILTER (
                   WHERE singleton IS TRUE AND protocol_version = #{@protocol_version}
                 )
          INTO protocol_rows, matching_protocol_rows
          FROM #{postgres_table_name("event_log_protocol")};

          IF protocol_rows IS DISTINCT FROM 1
             OR matching_protocol_rows IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'EventLog protocol epoch is unavailable'
              USING ERRCODE = '23514';
          END IF;

        """
      else
        ""
      end

    """
    CREATE OR REPLACE FUNCTION #{postgres_qualified_name("arbor_event_log_enforce_operation_fence")}()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      fence_status text;
      #{epoch_declarations}
    BEGIN
    #{epoch_check}  IF NEW.operation_id IS NULL
         OR NEW.operation_fingerprint IS NULL
         OR NEW.operation_fingerprint !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'EventLog protocol identity is required after cutover'
          USING ERRCODE = '23514';
      END IF;

      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.operation_id, 1));

      SELECT status
      INTO fence_status
      FROM #{postgres_table_name("event_log_operations")}
      WHERE operation_id = NEW.operation_id;

      IF FOUND THEN
        RAISE EXCEPTION 'EventLog operation % is terminal (%)', NEW.operation_id, fence_status
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END
    $$
    """
  end

  defp replace_sqlite_fence_trigger! do
    execute("DROP TRIGGER events_event_log_protocol_insert")
    execute(sqlite_fence_trigger(true))
  end

  defp restore_sqlite_r3_fence_trigger! do
    execute("DROP TRIGGER events_event_log_protocol_insert")
    execute(sqlite_fence_trigger(false))
  end

  defp sqlite_fence_trigger(verify_epoch?) do
    epoch_check =
      if verify_epoch? do
        """
          SELECT RAISE(ABORT, 'EventLog protocol epoch is unavailable')
          WHERE (SELECT COUNT(*) FROM event_log_protocol) <> 1
             OR (SELECT COUNT(*)
                 FROM event_log_protocol
                 WHERE singleton = 1 AND protocol_version = #{@protocol_version}) <> 1;

        """
      else
        ""
      end

    """
    CREATE TRIGGER events_event_log_protocol_insert
    BEFORE INSERT ON events
    FOR EACH ROW
    BEGIN
    #{epoch_check}  SELECT RAISE(ABORT, 'EventLog event_number is outside protocol capacity')
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
    """
  end

  defp table_name(name), do: qualified_name(name)

  defp postgres_table_name(name), do: postgres_qualified_name(name)

  defp postgres_qualified_name(name) do
    schema =
      case prefix() do
        nil -> repo().query!("SELECT current_schema()").rows |> hd() |> hd()
        configured -> configured
      end

    quote_identifier(schema) <> "." <> quote_identifier(name)
  end

  defp qualified_name(name) do
    case prefix() do
      nil -> quote_identifier(name)
      schema -> quote_identifier(schema) <> "." <> quote_identifier(name)
    end
  end

  defp quote_identifier(identifier),
    do: ~s("#{String.replace(identifier, "\"", "\"\"")}")
end
