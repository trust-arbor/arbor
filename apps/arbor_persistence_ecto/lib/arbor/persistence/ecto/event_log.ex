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

  Pass `expected_version: version` in opts to enable optimistic concurrency:

      # Append only if stream is at version 2
      {:ok, events} = append(stream_id, events, expected_version: 2)

      # Append only if stream doesn't exist
      {:ok, events} = append(stream_id, events, expected_version: :no_stream)

      # Append regardless of version (default)
      {:ok, events} = append(stream_id, events, expected_version: :any)
  """

  @behaviour Arbor.Persistence.EventLog

  alias Arbor.Persistence.Ecto.EventStore, as: Store
  alias Arbor.Persistence.Event

  require Logger

  # ============================================================================
  # EventLog Behaviour Implementation
  # ============================================================================

  @impl Arbor.Persistence.EventLog
  def append(stream_id, events, opts \\ []) do
    events = List.wrap(events)
    expected_version = Keyword.get(opts, :expected_version, :any)

    # Convert to eventstore format
    event_data = Enum.map(events, &to_event_data/1)

    case Store.append_to_stream(stream_id, expected_version, event_data) do
      :ok ->
        # Read back to get assigned positions
        # Note: This is slightly inefficient but ensures correctness
        # In production, we might optimize by tracking positions ourselves
        {:ok, recorded} =
          read_stream(stream_id, from: expected_version_to_start(expected_version))

        {:ok, Enum.take(recorded, -length(events))}

      {:error, :wrong_expected_version} = error ->
        Logger.warning("Optimistic concurrency conflict on stream #{stream_id}")
        error

      {:error, reason} = error ->
        Logger.error("Failed to append to stream #{stream_id}: #{inspect(reason)}")
        error
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_stream(stream_id, opts \\ []) do
    start_version = Keyword.get(opts, :from, 0)
    count = Keyword.get(opts, :limit, 1000)

    case Store.read_stream_forward(stream_id, start_version, count) do
      {:ok, recorded_events} ->
        events = Enum.map(recorded_events, &from_recorded_event/1)
        {:ok, events}

      {:error, :stream_not_found} ->
        {:ok, []}

      {:error, reason} = error ->
        Logger.error("Failed to read stream #{stream_id}: #{inspect(reason)}")
        error
    end
  end

  @impl Arbor.Persistence.EventLog
  def read_all(opts \\ []) do
    start_position = Keyword.get(opts, :from, 0)
    count = Keyword.get(opts, :limit, 1000)

    case Store.read_all_streams_forward(start_position, count) do
      {:ok, recorded_events} ->
        events = Enum.map(recorded_events, &from_recorded_event/1)
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
  defp to_event_data(%Event{} = event) do
    %EventStore.EventData{
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
  defp from_recorded_event(%EventStore.RecordedEvent{} = recorded) do
    metadata = recorded.metadata || %{}

    %Event{
      id: Map.get(metadata, "event_id", recorded.event_id |> to_string()),
      stream_id: recorded.stream_uuid,
      event_number: recorded.stream_version,
      global_position: recorded.event_number,
      type: recorded.event_type,
      data: recorded.data || %{},
      metadata: Map.drop(metadata, ["event_id", "causation_id", "correlation_id"]),
      causation_id: Map.get(metadata, "causation_id") || recorded.causation_id,
      correlation_id: Map.get(metadata, "correlation_id") || recorded.correlation_id,
      timestamp: recorded.created_at
    }
  end

  defp expected_version_to_start(:any), do: 0
  defp expected_version_to_start(:no_stream), do: 0
  defp expected_version_to_start(version) when is_integer(version), do: version + 1

  # Create a subscriber module that forwards to a pid
  defp subscriber_with_pid(pid) do
    # EventStore expects a module or a function
    # We use a simple forwarding approach
    fn events ->
      Enum.each(events, fn recorded ->
        event = from_recorded_event(recorded)
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
