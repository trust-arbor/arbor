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
    reconcile_append: 2,
    subscribe: 3,
    list_streams: 1,
    stream_count: 1,
    event_count: 1,
    read_agent_events: 2
  ]

  @doc false
  @spec with_operation_deadline(term(), (keyword(), integer() -> result)) ::
          result | {:error, :invalid_precondition}
        when result: term()
  def with_operation_deadline(opts, fun) when is_function(fun, 2) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, timeout_ms} <- append_timeout(normalized_opts) do
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

  def with_operation_deadline(_opts, _fun), do: {:error, :invalid_precondition}

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
  @spec operation_deadline(term()) :: {:ok, integer()} | {:error, :invalid_precondition}
  def operation_deadline(opts) do
    started_mono = System.monotonic_time(:millisecond)

    with {:ok, normalized_opts} <- normalize_opts(opts),
         {:ok, timeout_ms} <- append_timeout(normalized_opts) do
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
    validate_event_list(
      events,
      allow_empty?,
      enforce_unique?,
      @max_event_bytes,
      @max_append_bytes
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

  defp append_timeout(opts) do
    timeout =
      Keyword.get_lazy(opts, :append_timeout_ms, fn ->
        Keyword.get_lazy(opts, :call_timeout_ms, fn ->
          Keyword.get(opts, :sqlite_busy_deadline_ms, @default_append_timeout_ms)
        end)
      end)

    if is_integer(timeout) and timeout > 0 and timeout <= @max_append_timeout_ms,
      do: {:ok, timeout},
      else: {:error, :invalid_precondition}
  end

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
