defmodule Arbor.Persistence.Repo.Migrations.CreateEventLogOperations do
  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  def up do
    create table(:event_log_operations, primary_key: false) do
      add(:operation_id, :string, primary_key: true)
      add(:stream_id, :string, null: false)
      add(:identity, :map, null: false)
      add(:status, :string, null: false)
      add(:reason, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:event_log_operations, [:status, :inserted_at]))

    if postgres?() do
      create(
        constraint(:event_log_operations, :event_log_operations_terminal_status,
          check: "status IN ('committed', 'aborted', 'conflict')"
        )
      )
    end
  end

  def down do
    drop(table(:event_log_operations))
  end
end
