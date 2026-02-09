defmodule Arbor.Persistence.Repo.Migrations.AddVectorscaleDiskann do
  @moduledoc """
  Enables pgvectorscale and replaces the HNSW index with DiskANN.

  DiskANN provides significantly better performance at scale:
  - Lower latency for approximate nearest neighbor queries
  - Better memory efficiency (disk-based vs memory-resident)
  - Supports concurrent index builds

  The DiskANN index is a drop-in replacement — query syntax is unchanged,
  only the access method differs.
  """

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE")

    # Drop existing HNSW index
    execute("DROP INDEX IF EXISTS idx_memory_embeddings_vector")

    # Create DiskANN index (same operator class, different access method)
    execute("""
    CREATE INDEX idx_memory_embeddings_vector
    ON memory_embeddings USING diskann (embedding vector_cosine_ops)
    """)
  end

  def down do
    # Revert to HNSW index
    execute("DROP INDEX IF EXISTS idx_memory_embeddings_vector")

    execute("""
    CREATE INDEX idx_memory_embeddings_vector
    ON memory_embeddings USING hnsw (embedding vector_cosine_ops)
    """)

    # Don't drop vectorscale extension — other tables might use it
  end
end
