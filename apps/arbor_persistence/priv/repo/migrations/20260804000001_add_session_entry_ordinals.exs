defmodule Arbor.Persistence.Repo.Migrations.AddSessionEntryOrdinals do
  @moduledoc """
  Add a durable, per-session ordering key to session entries.

  Existing entries are ranked by timestamp and UUID before the column becomes
  non-null. New appends allocate ordinals under the session-row lock in the
  persistence boundary.
  """

  use Ecto.Migration

  import Arbor.Persistence.MigrationHelper

  @index_name :session_entries_session_id_entry_ordinal_index

  def up do
    if postgres?() do
      execute("ALTER TABLE session_entries ADD COLUMN entry_ordinal BIGINT")
    else
      execute("ALTER TABLE session_entries ADD COLUMN entry_ordinal INTEGER")
    end

    execute("UPDATE session_entries SET entry_ordinal = NULL")

    backfill_entry_ordinals!()

    if postgres?() do
      execute("ALTER TABLE session_entries ALTER COLUMN entry_ordinal SET NOT NULL")
    else
      rebuild_sqlite_table!()
    end

    create(unique_index(:session_entries, [:session_id, :entry_ordinal], name: @index_name))
  end

  def down do
    drop(index(:session_entries, [:session_id, :entry_ordinal], name: @index_name))

    execute("ALTER TABLE session_entries DROP COLUMN entry_ordinal")
  end

  defp rebuild_sqlite_table! do
    # SQLite cannot ALTER COLUMN. Build the same table with the final NOT NULL
    # definition, copy the already-ranked rows, then restore the original
    # table name and indexes. Deferred foreign-key checks allow parent entries
    # to be copied in UUID order without changing their logical relationships.
    execute("PRAGMA defer_foreign_keys = ON")

    execute("""
    CREATE TABLE session_entries__ordinal_upgrade (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      parent_entry_id TEXT REFERENCES session_entries__ordinal_upgrade(id) ON DELETE SET NULL,
      entry_type TEXT NOT NULL,
      role TEXT,
      content TEXT NOT NULL DEFAULT '[]',
      model TEXT,
      stop_reason TEXT,
      token_usage TEXT,
      timestamp TEXT NOT NULL DEFAULT (datetime('now')),
      metadata TEXT DEFAULT '{}',
      entry_ordinal INTEGER NOT NULL
    )
    """)

    execute("""
    INSERT INTO session_entries__ordinal_upgrade (
      id, session_id, parent_entry_id, entry_type, role, content, model,
      stop_reason, token_usage, timestamp, metadata, entry_ordinal
    )
    SELECT id, session_id, parent_entry_id, entry_type, role, content, model,
           stop_reason, token_usage, timestamp, metadata, entry_ordinal
    FROM session_entries
    """)

    execute("DROP TABLE session_entries")
    execute("ALTER TABLE session_entries__ordinal_upgrade RENAME TO session_entries")

    execute(
      "CREATE INDEX session_entries_session_id_timestamp_index ON session_entries (session_id, timestamp)"
    )

    execute("CREATE INDEX session_entries_entry_type_index ON session_entries (entry_type)")
  end

  defp backfill_entry_ordinals! do
    ranked_entries = """
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY session_id
             ORDER BY timestamp ASC, id ASC
           ) AS ordinal
    FROM session_entries
    """

    if postgres?() do
      # PostgreSQL does not decorrelate the SQLite-compatible subquery below;
      # UPDATE FROM computes the window once instead of once per target row.
      execute("""
      WITH ranked AS (#{ranked_entries})
      UPDATE session_entries AS target
      SET entry_ordinal = ranked.ordinal
      FROM ranked
      WHERE ranked.id = target.id
        AND target.entry_ordinal IS NULL
      """)
    else
      execute("""
      WITH ranked AS (#{ranked_entries})
      UPDATE session_entries
      SET entry_ordinal = (
        SELECT ordinal
        FROM ranked
        WHERE ranked.id = session_entries.id
      )
      WHERE entry_ordinal IS NULL
      """)
    end
  end
end
