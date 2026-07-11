defmodule Arbor.Persistence.EventLog.Ecto do
  @moduledoc """
  Ecto-backed EventLog implementation.

  Provides durable, ACID-compliant event storage. Adapter-agnostic: this
  module uses only `Ecto.Query` plus `Arbor.Persistence.Repo`, which
  dispatches to whichever Ecto adapter is configured at compile time
  (PostgreSQL or SQLite3 — see `Arbor.Persistence.Repo` for the
  selection logic).

  Supports:
  - Append-only event streams
  - Global ordering via sequence
  - Stream versioning with optimistic concurrency
  - Efficient range queries

  ## Configuration

  The Repo module must be configured and started. For PostgreSQL:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: "arbor_dev",
        username: System.get_env("DB_USER", "postgres"),
        password: System.get_env("DB_PASS", "postgres"),
        hostname: "localhost"

  For SQLite3:

      config :arbor_persistence, Arbor.Persistence.Repo,
        database: Path.expand("~/.arbor/arbor_dev.db")

  ## Usage

      # Append events to a stream
      event = Event.new("stream-123", "user.created", %{name: "Alice"})
      {:ok, [persisted]} = Ecto.append("stream-123", [event], repo: MyRepo)

      # Read events from a stream
      {:ok, events} = Ecto.read_stream("stream-123", repo: MyRepo)

      # Read with options
      {:ok, events} = Ecto.read_stream("stream-123",
        repo: MyRepo,
        from: 10,
        limit: 100
      )
  """

  @behaviour Arbor.Persistence.EventLog

  import Ecto.Query

  alias Arbor.Persistence.{Event, EventLog}
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
  - `:max_current_age_ms` - Require a current head younger than this duration

  ## Returns

  - `{:ok, [Event.t()]}` - Persisted events with assigned positions
  - `{:error, :version_conflict}` - Expected version didn't match
  - `{:error, term()}` - Database error
  """
  @impl true
  # Bounded optimistic-concurrency retry for the event_number race (see do_append).
  @max_append_attempts 5

  def append(stream_id, events, opts \\ [])

  def append(stream_id, %Event{} = event, opts) do
    append(stream_id, [event], opts)
  end

  def append(stream_id, events, opts) when is_list(events) do
    with {:ok, events, preconditions} <- EventLog.validate_append(stream_id, events, opts) do
      do_append(stream_id, events, preconditions, opts, 1)
    end
  end

  # Concurrent appends to the SAME stream race on event_number assignment: the
  # number is a read-modify-write (`max(event_number) + 1`) that no lock guards
  # — and on a fresh stream there are no rows to lock — so two appends can read
  # the same version, assign the same number, and the second violates the
  # `events_stream_id_event_number_index` unique constraint. (Surfaced by
  # heartbeat pipelines firing several durable signals concurrently to one
  # per-run stream via Task.start, flooding the logs with ConstraintError via
  # Signals.durable_emit.)
  #
  # Root-cause fix: serialize appends to the SAME stream with a per-stream
  # Postgres advisory transaction lock acquired BEFORE reading the version.
  # Concurrent appends to one stream queue behind the lock and each reads the
  # previous winner's committed event_number; appends to DIFFERENT streams use
  # different lock keys and don't contend. The lock auto-releases at transaction
  # end (commit or rollback). The bounded optimistic retry below is kept as a
  # backstop but should now essentially never fire.
  defp do_append(stream_id, events, preconditions, opts, attempt) do
    repo = Keyword.get(opts, :repo, Repo)

    transaction(repo, fn ->
      # Serialize concurrent appends to this stream at the database (Postgres
      # only — SQLite serializes writes already, and the ETS/Agent backends and
      # the retry-test stub repos have no such lock).
      lock_stream_for_append(repo, stream_id)

      # Get current stream version and global position
      current_version = get_current_version(repo, stream_id)
      global_pos = get_max_global_position(repo)

      # Optimistic concurrency check
      if not is_nil(preconditions.expected_version) and
           preconditions.expected_version != current_version do
        repo.rollback(:version_conflict)
      end

      if not head_fresh?(repo, stream_id, preconditions.max_current_age_ms) do
        repo.rollback(:deadline_exceeded)
      end

      # Assign positions and insert
      {persisted, _} =
        events
        |> Enum.with_index(current_version + 1)
        |> Enum.map_reduce(global_pos, fn {%Event{} = event, event_num}, gpos ->
          new_gpos = gpos + 1

          event_with_positions = %Event{
            event
            | event_number: event_num,
              global_position: new_gpos,
              timestamp: event.timestamp || DateTime.utc_now()
          }

          persisted_event = insert_event(repo, event_with_positions)
          {persisted_event, new_gpos}
        end)

      persisted
    end)
    |> handle_transaction_result()
  rescue
    # Two shapes of the same residual event_number conflict can surface here:
    #
    #   * `Ecto.ConstraintError` — when the DB constraint fires but the schema
    #     changeset did NOT declare it (e.g. the DB-free retry-test stub repos,
    #     which raise this directly from their fake `insert!/1`).
    #   * `Ecto.InvalidChangesetError` — what `insert!/1` raises once the
    #     changeset DOES declare `unique_constraint(:stream_id, :event_number)`:
    #     Ecto converts the DB violation into a changeset error and `insert!`
    #     wraps the now-invalid changeset.
    #
    # Both mean "lost the event_number race". Retry only that, and only when the
    # caller did NOT request a specific expected_version — optimistic-concurrency
    # callers must observe the conflict, not have it silently resolved underneath
    # them. (Body-scope bindings don't reach `rescue`; re-derive from `opts`.)
    e in [Ecto.ConstraintError, Ecto.InvalidChangesetError] ->
      retryable? = is_nil(Keyword.get(opts, :expected_version)) and event_number_conflict?(e)

      cond do
        retryable? and attempt < @max_append_attempts ->
          do_append(stream_id, events, preconditions, opts, attempt + 1)

        # Retries exhausted on a declared-constraint conflict: surface the
        # changeset rather than crashing the caller, per the append contract.
        retryable? and match?(%Ecto.InvalidChangesetError{}, e) ->
          {:error, e.changeset}

        true ->
          reraise(e, __STACKTRACE__)
      end
  end

  defp event_number_conflict?(%Ecto.ConstraintError{} = e) do
    String.contains?("#{e.constraint} #{Exception.message(e)}", "event_number")
  end

  defp event_number_conflict?(%Ecto.InvalidChangesetError{changeset: changeset}) do
    Enum.any?(changeset.errors, fn
      {field, {_msg, opts}} ->
        field == :stream_id or field == :event_number or
          Keyword.get(opts, :constraint_name) == "events_stream_id_event_number_index"

      _ ->
        false
    end)
  end

  defp event_number_conflict?(_), do: false

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
  Read the current stream head, optionally requiring backend-owned freshness.

  `:max_current_age_ms` compares `events.committed_at` to database time. The
  domain `Event.timestamp` is not consulted.
  """
  @impl true
  def read_stream_head(stream_id, opts \\ []) do
    with {:ok, max_current_age_ms} <- EventLog.validate_head_read(stream_id, opts) do
      repo = Keyword.get(opts, :repo, Repo)

      event =
        stream_id
        |> current_head_query()
        |> maybe_require_fresh_head(repo, max_current_age_ms)
        |> repo.one()
        |> case do
          nil -> nil
          schema -> EventSchema.to_event(schema)
        end

      {:ok, event}
    end
  rescue
    e ->
      Logger.error("Failed to read stream head #{stream_id}: #{inspect(e)}")
      {:error, {:read_failed, e}}
  end

  @doc """
  Read all events across all streams in global order.

  ## Options

  - `:repo` - Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  - `:from` - Start from this global_position (inclusive, default: 0)
  - `:limit` - Maximum events to return
  - `:agent_id` - Filter by agent_id (optional)
  """
  @impl true
  def read_all(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    from_pos = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)
    agent_id = Keyword.get(opts, :agent_id)

    query =
      from(e in EventSchema,
        where: e.global_position >= ^from_pos,
        order_by: [asc: e.global_position]
      )

    query = if agent_id, do: where(query, [e], e.agent_id == ^agent_id), else: query
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
  Read events for a specific agent across all streams.

  ## Options

  - `:repo` - Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  - `:from` - Start from this global_position (inclusive, default: 0)
  - `:limit` - Maximum events to return
  - `:type` - Filter by event type (optional)
  """
  @impl true
  def read_agent_events(agent_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    from_pos = Keyword.get(opts, :from, 0)
    limit = Keyword.get(opts, :limit)
    type = Keyword.get(opts, :type)

    query =
      from(e in EventSchema,
        where: e.agent_id == ^agent_id and e.global_position >= ^from_pos,
        order_by: [asc: e.global_position]
      )

    query = if type, do: where(query, [e], e.type == ^type), else: query
    query = if limit, do: limit(query, ^limit), else: query

    events =
      repo.all(query)
      |> Enum.map(&EventSchema.to_event/1)

    {:ok, events}
  rescue
    e ->
      Logger.error("Failed to read agent events for #{agent_id}: #{inspect(e)}")
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

  Note: durable-backed subscriptions are adapter-specific (pg_notify on
  PostgreSQL, no native equivalent on SQLite3). This is a placeholder
  that returns an error for now — real-time subscribers should use the
  ETS-backed EventLog, which carries the pubsub path.
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

  @doc """
  Return a snapshot of the EventLog's bookkeeping state — enough to
  rehydrate an in-memory cache's `stream_versions` map and
  `global_position` counter without replaying any events.

  Two aggregate SQL queries:

    1. `SELECT stream_id, max(event_number) FROM events GROUP BY stream_id`
    2. `SELECT max(global_position) FROM events`

  Used by `Arbor.Historian.Application` at boot to align the ETS
  cache's bookkeeping with the durable backend so that subsequent
  appends use correct, non-colliding `event_number` / `global_position`
  values from t=0, even though the ETS table starts empty (the
  fallthrough path in `QueryEngine` handles cold reads for historical
  events).

  Returns `{:ok, %{stream_versions: map, global_position: integer}}`.
  An empty database returns `{:ok, %{stream_versions: %{}, global_position: 0}}`.

  ## Options

    * `:repo` — Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  """
  @spec metadata_snapshot(keyword()) ::
          {:ok,
           %{
             stream_versions: %{String.t() => non_neg_integer()},
             global_position: non_neg_integer()
           }}
          | {:error, term()}
  def metadata_snapshot(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    stream_versions_query =
      from(e in EventSchema,
        group_by: e.stream_id,
        select: {e.stream_id, max(e.event_number)}
      )

    global_position_query = from(e in EventSchema, select: max(e.global_position))

    stream_versions =
      stream_versions_query
      |> repo.all()
      |> Map.new()

    global_position = repo.one(global_position_query) || 0

    {:ok, %{stream_versions: stream_versions, global_position: global_position}}
  rescue
    e ->
      {:error, {:metadata_snapshot_failed, e}}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Acquire a per-stream advisory transaction lock so concurrent appends to the
  # SAME stream serialize, eliminating the event_number read-modify-write race at
  # the root. `pg_advisory_xact_lock` is a blocking lock keyed on `hashtext(stream_id)`
  # and auto-releases at transaction end. Postgres-only; other backends (SQLite,
  # ETS/Agent, and the retry-test stub repos) skip it. We must already be inside a
  # `repo.transaction/1` for the lock to be transaction-scoped (do_append is).
  defp lock_stream_for_append(repo, stream_id) do
    if postgres_repo?(repo) do
      repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [stream_id])
    end

    :ok
  end

  defp transaction(repo, fun) do
    if sqlite_repo?(repo) do
      repo.transaction(fun, mode: :immediate)
    else
      repo.transaction(fun)
    end
  end

  # True only for a real Ecto.Adapters.Postgres-backed repo. Guarded so the stub
  # repos used in the DB-free retry tests (which don't define `__adapter__/0`)
  # don't crash here — they fall through to "not postgres" and skip the lock.
  defp postgres_repo?(repo) do
    function_exported?(repo, :__adapter__, 0) and
      repo.__adapter__() == Ecto.Adapters.Postgres
  end

  defp sqlite_repo?(repo) do
    function_exported?(repo, :__adapter__, 0) and
      repo.__adapter__() == Ecto.Adapters.SQLite3
  end

  defp head_fresh?(_repo, _stream_id, nil), do: true

  defp head_fresh?(repo, stream_id, max_current_age_ms) do
    stream_id
    |> current_head_query()
    |> maybe_require_fresh_head(repo, max_current_age_ms)
    |> select([e], true)
    |> repo.one()
    |> Kernel.==(true)
  end

  defp maybe_require_fresh_head(query, _repo, nil), do: query

  defp maybe_require_fresh_head(query, repo, max_current_age_ms) do
    head_id_query = select(query, [e], e.id)

    query =
      from(e in EventSchema,
        where: e.id in subquery(head_id_query)
      )

    if postgres_repo?(repo) do
      where(
        query,
        [e],
        fragment(
          "? > clock_timestamp() - (? * interval '1 millisecond')",
          e.committed_at,
          ^max_current_age_ms
        )
      )
    else
      where(
        query,
        [e],
        fragment(
          "((julianday('now') - julianday(?)) * 86400000.0) < ?",
          e.committed_at,
          ^max_current_age_ms
        )
      )
    end
  end

  defp current_head_query(stream_id) do
    from(e in EventSchema,
      where: e.stream_id == ^stream_id,
      order_by: [desc: e.event_number],
      limit: 1
    )
  end

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

    inserted =
      %EventSchema{}
      |> EventSchema.changeset(attrs)
      |> repo.insert!()

    case inserted do
      %EventSchema{id: id} ->
        %EventSchema{committed_at: %DateTime{}} = repo.get!(EventSchema, id)
        event

      _test_repo_result ->
        event
    end
  end

  defp order_by_direction(field, :forward), do: [asc: field]
  defp order_by_direction(field, :backward), do: [desc: field]

  defp handle_transaction_result({:ok, events}), do: {:ok, events}
  defp handle_transaction_result({:error, :version_conflict}), do: {:error, :version_conflict}
  defp handle_transaction_result({:error, :deadline_exceeded}), do: {:error, :deadline_exceeded}

  defp handle_transaction_result({:error, reason}) do
    Logger.error("Transaction failed: #{inspect(reason)}")
    {:error, reason}
  end
end
