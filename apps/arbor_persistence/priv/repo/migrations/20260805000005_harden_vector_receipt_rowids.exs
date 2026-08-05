defmodule Arbor.Persistence.Repo.Migrations.HardenVectorReceiptRowids do
  @moduledoc """
  Protects both SQLite uniqueness identities of the immutable receipt ledger.

  `vector_operation_receipts` is rowid-backed, so an explicit rowid can be the
  conflict target of `INSERT OR REPLACE` even when the incoming fingerprint is
  new. The replacement guard must therefore match both the logical primary key
  and the hidden rowid, then compare every immutable field including the
  fingerprint.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  def up do
    unless postgres?() do
      execute("DROP TRIGGER IF EXISTS vector_operation_receipts_reject_conflicting_insert")

      execute("""
      CREATE TRIGGER vector_operation_receipts_reject_conflicting_insert
      BEFORE INSERT ON vector_operation_receipts
      FOR EACH ROW
      WHEN EXISTS (
        SELECT 1
        FROM vector_operation_receipts AS existing
        WHERE (
          existing.operation_fingerprint = NEW.operation_fingerprint
          OR existing.rowid = NEW.rowid
        )
          AND NOT (
            existing.operation_fingerprint IS NEW.operation_fingerprint
            AND existing.agent_id IS NEW.agent_id
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
    irreversible migration: removing the rowid receipt guard would reopen an
    immutable-ledger bypass on SQLite connections with recursive triggers disabled
    """
  end
end
