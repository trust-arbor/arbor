defmodule Arbor.Persistence.Repo.Migrations.CreateRelationships do
  use Ecto.Migration

  def change do
    create table(:memory_relationships, primary_key: false) do
      add :id, :text, primary_key: true
      add :agent_id, :text, null: false
      add :name, :text, null: false
      add :preferred_name, :text
      add :background, {:array, :text}, null: false, default: []
      add :values, {:array, :text}, null: false, default: []
      add :connections, {:array, :text}, null: false, default: []
      add :key_moments, :jsonb, null: false, default: "[]"
      add :relationship_dynamic, :text
      add :personal_details, {:array, :text}, null: false, default: []
      add :current_focus, {:array, :text}, null: false, default: []
      add :uncertainties, {:array, :text}, null: false, default: []
      add :first_encountered, :utc_datetime_usec
      add :last_interaction, :utc_datetime_usec
      add :salience, :float, null: false, default: 0.5
      add :access_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # Primary lookup: get by agent_id + name
    create unique_index(:memory_relationships, [:agent_id, :name])

    # List relationships for an agent
    create index(:memory_relationships, [:agent_id])

    # Sort by salience (most important relationships first)
    create index(:memory_relationships, [:agent_id, :salience])

    # Sort by last_interaction (most recent relationships first)
    create index(:memory_relationships, [:agent_id, :last_interaction])

    # JSONB queries on key_moments (GIN index for containment queries)
    create index(:memory_relationships, [:key_moments], using: "GIN")
  end
end
