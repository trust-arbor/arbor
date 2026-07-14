defmodule Arbor.Persistence.Repo.Migrations.RecordsGenerationAndNamespaceKeyIdentity do
  @moduledoc """
  Additive migration for structured-record fencing and unambiguous physical identity.

  1. Restores unique `(namespace, key)` as the **physical** storage identity so
     `("a", "b:c")` and `("a:b", "c")` coexist (the old `namespace || ':' || key`
     primary-key scheme collapsed those pairs).
  2. Adds backend-owned `generation` (incarnation) alongside `revision`.
  3. Adds soft-delete `deleted_at` tombstones so delete/reinsert cannot revive a
     stale generation+revision CAS.
  4. Enforces `revision >= 0` and `generation >= 0` at the database (Postgres).

  Logical `id` remains the primary key and is no longer derived from namespace/key.
  Existing rows keep their current ids; generation defaults to 1 for live rows.

  Column adds use MigrationHelper's adapter-aware helpers rather than Ecto's
  `add_if_not_exists/3`, which ecto_sqlite3 does not translate (raises
  "Not supported by SQLite3" on a fresh SQLite migration chain).
  """
  use Ecto.Migration
  import Arbor.Persistence.MigrationHelper

  def up do
    add_column_if_not_exists(:records, :generation, :bigint, null: false, default: 1)
    add_column_if_not_exists(:records, :deleted_at, :utc_datetime_usec)

    # Physical identity: true (namespace, key). May already exist on DBs that
    # never applied 20260625000001; create_if_not_exists is additive either way.
    create_if_not_exists(
      unique_index(:records, [:namespace, :key], name: :records_namespace_key_index)
    )

    if postgres?() do
      execute("""
      ALTER TABLE records
        DROP CONSTRAINT IF EXISTS records_revision_nonneg
      """)

      execute("""
      ALTER TABLE records
        DROP CONSTRAINT IF EXISTS records_generation_nonneg
      """)

      execute("""
      ALTER TABLE records
        ADD CONSTRAINT records_revision_nonneg CHECK (revision >= 0)
      """)

      execute("""
      ALTER TABLE records
        ADD CONSTRAINT records_generation_nonneg CHECK (generation >= 0)
      """)
    end
  end

  def down do
    if postgres?() do
      execute("""
      ALTER TABLE records
        DROP CONSTRAINT IF EXISTS records_revision_nonneg
      """)

      execute("""
      ALTER TABLE records
        DROP CONSTRAINT IF EXISTS records_generation_nonneg
      """)
    end

    # Keep the unique index on down — removing it would re-introduce delimiter
    # collisions. Generation/deleted_at columns are dropped.
    remove_column_if_exists(:records, :deleted_at, :utc_datetime_usec)
    remove_column_if_exists(:records, :generation, :bigint)
  end
end
