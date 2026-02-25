defmodule Arbor.Persistence.Repo.Migrations.AddVectorscaleDiskann do
  @moduledoc """
  Enables pgvectorscale and replaces the HNSW index with DiskANN.

  PostgreSQL only — skips gracefully on SQLite.
  Also handles the case where vectorscale extension isn't installed
  on Postgres (keeps HNSW index as fallback).
  """

  use Ecto.Migration
  import Arbor.Persistence.MigrationHelper

  def up do
    # Skip entirely on SQLite — no vector indexes needed
    if postgres?() do
      # Try to enable vectorscale — skip gracefully if not installed
      case repo().query("CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE") do
        {:ok, _} ->
          # Drop existing HNSW index
          execute("DROP INDEX IF EXISTS idx_memory_embeddings_vector")

          # Create DiskANN index (same operator class, different access method)
          execute("""
          CREATE INDEX idx_memory_embeddings_vector
          ON memory_embeddings USING diskann (embedding vector_cosine_ops)
          """)

        {:error, _} ->
          # vectorscale not available — keep existing HNSW index
          IO.puts("[migration] vectorscale extension not available, keeping HNSW index")
      end
    end
  end

  def down do
    if postgres?() do
      # Revert to HNSW index
      execute("DROP INDEX IF EXISTS idx_memory_embeddings_vector")

      execute("""
      CREATE INDEX idx_memory_embeddings_vector
      ON memory_embeddings USING hnsw (embedding vector_cosine_ops)
      """)

      # Don't drop vectorscale extension — other tables might use it
    end
  end
end
