defmodule Arbor.Persistence.Repo.Migrations.CreateSkills do
  use Ecto.Migration

  def change do
    create table(:skills, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text, null: false)
      add(:body, :text, default: "")
      add(:tags, {:array, :text}, default: [])
      add(:category, :text)
      add(:source, :text, default: "skill")
      add(:path, :text)
      add(:license, :text)
      add(:compatibility, :text)
      add(:allowed_tools, {:array, :text}, default: [])
      add(:content_hash, :text, null: false)
      add(:taint, :text, default: "trusted")
      add(:provenance, :map, default: %{})
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:skills, [:name]))
    create(index(:skills, [:category]))
    create(index(:skills, [:taint]))

    # Full-text search: tsvector column updated via trigger
    # (to_tsvector with 'english' config is STABLE, not IMMUTABLE,
    # so GENERATED ALWAYS doesn't work — use trigger instead)
    execute(
      "ALTER TABLE skills ADD COLUMN searchable tsvector",
      "ALTER TABLE skills DROP COLUMN IF EXISTS searchable"
    )

    create(index(:skills, [:searchable], using: :gin))

    # Create the trigger function for tsvector updates
    execute(
      """
      CREATE OR REPLACE FUNCTION skills_searchable_trigger() RETURNS trigger AS $$
      BEGIN
        NEW.searchable :=
          setweight(to_tsvector('english', coalesce(NEW.name, '')), 'A') ||
          setweight(to_tsvector('english', coalesce(NEW.description, '')), 'B') ||
          setweight(to_tsvector('english', coalesce(array_to_string(NEW.tags, ' '), '')), 'C') ||
          setweight(to_tsvector('english', coalesce(NEW.body, '')), 'D');
        RETURN NEW;
      END
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION IF EXISTS skills_searchable_trigger()"
    )

    execute(
      """
      CREATE TRIGGER skills_searchable_update
      BEFORE INSERT OR UPDATE ON skills
      FOR EACH ROW EXECUTE FUNCTION skills_searchable_trigger()
      """,
      "DROP TRIGGER IF EXISTS skills_searchable_update ON skills"
    )

    # Semantic search: pgvector embedding column with DiskANN index
    execute(
      "ALTER TABLE skills ADD COLUMN embedding vector(768)",
      "ALTER TABLE skills DROP COLUMN IF EXISTS embedding"
    )

    execute(
      """
      CREATE INDEX skills_embedding_diskann_idx ON skills
      USING diskann (embedding)
      WHERE embedding IS NOT NULL
      """,
      "DROP INDEX IF EXISTS skills_embedding_diskann_idx"
    )
  end
end
