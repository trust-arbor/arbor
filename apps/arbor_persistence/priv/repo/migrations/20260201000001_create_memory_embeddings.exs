defmodule Arbor.Persistence.Repo.Migrations.CreateMemoryEmbeddings do
  @moduledoc """
  Creates the memory_embeddings table for persistent vector storage.

  Uses pgvector extension for efficient similarity search.
  """

  use Ecto.Migration

  def up do
    # Enable pgvector extension
    execute("CREATE EXTENSION IF NOT EXISTS vector")

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

    # Vector column — hardcoded dimension in migration (migrations are historical records).
    # If dimension needs to change, create a new migration.
    # 768 = nomic-embed-text (default), 1536 = OpenAI
    execute("ALTER TABLE memory_embeddings ADD COLUMN embedding vector(768) NOT NULL")

    create(index(:memory_embeddings, [:agent_id]))
    create(index(:memory_embeddings, [:agent_id, :memory_type]))
    create(unique_index(:memory_embeddings, [:agent_id, :content_hash]))

    # HNSW index for approximate nearest neighbor search
    # (HNSW works on empty tables, unlike IVFFlat which requires data)
    execute("""
    CREATE INDEX idx_memory_embeddings_vector
    ON memory_embeddings USING hnsw (embedding vector_cosine_ops)
    """)
  end

  def down do
    drop(table(:memory_embeddings))
    # Don't drop the vector extension — other tables might use it
  end
end
