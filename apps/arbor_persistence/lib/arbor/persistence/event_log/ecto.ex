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
  - Strict global ordering via transactional append serialization
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

  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Persistence.{Event, EventLog}
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Event, as: EventSchema
  alias Arbor.Persistence.Schemas.EventLogOperation, as: OperationSchema
  alias Ecto.{Adapter, Adapters.SQL}

  require Logger

  @doc """
  Append one or more events to a stream.

  Events are assigned sequential event_numbers within the stream.
  Global positions are assigned across all streams.

  ## Options

  - `:repo` - Ecto Repo to use (default: `Arbor.Persistence.Repo`)
  - `:expected_version` - Optimistic concurrency check (optional)
  - `:max_current_age_ms` - Require a current head younger than this duration
  - `:append_timeout_ms` - Absolute database append budget in `1..60_000`
    milliseconds (default: `5_000`), including checkout, lock acquisition,
    preconditions, writes, and commit
  - `:sqlite_busy_deadline_ms` - Deprecated SQLite alias for
    `:append_timeout_ms`

  ## Returns

  - `{:ok, [Event.t()]}` - Persisted events with assigned positions
  - `{:error, :version_conflict}` - Expected version didn't match
  - `{:error, {:append_indeterminate, operation}}` - Commit outcome requires
    exact-ID reconciliation
  - `{:error, term()}` - Database error
  """
  @impl true
  # Bounded optimistic-concurrency retry for the event_number race (see do_append).
  @max_append_attempts 5
  @append_lock_initial_backoff_ms 2
  @append_lock_max_backoff_ms 50
  @sqlite_busy_slice_ms 5
  @sqlite_pragma_timeout_ms 25
  @global_append_lock_sql "SELECT pg_try_advisory_xact_lock(hashtext('arbor.persistence.event_log.global_append'))"
  @operation_append_lock_sql "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 1))"
  @operation_reconcile_lock_sql "SELECT pg_advisory_xact_lock(hashtextextended($1, 1))"
  @append_repo_callbacks [transaction: 1, rollback: 1, one: 1, insert!: 1]

  def append(stream_id, events, opts \\ []) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, append_deadline_mono ->
      with {:ok, events, preconditions, operation, ^append_deadline_mono} <-
             EventLog.prepare_append(stream_id, events, normalized_opts),
           {:ok, repo} <- fetch_repo(normalized_opts) do
        append_fun = fn ->
          append_prepared(
            repo,
            stream_id,
            events,
            preconditions,
            operation,
            normalized_opts,
            append_deadline_mono
          )
        end

        result =
          if database_repo?(repo),
            do: run_bounded(append_fun, operation, append_deadline_mono),
            else: append_fun.()

        EventLog.accept_completion(
          result,
          operation,
          append_deadline_mono,
          System.monotonic_time(:millisecond)
        )
      end
    end)
  end

  defp append_prepared(
         repo,
         stream_id,
         events,
         preconditions,
         operation,
         opts,
         append_deadline_mono
       ) do
    if database_repo?(repo) do
      do_append(
        stream_id,
        events,
        preconditions,
        operation,
        opts,
        1,
        append_deadline_mono,
        0
      )
    else
      do_append(
        stream_id,
        events,
        preconditions,
        operation,
        opts,
        1,
        append_deadline_mono,
        0
      )
    end
  end

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

  @impl Arbor.Persistence.EventLog
  def reconcile_append(operation, opts) do
    EventLog.with_operation_deadline(opts, fn normalized_opts, deadline_mono ->
      with {:ok, operation, normalized_opts, ^deadline_mono} <-
             EventLog.prepare_reconcile(operation, normalized_opts),
           {:ok, repo} <- fetch_repo(normalized_opts) do
        run_bounded(
          fn -> reconcile_operation(repo, operation, deadline_mono) end,
          operation,
          deadline_mono
        )
      end
    end)
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
  # Serialize every append before reading either stream or global position. The
  # global lock is conservative, but it preserves strict cross-stream ordering
  # without rewriting existing positions. PostgreSQL uses a bounded try-lock;
  # SQLite's BEGIN IMMEDIATE is the equivalent database-wide write lock.
  defp do_append(
         stream_id,
         events,
         preconditions,
         operation,
         opts,
         attempt,
         append_deadline_mono,
         lock_attempt
       ) do
    phase_key = {__MODULE__, :append_phase, operation.operation_id}

    context = %{
      stream_id: stream_id,
      events: events,
      preconditions: preconditions,
      operation: operation,
      opts: opts,
      attempt: attempt,
      deadline_mono: append_deadline_mono,
      lock_attempt: lock_attempt,
      phase_key: phase_key
    }

    try do
      Process.put(phase_key, :prewrite)

      with_append_errors(context, fn ->
        repo = Keyword.get(opts, :repo, Repo)

        transaction(repo, append_deadline_mono, fn ->
          append_in_transaction(
            repo,
            stream_id,
            events,
            preconditions,
            operation,
            phase_key,
            append_deadline_mono
          )
        end)
        |> handle_append_result(context)
      end)
    after
      Process.delete(phase_key)
    end
  end

  defp append_in_transaction(
         repo,
         stream_id,
         events,
         preconditions,
         operation,
         phase_key,
         deadline_mono
       ) do
    case acquire_operation_append_lock(repo, operation.operation_id, deadline_mono) do
      :ok -> :ok
      {:error, reason} -> repo.rollback(reason)
    end

    case acquire_global_append_lock(repo, deadline_mono) do
      :ok -> :ok
      {:error, reason} -> repo.rollback(reason)
    end

    operation_status =
      if database_repo?(repo),
        do: operation_state(repo, operation, deadline_mono),
        else: :absent

    case operation_status do
      {:committed, persisted} ->
        persisted

      {:aborted, reason} ->
        {:fenced, {:aborted, reason}}

      :conflict ->
        {:fenced, :conflict}

      :absent ->
        append_new_operation(
          repo,
          stream_id,
          events,
          preconditions,
          operation,
          phase_key,
          deadline_mono
        )
    end
  end

  defp append_new_operation(
         repo,
         stream_id,
         events,
         preconditions,
         operation,
         phase_key,
         deadline_mono
       ) do
    current_version = get_current_version(repo, stream_id, deadline_mono)
    global_position = get_max_global_position(repo, deadline_mono)

    with :ok <- enforce_expected_version(preconditions.expected_version, current_version),
         :ok <-
           enforce_fresh_head(
             repo,
             stream_id,
             preconditions.max_current_age_ms,
             deadline_mono
           ),
         :ok <-
           EventLog.ensure_position_capacity(current_version, global_position, length(events)) do
      persisted =
        persist_events(
          repo,
          stream_id,
          events,
          operation,
          current_version,
          global_position,
          phase_key,
          deadline_mono
        )

      maybe_insert_operation_fence!(repo, operation, "committed", nil, deadline_mono)
      ensure_before_deadline(repo, deadline_mono)
      persisted
    else
      {:error, reason} ->
        maybe_insert_operation_fence!(
          repo,
          operation,
          "aborted",
          Atom.to_string(reason),
          deadline_mono
        )

        {:fenced_error, reason}
    end
  end

  defp enforce_expected_version(nil, _current_version), do: :ok

  defp enforce_expected_version(expected_version, current_version) do
    if expected_version == current_version,
      do: :ok,
      else: {:error, :version_conflict}
  end

  defp enforce_fresh_head(repo, stream_id, max_current_age_ms, deadline_mono) do
    if head_fresh?(repo, stream_id, max_current_age_ms, deadline_mono),
      do: :ok,
      else: {:error, :deadline_exceeded}
  end

  defp persist_events(
         repo,
         stream_id,
         events,
         operation,
         current_version,
         global_position,
         phase_key,
         deadline_mono
       ) do
    Process.put(phase_key, :write_started)

    {persisted, _final_position} =
      events
      |> Enum.with_index(current_version + 1)
      |> Enum.map_reduce(global_position, fn {%Event{} = event, event_number}, position ->
        next_position = position + 1

        positioned_event = %Event{
          event
          | stream_id: stream_id,
            event_number: event_number,
            global_position: next_position
        }

        fingerprint = Map.fetch!(operation.fingerprints, event.id)

        {
          insert_event(
            repo,
            positioned_event,
            operation.operation_id,
            fingerprint,
            deadline_mono
          ),
          next_position
        }
      end)

    persisted
  end

  defp handle_append_result(
         {:error, :append_lock_busy},
         context
       ) do
    if write_started?(context) do
      EventLog.indeterminate(context.operation)
    else
      retry_append_lock(
        context.stream_id,
        context.events,
        context.preconditions,
        context.operation,
        context.opts,
        context.attempt,
        context.deadline_mono,
        context.lock_attempt
      )
    end
  end

  defp handle_append_result({:sqlite_busy, _after_begin}, context) do
    if write_started?(context),
      do: EventLog.indeterminate(context.operation),
      else: {:error, :database_busy}
  end

  defp handle_append_result({:ok, {:fenced, {:aborted, reason}}}, _context),
    do: {:error, aborted_append_reason(reason)}

  defp handle_append_result({:ok, {:fenced, :conflict}}, _context),
    do: {:error, :event_identity_conflict}

  defp handle_append_result({:ok, {:fenced_error, reason}}, _context), do: {:error, reason}

  defp handle_append_result({:ok, events}, _context), do: {:ok, events}

  defp handle_append_result({:error, reason}, context) do
    if write_started?(context) do
      EventLog.indeterminate(context.operation)
    else
      determinate_transaction_error(reason)
    end
  end

  defp handle_append_result(other, context) do
    if write_started?(context),
      do: EventLog.indeterminate(context.operation),
      else: {:error, {:database_unavailable, other}}
  end

  defp with_append_errors(context, fun) do
    fun.()
  rescue
    error in [Ecto.ConstraintError, Ecto.InvalidChangesetError] ->
      handle_constraint_conflict(error, context, __STACKTRACE__)

    error in DBConnection.ConnectionError ->
      handle_connection_error(error, context)

    error ->
      handle_append_exception(error, context, __STACKTRACE__)
  catch
    :exit, reason -> handle_append_exit(reason, context)
  end

  defp handle_constraint_conflict(error, context, stacktrace) do
    repo = context_repo(context)

    reconciliation =
      if database_repo?(repo),
        do: lookup_operation(repo, context.operation, context.deadline_mono),
        else: {:ok, :absent}

    case reconciliation do
      {:ok, {:committed, persisted}} ->
        {:ok, persisted}

      {:ok, :absent} ->
        handle_absent_constraint(constraint_kind(error), error, context, stacktrace)

      {:error, _reason} = reconciliation_error ->
        reconciliation_error
    end
  end

  defp handle_absent_constraint(:global_position, _error, context, _stacktrace),
    do: retry_constraint(context)

  defp handle_absent_constraint(:event_number, _error, context, _stacktrace) do
    if is_nil(context.preconditions.expected_version),
      do: retry_constraint(context),
      else: {:error, :version_conflict}
  end

  defp handle_absent_constraint(:event_id, _error, _context, _stacktrace),
    do: {:error, :event_identity_conflict}

  defp handle_absent_constraint(:other, error, _context, stacktrace),
    do: reraise(error, stacktrace)

  defp retry_constraint(%{attempt: attempt} = context) when attempt < @max_append_attempts do
    case EventLog.remaining_timeout(context.deadline_mono) do
      {:ok, _remaining} ->
        do_append(
          context.stream_id,
          context.events,
          context.preconditions,
          context.operation,
          context.opts,
          attempt + 1,
          context.deadline_mono,
          context.lock_attempt
        )

      {:error, :operation_timeout} ->
        {:error, deadline_error(context_repo(context))}
    end
  end

  defp retry_constraint(context), do: {:error, {:append_conflict, context.operation.operation_id}}

  defp handle_connection_error(error, context) do
    cond do
      write_started?(context) ->
        EventLog.indeterminate(context.operation)

      timeout_failure?(error) or deadline_expired?(context.deadline_mono) ->
        {:error, deadline_error(context_repo(context))}

      true ->
        {:error, {:database_unavailable, error}}
    end
  end

  defp handle_append_exception(error, context, stacktrace) do
    cond do
      write_started?(context) ->
        EventLog.indeterminate(context.operation)

      timeout_failure?(error) or deadline_expired?(context.deadline_mono) ->
        {:error, deadline_error(context_repo(context))}

      true ->
        reraise(error, stacktrace)
    end
  end

  defp handle_append_exit(reason, context) do
    cond do
      write_started?(context) ->
        EventLog.indeterminate(context.operation)

      timeout_failure?(reason) or deadline_expired?(context.deadline_mono) ->
        {:error, deadline_error(context_repo(context))}

      true ->
        {:error, {:database_unavailable, reason}}
    end
  end

  defp context_repo(context), do: Keyword.get(context.opts, :repo, Repo)

  defp fetch_repo(opts) do
    case Keyword.get(opts, :repo, Repo) do
      repo when is_atom(repo) and not is_nil(repo) ->
        if Code.ensure_loaded?(repo) and valid_append_repo?(repo),
          do: {:ok, repo},
          else: {:error, :invalid_precondition}

      _invalid ->
        {:error, :invalid_precondition}
    end
  end

  defp valid_append_repo?(repo) do
    Enum.all?(@append_repo_callbacks, fn {function, arity} ->
      function_exported?(repo, function, arity)
    end)
  end

  defp write_started?(context), do: Process.get(context.phase_key) == :write_started

  defp constraint_kind(%Ecto.ConstraintError{} = error) do
    classify_constraint("#{error.constraint} #{Exception.message(error)}")
  end

  defp constraint_kind(%Ecto.InvalidChangesetError{changeset: changeset}) do
    changeset.errors
    |> Enum.map(fn {_field, {_message, opts}} -> Keyword.get(opts, :constraint_name, "") end)
    |> Enum.join(" ")
    |> classify_constraint()
  end

  defp classify_constraint(name) do
    cond do
      String.contains?(name, "global_position") -> :global_position
      String.contains?(name, "event_number") -> :event_number
      String.contains?(name, "events_pkey") -> :event_id
      true -> :other
    end
  end

  defp determinate_transaction_error(reason)
       when reason in [
              :version_conflict,
              :deadline_exceeded,
              :operation_timeout,
              :database_busy,
              :stream_position_exhausted,
              :global_position_exhausted
            ],
       do: {:error, reason}

  defp determinate_transaction_error(reason), do: {:error, reason}

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
             global_position: non_neg_integer(),
             identity_history: {:unavailable, :metadata_only}
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

    {:ok,
     %{
       stream_versions: stream_versions,
       global_position: global_position,
       identity_history: {:unavailable, :metadata_only}
     }}
  rescue
    e ->
      {:error, {:metadata_snapshot_failed, e}}
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp acquire_operation_append_lock(repo, operation_id, deadline_mono) do
    if postgres_repo?(repo) do
      case repo.query(
             @operation_append_lock_sql,
             [operation_id],
             deadline_query_opts(repo, deadline_mono)
           ) do
        {:ok, %{rows: [[true]]}} -> :ok
        {:ok, %{rows: [[false]]}} -> {:error, :append_lock_busy}
        {:error, error} -> raise error
      end
    else
      :ok
    end
  end

  defp acquire_operation_reconcile_lock(repo, operation_id, deadline_mono) do
    if postgres_repo?(repo) do
      case repo.query(
             @operation_reconcile_lock_sql,
             [operation_id],
             deadline_query_opts(repo, deadline_mono)
           ) do
        {:ok, %{rows: [[_lock_result]]}} -> :ok
        {:error, error} -> raise error
      end
    else
      :ok
    end
  end

  defp operation_state(repo, operation, deadline_mono) do
    case operation_fence(repo, operation.operation_id, deadline_mono) do
      nil -> terminalize_existing_events(repo, operation, deadline_mono)
      fence -> classify_operation_fence(repo, fence, operation, deadline_mono)
    end
  end

  defp terminalize_existing_events(repo, operation, deadline_mono) do
    case reconcile_event_rows(repo, operation, deadline_mono) do
      {:ok, {:committed, events}} ->
        insert_operation_fence!(repo, operation, "committed", nil, deadline_mono)
        {:committed, events}

      {:ok, :absent} ->
        :absent

      {:error, _conflict_or_partial} ->
        insert_operation_fence!(
          repo,
          operation,
          "conflict",
          "event_identity_conflict",
          deadline_mono
        )

        :conflict
    end
  end

  defp classify_operation_fence(repo, fence, operation, deadline_mono) do
    if operation_fence_matches?(fence, operation) do
      case fence.status do
        "committed" ->
          case reconcile_event_rows(repo, operation, deadline_mono) do
            {:ok, {:committed, events}} -> {:committed, events}
            _missing_or_corrupt_commit -> :conflict
          end

        "aborted" ->
          {:aborted, fence.reason}

        "conflict" ->
          :conflict

        _invalid_status ->
          :conflict
      end
    else
      :conflict
    end
  end

  defp operation_fence(repo, operation_id, deadline_mono) do
    query =
      from(operation in OperationSchema,
        where: operation.operation_id == ^operation_id,
        limit: 1
      )

    repo_one(query, repo, deadline_mono)
  end

  defp operation_fence_matches?(%OperationSchema{} = fence, operation) do
    fence.stream_id == operation.stream_id and fence.identity == operation_identity(operation)
  end

  defp operation_identity(operation) do
    %{
      "event_ids" => operation.event_ids,
      "fingerprints" => operation.fingerprints
    }
  end

  defp insert_operation_fence!(repo, operation, status, reason, deadline_mono) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      operation_id: operation.operation_id,
      stream_id: operation.stream_id,
      identity: operation_identity(operation),
      status: status,
      reason: reason,
      inserted_at: now,
      updated_at: now
    }

    opts =
      [on_conflict: :nothing, conflict_target: :operation_id]
      |> Keyword.merge(deadline_query_opts(repo, deadline_mono))

    case repo.insert_all(OperationSchema, [attrs], opts) do
      {1, _rows} -> :ok
      {0, _rows} -> verify_existing_operation_fence!(repo, operation, status, deadline_mono)
    end
  end

  defp maybe_insert_operation_fence!(repo, operation, status, reason, deadline_mono) do
    if database_repo?(repo),
      do: insert_operation_fence!(repo, operation, status, reason, deadline_mono),
      else: :ok
  end

  defp aborted_append_reason("version_conflict"), do: :version_conflict
  defp aborted_append_reason("deadline_exceeded"), do: :deadline_exceeded
  defp aborted_append_reason("stream_position_exhausted"), do: :stream_position_exhausted
  defp aborted_append_reason("global_position_exhausted"), do: :global_position_exhausted
  defp aborted_append_reason(_reason), do: :operation_aborted

  defp verify_existing_operation_fence!(repo, operation, status, deadline_mono) do
    case operation_fence(repo, operation.operation_id, deadline_mono) do
      %OperationSchema{} = fence ->
        unless operation_fence_matches?(fence, operation) and fence.status == status do
          repo.rollback(:event_identity_conflict)
        end

        :ok

      nil ->
        repo.rollback(:operation_fence_unavailable)
    end
  end

  defp reconcile_event_rows(repo, operation, deadline_mono) do
    query =
      from(event in EventSchema,
        where: event.id in ^operation.event_ids
      )

    query
    |> repo_all(repo, deadline_mono)
    |> Enum.map(&EventSchema.to_event/1)
    |> then(&EventLog.reconcile_events(operation, &1))
  end

  defp lookup_operation(repo, operation, deadline_mono) do
    case reconcile_event_rows(repo, operation, deadline_mono) do
      {:ok, {:committed, persisted}} -> {:ok, {:committed, persisted}}
      {:ok, :absent} -> {:ok, :absent}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> EventLog.indeterminate(operation)
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  defp acquire_global_append_lock(repo, deadline_mono) do
    if postgres_repo?(repo) do
      case repo.query(@global_append_lock_sql, [], deadline_query_opts(repo, deadline_mono)) do
        {:ok, %{rows: [[true]]}} -> :ok
        {:ok, %{rows: [[false]]}} -> {:error, :append_lock_busy}
        {:error, error} -> raise error
      end
    else
      :ok
    end
  end

  defp transaction(repo, deadline_mono, fun) do
    cond do
      sqlite_repo?(repo) ->
        sqlite_transaction(repo, deadline_mono, fun)

      postgres_repo?(repo) ->
        postgres_transaction(repo, deadline_mono, fun)

      true ->
        repo.transaction(fun)
    end
  end

  defp postgres_transaction(repo, deadline_mono, fun) do
    case EventLog.remaining_timeout(deadline_mono) do
      {:ok, timeout} ->
        try do
          repo.transaction(fun,
            timeout: timeout,
            deadline: deadline_mono,
            queue: false
          )
        rescue
          error in DBConnection.ConnectionError ->
            if pool_unavailable?(error),
              do: {:error, :append_lock_busy},
              else: reraise(error, __STACKTRACE__)
        end

      {:error, :operation_timeout} ->
        {:error, :operation_timeout}
    end
  end

  defp sqlite_transaction(repo, deadline_mono, fun) do
    transaction_started = {__MODULE__, make_ref()}

    try do
      result =
        case EventLog.remaining_timeout(deadline_mono) do
          {:ok, checkout_timeout} ->
            checkout_sql_connection(repo, checkout_timeout, deadline_mono, fn ->
              original_busy_timeout = sqlite_busy_timeout(repo, deadline_mono)
              bounded_busy_timeout = sqlite_attempt_busy_timeout(deadline_mono)

              set_sqlite_busy_timeout(repo, bounded_busy_timeout, deadline_mono)

              try do
                case EventLog.remaining_timeout(deadline_mono) do
                  {:ok, transaction_timeout} ->
                    repo.transaction(
                      fn ->
                        Process.put(transaction_started, true)
                        fun.()
                      end,
                      mode: :immediate,
                      timeout: transaction_timeout,
                      deadline: deadline_mono
                    )

                  {:error, :operation_timeout} ->
                    {:error, :append_lock_busy}
                end
              after
                reset_sqlite_busy_timeout(repo, original_busy_timeout)
              end
            end)

          {:error, :operation_timeout} ->
            {:error, :append_lock_busy}
        end

      phase = sqlite_transaction_phase(transaction_started)

      if retryable_sqlite_failure?(result, phase) do
        if phase == :acquisition,
          do: {:error, :append_lock_busy},
          else: {:sqlite_busy, phase}
      else
        result
      end
    rescue
      error ->
        phase = sqlite_transaction_phase(transaction_started)

        if retryable_sqlite_failure?(error, phase) do
          if phase == :acquisition,
            do: {:error, :append_lock_busy},
            else: {:sqlite_busy, phase}
        else
          reraise(error, __STACKTRACE__)
        end
    catch
      :exit, reason ->
        phase = sqlite_transaction_phase(transaction_started)

        if retryable_sqlite_failure?(reason, phase) do
          if phase == :acquisition,
            do: {:error, :append_lock_busy},
            else: {:sqlite_busy, phase}
        else
          exit(reason)
        end
    after
      Process.delete(transaction_started)
    end
  end

  defp retry_append_lock(
         stream_id,
         events,
         preconditions,
         operation,
         opts,
         append_attempt,
         deadline_mono,
         lock_attempt
       ) do
    repo = Keyword.get(opts, :repo, Repo)

    case EventLog.remaining_timeout(deadline_mono) do
      {:error, :operation_timeout} ->
        {:error, deadline_error(repo)}

      {:ok, remaining_ms} ->
        backoff_ms =
          min(
            @append_lock_initial_backoff_ms * Integer.pow(2, min(lock_attempt, 5)),
            @append_lock_max_backoff_ms
          )

        Process.sleep(min(backoff_ms, remaining_ms))

        do_append(
          stream_id,
          events,
          preconditions,
          operation,
          opts,
          append_attempt,
          deadline_mono,
          lock_attempt + 1
        )
    end
  end

  defp checkout_sql_connection(repo, timeout, deadline_mono, fun) do
    repo.get_dynamic_repo()
    |> Adapter.lookup_meta()
    |> SQL.checkout(
      [timeout: timeout, deadline: deadline_mono, queue: false],
      fun
    )
  end

  defp sqlite_busy_timeout(repo, deadline_mono) do
    case repo.query("PRAGMA busy_timeout", [], sqlite_control_opts(deadline_mono)) do
      {:ok, %{rows: [[timeout]]}} when is_integer(timeout) -> timeout
      {:ok, result} -> raise "unexpected SQLite busy_timeout result: #{inspect(result)}"
      {:error, error} -> raise error
    end
  end

  defp sqlite_attempt_busy_timeout(deadline_mono) do
    case EventLog.remaining_timeout(deadline_mono) do
      {:ok, remaining_ms} -> max(1, min(remaining_ms, @sqlite_busy_slice_ms))
      {:error, :operation_timeout} -> 1
    end
  end

  defp set_sqlite_busy_timeout(repo, timeout, deadline_mono) do
    case repo.query(
           "PRAGMA busy_timeout = #{timeout}",
           [],
           sqlite_control_opts(deadline_mono)
         ) do
      {:ok, _result} -> :ok
      {:error, error} -> raise error
    end
  end

  defp reset_sqlite_busy_timeout(repo, timeout) do
    case repo.query("PRAGMA busy_timeout = #{timeout}", [], timeout: @sqlite_pragma_timeout_ms) do
      {:ok, _result} -> :ok
      {:error, %DBConnection.ConnectionError{}} -> :ok
      {:error, error} -> raise error
    end
  catch
    :exit, reason ->
      if nested_reason?(reason, :noproc) or sqlite_connection_closed?(reason),
        do: :ok,
        else: exit(reason)
  end

  defp sqlite_connection_closed?(value) when is_binary(value) do
    String.contains?(String.downcase(value), "connection is closed")
  end

  defp sqlite_connection_closed?(%{__exception__: true} = error) do
    error |> Exception.message() |> sqlite_connection_closed?()
  end

  defp sqlite_connection_closed?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&sqlite_connection_closed?/1)
  end

  defp sqlite_connection_closed?(value) when is_list(value),
    do: Enum.any?(value, &sqlite_connection_closed?/1)

  defp sqlite_connection_closed?(_value), do: false

  defp pool_unavailable?(%{__exception__: true} = error) do
    error |> Exception.message() |> pool_unavailable?()
  end

  defp pool_unavailable?(message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "connection not available") or
      String.contains?(normalized, "queuing is disabled")
  end

  defp pool_unavailable?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&pool_unavailable?/1)
  end

  defp pool_unavailable?(value) when is_list(value),
    do: Enum.any?(value, &pool_unavailable?/1)

  defp pool_unavailable?(_value), do: false

  defp sqlite_control_opts(deadline_mono) do
    timeout =
      case EventLog.remaining_timeout(deadline_mono) do
        {:ok, remaining_ms} -> min(remaining_ms, @sqlite_pragma_timeout_ms)
        {:error, :operation_timeout} -> 1
      end

    [timeout: timeout, deadline: deadline_mono]
  end

  defp sqlite_transaction_phase(marker) do
    if Process.get(marker), do: :transaction, else: :acquisition
  end

  defp retryable_sqlite_failure?(failure, phase) do
    sqlite_lock_failure?(failure) or
      (phase == :acquisition and
         (nested_reason?(failure, :timeout) or pool_unavailable?(failure)))
  end

  defp sqlite_lock_failure?(%{__exception__: true} = error) do
    error
    |> Exception.message()
    |> sqlite_lock_message?()
  end

  defp sqlite_lock_failure?(message) when is_binary(message), do: sqlite_lock_message?(message)

  defp sqlite_lock_failure?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&sqlite_lock_failure?/1)
  end

  defp sqlite_lock_failure?(value) when is_list(value),
    do: Enum.any?(value, &sqlite_lock_failure?/1)

  defp sqlite_lock_failure?(_value), do: false

  defp sqlite_lock_message?(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "database is busy") or
      String.contains?(normalized, "database busy") or
      String.contains?(normalized, "database is locked") or
      String.contains?(normalized, "database table is locked")
  end

  defp nested_reason?(value, expected) when value == expected, do: true

  defp nested_reason?(value, expected) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.any?(&nested_reason?(&1, expected))
  end

  defp nested_reason?(value, expected) when is_list(value),
    do: Enum.any?(value, &nested_reason?(&1, expected))

  defp nested_reason?(_value, _expected), do: false

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

  defp database_repo?(repo), do: postgres_repo?(repo) or sqlite_repo?(repo)

  defp head_fresh?(_repo, _stream_id, nil, _deadline_mono), do: true

  defp head_fresh?(repo, stream_id, max_current_age_ms, deadline_mono) do
    stream_id
    |> current_head_query()
    |> maybe_require_fresh_head(repo, max_current_age_ms)
    |> select([e], true)
    |> repo_one(repo, deadline_mono)
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

  defp reconcile_operation(repo, %AppendOperation{} = operation, deadline_mono) do
    if database_repo?(repo) do
      transaction(repo, deadline_mono, fn ->
        :ok = acquire_operation_reconcile_lock(repo, operation.operation_id, deadline_mono)
        reconcile_and_terminalize(repo, operation, deadline_mono)
      end)
      |> handle_reconcile_transaction(operation)
    else
      {:ok, :absent}
    end
  rescue
    _error -> EventLog.indeterminate(operation)
  catch
    :exit, _reason -> EventLog.indeterminate(operation)
  end

  defp reconcile_and_terminalize(repo, operation, deadline_mono) do
    case operation_fence(repo, operation.operation_id, deadline_mono) do
      %OperationSchema{} = fence ->
        case classify_operation_fence(repo, fence, operation, deadline_mono) do
          {:committed, events} -> {:ok, {:committed, events}}
          {:aborted, _reason} -> {:ok, :absent}
          :conflict -> {:error, :event_identity_conflict}
        end

      nil ->
        case reconcile_event_rows(repo, operation, deadline_mono) do
          {:ok, {:committed, events}} ->
            insert_operation_fence!(repo, operation, "committed", nil, deadline_mono)
            {:ok, {:committed, events}}

          {:ok, :absent} ->
            insert_operation_fence!(
              repo,
              operation,
              "aborted",
              "reconciled_absent",
              deadline_mono
            )

            {:ok, :absent}

          {:error, _conflict_or_partial} ->
            insert_operation_fence!(
              repo,
              operation,
              "conflict",
              "event_identity_conflict",
              deadline_mono
            )

            {:error, :event_identity_conflict}
        end
    end
  end

  defp handle_reconcile_transaction({:ok, result}, _operation), do: result

  defp handle_reconcile_transaction({:error, _reason}, operation),
    do: EventLog.indeterminate(operation)

  defp handle_reconcile_transaction(_other, operation), do: EventLog.indeterminate(operation)

  defp get_current_version(repo, stream_id) do
    get_current_version(repo, stream_id, nil)
  end

  defp get_current_version(repo, stream_id, deadline_mono) do
    query =
      from(e in EventSchema,
        where: e.stream_id == ^stream_id,
        select: max(e.event_number)
      )

    repo_one(query, repo, deadline_mono) || 0
  end

  defp get_max_global_position(repo, deadline_mono) do
    query = from(e in EventSchema, select: max(e.global_position))
    repo_one(query, repo, deadline_mono) || 0
  end

  defp insert_event(repo, %Event{} = event, operation_id, fingerprint, deadline_mono) do
    attrs =
      event
      |> EventSchema.from_event()
      |> Map.put(:operation_id, operation_id)
      |> Map.put(:operation_fingerprint, fingerprint)

    inserted =
      %EventSchema{}
      |> EventSchema.changeset(attrs)
      |> repo_insert!(repo, deadline_mono)

    case inserted do
      %EventSchema{id: id} ->
        %EventSchema{committed_at: %DateTime{}} = repo_get!(repo, EventSchema, id, deadline_mono)
        event

      _test_repo_result ->
        event
    end
  end

  defp repo_one(query, repo, nil), do: repo.one(query)

  defp repo_one(query, repo, deadline_mono) do
    if database_repo?(repo),
      do: repo.one(query, deadline_query_opts(repo, deadline_mono)),
      else: repo.one(query)
  end

  defp repo_insert!(changeset, repo, deadline_mono) do
    if database_repo?(repo),
      do: repo.insert!(changeset, deadline_query_opts(repo, deadline_mono)),
      else: repo.insert!(changeset)
  end

  defp repo_all(query, repo, deadline_mono) do
    if database_repo?(repo),
      do: repo.all(query, deadline_query_opts(repo, deadline_mono)),
      else: repo.all(query)
  end

  defp repo_get!(repo, schema, id, deadline_mono) do
    if database_repo?(repo),
      do: repo.get!(schema, id, deadline_query_opts(repo, deadline_mono)),
      else: repo.get!(schema, id)
  end

  defp deadline_query_opts(repo, deadline_mono) do
    case EventLog.remaining_timeout(deadline_mono) do
      {:ok, timeout} -> [timeout: timeout, deadline: deadline_mono]
      {:error, :operation_timeout} -> repo.rollback(deadline_error(repo))
    end
  end

  defp ensure_before_deadline(_repo, nil), do: :ok

  defp ensure_before_deadline(repo, deadline_mono) do
    if deadline_expired?(deadline_mono),
      do: repo.rollback(deadline_error(repo)),
      else: :ok
  end

  defp deadline_expired?(nil), do: false

  defp deadline_expired?(deadline_mono) do
    System.monotonic_time(:millisecond) >= deadline_mono
  end

  defp deadline_error(repo) do
    if sqlite_repo?(repo), do: :database_busy, else: :operation_timeout
  end

  defp timeout_failure?(reason) do
    nested_reason?(reason, :timeout) or
      (is_exception(reason) and
         reason |> Exception.message() |> String.downcase() |> String.contains?("timeout"))
  end

  defp order_by_direction(field, :forward), do: [asc: field]
  defp order_by_direction(field, :backward), do: [desc: field]
end
