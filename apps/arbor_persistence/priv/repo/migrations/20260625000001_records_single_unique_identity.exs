defmodule Arbor.Persistence.Repo.Migrations.RecordsSingleUniqueIdentity do
  @moduledoc """
  Collapse the `records` table to a single unique identity: the primary key `id`.

  Background — the spurious `records_pkey` violation race
  ------------------------------------------------------
  The `records` table carried TWO redundant unique constraints:

    * the primary key `id` (which `QueryableStore.Postgres.put/2` derives
      deterministically as `namespace <> ":" <> key`), and
    * the `records_namespace_key_index` UNIQUE on `(namespace, key)`.

  They are 1:1 by construction, but the upsert used
  `conflict_target: [:namespace, :key]`, so Postgres arbitrated ONLY that index.
  Postgres does NOT suppress violations on a *non-arbiter* unique index, so under
  concurrent async writes a fresh INSERT could surface the **pkey** violation —
  which the changeset did not declare, so Ecto raised `Ecto.ConstraintError`.

  This migration drops the redundant `(namespace, key)` UNIQUE index so `id`
  becomes the sole unique arbiter. The companion code switches the upsert to
  `conflict_target: [:id]`.

  Ordering / safety
  -----------------
  Step 1 normalizes every `id` to `namespace || ':' || key` *while the
  `(namespace, key)` UNIQUE index still exists* — that guarantees each row maps
  to a distinct `id`, so the UPDATE can never produce a pkey collision. Only
  AFTER ids are normalized and proven 1:1 do we drop the redundant unique index.

  Deploy ordering note
  --------------------
  The OLD running code (`conflict_target: [:namespace, :key]`) RELIES on the
  `(namespace, key)` UNIQUE index existing. Do NOT apply this migration until the
  new code (`conflict_target: [:id]`) is deployed/restarted. New code + migration
  go together.
  """

  use Ecto.Migration

  def up do
    # 1. Normalize ids to the deterministic `namespace:key` scheme. Safe because
    #    the (namespace, key) UNIQUE index still exists at this point, so every
    #    row maps to a DISTINCT id — no pkey collision possible during the UPDATE.
    execute("""
    UPDATE records
    SET id = namespace || ':' || key
    WHERE id <> namespace || ':' || key
    """)

    # 2. Drop the redundant (namespace, key) UNIQUE index. `id` (the pkey) is now
    #    the sole unique arbiter. Keep the non-unique `records_namespace_index`
    #    (used for namespace-scoped queries) — it is NOT touched here.
    drop_if_exists(unique_index(:records, [:namespace, :key]))

    # Get-by-(namespace, key) now computes `id` directly and hits the pkey index,
    # so no replacement non-unique (namespace, key) index is needed.
  end

  def down do
    # Re-create the (namespace, key) UNIQUE index. Safe: after the up migration,
    # ids are normalized to `namespace:key`, so (namespace, key) is 1:1 with `id`
    # and therefore already unique — the index will build without conflicts.
    create_if_not_exists(unique_index(:records, [:namespace, :key]))
  end
end
