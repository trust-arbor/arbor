defmodule Arbor.Persistence.EventLog.ProjectionCore do
  @moduledoc """
  Pure decision core for non-authoritative EventLog projection.

  A projection admits events that some other component already committed
  durably. It never assigns a stream or global position: every position in the
  batch is exact and caller-supplied, and every event carries the canonical
  `operation_fingerprint` that the durable writer persisted.

  The core owns the whole decision and returns **effects as data**. It performs
  no ETS access, no process calls, and no IO; the `Arbor.Persistence.EventLog.ETS`
  shell reads the resident rows, hands them here as a plain map, and applies the
  returned rows.

  ## Two-phase shape

  1. `prepare/1` canonicalizes and validates the complete batch in isolation
     (shape, bounds, positions, fingerprints, intra-batch uniqueness).
  2. The shell resolves the resident rows named by `lookup_keys/1`.
  3. `plan/4` classifies each entry against those five resident surfaces and
     returns the rows to insert, or the first conflict.

  Nothing is mutated until `plan/4` succeeds for the complete batch, which is
  what makes a projection batch atomic.
  """

  alias Arbor.Persistence.{Event, EventLog}

  @max_projection_events 1_000
  @max_position 2_147_483_647

  @typedoc "Immutable identity tuple stored in the projection's identity ledger."
  @type identity :: {String.t(), String.t(), pos_integer(), pos_integer()}

  @typedoc "One validated, canonicalized, exactly-positioned projection candidate."
  @type entry :: %{
          event: Event.t(),
          event_id: String.t(),
          stream_id: String.t(),
          event_number: pos_integer(),
          global_position: pos_integer(),
          fingerprint: String.t(),
          identity: identity(),
          stream_position: {String.t(), pos_integer()}
        }

  @typedoc "Resident rows for the exact keys named by `lookup_keys/1`."
  @type resident :: %{
          identities: %{optional(String.t()) => term()},
          identity_positions: %{optional(pos_integer()) => term()},
          identity_stream_positions: %{optional({String.t(), pos_integer()}) => term()},
          payloads: %{optional(pos_integer()) => term()},
          stream_pointers: %{optional({String.t(), pos_integer()}) => term()}
        }

  @typedoc "Rows to insert plus the derived resident-only metadata deltas."
  @type plan :: %{
          global_rows: [{pos_integer(), Event.t()}],
          stream_rows: [{{String.t(), pos_integer()}, pos_integer()}],
          identity_rows: [{String.t(), identity()}],
          identity_position_rows: [{pos_integer(), String.t()}],
          identity_stream_position_rows: [{{String.t(), pos_integer()}, String.t()}],
          stream_versions: %{optional(String.t()) => pos_integer()},
          max_global_position: non_neg_integer(),
          projected: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @typedoc "Closed conflict vocabulary, one atom per resident identity surface."
  @type conflict :: :event_id_conflict | :global_position_conflict | :stream_position_conflict

  @typedoc "Closed failure vocabulary for the projection core."
  @type error ::
          :invalid_projection_events
          | :projection_batch_bytes_exceeded
          | :projection_batch_too_large
          | :projection_capacity_exceeded
          | :projection_event_too_large
          | :projection_fingerprint_invalid
          | :projection_fingerprint_missing
          | :projection_fingerprint_mismatch
          | conflict()

  @doc "Maximum number of events admitted in one projection batch."
  @spec max_batch_events() :: pos_integer()
  def max_batch_events, do: @max_projection_events

  @doc """
  Canonicalize and validate a complete projection batch.

  Every event must be a `%Arbor.Persistence.Event{}` carrying a positive bounded
  `event_number` and `global_position`, a valid stream identity, JSON-object
  `data`/`metadata`, a valid UTC timestamp, and an `operation_fingerprint` equal
  to the canonical persisted fingerprint for its content. Event IDs, global
  positions, and stream positions must each be unique within the batch.
  """
  @spec prepare(term()) :: {:ok, [entry()]} | {:error, error()}
  def prepare(events) when is_list(events) do
    with :ok <- bounded_batch(events, 0),
         :ok <- bounded_bytes(events),
         {:ok, entries} <- build_entries(events) do
      dedupe(entries)
    end
  end

  def prepare(_events), do: {:error, :invalid_projection_events}

  @doc """
  Return the exact resident keys the shell must read for `plan/4`.

  Keys are grouped per ETS surface so the shell never scans a table.
  """
  @spec lookup_keys([entry()]) :: %{
          event_ids: [String.t()],
          global_positions: [pos_integer()],
          stream_positions: [{String.t(), pos_integer()}]
        }
  def lookup_keys(entries) when is_list(entries) do
    %{
      event_ids: Enum.map(entries, & &1.event_id),
      global_positions: Enum.map(entries, & &1.global_position),
      stream_positions: Enum.map(entries, & &1.stream_position)
    }
  end

  @doc """
  Classify a prepared batch against the resident rows and return rows to insert.

  A candidate whose five resident surfaces already hold byte-identical rows is
  counted as skipped and contributes nothing to mutate. A candidate whose rows
  are partly or wholly absent (for example after retention evicted them) is
  re-projected. Any disagreement on a resident surface fails the whole batch
  with the conflict atom for that surface.

  `retained_rows` is the current resident payload-row count and `max_events` the
  configured ceiling; exceeding it fails with `:projection_capacity_exceeded`.
  """
  @spec plan([entry()], resident(), non_neg_integer(), non_neg_integer()) ::
          {:ok, plan()} | {:error, error()}
  def plan(entries, resident, retained_rows, max_events)
      when is_list(entries) and is_map(resident) and is_integer(retained_rows) and
             retained_rows >= 0 and is_integer(max_events) and max_events >= 0 do
    entries
    |> Enum.reduce_while({:ok, empty_plan(), 0}, fn entry, {:ok, acc, new_payloads} ->
      case classify(entry, resident) do
        :skip ->
          {:cont, {:ok, observe(%{acc | skipped: acc.skipped + 1}, entry), new_payloads}}

        :insert ->
          {:cont,
           {:ok, insert_rows(acc, entry), new_payloads + new_payload_count(entry, resident)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc, new_payloads} -> finalize(acc, new_payloads, retained_rows, max_events)
      {:error, _reason} = error -> error
    end
  end

  def plan(_entries, _resident, _retained_rows, _max_events),
    do: {:error, :invalid_projection_events}

  # --- batch validation ---

  defp bounded_batch([], 0), do: {:error, :invalid_projection_events}
  defp bounded_batch([], _count), do: :ok

  defp bounded_batch(_remaining, @max_projection_events),
    do: {:error, :projection_batch_too_large}

  defp bounded_batch([_event | rest], count), do: bounded_batch(rest, count + 1)
  defp bounded_batch(_improper, _count), do: {:error, :invalid_projection_events}

  defp bounded_bytes(events) do
    case EventLog.validate_admission_byte_bounds(events) do
      :ok -> :ok
      {:error, :event_too_large} -> {:error, :projection_event_too_large}
      {:error, :append_batch_too_large} -> {:error, :projection_batch_bytes_exceeded}
      {:error, :invalid_events} -> {:error, :invalid_projection_events}
    end
  end

  defp build_entries(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case entry(event) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp entry(%Event{} = event) do
    with :ok <- validate_positions(event),
         {:ok, canonical} <- canonicalize(event),
         {:ok, fingerprint} <- verify_fingerprint(canonical) do
      {:ok,
       %{
         event: canonical,
         event_id: canonical.id,
         stream_id: canonical.stream_id,
         event_number: canonical.event_number,
         global_position: canonical.global_position,
         fingerprint: fingerprint,
         identity:
           {fingerprint, canonical.stream_id, canonical.event_number, canonical.global_position},
         stream_position: {canonical.stream_id, canonical.event_number}
       }}
    end
  end

  defp entry(_event), do: {:error, :invalid_projection_events}

  defp validate_positions(%Event{event_number: number, global_position: position}) do
    if bounded_position?(number) and bounded_position?(position),
      do: :ok,
      else: {:error, :invalid_projection_events}
  end

  defp bounded_position?(value) do
    is_integer(value) and value > 0 and value <= @max_position
  end

  defp canonicalize(%Event{} = event) do
    with {:ok, data} <- canonical_json(event.data),
         true <- is_map(data),
         {:ok, metadata} <- canonical_json(event.metadata),
         true <- is_map(metadata) do
      {:ok,
       %Event{
         event
         | data: data,
           metadata: metadata,
           timestamp: canonical_timestamp(event.timestamp)
       }}
    else
      _invalid -> {:error, :invalid_projection_events}
    end
  end

  defp canonical_timestamp(%DateTime{microsecond: {microsecond, _precision}} = timestamp),
    do: %DateTime{timestamp | microsecond: {microsecond, 6}}

  defp canonical_timestamp(_timestamp), do: nil

  defp canonical_json(value) when is_map(value) do
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

  defp canonical_json(_value), do: :error

  defp verify_fingerprint(%Event{operation_fingerprint: persisted} = event) do
    cond do
      is_nil(persisted) ->
        {:error, :projection_fingerprint_missing}

      not valid_fingerprint?(persisted) ->
        {:error, :projection_fingerprint_invalid}

      true ->
        compare_fingerprint(EventLog.event_fingerprint(event.stream_id, event), persisted)
    end
  end

  defp compare_fingerprint(nil, _persisted), do: {:error, :invalid_projection_events}
  defp compare_fingerprint(persisted, persisted), do: {:ok, persisted}
  defp compare_fingerprint(_canonical, _persisted), do: {:error, :projection_fingerprint_mismatch}

  defp valid_fingerprint?(fingerprint) do
    is_binary(fingerprint) and byte_size(fingerprint) == 64 and String.valid?(fingerprint) and
      fingerprint =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp dedupe(entries) do
    entries
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new(), MapSet.new()}, fn entry,
                                                                             {:ok, ids, positions,
                                                                              stream_positions} ->
      cond do
        MapSet.member?(ids, entry.event_id) ->
          {:halt, {:error, :event_id_conflict}}

        MapSet.member?(positions, entry.global_position) ->
          {:halt, {:error, :global_position_conflict}}

        MapSet.member?(stream_positions, entry.stream_position) ->
          {:halt, {:error, :stream_position_conflict}}

        true ->
          {:cont,
           {:ok, MapSet.put(ids, entry.event_id), MapSet.put(positions, entry.global_position),
            MapSet.put(stream_positions, entry.stream_position)}}
      end
    end)
    |> case do
      {:ok, _ids, _positions, _stream_positions} -> {:ok, entries}
      {:error, _reason} = error -> error
    end
  end

  # --- resident classification ---

  defp classify(entry, resident) do
    surfaces = resident_surfaces(entry, resident)

    cond do
      conflict = first_conflict(entry, surfaces) -> {:error, conflict}
      fully_resident?(entry, surfaces) -> :skip
      true -> :insert
    end
  end

  defp resident_surfaces(entry, resident) do
    %{
      identity: fetch_resident(resident, :identities, entry.event_id),
      identity_position: fetch_resident(resident, :identity_positions, entry.global_position),
      identity_stream_position:
        fetch_resident(resident, :identity_stream_positions, entry.stream_position),
      payload: fetch_resident(resident, :payloads, entry.global_position),
      stream_pointer: fetch_resident(resident, :stream_pointers, entry.stream_position)
    }
  end

  # Only a key the shell proved missing is `:absent`. Every other value —
  # including the `:malformed` sentinel the shell emits for a row it could not
  # read as a well-formed pair — is compared for exact equality, so anything the
  # core does not recognize fails the batch closed instead of being overwritten.
  defp fetch_resident(resident, surface, key) do
    resident
    |> Map.get(surface, %{})
    |> Map.get(key, :absent)
  end

  defp first_conflict(entry, surfaces) do
    Enum.find_value(
      [
        {:event_id_conflict, surfaces.identity, entry.identity},
        {:global_position_conflict, surfaces.identity_position, entry.event_id},
        {:stream_position_conflict, surfaces.identity_stream_position, entry.event_id},
        {:stream_position_conflict, surfaces.stream_pointer, entry.global_position}
      ],
      fn {reason, resident_value, expected} ->
        if resident_value != :absent and resident_value != expected, do: reason
      end
    ) || payload_conflict(entry, surfaces.payload)
  end

  defp payload_conflict(_entry, :absent), do: nil

  defp payload_conflict(entry, %Event{} = payload) do
    cond do
      payload.id != entry.event_id -> :global_position_conflict
      payload != entry.event -> :event_id_conflict
      true -> nil
    end
  end

  defp payload_conflict(_entry, _malformed), do: :global_position_conflict

  defp fully_resident?(entry, surfaces) do
    surfaces.identity == entry.identity and surfaces.identity_position == entry.event_id and
      surfaces.identity_stream_position == entry.event_id and
      surfaces.stream_pointer == entry.global_position and surfaces.payload == entry.event
  end

  defp new_payload_count(entry, resident) do
    if fetch_resident(resident, :payloads, entry.global_position) == :absent, do: 1, else: 0
  end

  # --- plan accumulation ---

  defp empty_plan do
    %{
      global_rows: [],
      stream_rows: [],
      identity_rows: [],
      identity_position_rows: [],
      identity_stream_position_rows: [],
      stream_versions: %{},
      max_global_position: 0,
      projected: 0,
      skipped: 0
    }
  end

  defp insert_rows(plan, entry) do
    %{
      plan
      | global_rows: [{entry.global_position, entry.event} | plan.global_rows],
        stream_rows: [{entry.stream_position, entry.global_position} | plan.stream_rows],
        identity_rows: [{entry.event_id, entry.identity} | plan.identity_rows],
        identity_position_rows: [
          {entry.global_position, entry.event_id} | plan.identity_position_rows
        ],
        identity_stream_position_rows: [
          {entry.stream_position, entry.event_id} | plan.identity_stream_position_rows
        ],
        projected: plan.projected + 1
    }
    |> observe(entry)
  end

  defp observe(plan, entry) do
    %{
      plan
      | stream_versions:
          Map.update(
            plan.stream_versions,
            entry.stream_id,
            entry.event_number,
            &max(&1, entry.event_number)
          ),
        max_global_position: max(plan.max_global_position, entry.global_position)
    }
  end

  defp finalize(plan, new_payloads, retained_rows, max_events) do
    if retained_rows + new_payloads > max_events do
      {:error, :projection_capacity_exceeded}
    else
      {:ok,
       %{
         plan
         | global_rows: Enum.reverse(plan.global_rows),
           stream_rows: Enum.reverse(plan.stream_rows),
           identity_rows: Enum.reverse(plan.identity_rows),
           identity_position_rows: Enum.reverse(plan.identity_position_rows),
           identity_stream_position_rows: Enum.reverse(plan.identity_stream_position_rows)
       }}
    end
  end
end
