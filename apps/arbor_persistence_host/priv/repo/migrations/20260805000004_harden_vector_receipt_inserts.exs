defmodule Arbor.Persistence.Repo.Migrations.HardenVectorReceiptInserts do
  @moduledoc """
  Makes SQLite receipt immutability independent of connection PRAGMAs.

  SQLite's `INSERT OR REPLACE` can suppress delete triggers when
  `recursive_triggers` is disabled. The insert guard observes the existing row
  before conflict replacement and rejects every non-identical value. Exact
  idempotent inserts remain compatible with `ON CONFLICT DO NOTHING`.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  def up do
    unless postgres?() do
      execute("""
      CREATE TRIGGER IF NOT EXISTS vector_operation_receipts_reject_conflicting_insert
      BEFORE INSERT ON vector_operation_receipts
      FOR EACH ROW
      WHEN EXISTS (
        SELECT 1
        FROM vector_operation_receipts AS existing
        WHERE existing.operation_fingerprint = NEW.operation_fingerprint
          AND NOT (
            existing.agent_id IS NEW.agent_id
            AND existing.operation_kind IS NEW.operation_kind
            AND existing.operation_json IS NEW.operation_json
            AND existing.operation_digest IS NEW.operation_digest
            AND existing.receipt_json IS NEW.receipt_json
            AND existing.receipt_digest IS NEW.receipt_digest
            AND existing.inserted_at IS NEW.inserted_at
          )
      )
      BEGIN
        SELECT RAISE(ABORT, 'vector_operation_receipts is immutable');
      END
      """)
    end
  end

  def down do
    raise """
    irreversible migration: removing the receipt insert guard would reopen an
    immutable-ledger bypass on SQLite connections with recursive triggers disabled
    """
  end
end
