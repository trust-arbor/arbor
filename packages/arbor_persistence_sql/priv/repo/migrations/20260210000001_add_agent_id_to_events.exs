defmodule Arbor.Persistence.SQL.Repo.Migrations.AddAgentIdToEvents do
  use Ecto.Migration
  # Standard Ecto — works on both Postgres and SQLite without changes

  def change do
    alter table(:events) do
      add :agent_id, :string
    end

    create index(:events, [:agent_id])
    create index(:events, [:agent_id, :stream_id])
    create index(:events, [:agent_id, :type])
  end
end
