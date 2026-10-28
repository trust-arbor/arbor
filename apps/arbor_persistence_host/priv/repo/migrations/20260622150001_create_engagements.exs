defmodule Arbor.Persistence.Repo.Migrations.CreateEngagements do
  use Ecto.Migration
  import Arbor.Persistence.MigrationHelper

  def change do
    uuid_gen = uuid_default()
    json_array = empty_json_array()

    # Engagements: device-independent conversations. Channels attach to one; a
    # Session keys its per-conversation transcript on (agent_id, engagement_id).
    # Adapter-portable column types only (SQLite3 / PostgreSQL via Repo config).
    create table(:engagements, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: uuid_gen)
      add(:engagement_id, :text, null: false)
      add(:agent_id, :text, null: false)
      add(:owner_tenant, :text)
      add(:scope, :text, null: false, default: "channel")
      add(:status, :text, null: false, default: "active")
      add(:visibility, :text, null: false, default: "private")
      # JSON array column (like channels.members) — portable across adapters.
      add(:attached_channels, :map, default: json_array)
      add(:primary_channel, :text)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:engagements, [:engagement_id]))
    create(index(:engagements, [:agent_id]))
    create(index(:engagements, [:agent_id, :status]))
  end
end
