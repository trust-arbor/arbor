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

  @type stream_id :: String.t()
  @type opts :: keyword()

  @doc """
  Append one or more events to a stream.

  Events are assigned monotonically increasing event_numbers within the stream
  and global_positions across all streams. Returns the list of persisted events
  with their assigned positions.
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

  @optional_callbacks [subscribe: 3, list_streams: 1, stream_count: 1, event_count: 1, read_agent_events: 2]
end
