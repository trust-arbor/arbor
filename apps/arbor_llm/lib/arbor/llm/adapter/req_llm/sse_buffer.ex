defmodule Arbor.LLM.Adapter.ReqLLM.SSEBuffer do
  @moduledoc false

  # Incremental SSE reassembly for Finch/Mint body chunks. Network frames are
  # not SSE events: a 2 KB `data: {...}` line often arrives as many `:data`
  # binaries, and `\n\n` can be split across frames. This module is the only
  # place that decides a line or event is complete — BoundedStream must not
  # JSON-decode a fragment.

  @type event :: %{
          required(:data) => binary(),
          optional(:event) => binary(),
          optional(:id) => binary()
        }

  @type state :: %{
          line_parts: [binary()],
          line_bytes: non_neg_integer(),
          data_parts: [binary()],
          event: binary() | nil,
          id: binary() | nil,
          event_bytes: non_neg_integer(),
          first_line?: boolean()
        }

  @type limits :: %{max_event_bytes: pos_integer()}

  @spec new() :: state()
  def new do
    %{
      line_parts: [],
      line_bytes: 0,
      data_parts: [],
      event: nil,
      id: nil,
      event_bytes: 0,
      first_line?: true
    }
  end

  @spec feed(state(), binary(), limits()) ::
          {:ok, [event()], non_neg_integer(), state()}
          | {:error, term(), [event()], non_neg_integer(), state()}
  def feed(state, chunk, limits) when is_binary(chunk) and is_map(limits) do
    consume(chunk, state, limits, [], 0)
  end

  @spec incomplete?(state()) :: boolean()
  def incomplete?(state) do
    state.line_bytes > 0 or state.line_parts != [] or state.data_parts != [] or
      not is_nil(state.event) or not is_nil(state.id)
  end

  defp consume("", state, _limits, events, lines) do
    {:ok, Enum.reverse(events), lines, state}
  end

  defp consume(data, state, limits, events, lines) do
    case :binary.match(data, "\n") do
      :nomatch ->
        case append_incomplete_line(state, data, limits) do
          {:ok, state} ->
            {:ok, Enum.reverse(events), lines, state}

          {:error, reason, state} ->
            {:error, reason, Enum.reverse(events), lines, state}
        end

      {index, 1} ->
        piece = binary_part(data, 0, index)
        rest = binary_part(data, index + 1, byte_size(data) - index - 1)
        consume_line(piece, rest, state, limits, events, lines)
    end
  end

  defp consume_line(piece, rest, state, limits, events, lines) do
    case complete_line(state, piece, limits) do
      {:error, reason, state} ->
        {:error, reason, Enum.reverse(events), lines, state}

      {:ok, line, state} ->
        case handle_line(state, line, limits) do
          {:error, reason, state} ->
            {:error, reason, Enum.reverse(events), lines + 1, state}

          {:ok, state, event} ->
            events = if event, do: [event | events], else: events
            consume(rest, state, limits, events, lines + 1)
        end
    end
  end

  defp append_incomplete_line(state, "", _limits), do: {:ok, state}

  defp append_incomplete_line(state, piece, limits) do
    bytes = state.line_bytes + byte_size(piece)

    if bytes > limits.max_event_bytes do
      {:error, {:stream_limit_exceeded, :incomplete_sse_bytes, limits.max_event_bytes}, state}
    else
      {:ok, %{state | line_parts: [piece | state.line_parts], line_bytes: bytes}}
    end
  end

  defp complete_line(state, piece, limits) do
    bytes = state.line_bytes + byte_size(piece)

    if bytes > limits.max_event_bytes do
      {:error, {:stream_limit_exceeded, :sse_line_bytes, limits.max_event_bytes}, state}
    else
      line =
        case state.line_parts do
          [] -> piece
          parts -> [piece | parts] |> Enum.reverse() |> IO.iodata_to_binary()
        end
        |> strip_carriage_return()

      {:ok, line, %{state | line_parts: [], line_bytes: 0}}
    end
  end

  defp strip_carriage_return(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  defp handle_line(state, line, limits) do
    line = if state.first_line?, do: strip_bom(line), else: line
    state = %{state | first_line?: false}

    cond do
      line == "" -> complete_event(state)
      match?(<<?:, _::binary>>, line) -> {:ok, state, nil}
      true -> put_field(line, state, limits)
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(line), do: line

  defp put_field(line, state, limits) do
    {field, value} = split_field(line)

    value =
      case value do
        <<" ", rest::binary>> -> rest
        _ -> value
      end

    bytes = state.event_bytes + byte_size(value) + 1

    if bytes > limits.max_event_bytes do
      {:error, {:stream_limit_exceeded, :sse_event_bytes, limits.max_event_bytes}, state}
    else
      state =
        case field do
          "data" -> %{state | data_parts: [value | state.data_parts], event_bytes: bytes}
          "event" -> %{state | event: value, event_bytes: bytes}
          "id" -> %{state | id: value, event_bytes: bytes}
          _ -> %{state | event_bytes: bytes}
        end

      {:ok, state, nil}
    end
  end

  defp split_field(line) do
    case :binary.match(line, ":") do
      :nomatch ->
        {line, ""}

      {index, 1} ->
        {binary_part(line, 0, index), binary_part(line, index + 1, byte_size(line) - index - 1)}
    end
  end

  defp complete_event(%{data_parts: [], event: nil, id: nil} = state) do
    {:ok, reset_event(state), nil}
  end

  defp complete_event(state) do
    data =
      state.data_parts
      |> Enum.reverse()
      |> Enum.intersperse("\n")
      |> IO.iodata_to_binary()

    event =
      %{data: data}
      |> maybe_put(:event, state.event)
      |> maybe_put(:id, state.id)

    {:ok, reset_event(state), event}
  end

  defp reset_event(state),
    do: %{state | data_parts: [], event: nil, id: nil, event_bytes: 0}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
