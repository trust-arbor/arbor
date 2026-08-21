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

  alias Arbor.Contracts.Persistence.AppendOperation
  alias Arbor.Contracts.Persistence.Store
  alias Arbor.Persistence.Event

  @max_string_bytes 255
  @max_options 64
  @max_append_events 1_000
  @max_event_bytes 1_048_576
  @max_append_bytes 4_194_304
  @max_identity_event_bytes @max_append_bytes
  @max_precondition_integer 2_147_483_647
  @default_append_timeout_ms 5_000
  @max_append_timeout_ms 60_000
  @max_stream_position 2_147_483_647
  @max_global_position 2_147_483_647
  @deadline_context_key {__MODULE__, :operation_deadline}

  @type stream_id :: String.t()
  @type opts :: keyword()
  @type append_preconditions :: %{
          expected_version: non_neg_integer() | nil,
          max_current_age_ms: non_neg_integer() | nil
        }
  @type append_result ::
          {:ok, [Event.t()]}
          | {:error, {:append_indeterminate, AppendOperation.t()}}
          | {:error, term()}
  @type append_reconciliation ::
          {:ok, {:committed, [Event.t()]}}
          | {:ok, :absent}
          | {:error,
             :event_identity_conflict
             | :invalid_append_operation
             | :invalid_reconciliation
             | {:append_indeterminate, AppendOperation.t()}}
  @type purge_error ::
          :backend_unavailable
          | :invalid_precondition
          | :invalid_stream_id
          | :purge_not_supported
          | :purge_verification_failed
  @type purge_result ::
          :ok
          | {:error, {:purge_indeterminate, stream_id()}}
          | {:error, purge_error()}
  @type absence_error ::
          :backend_unavailable
          | :invalid_precondition
          | :invalid_stream_id
          | :absence_not_supported
          | :absence_verification_failed
  @type absence_result ::
          {:ok, true}
          | {:ok, false}
          | {:error, {:absence_indeterminate, stream_id()}}
          | {:error, absence_error()}
  @type projection_error ::
          :backend_unavailable
          | :event_id_conflict
          | :global_position_conflict
          | :invalid_precondition
          | :invalid_projection_events
          | :projection_batch_bytes_exceeded
          | :projection_batch_too_large
          | :projection_capacity_exceeded
          | :projection_event_too_large
          | :projection_fingerprint_invalid
          | :projection_fingerprint_missing
          | :projection_fingerprint_mismatch
          | :projection_mode_required
          | :stream_position_conflict
  @type projection_result ::
          {:ok, %{projected: non_neg_integer(), skipped: non_neg_integer()}}
          | {:error, projection_error()}
  @type projection_control_error ::
          :backend_unavailable
          | :invalid_precondition
          | :invalid_stream_id
          | :projection_mode_required
          | :projection_not_supported
  @type projection_eviction_result ::
          {:ok, %{evicted: non_neg_integer()}}
          | {:error, projection_control_error()}

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
  bounded to 255 bytes, options to 64 entries, an append to 1,000 events and
  4 MiB total, and each event term to 1 MiB before backend work begins.

  Stream IDs, event IDs, event types, and optional identity fields are valid
  UTF-8 strings bounded to 255 bytes, matching the narrowest durable schema.
  Event `data` and `metadata` must serialize as JSON objects. Persisted and
  returned events use the canonical JSON representation produced by a JSON
  round-trip, including string map keys at every depth. Timestamps must be valid
  UTC `DateTime` values; agent, causation, and correlation IDs must be nil or
  bounded nonempty strings. These rules make one event fingerprint and one
  returned representation stable across the in-memory, Ecto, and EventStore
  adapters.

  `:append_timeout_ms` sets one absolute `1..60_000` millisecond deadline for
  validation, queueing, mutation, commit, and reply (default `5_000`). If the
  caller cannot prove whether a dispatched append committed, the result is
  `{:error, {:append_indeterminate, operation}}`; pass that stable operation to
  `reconcile_append/2` or retry the exact same event IDs and content.
  """
  @callback append(stream_id(), [Event.t()] | Event.t(), opts()) :: append_result()

  @doc """
  Reconcile an indeterminate append by exact submitted event IDs and content.

  `{:ok, {:committed, events}}` proves the complete operation committed,
  `{:ok, :absent}` proves none of it committed, and an indeterminate result means
  the backend cannot yet prove either outcome. Reusing an event ID with different
  content fails with `:event_identity_conflict`.
  """
  @callback reconcile_append(AppendOperation.t(), opts()) :: append_reconciliation()

  @doc """
  Permanently remove one complete stream and every backend-owned identity entry.

  The operation is idempotent. `:purge_timeout_ms` sets one absolute
  `1..60_000` millisecond deadline (default `5_000`) across validation,
  dispatch, mutation, absence verification, and reply. A timeout or worker exit
  after dispatch returns `{:error, {:purge_indeterminate, stream_id}}`; retrying
  the same stream converges on authoritative absence.

  This callback is optional so adapters that cannot prove whole-stream absence
  remain loadable. The public facade rejects those adapters before dispatch.
  """
  @callback purge_stream(stream_id(), opts()) :: purge_result()

  @doc """
  Prove whether one complete stream is absent on every backend-owned surface.

  Read-only. Returns `{:ok, true}` only after events, versions, identities,
  subscribers, and operation-fence rows owned by the backend for the exact
  stream are proven absent under one serialized observation. Retained state
  returns `{:ok, false}`. Post-dispatch uncertainty returns
  `{:error, {:absence_indeterminate, stream_id}}`.

  `:absence_timeout_ms` sets one absolute `1..60_000` millisecond deadline
  (default `5_000`) across validation, dispatch, serialized reads,
  verification, and reply. This callback is optional so adapters that cannot
  prove complete absence remain loadable; the public facade rejects those
  adapters before dispatch.
  """
  @callback stream_absent(stream_id(), opts()) :: absence_result()

  @doc """
  Read events from a stream.

  Options:
  - `:from` - start reading from this event_number (inclusive, default 0)
  - `:limit` - max events to return
  - `:direction` - :forward (default) or :backward
  """
  @callback read_stream(stream_id(), opts()) :: {:ok, [Event.t()]} | {:error, term()}

  @doc """
  Read one bounded page from an inclusive event-number range.

  This optional callback is for callers that need a stable upper bound while
  paging backward. Implementations require a positive `:limit`; `:from` and
  `:to` are inclusive non-negative event numbers, and `:direction` is
  `:forward` or `:backward`.
  """
  @callback read_stream_range(stream_id(), opts()) ::
              {:ok, [Event.t()]} | {:error, term()}

  @doc """
  Return the immutable fingerprint for one event ID in one stream.

  `nil` means that exact stream-scoped identity is absent. This optional
  callback lets projections compare identities without scanning an event log.
  `:max_event_number` optionally limits the lookup to identities at or before
  that inclusive stream position, allowing callers to preserve a captured
  stream snapshot while comparing projections. A backend with incomplete
  identity history returns `{:error, :identity_history_unavailable}` rather
  than claiming a missing identity is absent.
  """
  @callback event_identity(stream_id(), event_id :: String.t(), opts()) ::
              {:ok, String.t() | nil} | {:error, term()}

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

  @doc """
  Admit events that another component already committed durably.

  This optional callback exists for **non-authoritative projections only**. The
  caller supplies each event's exact `event_number`, `global_position`, and
  canonical `operation_fingerprint`; committed positions are positive and
  1-based. The backend assigns nothing, notifies no subscribers, and gains no
  identity, existence, head, or position authority from the resident rows.

  The complete batch is canonicalized and validated before any mutation, so a
  conflict on any event leaves every backend surface unchanged. Re-projecting a
  byte-identical batch is idempotent and reported as skipped rather than
  projected. Conflicts are reported per surface as `:event_id_conflict`,
  `:global_position_conflict`, or `:stream_position_conflict`.

  A backend running in its ordinary authoritative mode must refuse with
  `{:error, :projection_mode_required}`.
  """
  @callback project_committed_events([Event.t()], opts()) :: projection_result()

  @doc """
  Evict every resident projection row and index entry for exactly one stream.

  This optional callback is a cache operation, not a durable purge: success
  reports only how many resident event payloads were removed and makes no claim
  that the stream is absent from an authoritative store. It is idempotent, and
  byte-identical events may be projected again after eviction.

  An authoritative backend must refuse with `:projection_mode_required`.
  """
  @callback evict_projected_stream(stream_id(), opts()) :: projection_eviction_result()

  @doc """
  Return the highest event number currently resident for one projected stream.

  The result is observation-only and returns zero when no row for the stream is
  resident. It is not an authoritative stream version. An authoritative backend
  must refuse with `:projection_mode_required`.
  """
  @callback resident_projected_stream_version(stream_id(), opts()) ::
              {:ok, non_neg_integer()} | {:error, projection_control_error()}

  @doc """
  Return this EventLog's code-owned durability class.

  This value describes backend-owned durability semantics and is not configurable by
  callers or through options passed to this callback.
  """
  @callback durability_class(opts()) :: Store.durability_class()

  @optional_callbacks [
    reconcile_append: 2,
    purge_stream: 2,
    stream_absent: 2,
    read_stream_range: 2,
    event_identity: 3,
    subscribe: 3,
    list_streams: 1,
    stream_count: 1,
    event_count: 1,
    read_agent_events: 2,
    durability_class: 1,
    project_committed_events: 2,
    evict_projected_stream: 2,
    resident_projected_stream_version: 2
  ]

  @doc false
  @spec with_operation_deadline(term(), (keyword(), integer() -> result)) ::
          result | {:error, :invalid_precondition}
        when result: term()
  def with_operation_deadline(opts, fun) when is_function(fun, 2) do
    with_operation_deadline(opts, :append, fun)
  end

  def with_operation_deadline(_opts, _fun), do: {:error, :invalid_precondition}

  @doc false
  @spec with_operation_deadline(
          term(),
          :append | :purge | :absence,
          (keyword(), integer() -> result)
        ) :: result | {:error, :invalid_precondition}
        when result: term()
  def with_operation_deadline(opts, operation, fun)
      when operation in [:append, :purge, :absence] and is_function(fun, 2) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, timeout_ms} <- operation_timeout(operation, normalized_opts) do
      requested_deadline = started_mono + timeout_ms

      case active_deadline() do
        {:ok, inherited_deadline} ->
          effective_deadline = min(inherited_deadline, requested_deadline)
          previous = Process.get(@deadline_context_key)
          Process.put(@deadline_context_key, %{previous | deadline_mono: effective_deadline})

          try do
            fun.(normalized_opts, effective_deadline)
          after
            Process.put(@deadline_context_key, previous)
          end

        :none ->
          boundary = %{
            owner: self(),
            token: make_ref(),
            deadline_mono: requested_deadline
          }

          previous = Process.put(@deadline_context_key, boundary)

          try do
            fun.(normalized_opts, requested_deadline)
          after
            restore_deadline_context(previous)
          end
      end
    end
  end

  def with_operation_deadline(_opts, _operation, _fun),
    do: {:error, :invalid_precondition}

  @doc false
  @spec with_inherited_deadline(integer(), (-> result)) :: result | {:error, :operation_timeout}
        when result: term()
  def with_inherited_deadline(deadline_mono, fun)
      when is_integer(deadline_mono) and is_function(fun, 0) do
    case remaining_timeout(deadline_mono) do
      {:ok, _remaining} ->
        previous =
          Process.put(@deadline_context_key, %{
            owner: self(),
            token: make_ref(),
            deadline_mono: deadline_mono
          })

        try do
          fun.()
        after
          restore_deadline_context(previous)
        end

      {:error, :operation_timeout} = error ->
        error
    end
  end

  def with_inherited_deadline(_deadline_mono, _fun), do: {:error, :operation_timeout}

  @doc false
  @spec prepare_append(stream_id(), [Event.t()] | Event.t(), opts()) ::
          {:ok, [Event.t()], append_preconditions(), AppendOperation.t(), integer()}
          | {:error, term()}
  def prepare_append(stream_id, events, opts) do
    with {:ok, deadline_mono} <- require_active_deadline(),
         {:ok, events, _normalized_opts, preconditions} <-
           validate_append_input(stream_id, events, opts),
         {:ok, operation} <- build_validated_operation(stream_id, events) do
      {:ok, events, preconditions, operation, deadline_mono}
    end
  end

  @doc false
  @spec prepare_reconcile(term(), term()) ::
          {:ok, AppendOperation.t(), keyword(), integer()}
          | {:error, :invalid_append_operation | :invalid_precondition}
  def prepare_reconcile(operation, opts) do
    with {:ok, deadline_mono} <- require_active_deadline(),
         {:ok, operation} <- validate_operation(operation),
         {:ok, normalized_opts} <- normalize_opts(opts) do
      {:ok, operation, normalized_opts, deadline_mono}
    end
  end

  @doc false
  @spec prepare_purge(stream_id(), term()) ::
          {:ok, keyword(), integer()}
          | {:error, :invalid_stream_id | :invalid_precondition}
  def prepare_purge(stream_id, opts) do
    with {:ok, deadline_mono} <- require_active_deadline(),
         :ok <- validate_stream_id(stream_id),
         {:ok, normalized_opts} <- normalize_opts(opts),
         :ok <- validate_purge_opts(normalized_opts) do
      {:ok, normalized_opts, deadline_mono}
    end
  end

  @doc false
  @spec prepare_absence(stream_id(), term()) ::
          {:ok, keyword(), integer()}
          | {:error, :invalid_stream_id | :invalid_precondition}
  def prepare_absence(stream_id, opts) do
    with {:ok, deadline_mono} <- require_active_deadline(),
         :ok <- validate_stream_id(stream_id),
         {:ok, normalized_opts} <- normalize_opts(opts),
         :ok <- validate_absence_opts(normalized_opts) do
      {:ok, normalized_opts, deadline_mono}
    end
  end

  @doc false
  @spec validate_operation(term()) ::
          {:ok, AppendOperation.t()} | {:error, :invalid_append_operation}
  def validate_operation(%AppendOperation{} = operation) do
    operation
    |> Map.from_struct()
    |> AppendOperation.new()
  end

  def validate_operation(_operation), do: {:error, :invalid_append_operation}

  @doc false
  @spec normalize_opts(term()) :: {:ok, keyword()} | {:error, :invalid_precondition}
  def normalize_opts(opts), do: bounded_opts(opts, 0, [])

  @doc false
  @spec validate_projection_stream_request(stream_id(), term()) ::
          {:ok, keyword()} | {:error, :invalid_stream_id | :invalid_precondition}
  def validate_projection_stream_request(stream_id, opts) do
    with :ok <- validate_stream_id(stream_id),
         {:ok, normalized_opts} <- normalize_opts(opts),
         keys = Keyword.keys(normalized_opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 == :name)) do
      {:ok, normalized_opts}
    else
      false -> {:error, :invalid_precondition}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec prepare_projection_eviction(stream_id(), term()) ::
          {:ok, keyword(), integer()}
          | {:error, :invalid_stream_id | :invalid_precondition}
  def prepare_projection_eviction(stream_id, opts) do
    started_mono = System.monotonic_time(:millisecond)

    with :ok <- validate_stream_id(stream_id),
         {:ok, normalized_opts} <- normalize_opts(opts),
         keys = Keyword.keys(normalized_opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 == :timeout_ms)),
         {:ok, timeout_ms} <-
           bounded_timeout(Keyword.get(normalized_opts, :timeout_ms, @default_append_timeout_ms)) do
      {:ok, [], started_mono + timeout_ms}
    else
      false -> {:error, :invalid_precondition}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate_stream_range(stream_id(), term()) ::
          {:ok,
           %{
             direction: :forward | :backward,
             from: non_neg_integer(),
             limit: pos_integer(),
             to: non_neg_integer()
           }}
          | {:error, :invalid_precondition}
  def validate_stream_range(stream_id, opts) do
    with :ok <- validate_stream_id(stream_id),
         {:ok, opts} <- normalize_opts(opts),
         from when is_integer(from) and from >= 0 <- Keyword.get(opts, :from, 0),
         to when is_integer(to) and to >= from <- Keyword.get(opts, :to),
         limit when is_integer(limit) and limit > 0 and limit <= 1_000 <-
           Keyword.get(opts, :limit),
         direction when direction in [:forward, :backward] <-
           Keyword.get(opts, :direction, :forward) do
      {:ok, %{from: from, to: to, limit: limit, direction: direction}}
    else
      _invalid -> {:error, :invalid_precondition}
    end
  end

  @doc false
  @spec validate_identity_read(stream_id(), term(), term()) ::
          {:ok, non_neg_integer() | nil} | {:error, :invalid_precondition}
  def validate_identity_read(stream_id, event_id, opts \\ []) do
    with :ok <- validate_stream_id(stream_id),
         true <-
           is_binary(event_id) and byte_size(event_id) > 0 and
             byte_size(event_id) <= @max_string_bytes and String.valid?(event_id),
         {:ok, opts} <- normalize_opts(opts),
         max_event_number <- Keyword.get(opts, :max_event_number),
         true <-
           is_nil(max_event_number) or
             (is_integer(max_event_number) and max_event_number >= 0 and
                max_event_number <= @max_stream_position) do
      {:ok, max_event_number}
    else
      _invalid -> {:error, :invalid_precondition}
    end
  end

  @doc false
  @spec build_operation(stream_id(), term()) ::
          {:ok, AppendOperation.t()} | {:error, :invalid_append_operation}
  def build_operation(stream_id, events) do
    with :ok <- validate_stream_id(stream_id),
         {:ok, events} <- event_list(events),
         :ok <- validate_event_list(events, false, true),
         {:ok, events} <- canonicalize_events(events) do
      build_validated_operation(stream_id, events)
    else
      _invalid -> {:error, :invalid_append_operation}
    end
  end

  @doc false
  @spec event_fingerprint(stream_id(), term()) :: String.t() | nil
  def event_fingerprint(stream_id, event) do
    with :ok <- validate_stream_id(stream_id),
         %Event{} = event <- event,
         :ok <-
           validate_event_list(
             [event],
             false,
             true,
             @max_identity_event_bytes,
             @max_identity_event_bytes
           ) do
      do_event_fingerprint(stream_id, event)
    else
      _invalid -> nil
    end
  end

  @doc false
  @spec event_fingerprint_matches?(stream_id(), term(), term()) :: boolean()
  def event_fingerprint_matches?(stream_id, %Event{} = event, expected)
      when is_binary(expected) do
    case event_fingerprint(stream_id, event) do
      ^expected ->
        true

      _canonical_mismatch ->
        Enum.any?(legacy_timestamp_precisions(event.timestamp), fn timestamp ->
          legacy_event_fingerprint(stream_id, %Event{event | timestamp: timestamp}) == expected
        end)
    end
  end

  def event_fingerprint_matches?(_stream_id, _event, _expected), do: false

  @doc false
  @spec reconcile_events(term(), term()) :: append_reconciliation()
  def reconcile_events(operation, events) do
    with {:ok, operation} <- validate_operation(operation),
         {:ok, events} <- event_list(events),
         :ok <- validate_event_list(events, true, false),
         {:ok, events} <- canonicalize_events(events) do
      do_reconcile_events(operation, events)
    else
      {:error, :invalid_append_operation} = error -> error
      _invalid -> {:error, :invalid_reconciliation}
    end
  end

  @doc false
  @spec indeterminate(term()) ::
          {:error, {:append_indeterminate, AppendOperation.t()}}
          | {:error, :invalid_append_operation}
  def indeterminate(operation) do
    with {:ok, operation} <- validate_operation(operation) do
      {:error, {:append_indeterminate, operation}}
    end
  end

  @doc false
  @spec purge_indeterminate(term()) ::
          {:error, {:purge_indeterminate, stream_id()}}
          | {:error, :invalid_stream_id}
  def purge_indeterminate(stream_id) do
    with :ok <- validate_stream_id(stream_id) do
      {:error, {:purge_indeterminate, stream_id}}
    end
  end

  @doc false
  @spec absence_indeterminate(term()) ::
          {:error, {:absence_indeterminate, stream_id()}}
          | {:error, :invalid_stream_id}
  def absence_indeterminate(stream_id) do
    with :ok <- validate_stream_id(stream_id) do
      {:error, {:absence_indeterminate, stream_id}}
    end
  end

  @doc false
  @spec remaining_timeout(integer()) :: {:ok, pos_integer()} | {:error, :operation_timeout}
  def remaining_timeout(deadline_mono) when is_integer(deadline_mono) do
    remaining_ms = deadline_mono - System.monotonic_time(:millisecond)

    if remaining_ms > 0,
      do: {:ok, remaining_ms},
      else: {:error, :operation_timeout}
  end

  def remaining_timeout(_deadline), do: {:error, :operation_timeout}

  @doc false
  @spec stamp_completion(term()) :: {:event_log_completion, integer(), term()}
  def stamp_completion(result) do
    {:event_log_completion, System.monotonic_time(:millisecond), result}
  end

  @doc false
  @spec accept_completion(term(), AppendOperation.t(), integer()) :: append_result()
  def accept_completion(
        {:event_log_completion, completed_mono, result},
        operation,
        deadline_mono
      ) do
    accept_completion(result, operation, deadline_mono, completed_mono)
  end

  def accept_completion(_invalid_reply, operation, _deadline_mono),
    do: indeterminate(operation)

  @doc false
  @spec accept_completion(term(), AppendOperation.t(), integer(), integer()) :: append_result()
  def accept_completion(
        {:error, {:append_indeterminate, %AppendOperation{}}} = result,
        _operation,
        _deadline_mono,
        _completed_mono
      ),
      do: result

  def accept_completion(result, operation, deadline_mono, completed_mono)
      when is_integer(deadline_mono) and is_integer(completed_mono) do
    received_mono = System.monotonic_time(:millisecond)

    if completed_mono < deadline_mono and received_mono < deadline_mono,
      do: result,
      else: indeterminate(operation)
  end

  def accept_completion(_result, operation, _deadline_mono, _completed_mono),
    do: indeterminate(operation)

  @doc false
  @spec accept_purge_completion(term(), stream_id(), integer()) :: purge_result()
  def accept_purge_completion(
        {:event_log_completion, completed_mono, result},
        stream_id,
        deadline_mono
      ) do
    accept_purge_completion(result, stream_id, deadline_mono, completed_mono)
  end

  def accept_purge_completion(_invalid_reply, stream_id, _deadline_mono),
    do: purge_indeterminate(stream_id)

  @doc false
  @spec accept_purge_completion(term(), stream_id(), integer(), integer()) :: purge_result()
  def accept_purge_completion(
        {:error, {:purge_indeterminate, stream_id}} = result,
        stream_id,
        _deadline_mono,
        _completed_mono
      ),
      do: result

  def accept_purge_completion(result, stream_id, deadline_mono, completed_mono)
      when is_integer(deadline_mono) and is_integer(completed_mono) do
    received_mono = System.monotonic_time(:millisecond)

    if completed_mono < deadline_mono and received_mono < deadline_mono and
         valid_purge_result?(result),
       do: result,
       else: purge_indeterminate(stream_id)
  end

  def accept_purge_completion(_result, stream_id, _deadline_mono, _completed_mono),
    do: purge_indeterminate(stream_id)

  @doc false
  @spec accept_absence_completion(term(), stream_id(), integer()) :: absence_result()
  def accept_absence_completion(
        {:event_log_completion, completed_mono, result},
        stream_id,
        deadline_mono
      ) do
    accept_absence_completion(result, stream_id, deadline_mono, completed_mono)
  end

  def accept_absence_completion(_invalid_reply, stream_id, _deadline_mono),
    do: absence_indeterminate(stream_id)

  @doc false
  @spec accept_absence_completion(term(), stream_id(), integer(), integer()) :: absence_result()
  def accept_absence_completion(
        {:error, {:absence_indeterminate, stream_id}} = result,
        stream_id,
        _deadline_mono,
        _completed_mono
      ),
      do: result

  def accept_absence_completion(result, stream_id, deadline_mono, completed_mono)
      when is_integer(deadline_mono) and is_integer(completed_mono) do
    received_mono = System.monotonic_time(:millisecond)

    if completed_mono < deadline_mono and received_mono < deadline_mono and
         valid_absence_result?(result),
       do: result,
       else: absence_indeterminate(stream_id)
  end

  def accept_absence_completion(_result, stream_id, _deadline_mono, _completed_mono),
    do: absence_indeterminate(stream_id)

  @doc false
  @spec operation_deadline(term()) :: {:ok, integer()} | {:error, :invalid_precondition}
  def operation_deadline(opts) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, timeout_ms} <- append_timeout(normalized_opts) do
      {:ok, started_mono + timeout_ms}
    end
  end

  @doc false
  @spec purge_deadline(term()) :: {:ok, integer()} | {:error, :invalid_precondition}
  def purge_deadline(opts) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, timeout_ms} <- operation_timeout(:purge, normalized_opts) do
      {:ok, started_mono + timeout_ms}
    end
  end

  @doc false
  @spec absence_deadline(term()) :: {:ok, integer()} | {:error, :invalid_precondition}
  def absence_deadline(opts) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, timeout_ms} <- operation_timeout(:absence, normalized_opts) do
      {:ok, started_mono + timeout_ms}
    end
  end

  defp build_validated_operation(stream_id, events) do
    event_ids = Enum.map(events, & &1.id)

    fingerprints =
      Map.new(events, fn event -> {event.id, do_event_fingerprint(stream_id, event)} end)

    operation_id =
      {stream_id, Enum.map(event_ids, &{&1, Map.fetch!(fingerprints, &1)})}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> then(&("append_" <> &1))

    AppendOperation.new(
      operation_id: operation_id,
      stream_id: stream_id,
      event_ids: event_ids,
      fingerprints: fingerprints
    )
  end

  defp do_event_fingerprint(stream_id, %Event{} = event) do
    event_fingerprint_with_timestamp(stream_id, event, canonical_timestamp(event.timestamp))
  end

  defp legacy_event_fingerprint(stream_id, %Event{} = event) do
    event_fingerprint_with_timestamp(stream_id, event, event.timestamp)
  end

  defp event_fingerprint_with_timestamp(stream_id, %Event{} = event, timestamp) do
    {:ok, canonical_data} = canonical_json(event.data)
    {:ok, canonical_metadata} = canonical_json(event.metadata)

    payload =
      {1, stream_id, event.id, event.type, canonical_data, canonical_metadata, event.agent_id,
       event.causation_id, event.correlation_id, DateTime.to_iso8601(timestamp)}

    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp do_reconcile_events(operation, events) do
    events_by_id = Map.new(events, &{&1.id, &1})
    found_ids = Map.keys(events_by_id)

    cond do
      events == [] ->
        {:ok, :absent}

      length(found_ids) != length(events) ->
        {:error, :event_identity_conflict}

      Enum.any?(events, &event_conflicts?(operation, &1)) ->
        {:error, :event_identity_conflict}

      Enum.all?(operation.event_ids, &Map.has_key?(events_by_id, &1)) ->
        {:ok, {:committed, Enum.map(operation.event_ids, &Map.fetch!(events_by_id, &1))}}

      true ->
        {:error, {:append_indeterminate, operation}}
    end
  end

  @doc false
  @spec ensure_position_capacity(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          :ok | {:error, :stream_position_exhausted | :global_position_exhausted}
  def ensure_position_capacity(stream_position, global_position, count)
      when is_integer(stream_position) and stream_position >= 0 and is_integer(global_position) and
             global_position >= 0 and is_integer(count) and count > 0 do
    cond do
      stream_position > @max_stream_position - count -> {:error, :stream_position_exhausted}
      global_position > @max_global_position - count -> {:error, :global_position_exhausted}
      true -> :ok
    end
  end

  @doc false
  @spec admission_byte_limits() :: %{event: pos_integer(), batch: pos_integer()}
  def admission_byte_limits, do: %{event: @max_event_bytes, batch: @max_append_bytes}

  @doc false
  @spec validate_admission_byte_bounds(term()) ::
          :ok | {:error, :event_too_large | :append_batch_too_large | :invalid_events}
  def validate_admission_byte_bounds(events) do
    %{event: max_event_bytes, batch: max_batch_bytes} = admission_byte_limits()
    validate_admission_byte_bounds(events, 0, max_event_bytes, max_batch_bytes)
  end

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
    with {:ok, events, _normalized_opts, preconditions} <-
           validate_append_input(stream_id, events, opts) do
      {:ok, events, preconditions}
    end
  end

  @doc false
  @spec validate_head_read(stream_id(), opts()) ::
          {:ok, non_neg_integer() | nil}
          | {:error, :invalid_stream_id | :invalid_precondition}
  def validate_head_read(stream_id, opts) do
    with :ok <- validate_stream_id(stream_id),
         {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, preconditions} <- validate_preconditions(normalized_opts) do
      {:ok, preconditions.max_current_age_ms}
    end
  end

  defp validate_append_input(stream_id, events, opts) do
    with :ok <- validate_stream_id(stream_id),
         {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, events} <- append_event_list(events),
         :ok <- validate_event_list(events, false, true),
         {:ok, events} <- canonicalize_events(events),
         {:ok, preconditions} <- validate_preconditions(normalized_opts) do
      {:ok, events, normalized_opts, preconditions}
    end
  end

  defp validate_stream_id(stream_id)
       when is_binary(stream_id) and byte_size(stream_id) > 0 and
              byte_size(stream_id) <= @max_string_bytes do
    if String.valid?(stream_id), do: :ok, else: {:error, :invalid_stream_id}
  end

  defp validate_stream_id(_stream_id), do: {:error, :invalid_stream_id}

  defp bounded_opts([], _count, acc), do: {:ok, Enum.reverse(acc)}
  defp bounded_opts(_remaining, @max_options, _acc), do: {:error, :invalid_precondition}

  defp bounded_opts([{key, _value} = option | rest], count, acc) when is_atom(key) do
    bounded_opts(rest, count + 1, [option | acc])
  end

  defp bounded_opts(_improper_or_invalid, _count, _acc),
    do: {:error, :invalid_precondition}

  defp append_event_list(%Event{} = event), do: {:ok, [event]}
  defp append_event_list(events), do: event_list(events)

  defp event_list([]), do: {:ok, []}
  defp event_list([_head | _tail] = events), do: {:ok, events}
  defp event_list(_invalid), do: {:error, :invalid_events}

  defp validate_event_list(events, allow_empty?, enforce_unique?) do
    %{event: max_event_bytes, batch: max_batch_bytes} = admission_byte_limits()

    validate_event_list(
      events,
      allow_empty?,
      enforce_unique?,
      max_event_bytes,
      max_batch_bytes
    )
  end

  defp validate_event_list(
         events,
         allow_empty?,
         enforce_unique?,
         max_event_bytes,
         max_total_bytes
       ) do
    do_validate_event_list(
      events,
      0,
      0,
      MapSet.new(),
      allow_empty?,
      enforce_unique?,
      max_event_bytes,
      max_total_bytes
    )
  end

  defp do_validate_event_list(
         [],
         0,
         _total,
         _seen,
         false,
         _unique,
         _max_event_bytes,
         _max_total_bytes
       ),
       do: {:error, :invalid_events}

  defp do_validate_event_list(
         [],
         _count,
         _total,
         _seen,
         _allow_empty,
         _unique,
         _max_event_bytes,
         _max_total_bytes
       ),
       do: :ok

  defp do_validate_event_list(
         _remaining,
         @max_append_events,
         _total,
         _seen,
         _allow_empty,
         _unique,
         _max_event_bytes,
         _max_total_bytes
       ),
       do: {:error, :too_many_events}

  defp do_validate_event_list(
         [%Event{} = event | rest],
         count,
         total_bytes,
         seen,
         allow_empty?,
         enforce_unique?,
         max_event_bytes,
         max_total_bytes
       ) do
    event_bytes = safe_external_size(event)

    cond do
      not is_integer(event_bytes) ->
        {:error, :invalid_events}

      event_bytes > max_event_bytes ->
        {:error, :event_too_large}

      total_bytes + event_bytes > max_total_bytes ->
        {:error, :event_too_large}

      not valid_event_shape?(event) ->
        {:error, :invalid_events}

      enforce_unique? and MapSet.member?(seen, event.id) ->
        {:error, :invalid_events}

      true ->
        do_validate_event_list(
          rest,
          count + 1,
          total_bytes + event_bytes,
          MapSet.put(seen, event.id),
          allow_empty?,
          enforce_unique?,
          max_event_bytes,
          max_total_bytes
        )
    end
  end

  defp do_validate_event_list(
         _improper_or_invalid,
         _count,
         _total,
         _seen,
         _allow_empty,
         _unique,
         _max_event_bytes,
         _max_total_bytes
       ),
       do: {:error, :invalid_events}

  defp validate_admission_byte_bounds([], _total_bytes, _max_event_bytes, _max_batch_bytes),
    do: :ok

  defp validate_admission_byte_bounds(
         [event | rest],
         total_bytes,
         max_event_bytes,
         max_batch_bytes
       ) do
    event_bytes = safe_external_size(event)

    cond do
      not is_integer(event_bytes) ->
        {:error, :invalid_events}

      event_bytes > max_event_bytes ->
        {:error, :event_too_large}

      total_bytes + event_bytes > max_batch_bytes ->
        {:error, :append_batch_too_large}

      true ->
        validate_admission_byte_bounds(
          rest,
          total_bytes + event_bytes,
          max_event_bytes,
          max_batch_bytes
        )
    end
  end

  defp validate_admission_byte_bounds(
         _improper_or_invalid,
         _total_bytes,
         _max_event_bytes,
         _max_batch_bytes
       ),
       do: {:error, :invalid_events}

  defp valid_event_shape?(event) do
    bounded_binary?(event.id) and bounded_binary?(event.type) and json_object?(event.data) and
      json_object?(event.metadata) and bounded_optional_binary?(event.agent_id) and
      bounded_optional_binary?(event.causation_id) and
      bounded_optional_binary?(event.correlation_id) and valid_timestamp?(event.timestamp)
  end

  defp bounded_binary?(value) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_string_bytes and
      String.valid?(value)
  end

  defp bounded_optional_binary?(nil), do: true
  defp bounded_optional_binary?(value), do: bounded_binary?(value)

  defp valid_timestamp?(
         %DateTime{utc_offset: 0, std_offset: 0, calendar: Calendar.ISO} = timestamp
       ) do
    timestamp
    |> DateTime.to_iso8601()
    |> is_binary()
  rescue
    _invalid -> false
  end

  defp valid_timestamp?(_timestamp), do: false

  defp safe_external_size(term) do
    :erlang.external_size(term)
  rescue
    _invalid -> :error
  catch
    _kind, _reason -> :error
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

  defp validate_purge_opts(opts) do
    allowed = [:name, :repo, :purge_timeout_ms, :operation_timeout_ms, :call_timeout_ms]
    keys = Keyword.keys(opts)

    if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_precondition}
  end

  defp validate_absence_opts(opts) do
    allowed = [:name, :repo, :absence_timeout_ms, :operation_timeout_ms, :call_timeout_ms]
    keys = Keyword.keys(opts)

    if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in allowed)),
      do: :ok,
      else: {:error, :invalid_precondition}
  end

  defp valid_purge_result?(:ok), do: true

  defp valid_purge_result?({:error, reason})
       when reason in [
              :backend_unavailable,
              :invalid_precondition,
              :purge_not_supported,
              :purge_verification_failed
            ],
       do: true

  defp valid_purge_result?(_result), do: false

  defp valid_absence_result?({:ok, true}), do: true
  defp valid_absence_result?({:ok, false}), do: true

  defp valid_absence_result?({:error, reason})
       when reason in [
              :backend_unavailable,
              :invalid_precondition,
              :invalid_stream_id,
              :absence_not_supported,
              :absence_verification_failed
            ],
       do: true

  defp valid_absence_result?(_result), do: false

  defp operation_timeout(:append, opts), do: append_timeout(opts)

  defp operation_timeout(:purge, opts) do
    timeout =
      Keyword.get_lazy(opts, :purge_timeout_ms, fn ->
        Keyword.get_lazy(opts, :operation_timeout_ms, fn ->
          Keyword.get(opts, :call_timeout_ms, @default_append_timeout_ms)
        end)
      end)

    bounded_timeout(timeout)
  end

  defp operation_timeout(:absence, opts) do
    timeout =
      Keyword.get_lazy(opts, :absence_timeout_ms, fn ->
        Keyword.get_lazy(opts, :operation_timeout_ms, fn ->
          Keyword.get(opts, :call_timeout_ms, @default_append_timeout_ms)
        end)
      end)

    bounded_timeout(timeout)
  end

  defp append_timeout(opts) do
    timeout =
      Keyword.get_lazy(opts, :append_timeout_ms, fn ->
        Keyword.get_lazy(opts, :call_timeout_ms, fn ->
          Keyword.get(opts, :sqlite_busy_deadline_ms, @default_append_timeout_ms)
        end)
      end)

    bounded_timeout(timeout)
  end

  defp bounded_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_append_timeout_ms,
       do: {:ok, timeout}

  defp bounded_timeout(_timeout), do: {:error, :invalid_precondition}

  defp event_conflicts?(operation, %Event{} = event) do
    expected = Map.get(operation.fingerprints, event.id)

    is_nil(expected) or event.stream_id != operation.stream_id or
      not event_fingerprint_matches?(operation.stream_id, event, expected)
  end

  defp json_object?(value) when is_map(value) do
    case canonical_json(value) do
      {:ok, decoded} -> is_map(decoded)
      :error -> false
    end
  end

  defp json_object?(_value), do: false

  defp canonical_json(value) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, decoded} <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      _not_json -> :error
    end
  rescue
    _invalid -> :error
  catch
    _kind, _reason -> :error
  end

  defp canonicalize_events(events) do
    Enum.reduce_while(events, {:ok, []}, fn %Event{} = event, {:ok, acc} ->
      with {:ok, data} <- canonical_json(event.data),
           true <- is_map(data),
           {:ok, metadata} <- canonical_json(event.metadata),
           true <- is_map(metadata) do
        canonical = %Event{
          event
          | data: data,
            metadata: metadata,
            timestamp: canonical_timestamp(event.timestamp)
        }

        {:cont, {:ok, [canonical | acc]}}
      else
        _invalid -> {:halt, {:error, :invalid_events}}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, Enum.reverse(canonical)}
      {:error, _reason} = error -> error
    end
  end

  defp canonical_timestamp(%DateTime{microsecond: {microsecond, _precision}} = timestamp),
    do: %DateTime{timestamp | microsecond: {microsecond, 6}}

  defp legacy_timestamp_precisions(%DateTime{microsecond: {microsecond, _precision}} = timestamp) do
    0..5
    |> Enum.filter(fn precision ->
      divisor = Integer.pow(10, 6 - precision)
      rem(microsecond, divisor) == 0
    end)
    |> Enum.map(fn precision -> %DateTime{timestamp | microsecond: {microsecond, precision}} end)
  end

  defp legacy_timestamp_precisions(_timestamp), do: []

  defp active_deadline do
    case Process.get(@deadline_context_key) do
      %{owner: owner, token: token, deadline_mono: deadline_mono}
      when owner == self() and is_reference(token) and is_integer(deadline_mono) ->
        {:ok, deadline_mono}

      _missing_or_invalid ->
        :none
    end
  end

  defp require_active_deadline do
    case active_deadline() do
      {:ok, deadline_mono} -> {:ok, deadline_mono}
      :none -> {:error, :invalid_precondition}
    end
  end

  defp restore_deadline_context(nil), do: Process.delete(@deadline_context_key)
  defp restore_deadline_context(previous), do: Process.put(@deadline_context_key, previous)
end
