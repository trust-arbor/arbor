defmodule Arbor.Persistence.EventLog do
  @moduledoc """
  Behaviour for append-only event streams.

  An EventLog provides ordered, immutable event storage organized into
  named streams. Each stream maintains its own monotonic event numbering.
  A global position tracks total ordering across all streams.

  ## Implementing an EventLog

      defmodule MyEventLog do
        @behaviour Arbor.Persistence.EventLog

        @impl true
        def append(stream_id, events, opts), do: ...

        @impl true
        def read_stream(stream_id, opts), do: ...

        # ...
      end
  """

  alias Arbor.Persistence.Event

  @max_stream_id_bytes 1_024
  @max_options 64
  @max_append_events 1_000
  @max_event_bytes 1_048_576
  @max_append_bytes 4_194_304
  @max_precondition_integer 2_147_483_647

  @type stream_id :: String.t()
  @type opts :: keyword()
  @type append_preconditions :: %{
          expected_version: non_neg_integer() | nil,
          max_current_age_ms: non_neg_integer() | nil
        }

  @doc """
  Append one or more events to a stream.

  Events are assigned monotonically increasing event_numbers within the stream
  and global_positions across all streams. Returns the list of persisted events
  with their assigned positions.

  `:expected_version` accepts a non-negative integer and atomically requires the
  current stream version to match. `:max_current_age_ms` accepts a non-negative
  duration and atomically requires an existing head whose backend-owned commit
  age is strictly less than the duration. An empty stream, an age exactly equal
  to the duration, or unavailable backend freshness evidence fails with
  `{:error, :deadline_exceeded}`.

  Both precondition integers are bounded to `0..2_147_483_647`. Stream IDs are
  bounded to 1,024 bytes, options to 64 entries, an append to 1,000 events and
  4 MiB total, and each event term to 1 MiB before backend work begins.
  """
  @callback append(stream_id(), [Event.t()] | Event.t(), opts()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @doc """
  Read events from a stream.

  Options:
  - `:from` - start reading from this event_number (inclusive, default 0)
  - `:limit` - max events to return
  - `:direction` - :forward (default) or :backward
  """
  @callback read_stream(stream_id(), opts()) :: {:ok, [Event.t()]} | {:error, term()}

  @doc """
  Read at most the current head event for a stream.

  With no freshness option this returns the ordinary current head. With
  `:max_current_age_ms`, the backend returns `{:ok, nil}` when the stream is
  empty or the head's backend-owned age is greater than or equal to the
  duration. A backend that knows a stream is nonempty but does not have its head
  returns `{:error, :head_unavailable}` instead of projecting it as empty.
  Caller-provided `Event.timestamp` is never freshness authority. Durable rows
  created before a backend gained commit evidence fail freshness closed.
  """
  @callback read_stream_head(stream_id(), opts()) ::
              {:ok, Event.t() | nil} | {:error, term()}

  @doc """
  Read all events across all streams in global order.

  Options:
  - `:from` - start from this global_position (inclusive, default 0)
  - `:limit` - max events to return
  """
  @callback read_all(opts()) :: {:ok, [Event.t()]} | {:error, term()}

  @doc "Check if a stream exists (has any events)."
  @callback stream_exists?(stream_id(), opts()) :: boolean()

  @doc "Get the current version (latest event_number) of a stream. Returns 0 for empty/nonexistent streams."
  @callback stream_version(stream_id(), opts()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Subscribe to new events on a stream (or all streams with :all).

  The subscriber pid receives messages of the form:
  `{:event, %Event{}}` for each new event.

  Returns {:ok, reference} that can be used to unsubscribe.
  """
  @callback subscribe(stream_id() | :all, pid(), opts()) ::
              {:ok, reference()} | {:error, term()}

  @doc "List all known stream IDs."
  @callback list_streams(opts()) :: {:ok, [stream_id()]}

  @doc "Get the number of distinct streams."
  @callback stream_count(opts()) :: {:ok, non_neg_integer()}

  @doc "Get the total number of events across all streams."
  @callback event_count(opts()) :: {:ok, non_neg_integer()}

  @doc """
  Read events for a specific agent across all streams.

  Options:
  - `:from` - start from this global_position (inclusive, default 0)
  - `:limit` - max events to return
  - `:type` - filter by event type
  """
  @callback read_agent_events(agent_id :: String.t(), opts()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @optional_callbacks [
    subscribe: 3,
    list_streams: 1,
    stream_count: 1,
    event_count: 1,
    read_agent_events: 2
  ]

  @doc false
  @spec validate_append(stream_id(), [Event.t()] | Event.t(), opts()) ::
          {:ok, [Event.t()], append_preconditions()}
          | {:error,
             :invalid_stream_id
             | :invalid_events
             | :too_many_events
             | :event_too_large
             | :invalid_precondition}
  def validate_append(stream_id, events, opts) do
    events = List.wrap(events)

    with :ok <- validate_stream_id(stream_id),
         :ok <- validate_opts(opts),
         :ok <- validate_events(events),
         {:ok, preconditions} <- validate_preconditions(opts) do
      {:ok, events, preconditions}
    end
  end

  @doc false
  @spec validate_head_read(stream_id(), opts()) ::
          {:ok, non_neg_integer() | nil}
          | {:error, :invalid_stream_id | :invalid_precondition}
  def validate_head_read(stream_id, opts) do
    with :ok <- validate_stream_id(stream_id),
         :ok <- validate_opts(opts),
         {:ok, preconditions} <- validate_preconditions(opts) do
      {:ok, preconditions.max_current_age_ms}
    end
  end

  defp validate_stream_id(stream_id)
       when is_binary(stream_id) and byte_size(stream_id) > 0 and
              byte_size(stream_id) <= @max_stream_id_bytes,
       do: :ok

  defp validate_stream_id(_stream_id), do: {:error, :invalid_stream_id}

  defp validate_opts(opts) when is_list(opts) do
    opts
    |> Enum.reduce_while(0, fn
      _option, @max_options -> {:halt, {:error, :invalid_precondition}}
      {key, _value}, count when is_atom(key) -> {:cont, count + 1}
      _option, _count -> {:halt, {:error, :invalid_precondition}}
    end)
    |> case do
      count when is_integer(count) -> :ok
      {:error, :invalid_precondition} = error -> error
    end
  end

  defp validate_opts(_opts), do: {:error, :invalid_precondition}

  defp validate_events([]), do: {:error, :invalid_events}

  defp validate_events(events) do
    events
    |> Enum.reduce_while({:ok, 0, 0}, fn
      _event, {:ok, @max_append_events, _total_bytes} ->
        {:halt, {:error, :too_many_events}}

      %Event{} = event, {:ok, count, total_bytes} ->
        event_bytes = :erlang.external_size(event)

        cond do
          not valid_event_shape?(event) -> {:halt, {:error, :invalid_events}}
          event_bytes > @max_event_bytes -> {:halt, {:error, :event_too_large}}
          total_bytes + event_bytes > @max_append_bytes -> {:halt, {:error, :event_too_large}}
          true -> {:cont, {:ok, count + 1, total_bytes + event_bytes}}
        end

      _event, {:ok, _count, _total_bytes} ->
        {:halt, {:error, :invalid_events}}
    end)
    |> case do
      {:ok, _count, _total_bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp valid_event_shape?(event) do
    bounded_binary?(event.id) and bounded_binary?(event.type) and is_map(event.data) and
      is_map(event.metadata)
  end

  defp bounded_binary?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_stream_id_bytes
  end

  defp validate_preconditions(opts) do
    expected_version = Keyword.get(opts, :expected_version)
    max_current_age_ms = Keyword.get(opts, :max_current_age_ms)

    if bounded_precondition?(expected_version) and bounded_precondition?(max_current_age_ms) do
      {:ok, %{expected_version: expected_version, max_current_age_ms: max_current_age_ms}}
    else
      {:error, :invalid_precondition}
    end
  end

  defp bounded_precondition?(nil), do: true

  defp bounded_precondition?(value) do
    is_integer(value) and value >= 0 and value <= @max_precondition_integer
  end
end
