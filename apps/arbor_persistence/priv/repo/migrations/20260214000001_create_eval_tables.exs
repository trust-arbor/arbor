defmodule Arbor.Persistence.Repo.Migrations.CreateEvalTables do
  use Ecto.Migration

  def change do
    create table(:eval_runs, primary_key: false) do
      add(:id, :text, primary_key: true)
      add(:domain, :text, null: false)
      add(:model, :text, null: false)
      add(:provider, :text, null: false)
      add(:dataset, :text, null: false)
      add(:graders, {:array, :text}, null: false, default: [])
      add(:sample_count, :integer, null: false, default: 0)
      add(:duration_ms, :integer, null: false, default: 0)
      add(:metrics, :map, null: false, default: %{})
      add(:config, :map, null: false, default: %{})
      add(:status, :text, null: false, default: "running")
      add(:error, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:eval_runs, [:domain]))
    create(index(:eval_runs, [:model]))
    create(index(:eval_runs, [:provider]))
    create(index(:eval_runs, [:status]))
    create(index(:eval_runs, [:domain, :model]))
    create(index(:eval_runs, [:inserted_at]))

    create table(:eval_results, primary_key: false) do
      add(:id, :text, primary_key: true)

      add(:run_id, references(:eval_runs, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:sample_id, :text, null: false)
      add(:input, :text)
      add(:expected, :text)
      add(:actual, :text)
      add(:passed, :boolean, null: false, default: false)
      add(:scores, :map, null: false, default: %{})
      add(:duration_ms, :integer, null: false, default: 0)
      add(:ttft_ms, :integer)
      add(:tokens_generated, :integer)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:eval_results, [:run_id]))
    create(index(:eval_results, [:sample_id]))
    create(index(:eval_results, [:passed]))
    create(index(:eval_results, [:run_id, :passed]))
  end
end
