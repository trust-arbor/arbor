defmodule Arbor.Persistence.Repo.Migrations.AddEventCommittedAt do
  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  def up do
    alter table(:events) do
      add(:committed_at, :utc_datetime_usec)
    end

    flush()

    if postgres?() do
      alter table(:events) do
        modify(:committed_at, :utc_datetime_usec, default: fragment("clock_timestamp()"))
      end
    else
      # SQLite cannot ALTER COLUMN to add a non-constant expression default.
      # Keep the column nullable at the DDL level and make insertion authority a
      # database trigger instead. Legacy rows remain null on both adapters so a
      # migration can never renew an old stream; the EventLog treats them stale.
      execute(
        """
        CREATE TRIGGER events_set_committed_at_after_insert
        AFTER INSERT ON events
        FOR EACH ROW
        BEGIN
          UPDATE events
          SET committed_at = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
          WHERE id = NEW.id;
        END
        """,
        "DROP TRIGGER IF EXISTS events_set_committed_at_after_insert"
      )
    end
  end

  def down do
    if sqlite?() do
      execute("DROP TRIGGER IF EXISTS events_set_committed_at_after_insert")
    end

    alter table(:events) do
      remove(:committed_at)
    end
  end
end
