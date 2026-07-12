defmodule Arbor.Persistence.Ecto.EventLog do
  @moduledoc """
  Postgres-backed implementation of the EventLog behaviour using `eventstore`.

  Provides durable, crash-recoverable event storage with optimistic concurrency
  control and subscription support.

  ## Configuration

  Requires `Arbor.Persistence.Ecto.EventStore` to be configured and started.
  See that module for configuration options.

  ## Usage

      # Start the EventStore in your supervision tree
      children = [
        Arbor.Persistence.Ecto.EventStore
      ]

      # Append events
      event = Event.new("order-123", "OrderPlaced", %{amount: 100})
      {:ok, [persisted]} = Arbor.Persistence.Ecto.EventLog.append("order-123", event, [])

      # Read events
      {:ok, events} = Arbor.Persistence.Ecto.EventLog.read_stream("order-123", [])

  ## Optimistic Concurrency

  Pass a non-negative `expected_version: version` in opts to enable optimistic
  concurrency. This EventStore-backed adapter cannot atomically enforce
  `:max_current_age_ms` through EventStore's public API and returns
  `{:error, :unsupported_precondition}` when it is requested.

      # Append only if stream is at version 2
      {:ok, events} = append(stream_id, events, expected_version: 2)

      # Append regardless of version (default)
      {:ok, events} = append(stream_id, events)

  ## Append Deadlines

  `:append_timeout_ms` sets one absolute `1..60_000` millisecond budget across
  validation, pool checkout, append, commit reply, and exact-ID readback. A
  transport or commit-phase ambiguity returns
  `{:error, {:append_indeterminate, operation}}`; reconcile that operation or
  retry the exact same event IDs and content.
  """

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Persistence.Ecto.EventLogSchema
  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.{Event, EventLog}

  require Logger

  @position_lookup_timeout_ms 5_000
  @fingerprint_key "arbor_append_fingerprint"
  @operation_key "arbor_append_operation_id"
  @event_id_key "event_id"
  @agent_id_key "arbor_agent_id"
  @timestamp_key "arbor_event_timestamp"
  @operation_lock_sql "SELECT pg_advisory_xact_lock(hashtextextended($1, 1))"
  @reserved_metadata_keys [
    @event_id_key,
    @agent_id_key,
    "causation_id",
    "correlation_id",
    @timestamp_key,
    @operation_key,
    @fingerprint_key
  ]
  @reserved_input_metadata_keys @reserved_metadata_keys ++
                                  [
                                    :event_id,
                                    :arbor_agent_id,
                                    :causation_id,
                                    :correlation_id,
                                    :arbor_event_timestamp,
                                    :arbor_append_operation_id,
                                    :arbor_append_fingerprint
                                  ]

  # ============================================================================
  # EventLog Behaviour Implementation
  # ============================================================================

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts \\ []) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with {:ok, events, preconditions, _initial_operation, ^deadline_mono} <-
             EventLog.prepare_append(stream_id, events, normalized_opts),
           events = Enum.map(events, &sanitize_submitted_event/1),
           {:ok, operation} <- EventLog.build_operation(stream_id, events),
           :ok <- reject_freshness(preconditions.max_current_age_ms),
           :ok <- ensure_event_serializer() do
        result =
          run_bounded(
            fn -> append_prepared(stream_id, events, preconditions, operation, deadline_mono) end,
            operation,
            deadline_mono
          )

        EventLog.accept_completion(
          result,
          operation,
          deadline_mono,
          System.monotonic_time(:millisecond)
        )
      end
    end)
  end

  defp append_prepared(stream_id, events, preconditions, operation, deadline_mono) do
    with {:ok, conn, schema} <- event_store_connection(),
         {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono) do
      result =
        Postgrex.transaction(
          conn,
          fn transaction ->
            append_in_transaction(
              transaction,
              schema,
              stream_id,
              events,
              preconditions,
              operation,
              deadline_mono
            )
          end,
          timeout: timeout
        )

      case result do
        {:ok, append_result} -> append_result
        {:error, _reason} -> EventLog.indeterminate(operation)
      end
    else
      _unavailable -> EventLog.indeterminate(operation)
    end
  rescue
    _error -> EventLog.indeterminate(operation)
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  @impl Arbor.Persistence.EventLog
  def reconcile_append(operation, opts) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with {:ok, operation, _normalized_opts, ^deadline_mono} <-
             EventLog.prepare_reconcile(operation, normalized_opts),
           :ok <- ensure_event_serializer() do
        run_bounded(
          fn -> reconcile_operation(operation, deadline_mono) end,
          operation,
          deadline_mono
        )
      end
    end)
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts \\ []) do
    with {:ok, opts} <- EventLog.normalize_opts(opts),
         :ok <- ensure_event_serializer() do
      start_version = Keyword.get(opts, :from, 0)
      count = Keyword.get(opts, :limit, 1000)

      case Store.read_stream_forward(stream_id, start_version, count) do
        {:ok, recorded_events} ->
          from_stream_recordings(recorded_events)

        {:error, :stream_not_found} ->
          {:ok, []}

        {:error, reason} = error ->
          Logger.error("Failed to read stream #{stream_id}: #{inspect(reason)}")
          error
      end
    end
  rescue
    error -> {:error, {:read_failed, error}}
  catch
    :exit, reason -> {:error, {:read_failed, reason}}
  end

  @impl Arbor.Persistence.EventLog
  def read_stream_head(stream_id, opts \\ []) do
    with {:ok, max_current_age_ms} <- EventLog.validate_head_read(stream_id, opts),
         :ok <- reject_freshness(max_current_age_ms),
         :ok <- ensure_event_serializer() do
      read_atomic_stream_head(stream_id)
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_all(opts \\ []) do
    with {:ok, opts} <- EventLog.normalize_opts(opts),
         :ok <- ensure_event_serializer() do
      start_position = Keyword.get(opts, :from, 0)
      count = Keyword.get(opts, :limit, 1000)

      case Store.read_all_streams_forward(start_position, count) do
        {:ok, recorded_events} ->
          events = Enum.map(recorded_events, &from_recorded_event(&1, &1.event_number))
          {:ok, events}

        {:error, reason} = error ->
          Logger.error("Failed to read all streams: #{inspect(reason)}")
          error
      end
    end
  rescue
    error -> {:error, {:read_failed, error}}
  catch
    :exit, reason -> {:error, {:read_failed, reason}}
  end

  @impl Arbor.Persistence.EventLog
  def stream_exists?(stream_id, _opts \\ []) do
    case Store.stream_info(stream_id) do
      {:ok, %{stream_version: version}} when version > 0 -> true
      _ -> false
    end
  end

  @impl Arbor.Persistence.EventLog
  def stream_version(stream_id, _opts \\ []) do
    case Store.stream_info(stream_id) do
      {:ok, %{stream_version: version}} -> {:ok, version}
      {:error, :stream_not_found} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Arbor.Persistence.EventLog
  def subscribe(stream_id_or_all, pid, opts \\ []) do
    with {:ok, opts} <- EventLog.normalize_opts(opts),
         :ok <- ensure_event_serializer() do
      subscription_name = Keyword.get(opts, :name, "subscription_#{:erlang.unique_integer()}")

      result =
        case stream_id_or_all do
          :all ->
            Store.subscribe_to_all_streams(
              subscription_name,
              subscriber_with_pid(pid),
              subscription_opts(opts)
            )

          stream_id ->
            Store.subscribe_to_stream(
              stream_id,
              subscription_name,
              subscriber_with_pid(pid),
              subscription_opts(opts)
            )
        end

      case result do
        {:ok, subscription} ->
          ref = make_ref()
          Process.put({:eventstore_subscription, ref}, subscription)
          {:ok, ref}

        {:error, reason} = error ->
          Logger.error("Failed to subscribe: #{inspect(reason)}")
          error
      end
    end
  rescue
    error -> {:error, {:subscription_failed, error}}
  catch
    :exit, reason -> {:error, {:subscription_failed, reason}}
  end

  @impl Arbor.Persistence.EventLog
  def list_streams(_opts \\ []) do
    # EventStore doesn't have a direct list_streams API
    # We'd need to query the streams table directly
    # For now, return an error indicating this needs implementation
    Logger.warning("list_streams not yet implemented for Postgres backend")
    {:ok, []}
  end

  @impl Arbor.Persistence.EventLog
  def stream_count(_opts \\ []) do
    # Would need direct SQL query
    Logger.warning("stream_count not yet implemented for Postgres backend")
    {:ok, 0}
  end

  @impl Arbor.Persistence.EventLog
  def event_count(_opts \\ []) do
    # Would need direct SQL query
    Logger.warning("event_count not yet implemented for Postgres backend")
    {:ok, 0}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp run_bounded(fun, operation, deadline_mono) do
    case EventLog.remaining_timeout(deadline_mono) do
      {:ok, timeout} ->
        task = Task.async(fn -> EventLog.stamp_completion(fun.()) end)

        case Task.yield(task, timeout) do
          {:ok, completion} ->
            EventLog.accept_completion(completion, operation, deadline_mono)

          {:exit, _reason} ->
            EventLog.indeterminate(operation)

          nil ->
            _ = Task.shutdown(task, :brutal_kill)
            EventLog.indeterminate(operation)
        end

      {:error, :operation_timeout} ->
        EventLog.indeterminate(operation)
    end
  end

  defp append_in_transaction(
         conn,
         schema,
         stream_id,
         events,
         preconditions,
         operation,
         deadline_mono
       ) do
    with {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono),
         :ok <-
           EventLogSchema.verify(conn, schema,
             timeout: timeout,
             deadline_mono: deadline_mono,
             lock: :append
           ),
         :ok <- acquire_operation_lock(conn, operation.operation_id, deadline_mono),
         {:ok, stream_position, global_position} <-
           lock_position_rows(conn, schema, stream_id, deadline_mono) do
      case operation_state(conn, schema, operation, deadline_mono) do
        {:committed, persisted} ->
          {:ok, project_submitted_events(events, persisted, stream_id)}

        {:aborted, reason} ->
          {:error, aborted_append_reason(reason)}

        :conflict ->
          {:error, :event_identity_conflict}

        :absent ->
          append_new_operation(
            conn,
            schema,
            events,
            preconditions,
            operation,
            stream_position,
            global_position,
            deadline_mono
          )
      end
    else
      {:error, {:constraint_missing_or_invalid, _name} = reason} ->
        {:error, {:event_log_schema_unavailable, reason}}

      {:error, reason}
      when reason in [
             :migration_missing,
             :operation_table_missing,
             :operation_table_invalid,
             :event_metadata_type_invalid
           ] ->
        {:error, {:event_log_schema_unavailable, reason}}

      {:error, _reason} ->
        Postgrex.rollback(conn, :append_indeterminate)
    end
  end

  defp append_new_operation(
         conn,
         schema,
         events,
         preconditions,
         operation,
         stream_position,
         global_position,
         deadline_mono
       ) do
    with :ok <- enforce_expected_version(preconditions.expected_version, stream_position),
         :ok <-
           EventLog.ensure_position_capacity(stream_position, global_position, length(events)) do
      event_data =
        Enum.map(events, fn event ->
          to_event_data(
            event,
            deterministic_storage_id(event.id),
            operation.operation_id,
            Map.fetch!(operation.fingerprints, event.id)
          )
        end)

      {:ok, timeout} = EventLog.remaining_timeout(deadline_mono)
      expected_version = preconditions.expected_version || :any_version

      case Store.append_to_stream(operation.stream_id, expected_version, event_data,
             conn: conn,
             timeout: timeout
           ) do
        :ok ->
          case lookup_operation_events(conn, schema, operation, deadline_mono) do
            {:ok, {:committed, persisted}} ->
              insert_operation_fence!(conn, schema, operation, "committed", nil, deadline_mono)
              ensure_before_deadline!(conn, deadline_mono)
              {:ok, project_submitted_events(events, persisted, operation.stream_id)}

            _not_exact ->
              Postgrex.rollback(conn, :append_indeterminate)
          end

        {:error, :wrong_expected_version} ->
          insert_operation_fence!(
            conn,
            schema,
            operation,
            "aborted",
            "version_conflict",
            deadline_mono
          )

          {:error, :version_conflict}

        {:error, _reason} ->
          Postgrex.rollback(conn, :append_indeterminate)
      end
    else
      {:error, reason}
      when reason in [
             :version_conflict,
             :stream_position_exhausted,
             :global_position_exhausted
           ] ->
        insert_operation_fence!(
          conn,
          schema,
          operation,
          "aborted",
          Atom.to_string(reason),
          deadline_mono
        )

        {:error, reason}
    end
  end

  defp enforce_expected_version(nil, _stream_position), do: :ok
  defp enforce_expected_version(version, version), do: :ok
  defp enforce_expected_version(_expected, _actual), do: {:error, :version_conflict}

  defp aborted_append_reason("version_conflict"), do: :version_conflict
  defp aborted_append_reason("stream_position_exhausted"), do: :stream_position_exhausted
  defp aborted_append_reason("global_position_exhausted"), do: :global_position_exhausted
  defp aborted_append_reason(_reason), do: :operation_aborted

  defp project_submitted_events(submitted, persisted, stream_id) do
    persisted_by_id = Map.new(persisted, &{&1.id, &1})

    Enum.map(submitted, fn %Event{} = event ->
      stored = Map.fetch!(persisted_by_id, event.id)

      %Event{
        event
        | stream_id: stream_id,
          event_number: stored.event_number,
          global_position: stored.global_position
      }
    end)
  end

  # Convert our Event.t() to EventStore.EventData.
  defp to_event_data(%Event{} = event, storage_id, operation_id, fingerprint) do
    %EventStore.EventData{
      event_id: storage_id,
      event_type: event.type,
      data: event.data,
      metadata:
        Map.merge(event.metadata || %{}, %{
          @event_id_key => event.id,
          @agent_id_key => event.agent_id,
          "causation_id" => event.causation_id,
          "correlation_id" => event.correlation_id,
          @timestamp_key => encode_timestamp(event.timestamp),
          @operation_key => operation_id,
          @fingerprint_key => fingerprint
        })
    }
  end

  # Convert EventStore.RecordedEvent to our Event.t()
  defp from_recorded_event(%EventStore.RecordedEvent{} = recorded, global_position) do
    metadata = recorded.metadata || %{}

    %Event{
      id: Map.get(metadata, @event_id_key, recorded.event_id |> to_string()),
      stream_id: recorded.stream_uuid,
      event_number: recorded.stream_version,
      global_position: global_position,
      type: recorded.event_type,
      data: recorded.data || %{},
      metadata: Map.drop(metadata, @reserved_metadata_keys),
      causation_id: Map.get(metadata, "causation_id") || recorded.causation_id,
      correlation_id: Map.get(metadata, "correlation_id") || recorded.correlation_id,
      agent_id: Map.get(metadata, @agent_id_key),
      timestamp: decode_timestamp(Map.get(metadata, @timestamp_key), recorded.created_at)
    }
  end

  defp from_stream_recordings([]), do: {:ok, []}

  defp from_stream_recordings(recorded_events) do
    storage_ids = Enum.map(recorded_events, & &1.event_id)

    with {:ok, global_positions} <- lookup_global_positions(storage_ids),
         true <- map_size(global_positions) == length(storage_ids) do
      events =
        Enum.map(recorded_events, fn recorded ->
          from_recorded_event(recorded, Map.fetch!(global_positions, recorded.event_id))
        end)

      {:ok, events}
    else
      false -> {:error, :global_position_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp acquire_operation_lock(conn, operation_id, deadline_mono) do
    query_with_deadline!(conn, @operation_lock_sql, [operation_id], deadline_mono)
    :ok
  end

  defp lock_position_rows(conn, schema, stream_id, deadline_mono) do
    quoted_schema = EventLogSchema.quote_identifier(schema)

    global_sql = """
    SELECT stream_version
    FROM #{quoted_schema}.streams
    WHERE stream_id = 0
    FOR UPDATE
    """

    stream_sql = """
    SELECT stream_version
    FROM #{quoted_schema}.streams
    WHERE stream_id <> 0 AND stream_uuid = $1
    FOR UPDATE
    """

    with [[global_position]] <-
           query_with_deadline!(conn, global_sql, [], deadline_mono).rows do
      stream_position =
        case query_with_deadline!(conn, stream_sql, [stream_id], deadline_mono).rows do
          [[version]] -> version
          [] -> 0
        end

      {:ok, stream_position, global_position}
    else
      _missing_all_stream -> {:error, :event_store_uninitialized}
    end
  end

  defp reconcile_operation(%AppendOperation{} = operation, deadline_mono) do
    with {:ok, timeout} <- EventLog.remaining_timeout(deadline_mono),
         {:ok, conn, schema} <- event_store_connection() do
      result =
        Postgrex.transaction(
          conn,
          fn transaction ->
            with {:ok, verify_timeout} <- EventLog.remaining_timeout(deadline_mono),
                 :ok <-
                   EventLogSchema.verify(transaction, schema,
                     timeout: verify_timeout,
                     deadline_mono: deadline_mono,
                     lock: :reconcile
                   ),
                 :ok <-
                   acquire_operation_lock(
                     transaction,
                     operation.operation_id,
                     deadline_mono
                   ) do
              reconcile_and_terminalize(transaction, schema, operation, deadline_mono)
            else
              _unavailable -> Postgrex.rollback(transaction, :reconcile_indeterminate)
            end
          end,
          timeout: timeout
        )

      case result do
        {:ok, reconciliation} -> reconciliation
        {:error, _reason} -> EventLog.indeterminate(operation)
      end
    else
      _unavailable -> EventLog.indeterminate(operation)
    end
  rescue
    _error -> EventLog.indeterminate(operation)
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  defp reconcile_and_terminalize(conn, schema, operation, deadline_mono) do
    case operation_fence(conn, schema, operation.operation_id, deadline_mono) do
      nil ->
        terminalize_operation_from_events(conn, schema, operation, deadline_mono)

      fence ->
        case classify_operation_fence(conn, schema, fence, operation, deadline_mono) do
          {:committed, events} -> {:ok, {:committed, events}}
          {:aborted, _reason} -> {:ok, :absent}
          :conflict -> {:error, :event_identity_conflict}
        end
    end
  end

  defp operation_state(conn, schema, operation, deadline_mono) do
    case operation_fence(conn, schema, operation.operation_id, deadline_mono) do
      nil ->
        case lookup_operation_events(conn, schema, operation, deadline_mono) do
          {:ok, {:committed, events}} ->
            insert_operation_fence!(conn, schema, operation, "committed", nil, deadline_mono)
            {:committed, events}

          {:ok, :absent} ->
            :absent

          {:error, _conflict_or_partial} ->
            insert_operation_fence!(
              conn,
              schema,
              operation,
              "conflict",
              "event_identity_conflict",
              deadline_mono
            )

            :conflict
        end

      fence ->
        classify_operation_fence(conn, schema, fence, operation, deadline_mono)
    end
  end

  defp terminalize_operation_from_events(conn, schema, operation, deadline_mono) do
    case lookup_operation_events(conn, schema, operation, deadline_mono) do
      {:ok, {:committed, events}} ->
        insert_operation_fence!(conn, schema, operation, "committed", nil, deadline_mono)
        {:ok, {:committed, events}}

      {:ok, :absent} ->
        insert_operation_fence!(
          conn,
          schema,
          operation,
          "aborted",
          "reconciled_absent",
          deadline_mono
        )

        {:ok, :absent}

      {:error, _conflict_or_partial} ->
        insert_operation_fence!(
          conn,
          schema,
          operation,
          "conflict",
          "event_identity_conflict",
          deadline_mono
        )

        {:error, :event_identity_conflict}
    end
  end

  defp classify_operation_fence(conn, schema, fence, operation, deadline_mono) do
    if operation_fence_matches?(fence, operation) do
      case fence.status do
        "committed" ->
          case lookup_operation_events(conn, schema, operation, deadline_mono) do
            {:ok, {:committed, events}} -> {:committed, events}
            _missing_or_corrupt -> :conflict
          end

        "aborted" ->
          {:aborted, fence.reason}

        "conflict" ->
          :conflict

        _invalid ->
          :conflict
      end
    else
      :conflict
    end
  end

  defp operation_fence(conn, schema, operation_id, deadline_mono) do
    quoted_schema = EventLogSchema.quote_identifier(schema)

    sql = """
    SELECT stream_id, event_ids, fingerprints, status, reason
    FROM #{quoted_schema}.arbor_event_log_operations
    WHERE operation_id = $1
    """

    case query_with_deadline!(conn, sql, [operation_id], deadline_mono).rows do
      [] ->
        nil

      [[stream_id, event_ids, fingerprints, status, reason]] ->
        %{
          stream_id: stream_id,
          event_ids: event_ids,
          fingerprints: fingerprints,
          status: status,
          reason: reason
        }
    end
  end

  defp operation_fence_matches?(fence, operation) do
    fence.stream_id == operation.stream_id and fence.event_ids == operation.event_ids and
      fence.fingerprints == operation_fingerprints(operation)
  end

  defp insert_operation_fence!(conn, schema, operation, status, reason, deadline_mono) do
    quoted_schema = EventLogSchema.quote_identifier(schema)

    sql = """
    INSERT INTO #{quoted_schema}.arbor_event_log_operations (
      operation_id, stream_id, event_ids, fingerprints, status, reason
    )
    VALUES ($1, $2, $3, $4, $5, $6)
    ON CONFLICT (operation_id) DO NOTHING
    RETURNING operation_id
    """

    case query_with_deadline!(
           conn,
           sql,
           [
             operation.operation_id,
             operation.stream_id,
             operation.event_ids,
             operation_fingerprints(operation),
             status,
             reason
           ],
           deadline_mono
         ).rows do
      [[_operation_id]] ->
        :ok

      [] ->
        case operation_fence(conn, schema, operation.operation_id, deadline_mono) do
          %{status: ^status} = fence ->
            if operation_fence_matches?(fence, operation),
              do: :ok,
              else: Postgrex.rollback(conn, :event_identity_conflict)

          _different ->
            Postgrex.rollback(conn, :event_identity_conflict)
        end
    end
  end

  defp operation_fingerprints(operation) do
    Enum.map(operation.event_ids, &Map.fetch!(operation.fingerprints, &1))
  end

  defp lookup_operation_events(conn, schema, operation, deadline_mono) do
    storage_to_event_id =
      Map.new(operation.event_ids, &{deterministic_storage_id(&1), &1})

    storage_ids = Map.keys(storage_to_event_id)

    case query_with_deadline!(
           conn,
           operation_lookup_sql(schema),
           [storage_ids],
           deadline_mono
         ).rows do
      [] -> {:ok, :absent}
      rows -> reconcile_operation_rows(operation, storage_to_event_id, rows)
    end
  end

  defp operation_lookup_sql(schema) do
    quoted_schema = EventLogSchema.quote_identifier(schema)

    """
    SELECT source.event_id::text,
           source.stream_version,
           all_events.stream_version,
           streams.stream_uuid,
           events.event_type,
           events.correlation_id::text,
           events.causation_id::text,
           events.data,
           events.metadata,
           events.created_at
    FROM #{quoted_schema}.events AS events
    INNER JOIN #{quoted_schema}.stream_events AS source
      ON source.event_id = events.event_id
     AND source.stream_id = source.original_stream_id
    INNER JOIN #{quoted_schema}.streams AS streams
      ON streams.stream_id = source.stream_id
    INNER JOIN #{quoted_schema}.stream_events AS all_events
      ON all_events.event_id = source.event_id AND all_events.stream_id = 0
    WHERE events.event_id::text = ANY($1::text[])
    """
  end

  defp reconcile_operation_rows(operation, storage_to_event_id, rows) do
    {events, conflict?} =
      Enum.reduce(rows, {%{}, false}, fn row, {events, conflict?} ->
        {storage_id, _recorded, content_event, _global_position} = recorded_event_from_row(row)
        expected_event_id = Map.get(storage_to_event_id, storage_id)
        expected_fingerprint = Map.get(operation.fingerprints, expected_event_id)

        valid? =
          is_binary(expected_event_id) and content_event.id == expected_event_id and
            content_event.stream_id == operation.stream_id and
            EventLog.event_fingerprint_matches?(
              operation.stream_id,
              content_event,
              expected_fingerprint
            )

        if valid? do
          {Map.put(events, expected_event_id, content_event), conflict?}
        else
          {events, true}
        end
      end)

    cond do
      conflict? ->
        {:error, :event_identity_conflict}

      map_size(events) == length(operation.event_ids) ->
        {:ok, {:committed, Enum.map(operation.event_ids, &Map.fetch!(events, &1))}}

      true ->
        EventLog.indeterminate(operation)
    end
  end

  defp read_atomic_stream_head(stream_id) do
    with {:ok, conn, schema} <- event_store_connection() do
      quoted_schema = EventLogSchema.quote_identifier(schema)

      sql = """
      SELECT source.event_id::text,
             source.stream_version,
             all_events.stream_version,
             streams.stream_uuid,
             events.event_type,
             events.correlation_id::text,
             events.causation_id::text,
             events.data,
             events.metadata,
             events.created_at
      FROM #{quoted_schema}.streams AS streams
      INNER JOIN #{quoted_schema}.stream_events AS source
        ON source.stream_id = streams.stream_id
      INNER JOIN #{quoted_schema}.stream_events AS all_events
        ON all_events.event_id = source.event_id AND all_events.stream_id = 0
      INNER JOIN #{quoted_schema}.events AS events
        ON events.event_id = source.event_id
      WHERE streams.stream_uuid = $1
      ORDER BY source.stream_version DESC
      LIMIT 1
      """

      case Postgrex.query(conn, sql, [stream_id], timeout: @position_lookup_timeout_ms) do
        {:ok, %{rows: []}} ->
          {:ok, nil}

        {:ok, %{rows: [row]}} ->
          {_storage_id, recorded, _content_event, global_position} = recorded_event_from_row(row)
          {:ok, from_recorded_event(recorded, global_position)}

        {:error, reason} ->
          {:error, {:head_read_failed, reason}}
      end
    end
  rescue
    error -> {:error, {:head_read_failed, error}}
  catch
    :exit, reason -> {:error, {:head_read_failed, reason}}
  end

  defp recorded_event_from_row([
         storage_id,
         stream_version,
         global_position,
         stream_uuid,
         event_type,
         correlation_id,
         causation_id,
         data,
         metadata,
         created_at
       ]) do
    serializer = EventStore.Config.lookup(Store, :serializer)

    raw_recorded = %EventStore.RecordedEvent{
      event_number: stream_version,
      event_id: storage_id,
      stream_uuid: stream_uuid,
      stream_version: stream_version,
      correlation_id: blank_to_nil(correlation_id),
      causation_id: blank_to_nil(causation_id),
      event_type: event_type,
      data: data,
      metadata: metadata,
      created_at: normalize_created_at(created_at)
    }

    recorded = %EventStore.RecordedEvent{
      raw_recorded
      | data: serializer.deserialize(data, []),
        metadata: serializer.deserialize(metadata, [])
    }

    content_event = from_recorded_event(recorded, global_position)

    {storage_id, recorded, content_event, global_position}
  end

  defp sanitize_submitted_event(%Event{} = event) do
    %Event{event | metadata: Map.drop(event.metadata || %{}, @reserved_input_metadata_keys)}
  end

  defp lookup_global_positions(storage_ids) do
    with {:ok, conn, schema} <- event_store_connection() do
      quoted_schema = EventLogSchema.quote_identifier(schema)

      sql = """
      SELECT event_id::text, stream_version
      FROM #{quoted_schema}.stream_events
      WHERE stream_id = 0
        AND event_id::text = ANY($1::text[])
      """

      case Postgrex.query(conn, sql, [storage_ids], timeout: @position_lookup_timeout_ms) do
        {:ok, %{rows: rows}} ->
          {:ok,
           Map.new(rows, fn [storage_id, global_position] -> {storage_id, global_position} end)}

        {:error, reason} ->
          {:error, {:global_position_lookup_failed, reason}}
      end
    end
  end

  defp event_store_connection do
    config = EventStore.Config.lookup(Store)
    conn = Keyword.fetch!(config, :conn)
    schema = Keyword.fetch!(config, :schema)
    {:ok, conn, schema}
  rescue
    _error -> {:error, :backend_unavailable}
  end

  defp ensure_event_serializer do
    serializer = EventStore.Config.lookup(Store, :serializer)

    if is_atom(serializer) and Code.ensure_loaded?(serializer) and
         function_exported?(serializer, :arbor_event_log_serializer?, 0) and
         serializer.arbor_event_log_serializer?() do
      :ok
    else
      {:error, :incompatible_event_serializer}
    end
  rescue
    _error -> {:error, :backend_unavailable}
  end

  defp query_with_deadline!(conn, sql, params, deadline_mono) do
    {:ok, timeout} = EventLog.remaining_timeout(deadline_mono)
    Postgrex.query!(conn, sql, params, timeout: timeout)
  end

  defp ensure_before_deadline!(conn, deadline_mono) do
    case EventLog.remaining_timeout(deadline_mono) do
      {:ok, _remaining} -> :ok
      {:error, :operation_timeout} -> Postgrex.rollback(conn, :operation_timeout)
    end
  end

  defp deterministic_storage_id(event_id) do
    hex =
      :crypto.hash(:sha256, event_id)
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)

    binary_part(hex, 0, 8) <>
      "-" <>
      binary_part(hex, 8, 4) <>
      "-" <>
      binary_part(hex, 12, 4) <>
      "-" <>
      binary_part(hex, 16, 4) <>
      "-" <> binary_part(hex, 20, 12)
  end

  defp encode_timestamp(nil), do: nil
  defp encode_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp decode_timestamp(nil, fallback), do: normalize_created_at(fallback)

  defp decode_timestamp(timestamp, fallback) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed
      _invalid -> normalize_created_at(fallback)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_created_at(%DateTime{} = created_at), do: created_at

  defp normalize_created_at(%NaiveDateTime{} = created_at) do
    DateTime.from_naive!(created_at, "Etc/UTC")
  end

  defp normalize_created_at({:ok, %DateTime{} = created_at}), do: created_at

  defp reject_freshness(nil), do: :ok
  defp reject_freshness(_max_current_age_ms), do: {:error, :unsupported_precondition}

  # Create a subscriber module that forwards to a pid
  defp subscriber_with_pid(pid) do
    # EventStore expects a module or a function
    # We use a simple forwarding approach
    fn events ->
      projected =
        case from_stream_recordings(events) do
          {:ok, projected} ->
            projected

          {:error, reason} ->
            Logger.error("Failed to resolve subscription global positions: #{inspect(reason)}")
            Enum.map(events, &from_recorded_event(&1, nil))
        end

      Enum.each(projected, fn event ->
        send(pid, {:event, event})
      end)

      :ok
    end
  end

  defp subscription_opts(opts) do
    base = [start_from: Keyword.get(opts, :from, :origin)]

    if Keyword.get(opts, :transient, false) do
      base
    else
      # Persistent subscription
      Keyword.put(base, :concurrency_limit, 1)
    end
  end
end
