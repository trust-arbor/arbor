defmodule Arbor.Persistence.EventLog.Postgres do
  @moduledoc """
  PostgreSQL-backed EventLog implementation.

  Provides durable, ACID-compliant event storage with support for:
  - Append-only event streams
  - Global ordering via sequence
  - Stream versioning with optimistic concurrency
  - Efficient range queries

  ## Configuration

  The Repo module must be configured and started:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: "postgres",
        password: "postgres",
        hostname: "localhost"

  ## Usage

      # Append events to a stream
      event = Event.new("stream-123", "user.created", %{name: "Alice"})
      {:ok, [persisted]} = Postgres.append("stream-123", [event], repo: MyRepo)

      # Read events from a stream
      {:ok, events} = Postgres.read_stream("stream-123", repo: MyRepo)

      # Read with options
      {:ok, events} = Postgres.read_stream("stream-123",
        repo: MyRepo,
        from: 10,
        limit: 100
      )
  """

  @behaviour Arbor.Persistence.EventLog

  import Ecto.Query

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Event, as: EventSchema

  require Logger

  @doc """
  Append one or more events to a stream.

  Events are assigned sequential event_numbers within the stream.
  Global positions are assigned across all streams.

  ## Options

  - `:repo` - Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  - `:expected_version` - Optimistic concurrency check (optional)

  ## Returns

  - `{:ok, [Event.t()]}` - Persisted events with assigned positions
  - `{:error, :version_conflict}` - Expected version didn't match
  - `{:error, term()}` - Database error
  """
  @impl true
  def append(stream_id, events, opts \\ [])

  def append(stream_id, %Event{} = event, opts) do
    append(stream_id, [event], opts)
  end

  def append(stream_id, events, opts) when is_list(events) do
    repo = Keyword.get(opts, :repo, Repo)
    expected_version = Keyword.get(opts, :expected_version)

    repo.transaction(fn ->
      # Get current stream version and global position
      current_version = get_current_version(repo, stream_id)
      global_pos = get_max_global_position(repo)

      # Optimistic concurrency check
      if expected_version && expected_version != current_version do
        repo.rollback(:version_conflict)
      end

      # Assign positions and insert
      {persisted, _} =
        events
        |> Enum.with_index(current_version + 1)
        |> Enum.map_reduce(global_pos, fn {event, event_num}, gpos ->
          new_gpos = gpos + 1

          event_with_positions = %Event{
            event
            | event_number: event_num,
              global_position: new_gpos,
              timestamp: event.timestamp || DateTime.utc_now()
          }

          insert_event(repo, event_with_positions)
          {event_with_positions, new_gpos}
        end)

      persisted
    end)
    |> handle_transaction_result()
  end

  @doc """
  Read events from a stream.

  ## Options

  - `:repo` - Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  - `:from` - Start reading from this event_number (inclusive, default: 0)
  - `:limit` - Maximum events to return
  - `:direction` - `:forward` (default) or `:backward`
  """
  @impl true
  def read_stream(stream_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    from = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)
    direction = Keyword.get(opts, :direction, :forward)

    query =
      from(e in EventSchema,
        where: e.stream_id == ^stream_id and e.event_number >= ^from,
        order_by: ^order_by_direction(:event_number, direction)
      )

    query = if limit, do: limit(query, ^limit), else: query

    events =
      repo.all(query)
      |> Enum.map(&EventSchema.to_event/1)

    {:ok, events}
  rescue
    e ->
      Logger.error("Failed to read stream #{stream_id}: #{inspect(e)}")
      {:error, {:read_failed, e}}
  end

  @doc """
  Read all events across all streams in global order.

  ## Options

  - `:repo` - Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  - `:from` - Start from this global_position (inclusive, default: 0)
  - `:limit` - Maximum events to return
  """
  @impl true
  def read_all(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    from = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)

    query =
      from(e in EventSchema,
        where: e.global_position >= ^from,
        order_by: [asc: e.global_position]
      )

    query = if limit, do: limit(query, ^limit), else: query

    events =
      repo.all(query)
      |> Enum.map(&EventSchema.to_event/1)

    {:ok, events}
  rescue
    e ->
      Logger.error("Failed to read all events: #{inspect(e)}")
      {:error, {:read_failed, e}}
  end

  @doc """
  Check if a stream exists (has any events).
  """
  @impl true
  def stream_exists?(stream_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    query = from(e in EventSchema, where: e.stream_id == ^stream_id, limit: 1, select: 1)

    repo.exists?(query)
  end

  @doc """
  Get the current version (latest event_number) of a stream.

  Returns 0 for empty or nonexistent streams.
  """
  @impl true
  def stream_version(stream_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    {:ok, get_current_version(repo, stream_id)}
  rescue
    e ->
      {:error, {:version_check_failed, e}}
  end

  @doc """
  Subscribe to new events on a stream.

  Note: PostgreSQL subscriptions require pg_notify setup.
  This is a placeholder that returns an error for now.
  """
  @impl true
  def subscribe(_stream_id, _pid, _opts \\ []) do
    {:error, :not_implemented}
  end

  @doc """
  List all known stream IDs.
  """
  @impl true
  def list_streams(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    streams =
      from(e in EventSchema, select: e.stream_id, distinct: true, order_by: e.stream_id)
      |> repo.all()

    {:ok, streams}
  rescue
    e ->
      {:error, {:list_failed, e}}
  end

  @doc """
  Get the number of distinct streams.
  """
  @impl true
  def stream_count(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    count =
      from(e in EventSchema, select: count(e.stream_id, :distinct))
      |> repo.one()

    {:ok, count || 0}
  rescue
    e ->
      {:error, {:count_failed, e}}
  end

  @doc """
  Get the total number of events across all streams.
  """
  @impl true
  def event_count(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    count =
      from(e in EventSchema, select: count())
      |> repo.one()

    {:ok, count || 0}
  rescue
    e ->
      {:error, {:count_failed, e}}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp get_current_version(repo, stream_id) do
    query =
      from(e in EventSchema,
        where: e.stream_id == ^stream_id,
        select: max(e.event_number)
      )

    repo.one(query) || 0
  end

  defp get_max_global_position(repo) do
    query = from(e in EventSchema, select: max(e.global_position))
    repo.one(query) || 0
  end

  defp insert_event(repo, %Event{} = event) do
    attrs = EventSchema.from_event(event)

    %EventSchema{}
    |> EventSchema.changeset(attrs)
    |> repo.insert!()
  end

  defp order_by_direction(field, :forward), do: [asc: field]
  defp order_by_direction(field, :backward), do: [desc: field]

  defp handle_transaction_result({:ok, events}), do: {:ok, events}
  defp handle_transaction_result({:error, :version_conflict}), do: {:error, :version_conflict}

  defp handle_transaction_result({:error, reason}) do
    Logger.error("Transaction failed: #{inspect(reason)}")
    {:error, reason}
  end
end
