defmodule Arbor.Persistence.Repo.Migrations.CreateSessionsAndChannels do
  use Ecto.Migration

  def change do
    # ── Sessions: agent's private, append-only life log ──────────────
    create table(:sessions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :session_id, :text, null: false
      add :agent_id, :text, null: false
      add :status, :text, null: false, default: "active"
      add :model, :text
      add :cwd, :text
      add :git_branch, :text
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:session_id])
    create index(:sessions, [:agent_id])
    create index(:sessions, [:status])

    # ── Session entries: individual events (append-only) ─────────────
    create table(:session_entries, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :session_id, references(:sessions, type: :uuid, on_delete: :delete_all),
        null: false

      add :parent_entry_id, references(:session_entries, type: :uuid, on_delete: :nilify_all)
      add :entry_type, :text, null: false
      add :role, :text
      add :content, :map, null: false, default: fragment("'[]'::jsonb")
      add :model, :text
      add :stop_reason, :text
      add :token_usage, :map
      add :timestamp, :utc_datetime_usec, null: false, default: fragment("now()")
      add :metadata, :map, default: %{}
    end

    create index(:session_entries, [:session_id, :timestamp])
    create index(:session_entries, [:entry_type])

    # ── Channels: shared communication containers ────────────────────
    create table(:channels, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :channel_id, :text, null: false
      add :type, :text, null: false, default: "dm"
      add :name, :text
      add :owner_id, :text
      add :members, :map, default: fragment("'[]'::jsonb")
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channels, [:channel_id])

    # ── Channel messages ─────────────────────────────────────────────
    create table(:channel_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :channel_id, references(:channels, type: :uuid, on_delete: :delete_all),
        null: false

      add :sender_id, :text, null: false
      add :sender_name, :text
      add :sender_type, :text, default: "human"
      add :content, :text, null: false
      add :timestamp, :utc_datetime_usec, null: false, default: fragment("now()")
      add :metadata, :map, default: %{}
    end

    create index(:channel_messages, [:channel_id, :timestamp])
    create index(:channel_messages, [:sender_id])
  end
end
