defmodule Arbor.Memory.ArchiveReadView.Cursor do
  @moduledoc false

  @opaque t :: String.t()
end

defmodule Arbor.Memory.ArchiveReadView.State do
  @moduledoc false

  @enforce_keys [
    :version,
    :stream_id,
    :event_type,
    :direction,
    :legacy_head,
    :durable_head,
    :epoch,
    :legacy_position,
    :durable_position
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          version: pos_integer(),
          stream_id: String.t(),
          event_type: atom() | nil,
          direction: :forward | :backward,
          legacy_head: non_neg_integer(),
          durable_head: non_neg_integer(),
          epoch: :legacy | :durable | :done,
          legacy_position: non_neg_integer(),
          durable_position: non_neg_integer()
        }
end

defmodule Arbor.Memory.ArchiveReadView do
  @moduledoc false

  alias Arbor.Memory.ArchiveCursorSigner
  alias Arbor.Memory.ArchiveReadView.{Cursor, State}

  @default_limit 100
  @max_limit 1_000
  @max_cursor_bytes 4_096
  @cursor_version 1
  @read_keys [:cursor, :direction, :from, :limit]

  @enforce_keys [:limit, :direction, :cursor]
  defstruct [:limit, :direction, :cursor]

  @type t :: %__MODULE__{
          limit: non_neg_integer(),
          direction: :forward | :backward | nil,
          cursor: Cursor.t() | nil
        }

  @type source :: :legacy | :durable

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec normalize_options(term()) ::
          {:ok, t()}
          | {:error, :archive_scalar_cursor_unsupported | :invalid_archive_read_options}
  def normalize_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- closed_unique_options?(opts),
         :ok <- validate_legacy_from(Keyword.get(opts, :from, 0)),
         {:ok, cursor} <- normalize_cursor_option(Keyword.get(opts, :cursor)),
         {:ok, limit} <- normalize_limit(Keyword.get(opts, :limit, @default_limit)),
         {:ok, direction} <- normalize_direction(opts, cursor) do
      {:ok, %__MODULE__{limit: limit, direction: direction, cursor: cursor}}
    else
      {:error, :archive_scalar_cursor_unsupported} = error -> error
      _invalid -> {:error, :invalid_archive_read_options}
    end
  end

  def normalize_options(_opts), do: {:error, :invalid_archive_read_options}

  @spec new_state(String.t(), atom() | nil, :forward | :backward, map()) :: State.t()
  def new_state(stream_id, event_type, direction, heads) do
    epoch = if direction == :forward, do: :legacy, else: initial_backward_epoch(heads)

    %State{
      version: @cursor_version,
      stream_id: stream_id,
      event_type: event_type,
      direction: direction,
      legacy_head: heads.legacy,
      durable_head: heads.durable,
      epoch: epoch,
      legacy_position: if(direction == :forward, do: 1, else: heads.legacy),
      durable_position: if(direction == :forward, do: 1, else: heads.durable)
    }
    |> normalize_epoch()
  end

  @spec encode_cursor(State.t(), map()) ::
          {:ok, Cursor.t()} | {:error, :cursor_signer_unavailable}
  def encode_cursor(%State{} = state, target) do
    payload = state |> Map.from_struct() |> :erlang.term_to_binary([:deterministic])
    ArchiveCursorSigner.sign(payload, target_context(target))
  rescue
    _error -> {:error, :cursor_signer_unavailable}
  end

  @spec decode_cursor(Cursor.t(), String.t(), atom() | nil, map(), :forward | :backward | nil) ::
          {:ok, State.t()} | {:error, :invalid_archive_cursor}
  def decode_cursor(token, stream_id, event_type, target, requested_direction) do
    with {:ok, payload} <- ArchiveCursorSigner.verify(token, target_context(target)),
         decoded <- :erlang.binary_to_term(payload, [:safe]),
         {:ok, state} <- decode_state(decoded),
         true <- state.stream_id == stream_id,
         true <- state.event_type == event_type,
         true <- is_nil(requested_direction) or state.direction == requested_direction,
         true <- valid_positions?(state) do
      {:ok, normalize_epoch(state)}
    else
      _invalid -> {:error, :invalid_archive_cursor}
    end
  rescue
    _error -> {:error, :invalid_archive_cursor}
  catch
    _kind, _reason -> {:error, :invalid_archive_cursor}
  end

  @spec source_range(State.t(), pos_integer()) ::
          :done | {:ok, source(), keyword(), pos_integer()}
  def source_range(%State{epoch: :done}, _limit), do: :done

  def source_range(%State{} = state, limit) when is_integer(limit) and limit > 0 do
    state = normalize_epoch(state)

    case state.epoch do
      :done ->
        :done

      source ->
        position = position(state, source)
        head = head(state, source)

        opts =
          case state.direction do
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

  @spec advance(State.t(), source(), [Arbor.Persistence.Event.t()]) :: State.t()
  def advance(%State{direction: :forward} = state, source, events) do
    next_position =
      case List.last(events) do
        nil -> head(state, source) + 1
        event -> event.event_number + 1
      end

    state
    |> put_position(source, next_position)
    |> normalize_epoch()
  end

  def advance(%State{direction: :backward} = state, source, events) do
    next_position =
      case List.last(events) do
        nil -> 0
        event -> max(event.event_number - 1, 0)
      end

    state
    |> put_position(source, next_position)
    |> normalize_epoch()
  end

  @spec next_state(State.t()) :: State.t() | nil
  def next_state(%State{} = state) do
    case normalize_epoch(state) do
      %State{epoch: :done} -> nil
      state -> state
    end
  end

  @spec same_target?(map()) :: boolean()
  def same_target?(%{name: :memory_events, backend: Arbor.Persistence.EventLog.ETS}), do: true
  def same_target?(_target), do: false

  defp decode_state(
         %{
           version: @cursor_version,
           stream_id: stream_id,
           event_type: event_type,
           direction: direction,
           legacy_head: legacy_head,
           durable_head: durable_head,
           epoch: epoch,
           legacy_position: legacy_position,
           durable_position: durable_position
         } = decoded
       )
       when map_size(decoded) == 9 and is_binary(stream_id) and stream_id != "" and
              (is_atom(event_type) or is_nil(event_type)) and direction in [:forward, :backward] and
              epoch in [:legacy, :durable, :done] and is_integer(legacy_head) and
              legacy_head >= 0 and is_integer(durable_head) and durable_head >= 0 and
              is_integer(legacy_position) and legacy_position >= 0 and
              is_integer(durable_position) and durable_position >= 0 do
    {:ok,
     struct!(State, %{
       version: @cursor_version,
       stream_id: stream_id,
       event_type: event_type,
       direction: direction,
       legacy_head: legacy_head,
       durable_head: durable_head,
       epoch: epoch,
       legacy_position: legacy_position,
       durable_position: durable_position
     })}
  end

  defp decode_state(_decoded), do: {:error, :invalid_archive_cursor}

  defp target_context(%{name: name, backend: backend, opts: opts}) do
    :erlang.term_to_binary({:archive_target_v1, name, backend, opts}, [:deterministic])
  end

  defp normalize_limit(nil), do: {:ok, @default_limit}

  defp normalize_limit(limit) when is_integer(limit) and limit >= 0,
    do: {:ok, min(limit, @max_limit)}

  defp normalize_limit(_limit), do: :error

  defp normalize_cursor_option(nil), do: {:ok, nil}

  defp normalize_cursor_option(cursor)
       when is_binary(cursor) and byte_size(cursor) > 0 and
              byte_size(cursor) <= @max_cursor_bytes,
       do: {:ok, cursor}

  defp normalize_cursor_option(_cursor), do: :error

  defp normalize_direction(opts, nil) do
    case Keyword.get(opts, :direction, :forward) do
      direction when direction in [:forward, :backward] -> {:ok, direction}
      _invalid -> :error
    end
  end

  defp normalize_direction(opts, cursor) when is_binary(cursor) do
    case Keyword.fetch(opts, :direction) do
      :error -> {:ok, nil}
      {:ok, direction} when direction in [:forward, :backward] -> {:ok, direction}
      {:ok, _invalid} -> :error
    end
  end

  defp validate_legacy_from(0), do: :ok

  defp validate_legacy_from(from) when is_integer(from) and from > 0,
    do: {:error, :archive_scalar_cursor_unsupported}

  defp validate_legacy_from(_from), do: :error

  defp closed_unique_options?(opts) do
    keys = Keyword.keys(opts)
    Enum.all?(keys, &(&1 in @read_keys)) and length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp valid_positions?(%State{direction: :forward} = state) do
    state.legacy_position in 1..(state.legacy_head + 1) and
      state.durable_position in 1..(state.durable_head + 1)
  end

  defp valid_positions?(%State{direction: :backward} = state) do
    state.legacy_position <= state.legacy_head and
      state.durable_position <= state.durable_head
  end

  defp initial_backward_epoch(%{durable: durable}) when durable > 0, do: :durable
  defp initial_backward_epoch(_heads), do: :legacy

  defp normalize_epoch(%State{direction: :forward, epoch: :legacy} = state) do
    if state.legacy_position > state.legacy_head,
      do: normalize_epoch(%State{state | epoch: :durable}),
      else: state
  end

  defp normalize_epoch(%State{direction: :forward, epoch: :durable} = state) do
    if state.durable_position > state.durable_head,
      do: %State{state | epoch: :done},
      else: state
  end

  defp normalize_epoch(%State{direction: :backward, epoch: :durable} = state) do
    if state.durable_position == 0,
      do: normalize_epoch(%State{state | epoch: :legacy}),
      else: state
  end

  defp normalize_epoch(%State{direction: :backward, epoch: :legacy} = state) do
    if state.legacy_position == 0,
      do: %State{state | epoch: :done},
      else: state
  end

  defp normalize_epoch(%State{} = state), do: state

  defp head(state, :legacy), do: state.legacy_head
  defp head(state, :durable), do: state.durable_head
  defp position(state, :legacy), do: state.legacy_position
  defp position(state, :durable), do: state.durable_position

  defp put_position(%State{} = state, :legacy, position),
    do: %State{state | legacy_position: position}

  defp put_position(%State{} = state, :durable, position),
    do: %State{state | durable_position: position}
end
