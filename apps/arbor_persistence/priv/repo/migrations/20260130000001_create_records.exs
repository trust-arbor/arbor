defmodule Arbor.Persistence.Repo.Migrations.CreateRecords do
  use Ecto.Migration

  def change do
    create table(:records, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:namespace, :text, null: false)
      add(:key, :text, null: false)
      add(:data, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    # Primary lookup: get by namespace + key
    create(unique_index(:records, [:namespace, :key]))

    # List/filter within a namespace
    create(index(:records, [:namespace]))

    # Time-range queries scoped by namespace
    create(index(:records, [:namespace, :inserted_at]))
    create(index(:records, [:namespace, :updated_at]))

    # JSONB queries on data (GIN index for containment queries)
    create(index(:records, [:data], using: "GIN"))

    # JSONB queries on metadata
    create(index(:records, [:metadata], using: "GIN"))
  end
end
