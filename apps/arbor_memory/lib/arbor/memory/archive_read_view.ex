defmodule Arbor.Memory.ArchiveReadView do
  @moduledoc false

  alias Arbor.Persistence.Event

  @default_limit 100
  @max_limit 1_000
  @read_keys [:limit, :from, :direction]
  @immutable_event_fields [
    :id,
    :stream_id,
    :type,
    :data,
    :metadata,
    :agent_id,
    :causation_id,
    :correlation_id,
    :timestamp
  ]

  @enforce_keys [:limit, :from, :direction]
  defstruct [:limit, :from, :direction]

  @type t :: %__MODULE__{
          limit: non_neg_integer(),
          from: non_neg_integer(),
          direction: :forward | :backward
        }

  @spec normalize_options(term()) :: {:ok, t()} | {:error, :invalid_archive_read_options}
  def normalize_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- unique_read_keys?(opts),
         {:ok, limit} <- normalize_limit(Keyword.get(opts, :limit, @default_limit)),
         {:ok, from} <- normalize_from(Keyword.get(opts, :from, 0)),
         {:ok, direction} <- normalize_direction(Keyword.get(opts, :direction, :forward)) do
      {:ok, %__MODULE__{limit: limit, from: from, direction: direction}}
    else
      _invalid -> {:error, :invalid_archive_read_options}
    end
  end

  def normalize_options(_opts), do: {:error, :invalid_archive_read_options}

  @spec source_options(t()) :: keyword()
  def source_options(%__MODULE__{} = read) do
    [
      from: read.from,
      limit: read.limit,
      direction: read.direction,
      max_scan: read.limit
    ]
  end

  @spec expand_source_options(keyword()) :: {:ok, keyword()} | :source_limit_reached
  def expand_source_options(opts) do
    current_limit = Keyword.fetch!(opts, :limit)

    if current_limit >= @max_limit or current_limit == 0 do
      :source_limit_reached
    else
      next_limit = min(max(current_limit * 2, 1), @max_limit)

      {:ok,
       opts
       |> Keyword.put(:limit, next_limit)
       |> Keyword.put(:max_scan, next_limit)}
    end
  end

  @spec merge([Event.t()], [Event.t()], t(), atom() | nil) ::
          {:ok, [Event.t()]} | {:error, :archive_event_conflict | :archive_read_unavailable}
  def merge(legacy_events, durable_events, read, event_type \\ nil)

  def merge(legacy_events, durable_events, %__MODULE__{} = read, event_type)
      when is_list(legacy_events) and is_list(durable_events) do
    with :ok <- validate_event_type(event_type),
         {:ok, forward_events} <-
           merge_forward(
             to_forward(legacy_events, read.direction),
             to_forward(durable_events, read.direction)
           ) do
      forward_events
      |> maybe_filter_type(event_type)
      |> orient(read.direction)
      |> Enum.take(read.limit)
      |> then(&{:ok, &1})
    end
  end

  def merge(_legacy_events, _durable_events, %__MODULE__{}, _event_type),
    do: {:error, :archive_read_unavailable}

  defp normalize_limit(nil), do: {:ok, @default_limit}

  defp normalize_limit(limit) when is_integer(limit) and limit >= 0,
    do: {:ok, min(limit, @max_limit)}

  defp normalize_limit(_limit), do: :error

  defp normalize_from(from) when is_integer(from) and from >= 0, do: {:ok, from}
  defp normalize_from(_from), do: :error

  defp normalize_direction(direction) when direction in [:forward, :backward],
    do: {:ok, direction}

  defp normalize_direction(_direction), do: :error

  defp unique_read_keys?(opts) do
    keys = opts |> Keyword.keys() |> Enum.filter(&(&1 in @read_keys))
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp validate_event_type(nil), do: :ok
  defp validate_event_type(event_type) when is_atom(event_type), do: :ok
  defp validate_event_type(_event_type), do: {:error, :archive_read_unavailable}

  defp to_forward(events, :forward), do: events
  defp to_forward(events, :backward), do: Enum.reverse(events)

  defp orient(events, :forward), do: events
  defp orient(events, :backward), do: Enum.reverse(events)

  defp merge_forward(legacy_events, durable_events) do
    Enum.reduce_while(legacy_events ++ durable_events, {[], %{}}, fn
      %Event{id: event_id} = event, {events, identities}
      when is_binary(event_id) and event_id != "" ->
        identity = immutable_event_identity(event)

        case Map.fetch(identities, event_id) do
          :error ->
            {:cont, {[event | events], Map.put(identities, event_id, identity)}}

          {:ok, ^identity} ->
            {:cont, {events, identities}}

          {:ok, _conflicting_identity} ->
            {:halt, {:error, :archive_event_conflict}}
        end

      _invalid_event, _acc ->
        {:halt, {:error, :archive_read_unavailable}}
    end)
    |> case do
      {:error, _reason} = error -> error
      {events, _identities} -> {:ok, Enum.reverse(events)}
    end
  end

  defp immutable_event_identity(event), do: Map.take(event, @immutable_event_fields)

  defp maybe_filter_type(events, nil), do: events

  defp maybe_filter_type(events, event_type) do
    type = Atom.to_string(event_type)
    Enum.filter(events, &(&1.type == type))
  end
end
