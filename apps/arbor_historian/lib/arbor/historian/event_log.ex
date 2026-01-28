defmodule Arbor.Historian.EventLog do
  @moduledoc """
  Behaviour for append-only event log backends.

  Provides stream-based event storage with append, read, and listing operations.
  Events are organized into named streams and assigned both per-stream and global
  position numbers.
  """

  alias Arbor.Contracts.Events.Event

  @type stream_id :: String.t()
  @type position :: non_neg_integer()
  @type opts :: keyword()

  @doc "Start the event log process."
  @callback start_link(opts()) :: GenServer.on_start()

  @doc "Append an event to a stream. Returns the assigned stream position."
  @callback append(server :: GenServer.server(), stream_id(), Event.t()) ::
              {:ok, position()} | {:error, term()}

  @doc "Read all events from a stream, ordered by position."
  @callback read_stream(server :: GenServer.server(), stream_id()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @doc "Read all events across all streams, ordered by global position."
  @callback read_all(server :: GenServer.server()) :: {:ok, [Event.t()]}

  @doc "List all known stream IDs."
  @callback list_streams(server :: GenServer.server()) :: {:ok, [stream_id()]}

  @doc "Get the current event count for a stream."
  @callback stream_size(server :: GenServer.server(), stream_id()) :: {:ok, non_neg_integer()}

  @doc "Get the total event count across all streams."
  @callback total_size(server :: GenServer.server()) :: {:ok, non_neg_integer()}
end
