defmodule Arbor.Persistence.Repo.Migrations.PrepareVectorStoreV1 do
  @moduledoc """
  Adds the nullable C3G vector authority columns and immutable receipt ledger.

  Existing memory rows and the legacy `(agent_id, content_hash)` uniqueness
  remain untouched. A later additive migration installs and backfills the
  backend-owned protocol discriminator before the vector-store adapter runs.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  def up do
    add_column_if_not_exists(:memory_embeddings, :source_namespace, :string, size: 128)
    add_column_if_not_exists(:memory_embeddings, :source_key, :string, size: 1_024)
    add_column_if_not_exists(:memory_embeddings, :canonical_payload, :text)
    add_column_if_not_exists(:memory_embeddings, :payload_digest, :string, size: 64)
    add_vector_768_if_missing()
    add_column_if_not_exists(:memory_embeddings, :vector_bytes, :binary)
    add_column_if_not_exists(:memory_embeddings, :vector_digest, :string, size: 64)
    add_column_if_not_exists(:memory_embeddings, :model_id, :string, size: 255)
    add_column_if_not_exists(:memory_embeddings, :dimensions, :integer)
    add_column_if_not_exists(:memory_embeddings, :encoding, :string, size: 32)
    add_column_if_not_exists(:memory_embeddings, :category, :string, size: 64)
    add_column_if_not_exists(:memory_embeddings, :generation, :bigint)
    add_column_if_not_exists(:memory_embeddings, :revision, :bigint)
    add_column_if_not_exists(:memory_embeddings, :tombstone, :boolean)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS memory_embeddings_vector_identity_index
    ON memory_embeddings (agent_id, source_namespace, source_key)
    WHERE source_namespace IS NOT NULL AND source_key IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS memory_embeddings_vector_list_index
    ON memory_embeddings (agent_id, tombstone, category, source_namespace, source_key)
    WHERE source_namespace IS NOT NULL
    """)

    if postgres?() do
      execute("""
      CREATE INDEX IF NOT EXISTS memory_embeddings_vector_768_hnsw_index
      ON memory_embeddings USING hnsw (vector_768 vector_cosine_ops)
      WHERE source_namespace IS NOT NULL AND tombstone = FALSE AND vector_768 IS NOT NULL
      """)
    end

    create table(:vector_operation_receipts, primary_key: false) do
      add(:operation_fingerprint, :string, size: 64, primary_key: true)
      add(:agent_id, :string, null: false)
      add(:operation_kind, :string, size: 16, null: false)
      add(:operation_json, :text, null: false)
      add(:operation_digest, :string, size: 64, null: false)
      add(:receipt_json, :text, null: false)
      add(:receipt_digest, :string, size: 64, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:vector_operation_receipts, [:agent_id, :inserted_at]))
    install_immutable_ledger_guards()
  end

  def down do
    raise """
    irreversible migration: vector-store V1 rows and immutable operation receipts may
    contain committed state; use a separately approved reversal migration
    """
  end

  defp add_vector_768_if_missing do
    unless column_exists?(:memory_embeddings, :vector_768) do
      if postgres?() do
        execute("ALTER TABLE memory_embeddings ADD COLUMN vector_768 vector(768)")
      else
        execute("ALTER TABLE memory_embeddings ADD COLUMN vector_768 TEXT")
      end
    end
  end

  defp install_immutable_ledger_guards do
    if postgres?() do
      execute("""
      CREATE OR REPLACE FUNCTION arbor_vector_receipt_ledger_immutable()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'vector_operation_receipts is immutable'
          USING ERRCODE = 'integrity_constraint_violation';
      END;
      $$ LANGUAGE plpgsql
      """)

      execute("""
      CREATE TRIGGER vector_operation_receipts_reject_mutation
      BEFORE UPDATE OR DELETE ON vector_operation_receipts
      FOR EACH ROW EXECUTE FUNCTION arbor_vector_receipt_ledger_immutable()
      """)
    else
      execute("""
      CREATE TRIGGER vector_operation_receipts_reject_update
      BEFORE UPDATE ON vector_operation_receipts
      FOR EACH ROW
      BEGIN
        SELECT RAISE(ABORT, 'vector_operation_receipts is immutable');
      END
      """)

      execute("""
      CREATE TRIGGER vector_operation_receipts_reject_delete
      BEFORE DELETE ON vector_operation_receipts
      FOR EACH ROW
      BEGIN
        SELECT RAISE(ABORT, 'vector_operation_receipts is immutable');
      END
      """)
    end
  end
end
