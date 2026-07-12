defmodule Arbor.Persistence.Ecto.EventLogSchema do
  @moduledoc """
  Explicit schema migration and runtime verification for the EventStore adapter.

  Migrations require a deployment role with DDL privileges. Runtime verification
  only reads PostgreSQL catalogs and takes ordinary table locks, so application
  roles do not need permission to alter EventStore tables.
  """

  @migration_version 20_260_711_000_001
  @migration_lock "arbor.persistence.event_log.schema_migration"
  @stream_capacity_constraint "arbor_eventlog_stream_position_capacity"
  @global_capacity_constraint "arbor_eventlog_global_position_capacity"
  @operation_status_constraint "arbor_event_log_operations_terminal_status"
  @operation_identity_constraint "arbor_event_log_operations_identity_shape"
  @operation_primary_key "arbor_event_log_operations_pkey"
  @migration_file "priv/event_log/migrations/20260711000001_operation_fences_and_position_capacity.sql"
  @max_position 2_147_483_647

  @expected_stream_constraint "CHECK (((stream_id = 0) OR ((stream_version >= 0) AND (stream_version <= #{@max_position}))))"
  @expected_global_constraint "CHECK (((stream_id <> 0) OR ((stream_version >= 0) AND (stream_version <= #{@max_position}))))"
  @expected_operation_status_constraint "CHECK ((status = ANY (ARRAY['committed'::text, 'aborted'::text, 'conflict'::text])))"
  @expected_operation_identity_constraint "CHECK (((cardinality(event_ids) > 0) AND (cardinality(event_ids) = cardinality(fingerprints)) AND (array_position(event_ids, NULL::text) IS NULL) AND (array_position(fingerprints, NULL::text) IS NULL)))"
  @expected_operation_primary_key "PRIMARY KEY (operation_id)"

  @type verification_error ::
          :migration_missing
          | :operation_table_missing
          | :operation_table_invalid
          | :event_metadata_type_invalid
          | {:constraint_missing_or_invalid, String.t()}
          | term()

  @doc "Run Arbor's explicit EventStore schema migration and verify its result."
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

             unless migrated?(transaction, quoted_schema, timeout) do
               metadata_type = event_metadata_type!(transaction, schema, timeout)

               migration_statements(quoted_schema, metadata_type)
               |> Enum.each(&query!(transaction, &1, [], timeout))

               query!(
                 transaction,
                 "INSERT INTO #{quoted_schema}.arbor_event_log_schema_migrations (version) VALUES ($1)",
                 [@migration_version],
                 timeout
               )
             end

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

  @doc "Verify the exact migrated schema while holding locks appropriate to `mode`."
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
         :ok <- verify_migration(conn, quoted_schema, timeout),
         :ok <- verify_metadata_type(conn, schema, timeout),
         :ok <- verify_operation_columns(conn, schema, timeout),
         :ok <- verify_constraints(conn, schema, timeout) do
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

  defp migration_statements(quoted_schema, metadata_type) do
    metadata_json =
      case metadata_type do
        "bytea" ->
          "convert_from(events.metadata, 'UTF8')::jsonb"

        "jsonb" ->
          "(CASE WHEN jsonb_typeof(events.metadata) = 'string' " <>
            "THEN (events.metadata #>> '{}')::jsonb ELSE events.metadata END)"
      end

    :arbor_persistence_ecto
    |> Application.app_dir(@migration_file)
    |> File.read!()
    |> String.replace("__SCHEMA__", quoted_schema)
    |> String.replace("__SCHEMA_LITERAL__", quote_literal(unquote_identifier(quoted_schema)))
    |> String.replace("__METADATA_JSON__", metadata_json)
    |> String.split("-- arbor:statement")
    |> tl()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp migrated?(conn, quoted_schema, timeout) do
    query!(
      conn,
      "SELECT EXISTS (SELECT 1 FROM #{quoted_schema}.arbor_event_log_schema_migrations WHERE version = $1)",
      [@migration_version],
      timeout
    ).rows == [[true]]
  end

  defp lock_schema(_conn, _schema, :none, _timeout), do: :ok

  defp lock_schema(conn, schema, :append, timeout) do
    query!(
      conn,
      "LOCK TABLE #{schema}.streams, #{schema}.arbor_event_log_operations IN ROW EXCLUSIVE MODE",
      [],
      timeout
    )

    :ok
  end

  defp lock_schema(conn, schema, lock, timeout) when lock in [:reconcile, :migration] do
    query!(
      conn,
      "LOCK TABLE #{schema}.arbor_event_log_operations IN ROW EXCLUSIVE MODE",
      [],
      timeout
    )

    :ok
  end

  defp verify_migration(conn, schema, timeout) do
    case query!(
           conn,
           "SELECT EXISTS (SELECT 1 FROM #{schema}.arbor_event_log_schema_migrations WHERE version = $1)",
           [@migration_version],
           timeout
         ).rows do
      [[true]] -> :ok
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
      [["bytea", "bytea"]] -> :ok
      [["jsonb", "jsonb"]] -> :ok
      _other -> {:error, :event_metadata_type_invalid}
    end
  end

  defp event_metadata_type!(conn, schema, timeout) do
    sql = """
    SELECT data_type
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = 'events' AND column_name = 'metadata'
    """

    case query!(conn, sql, [schema], timeout).rows do
      [[type]] when type in ["bytea", "jsonb"] -> type
      other -> raise "unsupported EventStore metadata column: #{inspect(other)}"
    end
  end

  defp verify_operation_columns(conn, schema, timeout) do
    sql = """
    SELECT column_name, data_type, udt_name, is_nullable
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = 'arbor_event_log_operations'
    ORDER BY ordinal_position
    """

    expected = [
      ["operation_id", "text", "text", "NO"],
      ["stream_id", "text", "text", "NO"],
      ["event_ids", "ARRAY", "_text", "NO"],
      ["fingerprints", "ARRAY", "_text", "NO"],
      ["status", "text", "text", "NO"],
      ["reason", "text", "text", "YES"],
      ["inserted_at", "timestamp with time zone", "timestamptz", "NO"],
      ["updated_at", "timestamp with time zone", "timestamptz", "NO"]
    ]

    case query!(conn, sql, [schema], timeout).rows do
      ^expected -> :ok
      [] -> {:error, :operation_table_missing}
      _other -> {:error, :operation_table_invalid}
    end
  end

  defp verify_constraints(conn, schema, timeout) do
    quoted_schema = quote_identifier(schema)

    sql = """
    SELECT constraints.conname,
           pg_get_constraintdef(constraints.oid, false),
           constraints.convalidated
    FROM pg_constraint AS constraints
    WHERE constraints.conrelid IN (to_regclass($2::text), to_regclass($3::text))
      AND constraints.conname = ANY($1::text[])
    ORDER BY constraints.conname
    """

    actual =
      conn
      |> query!(
        sql,
        [
          [
            @stream_capacity_constraint,
            @global_capacity_constraint,
            @operation_status_constraint,
            @operation_identity_constraint,
            @operation_primary_key
          ],
          "#{quoted_schema}.streams",
          "#{quoted_schema}.arbor_event_log_operations"
        ],
        timeout
      )
      |> Map.fetch!(:rows)
      |> Map.new(fn [name, definition, validated] -> {name, {definition, validated}} end)

    expected = %{
      @stream_capacity_constraint => @expected_stream_constraint,
      @global_capacity_constraint => @expected_global_constraint,
      @operation_status_constraint => @expected_operation_status_constraint,
      @operation_identity_constraint => @expected_operation_identity_constraint,
      @operation_primary_key => @expected_operation_primary_key
    }

    Enum.reduce_while(expected, :ok, fn {name, definition}, :ok ->
      case Map.get(actual, name) do
        {^definition, true} -> {:cont, :ok}
        _missing_or_invalid -> {:halt, {:error, {:constraint_missing_or_invalid, name}}}
      end
    end)
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
