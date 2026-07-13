defmodule Arbor.Persistence.QueryableStore.Postgres do
  @moduledoc """
  PostgreSQL-backed implementation of the QueryableStore behaviour.

  Uses a single `records` table with namespace scoping. All domains
  (jobs, mailbox, sessions, etc.) share one table, differentiated by
  the `namespace` column. Domain-specific data lives in JSONB columns.

  ## Identity

  - **Logical id** — `Record.id` is stored as the table primary key and is
    preserved on update. It is never rewritten as `namespace <> ":" <> key`.
  - **Physical identity** — unique `(namespace, key)`. All get/delete/CAS
    predicates bind those columns so `("a", "b:c")` and `("a:b", "c")` coexist.

  ## Fencing

  Backend-owned `generation` + `revision` (both `>= 0`). Put/CAS advance tokens
  from stored state; callers cannot roll them backward. Soft-delete sets
  `deleted_at` and retains generation so reinsert becomes a new incarnation
  (ABA-safe for structured Records).

  ## Configuration

  The Repo module must be configured and started:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: "postgres",
        hostname: "localhost"

  ## Usage

      # Store a record
      record = Record.new("my-key", %{"status" => "active"})
      Postgres.put("my-key", record, name: :jobs)

      # Query records
      filter = Filter.new() |> Filter.where(:status, :eq, "active")
      {:ok, records} = Postgres.query(filter, name: :jobs)

  The `:name` option is used as the namespace. When called via the facade,
  this is the atom name passed to `Arbor.Persistence.put(:jobs, Postgres, ...)`.

  Durability class: `:node_restart`. Supports linearizable compare-and-swap as
  one atomic SQL insert-or-update decision (generation+revision predicate +
  affected rows), scoped by true `(namespace, key)`.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  import Ecto.Query

  alias Arbor.Contracts.Persistence.Filter
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Record, as: RecordSchema
  alias Arbor.Persistence.Store.Revision

  require Logger

  # ===========================================================================
  # Store Operations
  # ===========================================================================

  @impl true
  def put(key, %Record{} = record, opts \\ []) do
    if Revision.key_mismatch?(key, record) do
      {:error, :key_mismatch}
    else
      namespace = namespace_from_opts(opts)
      repo = repo_from_opts(opts)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      data = record.data || %{}
      metadata = record.metadata || %{}

      case atomic_upsert(repo, record.id, namespace, key, data, metadata, now) do
        {:ok, _record} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e ->
      Logger.error("Failed to put record: #{inspect(e)}")
      {:error, {:put_failed, e}}
  end

  @impl true
  def compare_and_swap(key, expected, %Record{} = replacement, opts \\ []) do
    if Revision.cas_operands_key_mismatch?(key, expected, replacement) do
      {:error, :key_mismatch}
    else
      namespace = namespace_from_opts(opts)
      repo = repo_from_opts(opts)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      data = replacement.data || %{}
      metadata = replacement.metadata || %{}

      case expected do
        :not_found ->
          atomic_cas_insert(repo, replacement.id, namespace, key, data, metadata, now)

        {:value, %Record{generation: exp_gen, revision: exp_rev}}
        when is_integer(exp_gen) and is_integer(exp_rev) and exp_gen >= 0 and exp_rev >= 0 ->
          atomic_cas_update(repo, namespace, key, exp_gen, exp_rev, data, metadata, now)

        {:value, _other} ->
          {:error, :conflict}
      end
    end
  rescue
    e ->
      Logger.error("Failed to compare_and_swap record: #{inspect(e)}")
      {:error, {:compare_and_swap_failed, e}}
  end

  @impl true
  def durability_class(_opts), do: :node_restart

  @impl true
  def get(key, opts \\ []) do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)

    query =
      from(r in RecordSchema,
        where: r.namespace == ^namespace and r.key == ^key and is_nil(r.deleted_at)
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      schema -> {:ok, RecordSchema.to_record(schema)}
    end
  rescue
    e ->
      Logger.error("Failed to get record: #{inspect(e)}")
      {:error, {:get_failed, e}}
  end

  @impl true
  def delete(key, opts \\ []) do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Soft-delete tombstone: retain generation for ABA-safe reinsert fencing.
    from(r in RecordSchema,
      where: r.namespace == ^namespace and r.key == ^key and is_nil(r.deleted_at)
    )
    |> repo.update_all(set: [deleted_at: now, updated_at: now])

    :ok
  rescue
    e ->
      Logger.error("Failed to delete record: #{inspect(e)}")
      {:error, {:delete_failed, e}}
  end

  @impl true
  def list(opts \\ []) do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)

    keys =
      from(r in RecordSchema,
        where: r.namespace == ^namespace and is_nil(r.deleted_at),
        select: r.key,
        order_by: r.key
      )
      |> repo.all()

    {:ok, keys}
  rescue
    e ->
      Logger.error("Failed to list keys: #{inspect(e)}")
      {:error, {:list_failed, e}}
  end

  @impl true
  def exists?(key, opts \\ []) do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)

    from(r in RecordSchema,
      where: r.namespace == ^namespace and r.key == ^key and is_nil(r.deleted_at)
    )
    |> repo.exists?()
  end

  # ===========================================================================
  # Query Operations
  # ===========================================================================

  @impl true
  def query(%Filter{} = filter, opts \\ []) do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)

    records =
      base_query(namespace)
      |> apply_conditions(filter.conditions)
      |> apply_since(filter.since)
      |> apply_until(filter.until)
      |> apply_order(filter.order_by)
      |> apply_offset(filter.offset)
      |> apply_limit(filter.limit)
      |> repo.all()
      |> Enum.map(&RecordSchema.to_record/1)

    {:ok, records}
  rescue
    e ->
      Logger.error("Failed to query records: #{inspect(e)}")
      {:error, {:query_failed, e}}
  end

  @impl true
  def count(%Filter{} = filter, opts \\ []) do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)

    count =
      base_query(namespace)
      |> apply_conditions(filter.conditions)
      |> apply_since(filter.since)
      |> apply_until(filter.until)
      |> select([r], count(r.id))
      |> repo.one()

    {:ok, count || 0}
  rescue
    e ->
      Logger.error("Failed to count records: #{inspect(e)}")
      {:error, {:count_failed, e}}
  end

  @impl true
  def aggregate(%Filter{} = filter, field, operation, opts \\ [])
      when operation in [:sum, :avg, :min, :max] do
    namespace = namespace_from_opts(opts)
    repo = repo_from_opts(opts)

    query =
      base_query(namespace)
      |> apply_conditions(filter.conditions)
      |> apply_since(filter.since)
      |> apply_until(filter.until)

    result = execute_aggregate(repo, query, to_string(field), operation)
    {:ok, result}
  rescue
    e ->
      Logger.error("Failed to aggregate records: #{inspect(e)}")
      {:error, {:aggregate_failed, e}}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp namespace_from_opts(opts) do
    opts |> Keyword.fetch!(:name) |> to_string()
  end

  defp repo_from_opts(opts) do
    Keyword.get(opts, :repo, Repo)
  end

  # Upsert bound to true (namespace, key). Logical id preserved on live update;
  # resurrected tombstones take the caller's logical id as a new incarnation.
  # Generation/revision are backend-owned (never taken from caller input).
  # Tombstone resurrection is a new incarnation: reset inserted_at; live updates
  # preserve the original inserted_at.
  defp atomic_upsert(repo, logical_id, namespace, key, data, metadata, now) do
    sql = """
    INSERT INTO records (
      id, namespace, key, data, metadata, generation, revision,
      deleted_at, inserted_at, updated_at
    )
    VALUES ($1, $2, $3, $4, $5, 1, 1, NULL, $6, $7)
    ON CONFLICT (namespace, key) DO UPDATE SET
      data = EXCLUDED.data,
      metadata = EXCLUDED.metadata,
      id = CASE
        WHEN records.deleted_at IS NULL THEN records.id
        ELSE EXCLUDED.id
      END,
      generation = CASE
        WHEN records.deleted_at IS NULL THEN records.generation
        ELSE records.generation + 1
      END,
      revision = CASE
        WHEN records.deleted_at IS NULL THEN records.revision + 1
        ELSE 1
      END,
      deleted_at = NULL,
      inserted_at = CASE
        WHEN records.deleted_at IS NULL THEN records.inserted_at
        ELSE EXCLUDED.inserted_at
      END,
      updated_at = EXCLUDED.updated_at
    RETURNING id, namespace, key, data, metadata, generation, revision,
              deleted_at, inserted_at, updated_at
    """

    case repo.query(sql, [logical_id, namespace, key, data, metadata, now, now]) do
      {:ok, %{num_rows: 1, rows: [row], columns: columns}} ->
        {:ok, row_to_record(columns, row)}

      {:ok, other} ->
        {:error, {:put_failed, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Insert-only CAS: succeeds when absent, or when only a soft-deleted tombstone
  # remains (new generation). Bound to true (namespace, key). Resurrection is a
  # new incarnation and therefore resets inserted_at.
  defp atomic_cas_insert(repo, logical_id, namespace, key, data, metadata, now) do
    sql = """
    INSERT INTO records (
      id, namespace, key, data, metadata, generation, revision,
      deleted_at, inserted_at, updated_at
    )
    VALUES ($1, $2, $3, $4, $5, 1, 1, NULL, $6, $7)
    ON CONFLICT (namespace, key) DO UPDATE SET
      id = EXCLUDED.id,
      data = EXCLUDED.data,
      metadata = EXCLUDED.metadata,
      generation = records.generation + 1,
      revision = 1,
      deleted_at = NULL,
      inserted_at = EXCLUDED.inserted_at,
      updated_at = EXCLUDED.updated_at
    WHERE records.deleted_at IS NOT NULL
    RETURNING id, namespace, key, data, metadata, generation, revision,
              deleted_at, inserted_at, updated_at
    """

    case repo.query(sql, [logical_id, namespace, key, data, metadata, now, now]) do
      {:ok, %{num_rows: 1, rows: [row], columns: columns}} ->
        {:ok, row_to_record(columns, row)}

      {:ok, %{num_rows: 0}} ->
        {:error, :conflict}

      {:ok, other} ->
        {:error, {:compare_and_swap_failed, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Expected generation+revision CAS on the true (namespace, key) row.
  defp atomic_cas_update(repo, namespace, key, exp_gen, exp_rev, data, metadata, now) do
    sql = """
    UPDATE records
    SET data = $1,
        metadata = $2,
        revision = revision + 1,
        updated_at = $3
    WHERE namespace = $4
      AND key = $5
      AND generation = $6
      AND revision = $7
      AND deleted_at IS NULL
    RETURNING id, namespace, key, data, metadata, generation, revision,
              deleted_at, inserted_at, updated_at
    """

    case repo.query(sql, [data, metadata, now, namespace, key, exp_gen, exp_rev]) do
      {:ok, %{num_rows: 1, rows: [row], columns: columns}} ->
        {:ok, row_to_record(columns, row)}

      {:ok, %{num_rows: 0}} ->
        {:error, :conflict}

      {:ok, other} ->
        {:error, {:compare_and_swap_failed, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp row_to_record(columns, row) do
    map =
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {to_string(col), val} end)

    %Record{
      id: map["id"],
      key: map["key"],
      data: map["data"] || %{},
      metadata: map["metadata"] || %{},
      generation: map["generation"] || 0,
      revision: map["revision"] || 0,
      inserted_at: map["inserted_at"],
      updated_at: map["updated_at"]
    }
  end

  defp base_query(namespace) do
    from(r in RecordSchema, where: r.namespace == ^namespace and is_nil(r.deleted_at))
  end

  # ---------------------------------------------------------------------------
  # Condition Translation
  #
  # Top-level Record fields (key, inserted_at, updated_at) → direct column queries
  # Everything else → JSONB data column queries
  # ---------------------------------------------------------------------------

  defp apply_conditions(query, []), do: query

  defp apply_conditions(query, [{field, op, value} | rest]) do
    query
    |> apply_condition(field, op, value)
    |> apply_conditions(rest)
  end

  # Key field — direct column
  defp apply_condition(query, :key, :eq, value),
    do: where(query, [r], r.key == ^value)

  defp apply_condition(query, :key, :neq, value),
    do: where(query, [r], r.key != ^value)

  defp apply_condition(query, :key, :in, values) when is_list(values),
    do: where(query, [r], r.key in ^values)

  defp apply_condition(query, :key, :contains, value),
    do: where(query, [r], ilike(r.key, ^"%#{escape_like(value)}%"))

  # Timestamp fields — direct columns
  defp apply_condition(query, :inserted_at, op, value),
    do: apply_timestamp_condition(query, :inserted_at, op, value)

  defp apply_condition(query, :updated_at, op, value),
    do: apply_timestamp_condition(query, :updated_at, op, value)

  # Data fields — JSONB queries
  defp apply_condition(query, field, :eq, value) do
    field_str = to_string(field)

    where(
      query,
      [r],
      fragment("? @> ?::jsonb", r.data, ^%{field_str => value})
    )
  end

  defp apply_condition(query, field, :neq, value) do
    field_str = to_string(field)

    where(
      query,
      [r],
      fragment("NOT (? @> ?::jsonb)", r.data, ^%{field_str => value})
    )
  end

  defp apply_condition(query, field, :in, values) when is_list(values) do
    field_str = to_string(field)
    str_values = Enum.map(values, &to_string/1)

    where(
      query,
      [r],
      fragment("?->>? = ANY(?)", r.data, ^field_str, ^str_values)
    )
  end

  defp apply_condition(query, field, :contains, value) do
    field_str = to_string(field)
    escaped = "%#{escape_like(value)}%"

    where(
      query,
      [r],
      fragment("?->>? ILIKE ?", r.data, ^field_str, ^escaped)
    )
  end

  defp apply_condition(query, field, op, value) when op in [:gt, :gte, :lt, :lte] do
    field_str = to_string(field)

    case op do
      :gt ->
        where(query, [r], fragment("(?->>?)::numeric > ?::numeric", r.data, ^field_str, ^value))

      :gte ->
        where(query, [r], fragment("(?->>?)::numeric >= ?::numeric", r.data, ^field_str, ^value))

      :lt ->
        where(query, [r], fragment("(?->>?)::numeric < ?::numeric", r.data, ^field_str, ^value))

      :lte ->
        where(query, [r], fragment("(?->>?)::numeric <= ?::numeric", r.data, ^field_str, ^value))
    end
  end

  defp apply_timestamp_condition(query, :inserted_at, op, value),
    do: apply_inserted_at(query, op, value)

  defp apply_timestamp_condition(query, :updated_at, op, value),
    do: apply_updated_at(query, op, value)

  defp apply_inserted_at(query, :gt, value), do: where(query, [r], r.inserted_at > ^value)
  defp apply_inserted_at(query, :gte, value), do: where(query, [r], r.inserted_at >= ^value)
  defp apply_inserted_at(query, :lt, value), do: where(query, [r], r.inserted_at < ^value)
  defp apply_inserted_at(query, :lte, value), do: where(query, [r], r.inserted_at <= ^value)
  defp apply_inserted_at(query, :eq, value), do: where(query, [r], r.inserted_at == ^value)

  defp apply_updated_at(query, :gt, value), do: where(query, [r], r.updated_at > ^value)
  defp apply_updated_at(query, :gte, value), do: where(query, [r], r.updated_at >= ^value)
  defp apply_updated_at(query, :lt, value), do: where(query, [r], r.updated_at < ^value)
  defp apply_updated_at(query, :lte, value), do: where(query, [r], r.updated_at <= ^value)
  defp apply_updated_at(query, :eq, value), do: where(query, [r], r.updated_at == ^value)

  # ---------------------------------------------------------------------------
  # Time Range
  # ---------------------------------------------------------------------------

  defp apply_since(query, nil), do: query
  defp apply_since(query, %DateTime{} = dt), do: where(query, [r], r.inserted_at >= ^dt)

  defp apply_until(query, nil), do: query
  defp apply_until(query, %DateTime{} = dt), do: where(query, [r], r.inserted_at <= ^dt)

  # ---------------------------------------------------------------------------
  # Ordering
  # ---------------------------------------------------------------------------

  defp apply_order(query, nil), do: query

  defp apply_order(query, {:inserted_at, dir}),
    do: order_by(query, [r], [{^dir, r.inserted_at}])

  defp apply_order(query, {:updated_at, dir}),
    do: order_by(query, [r], [{^dir, r.updated_at}])

  defp apply_order(query, {:key, dir}),
    do: order_by(query, [r], [{^dir, r.key}])

  defp apply_order(query, {field, dir}) do
    field_str = to_string(field)
    order_by(query, [r], [{^dir, fragment("?->>?", r.data, ^field_str)}])
  end

  # ---------------------------------------------------------------------------
  # Pagination
  # ---------------------------------------------------------------------------

  defp apply_offset(query, 0), do: query
  defp apply_offset(query, nil), do: query
  defp apply_offset(query, n) when is_integer(n), do: offset(query, ^n)

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, n) when is_integer(n), do: limit(query, ^n)

  # ---------------------------------------------------------------------------
  # Aggregation
  # ---------------------------------------------------------------------------

  defp execute_aggregate(repo, query, field_str, :sum) do
    repo.one(select(query, [r], fragment("SUM((?->>?)::numeric)", r.data, ^field_str)))
  end

  defp execute_aggregate(repo, query, field_str, :avg) do
    repo.one(select(query, [r], fragment("AVG((?->>?)::numeric)", r.data, ^field_str)))
  end

  defp execute_aggregate(repo, query, field_str, :min) do
    repo.one(select(query, [r], fragment("MIN((?->>?)::numeric)", r.data, ^field_str)))
  end

  defp execute_aggregate(repo, query, field_str, :max) do
    repo.one(select(query, [r], fragment("MAX((?->>?)::numeric)", r.data, ^field_str)))
  end

  # ---------------------------------------------------------------------------
  # LIKE Injection Prevention
  #
  # Escapes LIKE metacharacters (%, _, \) so user input is matched literally
  # when used in ILIKE patterns. Without this, a user passing "%" as a filter
  # value would match every row (full table scan + information disclosure).
  # ---------------------------------------------------------------------------

  defp escape_like(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
