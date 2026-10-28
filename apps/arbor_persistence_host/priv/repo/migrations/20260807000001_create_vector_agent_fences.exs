defmodule Arbor.Persistence.Repo.Migrations.CreateVectorAgentFences do
  @moduledoc """
  Durable per-agent strict-vector fence with open/destroying/closed states.

  Backfills open fences for distinct non-null agents already represented by
  strict V1 rows or vector operation receipts. Installs exact-tenant receipt
  insert/delete admission predicates. PostgreSQL insert admission takes
  FOR KEY SHARE on the exact fence row inside the trigger.

  This is a new security authority: table and trigger creation fails closed on
  collisions with pre-existing objects (no IF NOT EXISTS, no unscoped repair).
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  @vector_protocol "arbor_vector_store_v1"

  def up do
    create_fence_table()
    backfill_open_fences()
    install_receipt_fence_guards()
  end

  def down do
    raise """
    irreversible migration: vector_agent_fences and receipt fence admission guards
    protect closed-tenant strict vector destruction; use a separately approved
    reversal migration
    """
  end

  defp create_fence_table do
    if postgres?() do
      execute("""
      CREATE TABLE vector_agent_fences (
        agent_id varchar(256) PRIMARY KEY,
        state varchar(16) NOT NULL,
        closed_at timestamp(6) without time zone,
        updated_at timestamp(6) without time zone NOT NULL,
        CONSTRAINT vector_agent_fences_state_check
          CHECK (state IN ('open', 'destroying', 'closed')),
        CONSTRAINT vector_agent_fences_closed_at_coherent
          CHECK (
            (state = 'closed' AND closed_at IS NOT NULL) OR
            (state IN ('open', 'destroying') AND closed_at IS NULL)
          ),
        CONSTRAINT vector_agent_fences_agent_id_bytes_check
          CHECK (
            octet_length(agent_id) > 0
            AND octet_length(agent_id) <= 256
            AND btrim(agent_id) <> ''
          )
      )
      """)
    else
      execute("""
      CREATE TABLE vector_agent_fences (
        agent_id TEXT PRIMARY KEY NOT NULL,
        state TEXT NOT NULL,
        closed_at TEXT,
        updated_at TEXT NOT NULL,
        CHECK (state IN ('open', 'destroying', 'closed')),
        CHECK (
          (state = 'closed' AND closed_at IS NOT NULL) OR
          (state IN ('open', 'destroying') AND closed_at IS NULL)
        ),
        CHECK (
          length(CAST(agent_id AS BLOB)) > 0
          AND length(CAST(agent_id AS BLOB)) <= 256
          AND trim(agent_id) <> ''
        )
      )
      """)
    end
  end

  defp backfill_open_fences do
    if postgres?() do
      execute("""
      INSERT INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      SELECT DISTINCT agents.agent_id, 'open',
             NULL::timestamp(6) without time zone, CURRENT_TIMESTAMP
      FROM (
        SELECT agent_id
        FROM memory_embeddings
        WHERE vector_protocol = '#{@vector_protocol}'
          AND agent_id IS NOT NULL
        UNION
        SELECT agent_id
        FROM vector_operation_receipts
        WHERE agent_id IS NOT NULL
      ) AS agents
      ON CONFLICT (agent_id) DO NOTHING
      """)
    else
      execute("""
      INSERT OR IGNORE INTO vector_agent_fences (agent_id, state, closed_at, updated_at)
      SELECT DISTINCT agents.agent_id, 'open', NULL, CURRENT_TIMESTAMP
      FROM (
        SELECT agent_id
        FROM memory_embeddings
        WHERE vector_protocol = '#{@vector_protocol}'
          AND agent_id IS NOT NULL
        UNION
        SELECT agent_id
        FROM vector_operation_receipts
        WHERE agent_id IS NOT NULL
      ) AS agents
      """)
    end
  end

  defp install_receipt_fence_guards do
    if postgres?() do
      install_postgres_receipt_fence_guards()
    else
      install_sqlite_receipt_fence_guards()
    end
  end

  defp install_postgres_receipt_fence_guards do
    execute("""
    DROP TRIGGER IF EXISTS vector_operation_receipts_reject_mutation
    ON vector_operation_receipts
    """)

    execute("""
    CREATE FUNCTION arbor_vector_receipt_ledger_immutable_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'vector_operation_receipts is immutable'
        USING ERRCODE = 'integrity_constraint_violation';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE FUNCTION arbor_vector_receipt_delete_admit()
    RETURNS trigger AS $$
    DECLARE
      fence_state text;
    BEGIN
      EXECUTE format(
        'SELECT state FROM %I.vector_agent_fences WHERE agent_id = $1 FOR KEY SHARE',
        TG_TABLE_SCHEMA
      )
      INTO fence_state
      USING OLD.agent_id;

      IF fence_state IS DISTINCT FROM 'destroying' THEN
        RAISE EXCEPTION 'vector_operation_receipts is immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE FUNCTION arbor_vector_receipt_insert_admit()
    RETURNS trigger AS $$
    DECLARE
      fence_open boolean;
    BEGIN
      EXECUTE format(
        'SELECT state = $2 FROM %I.vector_agent_fences WHERE agent_id = $1 FOR KEY SHARE',
        TG_TABLE_SCHEMA
      )
      INTO fence_open
      USING NEW.agent_id, 'open';

      IF fence_open IS NOT TRUE THEN
        RAISE EXCEPTION 'vector_operation_receipts insert rejected: fence not open'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER vector_operation_receipts_reject_update
    BEFORE UPDATE ON vector_operation_receipts
    FOR EACH ROW EXECUTE FUNCTION arbor_vector_receipt_ledger_immutable_update()
    """)

    execute("""
    CREATE TRIGGER vector_operation_receipts_admit_delete
    BEFORE DELETE ON vector_operation_receipts
    FOR EACH ROW EXECUTE FUNCTION arbor_vector_receipt_delete_admit()
    """)

    execute("""
    CREATE TRIGGER vector_operation_receipts_admit_insert
    BEFORE INSERT ON vector_operation_receipts
    FOR EACH ROW EXECUTE FUNCTION arbor_vector_receipt_insert_admit()
    """)
  end

  defp install_sqlite_receipt_fence_guards do
    execute("DROP TRIGGER IF EXISTS vector_operation_receipts_reject_delete")

    execute("""
    CREATE TRIGGER vector_operation_receipts_admit_delete
    BEFORE DELETE ON vector_operation_receipts
    FOR EACH ROW
    WHEN NOT EXISTS (
      SELECT 1
      FROM vector_agent_fences AS fence
      WHERE fence.agent_id = OLD.agent_id
        AND fence.state = 'destroying'
    )
    BEGIN
      SELECT RAISE(ABORT, 'vector_operation_receipts is immutable');
    END
    """)

    execute("""
    CREATE TRIGGER vector_operation_receipts_admit_insert
    BEFORE INSERT ON vector_operation_receipts
    FOR EACH ROW
    WHEN NOT EXISTS (
      SELECT 1
      FROM vector_agent_fences AS fence
      WHERE fence.agent_id = NEW.agent_id
        AND fence.state = 'open'
    )
    BEGIN
      SELECT RAISE(ABORT, 'vector_operation_receipts insert rejected: fence not open');
    END
    """)
  end
end
