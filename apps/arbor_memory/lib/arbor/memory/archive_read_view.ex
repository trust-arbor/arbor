defmodule Arbor.Memory.ArchiveReadView.Cursor do
  @moduledoc false

  @enforce_keys [
    :version,
    :stream_id,
    :event_type,
    :direction,
    :target,
    :legacy_head,
    :durable_head,
    :epoch,
    :legacy_position,
    :durable_position
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            version: pos_integer(),
            stream_id: String.t(),
            event_type: atom() | nil,
            direction: :forward | :backward,
            target: map(),
            legacy_head: non_neg_integer(),
            durable_head: non_neg_integer(),
            epoch: :legacy | :durable | :done,
            legacy_position: non_neg_integer(),
            durable_position: non_neg_integer()
          }
end

defmodule Arbor.Memory.ArchiveReadView do
  @moduledoc false

  alias Arbor.Memory.ArchiveReadView.Cursor

  @default_limit 100
  @max_limit 1_000
  @cursor_version 1
  @read_keys [:cursor, :direction, :from, :limit]

  @enforce_keys [:limit, :direction, :cursor]
  defstruct [:limit, :direction, :cursor]

  @type t :: %__MODULE__{
          limit: pos_integer(),
          direction: :forward | :backward,
          cursor: Cursor.t() | nil
        }

  @type source :: :legacy | :durable

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec normalize_options(term()) :: {:ok, t()} | {:error, :invalid_archive_read_options}
  def normalize_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- closed_unique_options?(opts),
         :ok <- validate_legacy_from(Keyword.get(opts, :from, 0)),
         {:ok, cursor} <- normalize_cursor_option(Keyword.get(opts, :cursor)),
         {:ok, limit} <- normalize_limit(Keyword.get(opts, :limit, @default_limit)),
         {:ok, direction} <- normalize_direction(opts, cursor) do
      {:ok, %__MODULE__{limit: limit, direction: direction, cursor: cursor}}
    else
      _invalid -> {:error, :invalid_archive_read_options}
    end
  end

  def normalize_options(_opts), do: {:error, :invalid_archive_read_options}

  @spec new_cursor(String.t(), atom() | nil, :forward | :backward, map(), map()) :: Cursor.t()
  def new_cursor(stream_id, event_type, direction, target, heads) do
    epoch = if direction == :forward, do: :legacy, else: initial_backward_epoch(heads)

    %Cursor{
      version: @cursor_version,
      stream_id: stream_id,
      event_type: event_type,
      direction: direction,
      target: target,
      legacy_head: heads.legacy,
      durable_head: heads.durable,
      epoch: epoch,
      legacy_position: if(direction == :forward, do: 1, else: heads.legacy),
      durable_position: if(direction == :forward, do: 1, else: heads.durable)
    }
    |> normalize_epoch()
  end

  @spec validate_cursor(Cursor.t(), String.t(), atom() | nil, map()) ::
          {:ok, Cursor.t()} | {:error, :invalid_archive_cursor}
  def validate_cursor(
        %Cursor{
          version: @cursor_version,
          stream_id: stream_id,
          event_type: event_type,
          direction: direction,
          target: target,
          legacy_head: legacy_head,
          durable_head: durable_head,
          epoch: epoch,
          legacy_position: legacy_position,
          durable_position: durable_position
        } = cursor,
        stream_id,
        event_type,
        target
      )
      when direction in [:forward, :backward] and epoch in [:legacy, :durable, :done] and
             is_integer(legacy_head) and legacy_head >= 0 and is_integer(durable_head) and
             durable_head >= 0 and is_integer(legacy_position) and legacy_position >= 0 and
             is_integer(durable_position) and durable_position >= 0 do
    if valid_positions?(cursor),
      do: {:ok, normalize_epoch(cursor)},
      else: {:error, :invalid_archive_cursor}
  end

  def validate_cursor(_cursor, _stream_id, _event_type, _target),
    do: {:error, :invalid_archive_cursor}

  @spec source_range(Cursor.t(), pos_integer()) ::
          :done | {:ok, source(), keyword(), pos_integer()}
  def source_range(%Cursor{epoch: :done}, _limit), do: :done

  def source_range(%Cursor{} = cursor, limit) when is_integer(limit) and limit > 0 do
    cursor = normalize_epoch(cursor)

    case cursor.epoch do
      :done ->
        :done

      source ->
        position = position(cursor, source)
        head = head(cursor, source)

        opts =
          case cursor.direction do
            :forward ->
              [
                from: position,
                to: head,
                direction: :forward,
                limit: min(limit, head - position + 1)
              ]

            :backward ->
              [from: 1, to: position, direction: :backward, limit: min(limit, position)]
          end

        {:ok, source, opts, Keyword.fetch!(opts, :limit)}
    end
  end

  @spec advance(Cursor.t(), source(), [Arbor.Persistence.Event.t()]) :: Cursor.t()
  def advance(%Cursor{direction: :forward} = cursor, source, events) do
    next_position =
      case List.last(events) do
        nil -> head(cursor, source) + 1
        event -> event.event_number + 1
      end

    cursor
    |> put_position(source, next_position)
    |> normalize_epoch()
  end

  def advance(%Cursor{direction: :backward} = cursor, source, events) do
    next_position =
      case List.last(events) do
        nil -> 0
        event -> max(event.event_number - 1, 0)
      end

    cursor
    |> put_position(source, next_position)
    |> normalize_epoch()
  end

  @spec next_cursor(Cursor.t()) :: Cursor.t() | nil
  def next_cursor(%Cursor{} = cursor) do
    case normalize_epoch(cursor) do
      %Cursor{epoch: :done} -> nil
      cursor -> cursor
    end
  end

  @spec same_target?(map()) :: boolean()
  def same_target?(%{name: :memory_events, backend: Arbor.Persistence.EventLog.ETS}), do: true
  def same_target?(_target), do: false

  defp normalize_limit(limit) when is_integer(limit) and limit > 0,
    do: {:ok, min(limit, @max_limit)}

  defp normalize_limit(_limit), do: :error

  defp normalize_cursor_option(nil), do: {:ok, nil}
  defp normalize_cursor_option(%Cursor{} = cursor), do: {:ok, cursor}
  defp normalize_cursor_option(_cursor), do: :error

  defp normalize_direction(opts, nil) do
    case Keyword.get(opts, :direction, :forward) do
      direction when direction in [:forward, :backward] -> {:ok, direction}
      _invalid -> :error
    end
  end

  defp normalize_direction(opts, %Cursor{direction: cursor_direction}) do
    case Keyword.fetch(opts, :direction) do
      :error -> {:ok, cursor_direction}
      {:ok, ^cursor_direction} -> {:ok, cursor_direction}
      {:ok, _mismatch} -> :error
    end
  end

  defp validate_legacy_from(0), do: :ok
  defp validate_legacy_from(_from), do: :error

  defp closed_unique_options?(opts) do
    keys = Keyword.keys(opts)
    Enum.all?(keys, &(&1 in @read_keys)) and length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp valid_positions?(%Cursor{direction: :forward} = cursor) do
    cursor.legacy_position in 1..(cursor.legacy_head + 1) and
      cursor.durable_position in 1..(cursor.durable_head + 1)
  end

  defp valid_positions?(%Cursor{direction: :backward} = cursor) do
    cursor.legacy_position <= cursor.legacy_head and
      cursor.durable_position <= cursor.durable_head
  end

  defp initial_backward_epoch(%{durable: durable}) when durable > 0, do: :durable
  defp initial_backward_epoch(_heads), do: :legacy

  defp normalize_epoch(%Cursor{direction: :forward, epoch: :legacy} = cursor) do
    if cursor.legacy_position > cursor.legacy_head,
      do: normalize_epoch(%Cursor{cursor | epoch: :durable}),
      else: cursor
  end

  defp normalize_epoch(%Cursor{direction: :forward, epoch: :durable} = cursor) do
    if cursor.durable_position > cursor.durable_head,
      do: %Cursor{cursor | epoch: :done},
      else: cursor
  end

  defp normalize_epoch(%Cursor{direction: :backward, epoch: :durable} = cursor) do
    if cursor.durable_position == 0,
      do: normalize_epoch(%Cursor{cursor | epoch: :legacy}),
      else: cursor
  end

  defp normalize_epoch(%Cursor{direction: :backward, epoch: :legacy} = cursor) do
    if cursor.legacy_position == 0,
      do: %Cursor{cursor | epoch: :done},
      else: cursor
  end

  defp normalize_epoch(%Cursor{} = cursor), do: cursor

  defp head(cursor, :legacy), do: cursor.legacy_head
  defp head(cursor, :durable), do: cursor.durable_head
  defp position(cursor, :legacy), do: cursor.legacy_position
  defp position(cursor, :durable), do: cursor.durable_position

  defp put_position(%Cursor{} = cursor, :legacy, position),
    do: %Cursor{cursor | legacy_position: position}

  defp put_position(%Cursor{} = cursor, :durable, position),
    do: %Cursor{cursor | durable_position: position}
end
