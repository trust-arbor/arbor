defmodule Arbor.Persistence.Ecto.EventLogSchema do
  @moduledoc """
  Explicit migration ledger and runtime schema verification for EventStore.

  Protocol epoch 3 is a maintenance cutover: its migration takes exclusive
  locks to drain old writers, then installs a database trigger that fences any
  old binary still writing afterward. Runtime verification performs no DDL.
  """

  @migration_v1 20_260_711_000_001
  @migration_v2 20_260_712_000_002
  @migration_lock "arbor.persistence.event_log.schema_migration"
  @migration_files [
    {@migration_v1,
     "priv/event_log/migrations/20260711000001_operation_fences_and_position_capacity.sql"},
    {@migration_v2, "priv/event_log/migrations/20260712000002_database_writer_fence.sql"}
  ]
  @protocol_version 3

  @stream_capacity_constraint "arbor_eventlog_stream_position_capacity"
  @global_capacity_constraint "arbor_eventlog_global_position_capacity"
  @operation_status_constraint "arbor_event_log_operations_terminal_status"
  @operation_identity_constraint "arbor_event_log_operations_identity_shape"
  @operation_primary_key "arbor_event_log_operations_pkey"
  @protocol_primary_key "arbor_event_log_protocol_pkey"
  @protocol_singleton_constraint "arbor_event_log_protocol_singleton_true"
  @protocol_version_constraint "arbor_event_log_protocol_version"
  @operation_index "arbor_event_log_operations_status_inserted_at_idx"
  @operation_trigger "arbor_event_log_operation_fence_insert"
  @operation_trigger_function "arbor_event_log_enforce_operation_fence"
  @max_position 2_147_483_647

  @expected_stream_constraint "CHECK (((stream_id = 0) OR ((stream_version >= 0) AND (stream_version <= #{@max_position}))))"
  @expected_global_constraint "CHECK (((stream_id <> 0) OR ((stream_version >= 0) AND (stream_version <= #{@max_position}))))"
  @expected_operation_status_constraint "CHECK ((status = ANY (ARRAY['committed'::text, 'aborted'::text, 'conflict'::text])))"
  @expected_operation_identity_constraint "CHECK (((cardinality(event_ids) > 0) AND (cardinality(event_ids) = cardinality(fingerprints)) AND (array_position(event_ids, NULL::text) IS NULL) AND (array_position(fingerprints, NULL::text) IS NULL)))"
  @expected_operation_primary_key "PRIMARY KEY (operation_id)"
  @expected_protocol_primary_key "PRIMARY KEY (singleton)"
  @expected_protocol_singleton_constraint "CHECK (singleton)"
  @expected_protocol_version_constraint "CHECK ((protocol_version = 3))"

  @type verification_error ::
          :migration_missing
          | :operation_table_missing
          | :protocol_table_missing
          | :event_metadata_type_invalid
          | :protocol_version_invalid
          | :operation_index_invalid
          | :operation_trigger_invalid
          | {:operation_column_invalid, String.t()}
          | {:protocol_column_invalid, String.t()}
          | {:constraint_missing_or_invalid, String.t()}
          | term()

  @doc "Run every pending Arbor EventStore migration and verify the result."
  @spec migrate!(GenServer.server(), String.t(), keyword()) :: :ok
  def migrate!(conn, schema, opts \\ []) when is_binary(schema) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    quoted_schema = quote_identifier(schema)

    case Postgrex.transaction(
           conn,
           fn transaction ->
             query!(
               transaction,
               "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
               [@migration_lock],
               timeout
             )

             query!(
               transaction,
               """
               CREATE TABLE IF NOT EXISTS #{quoted_schema}.arbor_event_log_schema_migrations (
                 version bigint PRIMARY KEY,
                 migrated_at timestamptz NOT NULL DEFAULT clock_timestamp()
               )
               """,
               [],
               timeout
             )

             metadata_type = event_metadata_type!(transaction, schema, timeout)

             Enum.each(@migration_files, fn {version, migration_file} ->
               unless migrated?(transaction, quoted_schema, version, timeout) do
                 migration_file
                 |> migration_statements(quoted_schema, metadata_type)
                 |> Enum.each(&query!(transaction, &1, [], timeout))

                 query!(
                   transaction,
                   "INSERT INTO #{quoted_schema}.arbor_event_log_schema_migrations (version) VALUES ($1)",
                   [version],
                   timeout
                 )
               end
             end)

             case verify(transaction, schema, timeout: timeout, lock: :migration) do
               :ok -> :ok
               {:error, reason} -> Postgrex.rollback(transaction, reason)
             end
           end,
           timeout: timeout
         ) do
      {:ok, :ok} -> :ok
      {:error, reason} -> raise "EventLog schema migration failed: #{inspect(reason)}"
    end
  end

  @doc "Verify the exact protocol schema while holding locks appropriate to `mode`."
  @spec verify(GenServer.server(), String.t(), keyword()) ::
          :ok | {:error, verification_error()}
  def verify(conn, schema, opts \\ []) when is_binary(schema) and is_list(opts) do
    timeout =
      case Keyword.fetch(opts, :deadline_mono) do
        {:ok, deadline_mono} -> {:deadline, deadline_mono}
        :error -> Keyword.fetch!(opts, :timeout)
      end

    lock = Keyword.get(opts, :lock, :none)
    quoted_schema = quote_identifier(schema)

    with :ok <- lock_schema(conn, quoted_schema, lock, timeout),
         :ok <- verify_migrations(conn, quoted_schema, timeout),
         {:ok, metadata_type} <- verify_metadata_type(conn, schema, timeout),
         :ok <- verify_operation_columns(conn, schema, timeout),
         :ok <- verify_protocol_columns(conn, schema, timeout),
         :ok <- verify_protocol_version(conn, quoted_schema, timeout),
         :ok <- verify_constraints(conn, schema, timeout),
         :ok <- verify_operation_index(conn, schema, timeout),
         :ok <- verify_operation_trigger(conn, schema, metadata_type, timeout) do
      :ok
    end
  rescue
    error -> {:error, error}
  catch
    _kind, reason -> {:error, reason}
  end

  @doc false
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(identifier) when is_binary(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end

  @doc false
  @spec migration_versions() :: [integer()]
  def migration_versions, do: Enum.map(@migration_files, &elem(&1, 0))

  defp migration_statements(migration_file, quoted_schema, metadata_type) do
    metadata_json = metadata_json_expression(metadata_type, "events.metadata")
    new_metadata_json = metadata_json_expression(metadata_type, "NEW.metadata")

    :arbor_persistence_ecto
    |> Application.app_dir(migration_file)
    |> File.read!()
    |> String.replace("__SCHEMA__", quoted_schema)
    |> String.replace("__SCHEMA_LITERAL__", quote_literal(unquote_identifier(quoted_schema)))
    |> String.replace("__METADATA_JSON__", metadata_json)
    |> String.replace("__NEW_METADATA_JSON__", new_metadata_json)
    |> String.split("-- arbor:statement")
    |> tl()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp metadata_json_expression("bytea", field),
    do: "convert_from(#{field}, 'UTF8')::jsonb"

  defp metadata_json_expression("jsonb", field) do
    "(CASE WHEN jsonb_typeof(#{field}) = 'string' " <>
      "THEN (#{field} #>> '{}')::jsonb ELSE #{field} END)"
  end

  defp migrated?(conn, quoted_schema, version, timeout) do
    query!(
      conn,
      "SELECT EXISTS (SELECT 1 FROM #{quoted_schema}.arbor_event_log_schema_migrations WHERE version = $1)",
      [version],
      timeout
    ).rows == [[true]]
  end

  defp lock_schema(_conn, _schema, :none, _timeout), do: :ok

  defp lock_schema(conn, schema, lock, timeout) when lock in [:append, :migration] do
    query!(
      conn,
      "LOCK TABLE #{schema}.streams, #{schema}.events, #{schema}.stream_events, " <>
        "#{schema}.arbor_event_log_operations, #{schema}.arbor_event_log_protocol " <>
        "IN ROW EXCLUSIVE MODE",
      [],
      timeout
    )

    :ok
  end

  defp lock_schema(conn, schema, :reconcile, timeout) do
    query!(
      conn,
      "LOCK TABLE #{schema}.streams, #{schema}.events, #{schema}.stream_events, " <>
        "#{schema}.arbor_event_log_protocol IN ACCESS SHARE MODE",
      [],
      timeout
    )

    query!(
      conn,
      "LOCK TABLE #{schema}.arbor_event_log_operations IN ROW EXCLUSIVE MODE",
      [],
      timeout
    )

    :ok
  end

  defp verify_migrations(conn, schema, timeout) do
    versions = migration_versions()
    expected_rows = Enum.map(versions, &[&1])

    sql = """
    SELECT version
    FROM #{schema}.arbor_event_log_schema_migrations
    WHERE version = ANY($1::bigint[])
    ORDER BY version
    """

    case query!(conn, sql, [versions], timeout).rows do
      ^expected_rows -> :ok
      _missing -> {:error, :migration_missing}
    end
  end

  defp verify_metadata_type(conn, schema, timeout) do
    sql = """
    SELECT data_type, udt_name
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = 'events' AND column_name = 'metadata'
    """

    case query!(conn, sql, [schema], timeout).rows do
      [["bytea", "bytea"]] -> {:ok, "bytea"}
      [["jsonb", "jsonb"]] -> {:ok, "jsonb"}
      _other -> {:error, :event_metadata_type_invalid}
    end
  end

  defp event_metadata_type!(conn, schema, timeout) do
    case verify_metadata_type(conn, schema, timeout) do
      {:ok, type} -> type
      {:error, _reason} -> raise "unsupported EventStore metadata column in #{schema}"
    end
  end

  defp verify_operation_columns(conn, schema, timeout) do
    expected = [
      expected_column("operation_id", "text", "text", "NO", nil),
      expected_column("stream_id", "text", "text", "NO", nil),
      expected_column("event_ids", "ARRAY", "_text", "NO", nil),
      expected_column("fingerprints", "ARRAY", "_text", "NO", nil),
      expected_column("status", "text", "text", "NO", nil),
      expected_column("reason", "text", "text", "YES", nil),
      expected_column(
        "inserted_at",
        "timestamp with time zone",
        "timestamptz",
        "NO",
        "clock_timestamp()"
      ),
      expected_column(
        "updated_at",
        "timestamp with time zone",
        "timestamptz",
        "NO",
        "clock_timestamp()"
      )
    ]

    verify_columns(
      conn,
      schema,
      "arbor_event_log_operations",
      expected,
      :operation_table_missing,
      :operation_column_invalid,
      timeout
    )
  end

  defp verify_protocol_columns(conn, schema, timeout) do
    expected = [
      expected_column("singleton", "boolean", "bool", "NO", "true"),
      expected_column("protocol_version", "bigint", "int8", "NO", nil),
      expected_column(
        "cutover_at",
        "timestamp with time zone",
        "timestamptz",
        "NO",
        "clock_timestamp()"
      )
    ]

    verify_columns(
      conn,
      schema,
      "arbor_event_log_protocol",
      expected,
      :protocol_table_missing,
      :protocol_column_invalid,
      timeout
    )
  end

  defp verify_columns(
         conn,
         schema,
         table,
         expected,
         missing_error,
         invalid_tag,
         timeout
       ) do
    sql = """
    SELECT column_name,
           data_type,
           udt_name,
           is_nullable,
           column_default,
           is_identity,
           is_generated,
           generation_expression
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    ORDER BY ordinal_position
    """

    case query!(conn, sql, [schema, table], timeout).rows do
      ^expected ->
        :ok

      [] ->
        {:error, missing_error}

      actual ->
        name = first_invalid_column(expected, actual)
        {:error, {invalid_tag, name}}
    end
  end

  defp expected_column(name, data_type, udt_name, nullable, default) do
    [name, data_type, udt_name, nullable, default, "NO", "NEVER", nil]
  end

  defp first_invalid_column(expected, actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.find_value(fn
      {row, row} -> nil
      {[name | _expected], _actual} -> name
    end)
    |> case do
      nil ->
        case Enum.at(actual, length(expected)) do
          [name | _rest] -> name
          nil -> expected |> Enum.at(length(actual)) |> List.first()
        end

      name ->
        name
    end
  end

  defp verify_protocol_version(conn, quoted_schema, timeout) do
    sql = """
    SELECT singleton, protocol_version
    FROM #{quoted_schema}.arbor_event_log_protocol
    """

    case query!(conn, sql, [], timeout).rows do
      [[true, @protocol_version]] -> :ok
      _invalid -> {:error, :protocol_version_invalid}
    end
  end

  defp verify_constraints(conn, schema, timeout) do
    quoted_schema = quote_identifier(schema)

    expected = %{
      @stream_capacity_constraint => @expected_stream_constraint,
      @global_capacity_constraint => @expected_global_constraint,
      @operation_status_constraint => @expected_operation_status_constraint,
      @operation_identity_constraint => @expected_operation_identity_constraint,
      @operation_primary_key => @expected_operation_primary_key,
      @protocol_primary_key => @expected_protocol_primary_key,
      @protocol_singleton_constraint => @expected_protocol_singleton_constraint,
      @protocol_version_constraint => @expected_protocol_version_constraint
    }

    sql = """
    SELECT constraints.conname,
           pg_get_constraintdef(constraints.oid, false),
           constraints.convalidated
    FROM pg_constraint AS constraints
    WHERE constraints.conrelid IN (
      to_regclass($2::text),
      to_regclass($3::text),
      to_regclass($4::text)
    )
      AND constraints.conname = ANY($1::text[])
    ORDER BY constraints.conname
    """

    actual =
      conn
      |> query!(
        sql,
        [
          Map.keys(expected),
          "#{quoted_schema}.streams",
          "#{quoted_schema}.arbor_event_log_operations",
          "#{quoted_schema}.arbor_event_log_protocol"
        ],
        timeout
      )
      |> Map.fetch!(:rows)
      |> Map.new(fn [name, definition, validated] -> {name, {definition, validated}} end)

    Enum.reduce_while(expected, :ok, fn {name, definition}, :ok ->
      case Map.get(actual, name) do
        {^definition, true} -> {:cont, :ok}
        _missing_or_invalid -> {:halt, {:error, {:constraint_missing_or_invalid, name}}}
      end
    end)
  end

  defp verify_operation_index(conn, schema, timeout) do
    sql = """
    SELECT indexes.indisunique,
           indexes.indisvalid,
           indexes.indisready,
           pg_get_indexdef(indexes.indexrelid, 0, false)
    FROM pg_index AS indexes
    INNER JOIN pg_class AS index_class ON index_class.oid = indexes.indexrelid
    INNER JOIN pg_class AS table_class ON table_class.oid = indexes.indrelid
    INNER JOIN pg_namespace AS namespaces ON namespaces.oid = table_class.relnamespace
    WHERE namespaces.nspname = $1
      AND table_class.relname = 'arbor_event_log_operations'
      AND index_class.relname = $2
    """

    expected_definition =
      "CREATE INDEX #{@operation_index} ON #{quote_identifier(schema)}." <>
        "arbor_event_log_operations USING btree (status, inserted_at)"

    case query!(conn, sql, [schema, @operation_index], timeout).rows do
      [[false, true, true, definition]] ->
        if normalize_sql(definition) == normalize_sql(expected_definition),
          do: :ok,
          else: {:error, :operation_index_invalid}

      _invalid ->
        {:error, :operation_index_invalid}
    end
  end

  defp verify_operation_trigger(conn, schema, metadata_type, timeout) do
    sql = """
    SELECT pg_get_triggerdef(triggers.oid, false),
           triggers.tgenabled::text,
           procedures.prosrc,
           procedure_namespaces.nspname,
           procedures.prosecdef,
           procedures.proleakproof,
           procedures.provolatile::text,
           procedures.proparallel::text,
           procedures.proconfig,
           pg_get_function_result(procedures.oid),
           pg_get_function_arguments(procedures.oid)
    FROM pg_trigger AS triggers
    INNER JOIN pg_class AS tables ON tables.oid = triggers.tgrelid
    INNER JOIN pg_namespace AS namespaces ON namespaces.oid = tables.relnamespace
    INNER JOIN pg_proc AS procedures ON procedures.oid = triggers.tgfoid
    INNER JOIN pg_namespace AS procedure_namespaces
      ON procedure_namespaces.oid = procedures.pronamespace
    WHERE namespaces.nspname = $1
      AND tables.relname = 'events'
      AND triggers.tgname = $2
      AND NOT triggers.tgisinternal
    """

    expected_trigger =
      "CREATE TRIGGER #{@operation_trigger} BEFORE INSERT ON #{schema}.events " <>
        "FOR EACH ROW EXECUTE FUNCTION #{@operation_trigger_function}()"

    expected_source = expected_trigger_source(schema, metadata_type)

    case query!(conn, sql, [schema, @operation_trigger], timeout).rows do
      [
        [
          trigger_definition,
          "O",
          source,
          ^schema,
          false,
          false,
          "v",
          "u",
          nil,
          "trigger",
          ""
        ]
      ] ->
        if normalize_sql(trigger_definition) == normalize_sql(expected_trigger) and
             normalize_sql(source) == normalize_sql(expected_source),
           do: :ok,
           else: {:error, :operation_trigger_invalid}

      _invalid ->
        {:error, :operation_trigger_invalid}
    end
  end

  defp expected_trigger_source(schema, metadata_type) do
    quoted_schema = quote_identifier(schema)
    metadata_json = metadata_json_expression(metadata_type, "NEW.metadata")

    """
    DECLARE
      metadata_json jsonb;
      operation_id_value text;
      fingerprint_value text;
      event_id_value text;
      fence_status text;
    BEGIN
      metadata_json := #{metadata_json};

      IF metadata_json IS NULL
         OR jsonb_typeof(metadata_json -> 'arbor_append_operation_id') <> 'string'
         OR jsonb_typeof(metadata_json -> 'arbor_append_fingerprint') <> 'string'
         OR jsonb_typeof(metadata_json -> 'event_id') <> 'string' THEN
        RAISE EXCEPTION 'EventLog operation identity is required after protocol cutover'
          USING ERRCODE = '23514';
      END IF;

      operation_id_value := metadata_json ->> 'arbor_append_operation_id';
      fingerprint_value := metadata_json ->> 'arbor_append_fingerprint';
      event_id_value := metadata_json ->> 'event_id';

      IF octet_length(operation_id_value) NOT BETWEEN 1 AND 255
         OR fingerprint_value !~ '^[0-9a-f]{64}$'
         OR octet_length(event_id_value) NOT BETWEEN 1 AND 255 THEN
        RAISE EXCEPTION 'EventLog operation identity is malformed'
          USING ERRCODE = '23514';
      END IF;

      PERFORM pg_advisory_xact_lock(hashtextextended(operation_id_value, 1));

      SELECT status
      INTO fence_status
      FROM #{quoted_schema}.arbor_event_log_operations
      WHERE operation_id = operation_id_value;

      IF FOUND THEN
        RAISE EXCEPTION 'EventLog operation % is terminal (%)', operation_id_value, fence_status
          USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END
    """
  end

  defp normalize_sql(sql) do
    sql
    |> String.replace("\"", "")
    |> String.split()
    |> Enum.join(" ")
    |> String.trim_trailing(";")
  end

  defp query!(conn, sql, params, timeout) do
    Postgrex.query!(conn, sql, params, timeout: query_timeout(timeout))
  end

  defp query_timeout({:deadline, deadline_mono}) do
    remaining = deadline_mono - System.monotonic_time(:millisecond)
    if remaining > 0, do: remaining, else: throw(:operation_timeout)
  end

  defp query_timeout(timeout), do: timeout

  defp quote_literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp unquote_identifier(<<?\", rest::binary>>) do
    rest
    |> binary_part(0, byte_size(rest) - 1)
    |> String.replace("\"\"", "\"")
  end
end
