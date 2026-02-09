defmodule Arbor.Persistence.Repo.Migrations.AddAgentIdToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add :agent_id, :string
    end

    create index(:events, [:agent_id])
    create index(:events, [:agent_id, :stream_id])
    create index(:events, [:agent_id, :type])
  end
end
