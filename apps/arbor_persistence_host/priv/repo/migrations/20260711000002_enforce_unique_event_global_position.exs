defmodule Arbor.Persistence.Repo.Migrations.EnforceUniqueEventGlobalPosition do
  use Ecto.Migration

  def up do
    audit_global_positions!()

    drop_if_exists(index(:events, [:global_position], name: :events_global_position_index))
    create(unique_index(:events, [:global_position], name: :events_global_position_index))
  end

  def down do
    drop_if_exists(index(:events, [:global_position], name: :events_global_position_index))
    create(index(:events, [:global_position], name: :events_global_position_index))
  end

  defp audit_global_positions! do
    result =
      repo().query!("""
      SELECT global_position, COUNT(*)
      FROM events
      WHERE global_position IS NOT NULL
      GROUP BY global_position
      HAVING COUNT(*) > 1
      LIMIT 1
      """)

    case result.rows do
      [] ->
        :ok

      [[position, count]] ->
        raise "cannot enforce unique EventLog global ordering: " <>
                "global_position #{position} occurs #{count} times; repair the duplicate rows explicitly"
    end
  end
end
