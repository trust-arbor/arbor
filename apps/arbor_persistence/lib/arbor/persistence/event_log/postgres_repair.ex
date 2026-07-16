defmodule Arbor.Persistence.EventLog.PostgresRepair do
  @moduledoc """
  Explicit PostgreSQL maintenance operations for legacy EventLog rows.

  This module is intentionally not part of normal EventLog replay or append
  processing. Position repair records a retained, ID-keyed rollback map before
  changing rows. Identity remediation stages a trusted operator cutover snapshot
  before it writes fingerprints; it does not establish integrity of data from
  before that snapshot.
  """

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.Repo

  @max_position 2_147_483_647
  @position_batches "arbor_event_log_position_repair_batches"
  @position_rows "arbor_event_log_position_repair_rows"
  @identity_batches "arbor_event_log_identity_repair_batches"
  @identity_rows "arbor_event_log_identity_repair_rows"
  @position_disposition "operator_reviewed_backup_bound_position_repair_v1"
  @position_algorithm "row_number_global_position_created_at_id_v1"
  @identity_provenance "legacy_trusted_cutover_snapshot_v1"
  @identity_disposition "synthetic_operation_ids_anchor_operator_reviewed_cutover_snapshot_not_original_append_boundaries_v1"
  @default_batch_size 1_000
  @max_batch_size 10_000

  @type audit :: %{
          event_count: non_neg_integer(),
          min_global_position: integer() | nil,
          max_global_position: integer() | nil,
          distinct_global_positions: non_neg_integer(),
          duplicate_global_position_groups: non_neg_integer(),
          duplicate_global_position_excess: non_neg_integer(),
          duplicate_global_position_max_multiplicity: non_neg_integer(),
          null_or_invalid_global_positions: non_neg_integer(),
          null_or_invalid_event_numbers: non_neg_integer(),
          same_stream_position_collision_groups: non_neg_integer(),
          same_stream_position_collision_excess: non_neg_integer(),
          stream_sequence_problem_groups: non_neg_integer(),
          stream_global_position_regressions_or_ties: non_neg_integer()
        }

  @doc "Audits legacy global positions without changing data."
  @spec audit(module()) :: {:ok, audit()} | {:error, term()}
  def audit(repo \\ Repo) do
    with :ok <- postgres_repo(repo) do
      {:ok, audit!(repo)}
    end
  rescue
    error -> {:error, {:database_error, Exception.message(error)}}
  end

  @doc """
  Deterministically rewrites all global positions under an exclusive lock.

  `expected_count` and `expected_old_max` must be copied from a preceding audit.
  `source_backup_digest` binds the retained mapping to the reviewed source
  backup. The retained rollback table is deliberately single-use: any existing
  mapping is treated as a conflict until a human reviews and removes it separately.
  """
  @spec apply_positions(module(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def apply_positions(expected_count, expected_old_max, source_backup_digest)
      when is_integer(expected_count) and is_integer(expected_old_max) and
             is_binary(source_backup_digest) do
    apply_positions(Repo, expected_count, expected_old_max, source_backup_digest)
  end

  def apply_positions(repo, expected_count, expected_old_max, source_backup_digest)
      when is_integer(expected_count) and expected_count >= 0 and is_integer(expected_old_max) and
             expected_old_max >= 0 and is_binary(source_backup_digest) do
    with :ok <- postgres_repo(repo),
         :ok <- validate_position_expectations(expected_count, expected_old_max),
         :ok <- validate_source_backup_digest(source_backup_digest),
         :ok <- ensure_sha256_support(repo),
         :ok <- reject_active_or_waiting_writers(repo) do
      transaction(repo, fn ->
        lock_events!(repo)
        audit = audit!(repo)
        assert_position_expectations!(audit, expected_count, expected_old_max)
        assert_repairable_history!(audit)
        create_position_tables!(repo)
        assert_no_position_provenance!(repo)

        batch_id = "position_" <> Ecto.UUID.generate()
        insert_position_batch!(repo, batch_id, audit, source_backup_digest)
        stage_positions!(repo, batch_id)
        assert_position_stage_complete!(repo, batch_id, expected_count)
        update_positions!(repo, batch_id)
        verify_position_source_rows!(repo, batch_id)
        reset_legacy_sequence!(repo, expected_count)
        verify_dense_positions!(repo, expected_count)
        verify_stream_monotonicity!(repo)
        mark_position_batch!(repo, batch_id, "applied")

        %{
          batch_id: batch_id,
          audit: audit,
          event_count: expected_count,
          source_backup_digest: source_backup_digest,
          disposition: @position_disposition,
          algorithm: @position_algorithm
        }
      end)
    end
  rescue
    error -> {:error, {:database_error, Exception.message(error)}}
  end

  def apply_positions(_repo, _expected_count, _expected_old_max, _source_backup_digest),
    do: {:error, :invalid_position_expectations}

  @doc "Restores the exact retained old positions for an applied repair batch."
  @spec rollback_positions(module(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rollback_positions(repo \\ Repo, batch_id, confirmation)

  def rollback_positions(repo, batch_id, confirmation)
      when is_binary(batch_id) and is_binary(confirmation) do
    with :ok <- postgres_repo(repo),
         :ok <- exact_confirmation(batch_id, confirmation),
         :ok <- ensure_sha256_support(repo),
         :ok <- reject_active_or_waiting_writers(repo) do
      transaction(repo, fn ->
        lock_events!(repo)
        create_position_tables!(repo)
        batch = fetch_applied_position_batch!(repo, batch_id)
        assert_position_stage_complete!(repo, batch_id, batch.event_count)
        assert_rollback_index_allows_duplicates!(repo)
        assert_current_positions_match_stage!(repo, batch_id, :proposed)
        verify_position_source_rows!(repo, batch_id)
        restore_old_positions!(repo, batch_id)
        reset_legacy_sequence!(repo, batch.old_maximum)
        assert_current_positions_match_stage!(repo, batch_id, :old)
        verify_stream_monotonicity!(repo)
        mark_position_batch!(repo, batch_id, "rolled_back")

        %{
          batch_id: batch_id,
          event_count: batch.event_count,
          restored_old_maximum: batch.old_maximum
        }
      end)
    end
  rescue
    error -> {:error, {:database_error, Exception.message(error)}}
  end

  def rollback_positions(_repo, _batch_id, _confirmation), do: {:error, :invalid_rollback_request}

  @doc """
  Stages canonical legacy fingerprints in bounded keyset batches.

  The supplied digest identifies the reviewed source backup. Its presence is
  provenance only: synthetic operation IDs anchor the operator-reviewed cutover
  snapshot, do not reconstruct original append boundaries, and do not prove
  integrity of pre-cutover event data.
  """
  @spec stage_identity(module(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def stage_identity(
        repo \\ Repo,
        batch_id,
        source_backup_digest,
        batch_size \\ @default_batch_size
      )

  def stage_identity(
        repo,
        batch_id,
        source_backup_digest,
        batch_size
      )
      when is_binary(batch_id) and is_binary(source_backup_digest) do
    with :ok <- postgres_repo(repo),
         :ok <- validate_batch_id(batch_id),
         :ok <- validate_source_backup_digest(source_backup_digest),
         :ok <- ensure_sha256_support(repo),
         :ok <- validate_batch_size(batch_size) do
      create_identity_tables(repo)
      ensure_identity_schema!(repo)
      reject_half_present_identities!(repo)
      assert_no_identity_provenance!(repo)

      transaction(repo, fn ->
        expected_event_count = scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, "events")}")
        insert_identity_batch!(repo, batch_id, expected_event_count, source_backup_digest)

        staged_count =
          stage_identity_pages!(repo, batch_id, source_backup_digest, batch_size, nil, 0)

        update_identity_batch_count!(repo, batch_id, staged_count)

        %{
          batch_id: batch_id,
          expected_event_count: expected_event_count,
          staged_count: staged_count,
          source_backup_digest: source_backup_digest,
          provenance: @identity_provenance,
          disposition: @identity_disposition
        }
      end)
    end
  rescue
    error -> {:error, {:database_error, Exception.message(error)}}
  end

  def stage_identity(_repo, _batch_id, _source_backup_digest, _batch_size),
    do: {:error, :invalid_identity_stage_request}

  @doc """
  Applies one previously staged legacy identity batch under an exclusive lock.

  Before updating, it verifies the whole staged snapshot against current event
  representations and rejects any tampering or concurrent change.
  """
  @spec apply_staged_identity(module(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def apply_staged_identity(repo \\ Repo, batch_id, batch_size \\ @default_batch_size)

  def apply_staged_identity(repo, batch_id, batch_size)
      when is_binary(batch_id) do
    with :ok <- postgres_repo(repo),
         :ok <- validate_batch_id(batch_id),
         :ok <- validate_batch_size(batch_size),
         :ok <- ensure_sha256_support(repo),
         :ok <- reject_active_or_waiting_writers(repo) do
      transaction(repo, fn ->
        lock_events!(repo)
        create_identity_tables(repo)
        ensure_identity_schema!(repo)
        batch = fetch_staged_identity_batch!(repo, batch_id)
        reject_half_present_identities!(repo)
        assert_identity_stage_complete!(repo, batch)

        assert_identity_verification_count!(
          verify_staged_identity_pages!(repo, batch_id, batch_size, nil, 0),
          batch.staged_count
        )

        apply_identity_rows!(repo, batch_id)

        assert_identity_verification_count!(
          verify_applied_identity_pages!(repo, batch_id, batch_size, nil, 0),
          batch.staged_count
        )

        validate_fingerprint_constraint!(repo)
        mark_identity_batch!(repo, batch_id, "applied")

        batch
        |> Map.put(:provenance, @identity_provenance)
        |> Map.put(:disposition, @identity_disposition)
      end)
    end
  rescue
    error -> {:error, {:database_error, Exception.message(error)}}
  end

  def apply_staged_identity(_repo, _batch_id, _batch_size),
    do: {:error, :invalid_identity_apply_request}

  defp postgres_repo(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and
         repo.__adapter__() == Ecto.Adapters.Postgres,
       do: :ok,
       else: {:error, :postgres_required}
  end

  defp postgres_repo(_repo), do: {:error, :postgres_required}

  defp ensure_sha256_support(repo) do
    query!(repo, "SELECT encode(sha256(''::bytea), 'hex')")
    :ok
  rescue
    _error -> {:error, :postgres_builtin_sha256_required}
  end

  defp validate_position_expectations(count, maximum)
       when count <= @max_position and maximum <= @max_position,
       do: :ok

  defp validate_position_expectations(_count, _maximum), do: {:error, :position_capacity_exceeded}

  defp exact_confirmation(batch_id, confirmation) do
    if confirmation == batch_id, do: :ok, else: {:error, :rollback_confirmation_mismatch}
  end

  defp validate_batch_id(batch_id) do
    if byte_size(batch_id) in 1..255 and String.match?(batch_id, ~r/^[A-Za-z0-9._:-]+$/),
      do: :ok,
      else: {:error, :invalid_batch_id}
  end

  defp validate_source_backup_digest(digest) do
    if String.match?(digest, ~r/^[0-9a-f]{64}$/),
      do: :ok,
      else: {:error, :invalid_source_backup_digest}
  end

  defp validate_batch_size(size) when is_integer(size) and size in 1..@max_batch_size, do: :ok
  defp validate_batch_size(_size), do: {:error, :invalid_batch_size}

  defp transaction(repo, fun) do
    case repo.transaction(fun, timeout: :infinity) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp audit!(repo) do
    [[count, minimum, maximum, distinct_count]] =
      query!(repo, """
      SELECT COUNT(*), MIN(global_position), MAX(global_position), COUNT(DISTINCT global_position)
      FROM #{table(repo, "events")}
      """)

    [[duplicate_groups, duplicate_excess, maximum_multiplicity]] =
      query!(repo, """
      SELECT COUNT(*),
             COALESCE(SUM(multiplicity - 1), 0)::bigint,
             COALESCE(MAX(multiplicity), 0)::bigint
      FROM (
        SELECT COUNT(*) AS multiplicity
        FROM #{table(repo, "events")}
        WHERE global_position IS NOT NULL
        GROUP BY global_position
        HAVING COUNT(*) > 1
      ) duplicates
      """)

    [[invalid_global_positions, invalid_event_numbers]] =
      query!(repo, """
      SELECT
        COUNT(*) FILTER (
          WHERE global_position IS NULL OR global_position < 1 OR global_position > #{@max_position}
        ),
        COUNT(*) FILTER (
          WHERE event_number IS NULL OR event_number < 1 OR event_number > #{@max_position}
        )
      FROM #{table(repo, "events")}
      """)

    [[stream_collision_groups, stream_collision_excess]] =
      query!(repo, """
      SELECT COUNT(*), COALESCE(SUM(multiplicity - 1), 0)::bigint
      FROM (
        SELECT COUNT(*) AS multiplicity
        FROM #{table(repo, "events")}
        WHERE global_position IS NOT NULL
        GROUP BY stream_id, global_position
        HAVING COUNT(*) > 1
      ) collisions
      """)

    [[stream_sequence_problem_groups, stream_global_regressions]] =
      query!(repo, """
      WITH numbered AS (
        SELECT stream_id,
               event_number,
               global_position,
               LAG(global_position) OVER (PARTITION BY stream_id ORDER BY event_number, id) AS prior_global_position
        FROM #{table(repo, "events")}
      ), stream_shapes AS (
        SELECT stream_id
        FROM #{table(repo, "events")}
        GROUP BY stream_id
        HAVING MIN(event_number) <> 1
            OR MAX(event_number) <> COUNT(*)
            OR COUNT(*) <> COUNT(DISTINCT event_number)
      )
      SELECT
        (SELECT COUNT(*) FROM stream_shapes),
        COUNT(*) FILTER (
          WHERE prior_global_position IS NOT NULL AND global_position <= prior_global_position
        )
      FROM numbered
      """)

    %{
      event_count: count,
      min_global_position: minimum,
      max_global_position: maximum,
      distinct_global_positions: distinct_count,
      duplicate_global_position_groups: duplicate_groups,
      duplicate_global_position_excess: duplicate_excess,
      duplicate_global_position_max_multiplicity: maximum_multiplicity,
      null_or_invalid_global_positions: invalid_global_positions,
      null_or_invalid_event_numbers: invalid_event_numbers,
      same_stream_position_collision_groups: stream_collision_groups,
      same_stream_position_collision_excess: stream_collision_excess,
      stream_sequence_problem_groups: stream_sequence_problem_groups,
      stream_global_position_regressions_or_ties: stream_global_regressions
    }
  end

  defp assert_position_expectations!(audit, expected_count, expected_old_max) do
    if audit.event_count == expected_count and audit.max_global_position == expected_old_max do
      :ok
    else
      raise "position repair confirmation mismatch: expected count=#{expected_count} max=#{expected_old_max}, " <>
              "found count=#{audit.event_count} max=#{inspect(audit.max_global_position)}"
    end
  end

  defp assert_repairable_history!(audit) do
    malformed? =
      audit.null_or_invalid_global_positions > 0 or
        audit.null_or_invalid_event_numbers > 0 or
        audit.same_stream_position_collision_groups > 0 or
        audit.stream_sequence_problem_groups > 0 or
        audit.stream_global_position_regressions_or_ties > 0

    if malformed?, do: raise("refusing malformed EventLog history: #{inspect(audit)}")
  end

  defp reject_active_or_waiting_writers(repo) do
    [[active_or_holding_writers, waiting_writers]] =
      query!(repo, """
      SELECT
        COUNT(*) FILTER (
          WHERE granted
            AND mode IN ('RowExclusiveLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')
        ),
        COUNT(*) FILTER (WHERE NOT granted)
      FROM pg_locks locks
      JOIN pg_class relation ON relation.oid = locks.relation
      JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
      WHERE relation.relname = 'events'
        AND namespace.nspname = current_schema()
        AND locks.pid <> pg_backend_pid()
      """)

    if active_or_holding_writers == 0 and waiting_writers == 0,
      do: :ok,
      else:
        {:error,
         {:event_log_writers_active_or_waiting, active_or_holding_writers, waiting_writers}}
  end

  defp lock_events!(repo),
    do: query!(repo, "LOCK TABLE #{table(repo, "events")} IN ACCESS EXCLUSIVE MODE NOWAIT")

  defp create_position_tables!(repo) do
    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{table(repo, @position_batches)} (
      batch_id text PRIMARY KEY,
      event_count bigint NOT NULL,
      old_maximum bigint NOT NULL,
      source_backup_digest text NOT NULL,
      disposition_marker text NOT NULL,
      position_algorithm text NOT NULL,
      status text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      applied_at timestamptz
    )
    """)

    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{table(repo, @position_rows)} (
      event_id text PRIMARY KEY,
      batch_id text NOT NULL REFERENCES #{table(repo, @position_batches)}(batch_id),
      old_global_position bigint NOT NULL,
      proposed_global_position bigint NOT NULL,
      source_row_sha256 text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
    """)

    query!(repo, """
    ALTER TABLE #{table(repo, @position_batches)}
    ADD COLUMN IF NOT EXISTS source_backup_digest text,
    ADD COLUMN IF NOT EXISTS disposition_marker text,
    ADD COLUMN IF NOT EXISTS position_algorithm text
    """)

    query!(repo, """
    ALTER TABLE #{table(repo, @position_rows)}
    ADD COLUMN IF NOT EXISTS source_row_sha256 text
    """)
  end

  defp assert_no_position_provenance!(repo) do
    if scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, @position_rows)}") == 0,
      do: :ok,
      else: raise("position rollback provenance already exists; refusing conflicting repair")
  end

  defp insert_position_batch!(repo, batch_id, audit, source_backup_digest) do
    query!(
      repo,
      """
      INSERT INTO #{table(repo, @position_batches)} (
        batch_id, event_count, old_maximum, source_backup_digest,
        disposition_marker, position_algorithm, status
      ) VALUES ($1, $2, $3, $4, $5, $6, 'staged')
      """,
      [
        batch_id,
        audit.event_count,
        audit.max_global_position || 0,
        source_backup_digest,
        @position_disposition,
        @position_algorithm
      ]
    )
  end

  defp stage_positions!(repo, batch_id) do
    query!(
      repo,
      """
      INSERT INTO #{table(repo, @position_rows)} (
        event_id, batch_id, old_global_position, proposed_global_position, source_row_sha256
      )
      SELECT id,
             $1,
             global_position,
             ROW_NUMBER() OVER (ORDER BY global_position, created_at, id),
             #{position_source_checksum_sql("event")}
      FROM #{table(repo, "events")}
      AS event
      ORDER BY global_position, created_at, id
      """,
      [batch_id]
    )
  end

  defp assert_position_stage_complete!(repo, batch_id, expected_count) do
    count =
      scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, @position_rows)} WHERE batch_id = $1", [
        batch_id
      ])

    if count == expected_count, do: :ok, else: raise("position rollback staging count mismatch")
  end

  defp update_positions!(repo, batch_id) do
    %{num_rows: count} =
      query_result!(
        repo,
        """
        UPDATE #{table(repo, "events")} event
        SET global_position = staged.proposed_global_position
        FROM #{table(repo, @position_rows)} staged
        WHERE staged.batch_id = $1 AND staged.event_id = event.id
        """,
        [batch_id]
      )

    expected =
      scalar!(
        repo,
        "SELECT event_count FROM #{table(repo, @position_batches)} WHERE batch_id = $1",
        [batch_id]
      )

    if count == expected,
      do: :ok,
      else: raise("position repair updated an unexpected number of events")
  end

  defp verify_position_source_rows!(repo, batch_id) do
    [[mismatches]] =
      query!(
        repo,
        """
        SELECT COUNT(*)
        FROM #{table(repo, @position_rows)} staged
        JOIN #{table(repo, "events")} event ON event.id = staged.event_id
        WHERE staged.batch_id = $1
          AND staged.source_row_sha256 IS DISTINCT FROM #{position_source_checksum_sql("event")}
        """,
        [batch_id]
      )

    if mismatches == 0,
      do: :ok,
      else: raise("position repair source-row checksum mismatch")
  end

  defp verify_dense_positions!(repo, expected_count) do
    [[minimum, maximum, count, distinct_count]] =
      query!(
        repo,
        """
        SELECT MIN(global_position), MAX(global_position), COUNT(*), COUNT(DISTINCT global_position)
        FROM #{table(repo, "events")}
        """
      )

    expected = if expected_count == 0, do: {nil, nil}, else: {1, expected_count}

    if {minimum, maximum} == expected and count == expected_count and
         distinct_count == expected_count,
       do: :ok,
       else: raise("position repair verification failed")
  end

  defp verify_stream_monotonicity!(repo) do
    [[violations]] =
      query!(repo, """
      WITH ordered AS (
        SELECT stream_id,
               global_position,
               LAG(global_position) OVER (PARTITION BY stream_id ORDER BY event_number, id) AS prior_global_position
        FROM #{table(repo, "events")}
      )
      SELECT COUNT(*)
      FROM ordered
      WHERE prior_global_position IS NOT NULL AND global_position <= prior_global_position
      """)

    if violations == 0, do: :ok, else: raise("stream monotonicity verification failed")
  end

  defp reset_legacy_sequence!(repo, count) do
    [[sequence]] =
      query!(repo, """
      SELECT COALESCE(to_regclass(current_schema() || '.events_global_position_seq')::text, '')
      """)

    if sequence != "" do
      {value, called} = if count == 0, do: {1, false}, else: {count, true}
      query!(repo, "SELECT setval(to_regclass($1), $2, $3)", [sequence, value, called])
    end
  end

  defp mark_position_batch!(repo, batch_id, status) do
    query!(
      repo,
      """
      UPDATE #{table(repo, @position_batches)}
      SET status = $2, applied_at = clock_timestamp()
      WHERE batch_id = $1
      """,
      [batch_id, status]
    )
  end

  defp fetch_applied_position_batch!(repo, batch_id) do
    case query!(
           repo,
           """
           SELECT event_count, old_maximum
           FROM #{table(repo, @position_batches)}
           WHERE batch_id = $1 AND status = 'applied'
           """,
           [batch_id]
         ) do
      [[event_count, old_maximum]] -> %{event_count: event_count, old_maximum: old_maximum}
      [] -> raise("no applied position repair batch #{inspect(batch_id)}")
    end
  end

  defp assert_rollback_index_allows_duplicates!(repo) do
    [[index_count]] =
      query!(
        repo,
        """
        SELECT COUNT(*)
        FROM pg_index index_definition
        JOIN pg_attribute attribute
          ON attribute.attrelid = index_definition.indrelid
         AND attribute.attnum = ANY (index_definition.indkey)
        WHERE index_definition.indrelid = to_regclass($1)
          AND index_definition.indisunique
          AND index_definition.indpred IS NULL
          AND index_definition.indnkeyatts = 1
          AND attribute.attname = 'global_position'
        """,
        [regclass_name(repo, "events")]
      )

    if index_count == 0 do
      :ok
    else
      raise(
        "exact rollback is unavailable while a unique global_position index exists; " <>
          "rollback after protocol migration requires restoring the database snapshot " <>
          "or an explicitly reviewed index downgrade"
      )
    end
  end

  defp assert_current_positions_match_stage!(repo, batch_id, column) do
    staged_column =
      if column == :proposed, do: "proposed_global_position", else: "old_global_position"

    staged_count =
      scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, @position_rows)} WHERE batch_id = $1", [
        batch_id
      ])

    event_count = scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, "events")}")

    if event_count != staged_count do
      raise("position rollback map no longer covers the exact EventLog")
    end

    [[mismatches]] =
      query!(
        repo,
        """
        SELECT COUNT(*)
        FROM #{table(repo, @position_rows)} staged
        LEFT JOIN #{table(repo, "events")} event ON event.id = staged.event_id
        WHERE staged.batch_id = $1
          AND (event.id IS NULL OR event.global_position IS DISTINCT FROM staged.#{staged_column})
        """,
        [batch_id]
      )

    if mismatches == 0, do: :ok, else: raise("position rollback map no longer matches events")
  end

  defp restore_old_positions!(repo, batch_id) do
    query!(
      repo,
      """
      UPDATE #{table(repo, "events")} event
      SET global_position = staged.old_global_position
      FROM #{table(repo, @position_rows)} staged
      WHERE staged.batch_id = $1 AND staged.event_id = event.id
      """,
      [batch_id]
    )
  end

  defp create_identity_tables(repo) do
    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{table(repo, @identity_batches)} (
      batch_id text PRIMARY KEY,
      expected_event_count bigint NOT NULL,
      staged_count bigint NOT NULL DEFAULT 0,
      source_backup_digest text NOT NULL,
      provenance_marker text NOT NULL,
      status text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
      applied_at timestamptz
    )
    """)

    query!(repo, """
    CREATE TABLE IF NOT EXISTS #{table(repo, @identity_rows)} (
      event_id text PRIMARY KEY,
      batch_id text NOT NULL REFERENCES #{table(repo, @identity_batches)}(batch_id),
      operation_id text NOT NULL,
      operation_fingerprint text NOT NULL,
      source_row_sha256 text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
    """)

    query!(repo, """
    ALTER TABLE #{table(repo, @identity_rows)}
    ADD COLUMN IF NOT EXISTS source_row_sha256 text
    """)
  end

  defp ensure_identity_schema!(repo) do
    [[columns, fingerprint_constraint]] =
      query!(
        repo,
        """
        SELECT
          COUNT(*) FILTER (WHERE column_name IN ('operation_id', 'operation_fingerprint')),
          EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = to_regclass($1)
              AND conname = 'events_operation_fingerprint_present'
          )
        FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'events'
        """,
        [regclass_name(repo, "events")]
      )

    if columns == 2 and fingerprint_constraint,
      do: :ok,
      else: raise("EventLog identity migrations are not ready")
  end

  defp reject_half_present_identities!(repo) do
    count =
      scalar!(repo, """
      SELECT COUNT(*)
      FROM #{table(repo, "events")}
      WHERE (operation_id IS NULL) <> (operation_fingerprint IS NULL)
      """)

    if count == 0, do: :ok, else: raise("refusing half-present EventLog identities")
  end

  defp assert_no_identity_provenance!(repo) do
    if scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, @identity_rows)}") == 0,
      do: :ok,
      else: raise("identity provenance already exists; refusing conflicting remediation")
  end

  defp insert_identity_batch!(repo, batch_id, expected_event_count, digest) do
    query!(
      repo,
      """
      INSERT INTO #{table(repo, @identity_batches)} (
        batch_id, expected_event_count, source_backup_digest, provenance_marker, status
      ) VALUES ($1, $2, $3, $4, 'staging')
      """,
      [batch_id, expected_event_count, digest, @identity_provenance]
    )
  end

  defp stage_identity_pages!(repo, batch_id, digest, batch_size, last_id, staged_count) do
    rows = stage_identity_page!(repo, batch_size, last_id)

    case rows do
      [] ->
        staged_count

      _ ->
        staged = Enum.map(rows, &identity_stage_row!(&1, digest))
        insert_identity_rows!(repo, batch_id, staged)

        stage_identity_pages!(
          repo,
          batch_id,
          digest,
          batch_size,
          staged |> List.last() |> elem(0),
          staged_count + length(staged)
        )
    end
  end

  defp stage_identity_page!(repo, batch_size, nil) do
    query!(
      repo,
      """
      SELECT event.id, event.stream_id, event.event_number, event.global_position,
             event.type, event.data, event.metadata, event.agent_id,
             event.causation_id, event.correlation_id, event.event_timestamp,
             #{identity_source_checksum_sql("event")}
      FROM #{table(repo, "events")} AS event
      WHERE event.operation_id IS NULL
        AND event.operation_fingerprint IS NULL
      ORDER BY event.id
      LIMIT $1
      """,
      [batch_size]
    )
  end

  defp stage_identity_page!(repo, batch_size, last_id) when is_binary(last_id) do
    query!(
      repo,
      """
      SELECT event.id, event.stream_id, event.event_number, event.global_position,
             event.type, event.data, event.metadata, event.agent_id,
             event.causation_id, event.correlation_id, event.event_timestamp,
             #{identity_source_checksum_sql("event")}
      FROM #{table(repo, "events")} AS event
      WHERE event.operation_id IS NULL
        AND event.operation_fingerprint IS NULL
        AND event.id > $1
      ORDER BY event.id
      LIMIT $2
      """,
      [last_id, batch_size]
    )
  end

  defp identity_stage_row!(
         [
           id,
           stream_id,
           event_number,
           global_position,
           type,
           data,
           metadata,
           agent_id,
           causation_id,
           correlation_id,
           timestamp,
           source_row_sha256
         ],
         _digest
       ) do
    event = %Event{
      id: id,
      stream_id: stream_id,
      event_number: event_number,
      global_position: global_position,
      type: type,
      data: data || %{},
      metadata: metadata || %{},
      agent_id: agent_id,
      causation_id: causation_id,
      correlation_id: correlation_id,
      timestamp: utc_datetime!(timestamp)
    }

    fingerprint =
      EventLog.event_fingerprint(stream_id, event) ||
        raise("cannot fingerprint legacy event #{inspect(id)}")

    operation_id = deterministic_identity_operation_id(id, fingerprint)
    {id, operation_id, fingerprint, source_row_sha256}
  end

  defp insert_identity_rows!(repo, batch_id, rows) do
    ids = Enum.map(rows, &elem(&1, 0))
    operation_ids = Enum.map(rows, &elem(&1, 1))
    fingerprints = Enum.map(rows, &elem(&1, 2))
    source_row_sha256s = Enum.map(rows, &elem(&1, 3))

    query!(
      repo,
      """
      INSERT INTO #{table(repo, @identity_rows)} (
        event_id, batch_id, operation_id, operation_fingerprint, source_row_sha256
      )
      SELECT * FROM UNNEST($1::text[], $2::text[], $3::text[], $4::text[], $5::text[])
      """,
      [
        ids,
        List.duplicate(batch_id, length(ids)),
        operation_ids,
        fingerprints,
        source_row_sha256s
      ]
    )
  end

  defp deterministic_identity_operation_id(event_id, fingerprint) do
    suffix =
      {event_id, fingerprint}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "legacy_identity_v1_" <> suffix
  end

  defp update_identity_batch_count!(repo, batch_id, staged_count) do
    query!(
      repo,
      """
      UPDATE #{table(repo, @identity_batches)}
      SET staged_count = $2, status = 'staged'
      WHERE batch_id = $1
      """,
      [batch_id, staged_count]
    )
  end

  defp fetch_staged_identity_batch!(repo, batch_id) do
    case query!(
           repo,
           """
           SELECT expected_event_count, staged_count, source_backup_digest
           FROM #{table(repo, @identity_batches)}
           WHERE batch_id = $1 AND status = 'staged'
           """,
           [batch_id]
         ) do
      [[expected_event_count, staged_count, source_backup_digest]] ->
        %{
          batch_id: batch_id,
          expected_event_count: expected_event_count,
          staged_count: staged_count,
          source_backup_digest: source_backup_digest
        }

      [] ->
        raise("no staged identity remediation batch #{inspect(batch_id)}")
    end
  end

  defp assert_identity_stage_complete!(repo, batch) do
    current_count = scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, "events")}")

    staged_rows =
      scalar!(repo, "SELECT COUNT(*) FROM #{table(repo, @identity_rows)} WHERE batch_id = $1", [
        batch.batch_id
      ])

    legacy_rows =
      scalar!(
        repo,
        "SELECT COUNT(*) FROM #{table(repo, "events")} WHERE operation_id IS NULL AND operation_fingerprint IS NULL"
      )

    if current_count == batch.expected_event_count and staged_rows == batch.staged_count and
         legacy_rows == batch.staged_count,
       do: :ok,
       else: raise("identity staging no longer matches the EventLog snapshot")
  end

  defp verify_staged_identity_pages!(repo, batch_id, batch_size, last_id, verified_count) do
    rows = identity_verification_page!(repo, batch_id, batch_size, last_id)

    case rows do
      [] ->
        verified_count

      _ ->
        Enum.each(rows, &verify_identity_row!(&1, :staged))

        verify_staged_identity_pages!(
          repo,
          batch_id,
          batch_size,
          rows |> List.last() |> hd(),
          verified_count + length(rows)
        )
    end
  end

  defp verify_applied_identity_pages!(repo, batch_id, batch_size, last_id, verified_count) do
    rows = identity_verification_page!(repo, batch_id, batch_size, last_id)

    case rows do
      [] ->
        verified_count

      _ ->
        Enum.each(rows, &verify_identity_row!(&1, :applied))

        verify_applied_identity_pages!(
          repo,
          batch_id,
          batch_size,
          rows |> List.last() |> hd(),
          verified_count + length(rows)
        )
    end
  end

  defp assert_identity_verification_count!(actual, expected) do
    if actual == expected,
      do: :ok,
      else: raise("identity staging row count changed during verification")
  end

  defp identity_verification_page!(repo, batch_id, batch_size, nil) do
    query!(
      repo,
      """
      SELECT staged.event_id, staged.operation_id, staged.operation_fingerprint,
             staged.source_row_sha256,
             event.stream_id, event.event_number, event.global_position, event.type,
             event.data, event.metadata, event.agent_id, event.causation_id,
             event.correlation_id, event.event_timestamp, event.operation_id,
             event.operation_fingerprint, #{identity_source_checksum_sql("event")}
      FROM #{table(repo, @identity_rows)} staged
      JOIN #{table(repo, "events")} event ON event.id = staged.event_id
      WHERE staged.batch_id = $1
      ORDER BY staged.event_id
      LIMIT $2
      """,
      [batch_id, batch_size]
    )
  end

  defp identity_verification_page!(repo, batch_id, batch_size, last_id) when is_binary(last_id) do
    query!(
      repo,
      """
      SELECT staged.event_id, staged.operation_id, staged.operation_fingerprint,
             staged.source_row_sha256,
             event.stream_id, event.event_number, event.global_position, event.type,
             event.data, event.metadata, event.agent_id, event.causation_id,
             event.correlation_id, event.event_timestamp, event.operation_id,
             event.operation_fingerprint, #{identity_source_checksum_sql("event")}
      FROM #{table(repo, @identity_rows)} staged
      JOIN #{table(repo, "events")} event ON event.id = staged.event_id
      WHERE staged.batch_id = $1
        AND staged.event_id > $2
      ORDER BY staged.event_id
      LIMIT $3
      """,
      [batch_id, last_id, batch_size]
    )
  end

  defp verify_identity_row!(
         [
           id,
           staged_operation_id,
           staged_fingerprint,
           staged_source_row_sha256,
           stream_id,
           event_number,
           global_position,
           type,
           data,
           metadata,
           agent_id,
           causation_id,
           correlation_id,
           timestamp,
           operation_id,
           operation_fingerprint,
           current_source_row_sha256
         ],
         phase
       ) do
    event = %Event{
      id: id,
      stream_id: stream_id,
      event_number: event_number,
      global_position: global_position,
      type: type,
      data: data || %{},
      metadata: metadata || %{},
      agent_id: agent_id,
      causation_id: causation_id,
      correlation_id: correlation_id,
      timestamp: utc_datetime!(timestamp)
    }

    current_fingerprint = EventLog.event_fingerprint(stream_id, event)

    valid? =
      current_fingerprint == staged_fingerprint and
        current_source_row_sha256 == staged_source_row_sha256 and
        case phase do
          :staged ->
            is_nil(operation_id) and is_nil(operation_fingerprint)

          :applied ->
            operation_id == staged_operation_id and operation_fingerprint == staged_fingerprint
        end

    if valid?, do: :ok, else: raise("identity staging mismatch for event #{inspect(id)}")
  end

  defp apply_identity_rows!(repo, batch_id) do
    %{num_rows: count} =
      query_result!(
        repo,
        """
        UPDATE #{table(repo, "events")} event
        SET operation_id = staged.operation_id,
            operation_fingerprint = staged.operation_fingerprint
        FROM #{table(repo, @identity_rows)} staged
        WHERE staged.batch_id = $1
          AND staged.event_id = event.id
          AND event.operation_id IS NULL
          AND event.operation_fingerprint IS NULL
        """,
        [batch_id]
      )

    staged_count =
      scalar!(
        repo,
        "SELECT staged_count FROM #{table(repo, @identity_batches)} WHERE batch_id = $1",
        [batch_id]
      )

    if count == staged_count,
      do: :ok,
      else: raise("identity remediation updated an unexpected number of events")
  end

  defp validate_fingerprint_constraint!(repo) do
    query!(
      repo,
      "ALTER TABLE #{table(repo, "events")} VALIDATE CONSTRAINT events_operation_fingerprint_present"
    )
  end

  defp mark_identity_batch!(repo, batch_id, status) do
    query!(
      repo,
      """
      UPDATE #{table(repo, @identity_batches)}
      SET status = $2, applied_at = clock_timestamp()
      WHERE batch_id = $1
      """,
      [batch_id, status]
    )
  end

  defp utc_datetime!(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")
  defp utc_datetime!(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")
  defp utc_datetime!(other), do: raise("invalid persisted event timestamp: #{inspect(other)}")

  # jsonb text is canonicalized by PostgreSQL. These checksums cover all current
  # persisted event columns without materializing the log in the BEAM process.
  defp position_source_checksum_sql(event_alias) do
    "encode(sha256(convert_to((to_jsonb(#{event_alias}) - 'global_position')::text, 'UTF8')), 'hex')"
  end

  defp identity_source_checksum_sql(event_alias) do
    "encode(sha256(convert_to((to_jsonb(#{event_alias}) - 'operation_id' - 'operation_fingerprint')::text, 'UTF8')), 'hex')"
  end

  defp table(repo, name) do
    prefix = repo.config() |> Keyword.get(:prefix)
    quoted = quote_identifier(name)
    if prefix, do: quote_identifier(prefix) <> "." <> quoted, else: quoted
  end

  defp regclass_name(repo, name) do
    prefix = repo.config() |> Keyword.get(:prefix)
    if prefix, do: prefix <> "." <> name, else: name
  end

  defp quote_identifier(identifier), do: ~s("#{String.replace(identifier, "\"", "\"\"")}")

  defp scalar!(repo, sql, params \\ []) do
    [[value]] = query!(repo, sql, params)
    value
  end

  defp query!(repo, sql, params \\ []), do: query_result!(repo, sql, params).rows

  defp query_result!(repo, sql, params),
    do: repo.query!(sql, params, timeout: :infinity, prepare: :unnamed)
end
