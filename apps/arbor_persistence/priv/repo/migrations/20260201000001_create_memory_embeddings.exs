defmodule Arbor.Persistence.Repo.Migrations.CreateMemoryEmbeddings do
  @moduledoc """
  Creates the memory_embeddings table for persistent vector storage.

  On PostgreSQL, uses pgvector extension for efficient similarity search.
  On SQLite, creates the table without vector columns — embedding search
  uses the ETS-based path instead.
  """

  use Ecto.Migration
  import Arbor.Persistence.MigrationHelper

  def up do
    if postgres?() do
      # Enable pgvector extension
      execute("CREATE EXTENSION IF NOT EXISTS vector")
    end

    create table(:memory_embeddings, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:agent_id, :string, null: false)
      add(:content, :text, null: false)
      add(:content_hash, :string, size: 64, null: false)
      add(:memory_type, :string, size: 50)
      add(:source, :string, size: 255)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    if postgres?() do
      # Vector column — 768 = nomic-embed-text (default), 1536 = OpenAI
      execute("ALTER TABLE memory_embeddings ADD COLUMN embedding vector(768) NOT NULL")
    else
      # SQLite: store embedding as JSON text for potential future sqlite-vec use
      # Embedding search currently uses the ETS-based path
      execute("ALTER TABLE memory_embeddings ADD COLUMN embedding TEXT")
    end

    create(index(:memory_embeddings, [:agent_id]))
    create(index(:memory_embeddings, [:agent_id, :memory_type]))
    create(unique_index(:memory_embeddings, [:agent_id, :content_hash]))

    if postgres?() do
      # HNSW index for approximate nearest neighbor search
      execute("""
      CREATE INDEX idx_memory_embeddings_vector
      ON memory_embeddings USING hnsw (embedding vector_cosine_ops)
      """)
    end
  end

  def down do
    drop(table(:memory_embeddings))
    # Don't drop the vector extension — other tables might use it
  end
end
