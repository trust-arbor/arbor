defmodule Arbor.Persistence.Repo.Migrations.CreateTelemetryEvents do
  use Ecto.Migration
  import Arbor.Persistence.MigrationHelper

  def change do
    create table(:telemetry_events, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:agent_id, :text, null: false)
      add(:event_type, :text, null: false)
      add(:timestamp, :utc_datetime_usec, null: false)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:telemetry_events, [:agent_id]))
    create(index(:telemetry_events, [:event_type]))
    create(index(:telemetry_events, [:timestamp]))
    create(index(:telemetry_events, [:agent_id, :timestamp]))
  end
end
