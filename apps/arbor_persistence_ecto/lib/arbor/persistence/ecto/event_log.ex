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
  """

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.{Event, EventLog}

  require Logger

  @position_lookup_timeout_ms 5_000

  # ============================================================================
  # EventLog Behaviour Implementation
  # ============================================================================

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts \\ []) do
    with {:ok, events, preconditions} <- EventLog.validate_append(stream_id, events, opts),
         :ok <- reject_freshness(preconditions.max_current_age_ms) do
      expected_version = preconditions.expected_version || :any_version

      submitted = Enum.map(events, &{&1, Ecto.UUID.generate()})

      event_data =
        Enum.map(submitted, fn {event, storage_id} -> to_event_data(event, storage_id) end)

      case Store.append_to_stream(stream_id, expected_version, event_data) do
        :ok ->
          read_back_submitted(stream_id, submitted)

        {:error, :wrong_expected_version} ->
          Logger.warning("Optimistic concurrency conflict on stream #{stream_id}")
          {:error, :version_conflict}

        {:error, reason} = error ->
          Logger.error("Failed to append to stream #{stream_id}: #{inspect(reason)}")
          error
      end
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts \\ []) do
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

  @impl Arbor.Persistence.EventLog
  def read_stream_head(stream_id, opts \\ []) do
    with {:ok, max_current_age_ms} <- EventLog.validate_head_read(stream_id, opts),
         :ok <- reject_freshness(max_current_age_ms),
         {:ok, version} <- stream_version(stream_id, opts) do
      if version == 0 do
        {:ok, nil}
      else
        case Store.read_stream_forward(stream_id, version, 1) do
          {:ok, [recorded | _]} ->
            with {:ok, [event]} <- from_stream_recordings([recorded]), do: {:ok, event}

          {:ok, []} ->
            {:error, :head_unavailable}

          {:error, :stream_not_found} ->
            {:error, :head_unavailable}

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_all(opts \\ []) do
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
        # Return a reference that wraps the subscription
        ref = make_ref()
        # Store mapping for potential unsubscribe
        Process.put({:eventstore_subscription, ref}, subscription)
        {:ok, ref}

      {:error, reason} = error ->
        Logger.error("Failed to subscribe: #{inspect(reason)}")
        error
    end
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

  # Convert our Event.t() to EventStore.EventData
  defp to_event_data(%Event{} = event, storage_id) do
    %EventStore.EventData{
      event_id: storage_id,
      event_type: event.type,
      data: event.data,
      metadata:
        Map.merge(event.metadata || %{}, %{
          "event_id" => event.id,
          "causation_id" => event.causation_id,
          "correlation_id" => event.correlation_id
        })
    }
  end

  # Convert EventStore.RecordedEvent to our Event.t()
  defp from_recorded_event(%EventStore.RecordedEvent{} = recorded, global_position) do
    metadata = recorded.metadata || %{}

    %Event{
      id: Map.get(metadata, "event_id", recorded.event_id |> to_string()),
      stream_id: recorded.stream_uuid,
      event_number: recorded.stream_version,
      global_position: global_position,
      type: recorded.event_type,
      data: recorded.data || %{},
      metadata: Map.drop(metadata, ["event_id", "causation_id", "correlation_id"]),
      causation_id: Map.get(metadata, "causation_id") || recorded.causation_id,
      correlation_id: Map.get(metadata, "correlation_id") || recorded.correlation_id,
      timestamp: recorded.created_at
    }
  end

  defp read_back_submitted(stream_id, submitted) do
    storage_ids = Enum.map(submitted, &elem(&1, 1))

    with {:ok, positions} <- lookup_submitted_positions(stream_id, storage_ids),
         true <- map_size(positions) == length(storage_ids) do
      events =
        Enum.map(submitted, fn {%Event{} = event, storage_id} ->
          {event_number, global_position, created_at} = Map.fetch!(positions, storage_id)

          %Event{
            event
            | stream_id: stream_id,
              event_number: event_number,
              global_position: global_position,
              timestamp: normalize_created_at(created_at)
          }
        end)

      {:ok, events}
    else
      false -> {:error, :event_readback_incomplete}
      {:error, _reason} = error -> error
    end
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

  defp lookup_submitted_positions(stream_id, storage_ids) do
    with {:ok, conn, schema} <- event_store_connection() do
      sql = """
      SELECT source.event_id::text,
             source.stream_version,
             all_events.stream_version,
             events.created_at
      FROM #{schema}.stream_events AS source
      INNER JOIN #{schema}.streams AS streams
        ON streams.stream_id = source.stream_id
      INNER JOIN #{schema}.stream_events AS all_events
        ON all_events.event_id = source.event_id AND all_events.stream_id = 0
      INNER JOIN #{schema}.events AS events
        ON events.event_id = source.event_id
      WHERE streams.stream_uuid = $1
        AND source.event_id::text = ANY($2::text[])
      """

      case Postgrex.query(conn, sql, [stream_id, storage_ids],
             timeout: @position_lookup_timeout_ms
           ) do
        {:ok, %{rows: rows}} ->
          {:ok,
           Map.new(rows, fn [storage_id, stream_version, global_position, created_at] ->
             {storage_id, {stream_version, global_position, created_at}}
           end)}

        {:error, reason} ->
          {:error, {:event_readback_failed, reason}}
      end
    end
  end

  defp lookup_global_positions(storage_ids) do
    with {:ok, conn, schema} <- event_store_connection() do
      sql = """
      SELECT event_id::text, stream_version
      FROM #{schema}.stream_events
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
    schema = config |> Keyword.fetch!(:schema) |> quote_identifier()
    {:ok, conn, schema}
  rescue
    _error -> {:error, :backend_unavailable}
  end

  defp quote_identifier(identifier) when is_binary(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end

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
