defmodule Arbor.Persistence.Repo.Migrations.IsolateVectorStoreV1Rows do
  @moduledoc """
  Adds the backend-owned discriminator that isolates vector-store V1 rows.

  Any row with staged V1 state is classified as V1 during backfill. Legacy
  memory operations only admit rows with both a null protocol and a null
  source namespace.

  Reversal requires a separately reviewed migration because removing this
  marker would expose V1 rows to destructive legacy operations.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  @vector_protocol "arbor_vector_store_v1"

  def up do
    add_column_if_not_exists(:memory_embeddings, :vector_protocol, :string, size: 32)

    execute("""
    UPDATE memory_embeddings
    SET vector_protocol = '#{@vector_protocol}'
    WHERE vector_protocol IS NULL
      AND (
        source_namespace IS NOT NULL OR
        source_key IS NOT NULL OR
        canonical_payload IS NOT NULL OR
        payload_digest IS NOT NULL OR
        vector_768 IS NOT NULL OR
        vector_bytes IS NOT NULL OR
        vector_digest IS NOT NULL OR
        model_id IS NOT NULL OR
        dimensions IS NOT NULL OR
        encoding IS NOT NULL OR
        category IS NOT NULL OR
        generation IS NOT NULL OR
        revision IS NOT NULL OR
        tombstone IS NOT NULL
      )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS memory_embeddings_legacy_protocol_index
    ON memory_embeddings (agent_id, id)
    WHERE vector_protocol IS NULL AND source_namespace IS NULL
    """)
  end

  def down do
    raise """
    irreversible migration: vector_protocol isolates committed V1 vector rows from
    destructive legacy memory operations; use a separately approved reversal migration
    """
  end
end
