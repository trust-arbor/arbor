defmodule Arbor.Persistence.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:stream_id, :string, null: false)
      add(:event_number, :integer, null: false)
      add(:global_position, :bigint)
      add(:type, :string, null: false)
      add(:data, :map, default: %{})
      add(:metadata, :map, default: %{})
      add(:causation_id, :string)
      add(:correlation_id, :string)
      add(:event_timestamp, :utc_datetime_usec)

      add(:created_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    # Unique constraint on stream + event_number for optimistic concurrency
    # Also serves as the index for reading events by stream
    create(unique_index(:events, [:stream_id, :event_number]))

    # Index for global ordering
    create(index(:events, [:global_position]))

    # Index for correlation queries
    create(index(:events, [:correlation_id]))

    # Index for event type queries
    create(index(:events, [:type]))

    # Add a sequence for global_position
    execute(
      "CREATE SEQUENCE IF NOT EXISTS events_global_position_seq",
      "DROP SEQUENCE IF EXISTS events_global_position_seq"
    )
  end
end
