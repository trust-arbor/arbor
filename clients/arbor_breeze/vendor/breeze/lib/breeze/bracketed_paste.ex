defmodule Breeze.BracketedPaste do
  @moduledoc """
  Pure streaming decoder for terminal bracketed paste.

  `feed/2` separates ordinary bytes from complete bracketed pastes while
  preserving their order. It accepts arbitrary binary chunks, including split
  delimiters and UTF-8 codepoints. Ordinary bytes are returned unchanged;
  complete paste bodies must be valid UTF-8 and have CRLF and CR normalized to
  LF. Tabs and other valid UTF-8 characters remain in the paste event.

  The configurable `:max_bytes` limit applies to the raw paste body, before
  newline normalization, and defaults to 1 MiB. A rejected paste is discarded
  through its closing delimiter. Its contents are never replayed as key input.

  `flush/1` releases a standalone Escape and retains a bounded guard against
  its late framing continuation. A deeper incomplete delimiter or unfinished
  paste reports `:incomplete` and discards subsequent bytes through its closing
  delimiter. Input resumes after that delimiter; a lost ending is not repaired
  by replaying ambiguous bytes as keys.
  """

  @start "\e[200~"
  @finish "\e[201~"
  @default_max_bytes 1024 * 1024

  defstruct mode: :idle,
            pending: "",
            body: [],
            body_bytes: 0,
            max_bytes: @default_max_bytes,
            sequence: 0

  @opaque t :: %__MODULE__{}
  @type event :: {:data, binary()} | {:paste, String.t()} | {:paste_error, error()}
  @type framed_event ::
          {:data, binary()}
          | {:paste_start, pos_integer()}
          | {:paste, pos_integer(), String.t()}
          | {:paste_error, pos_integer(), error()}
  @type error :: :too_large | :invalid_utf8 | :incomplete

  @doc "Constructs a decoder with an optional positive raw paste-body byte limit."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if is_integer(max_bytes) and max_bytes > 0 do
      %__MODULE__{max_bytes: max_bytes}
    else
      raise ArgumentError, "max_bytes must be a positive integer"
    end
  end

  @doc "Consumes a binary chunk and returns ordered input events and the next decoder."
  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    {events, state} = feed_framed(state, bytes)

    events =
      Enum.flat_map(events, fn
        {:paste_start, _sequence} -> []
        {:paste, _sequence, text} -> [{:paste, text}]
        {:paste_error, _sequence, reason} -> [{:paste_error, reason}]
        {:data, _bytes} = event -> [event]
      end)

    {events, state}
  end

  # Runtime integration uses these ordered boundaries to bind a paste to the
  # native input instance present at its start. sequence is monotonic per
  # decoder and remains available on the state when flush/1 reports an error.
  @doc false
  @spec feed_framed(t(), binary()) :: {[framed_event()], t()}
  def feed_framed(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    scan(%{state | pending: ""}, state.pending <> bytes, [])
  end

  @doc "Whether a delimiter prefix or unfinished paste remains pending."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{mode: :idle, pending: ""}), do: false
  def pending?(%__MODULE__{mode: :retired_prefix, pending: "\e"}), do: false
  def pending?(%__MODULE__{}), do: true

  @doc "Releases an idle prefix or aborts an unfinished paste without replaying its body."
  @spec flush(t()) :: {[event()], t()}
  def flush(%__MODULE__{mode: :idle, pending: ""} = state), do: {[], state}

  def flush(%__MODULE__{mode: :idle, pending: "\e"} = state),
    do: {[{:data, "\e"}], %{state | mode: :retired_prefix}}

  def flush(%__MODULE__{mode: :retired_prefix, pending: "\e"} = state), do: {[], state}

  def flush(%__MODULE__{mode: mode} = state) when mode in [:idle, :retired_prefix] do
    state = %{state | sequence: state.sequence + 1, pending: ""}
    {[{:paste_error, :incomplete}], discard(state)}
  end

  def flush(%__MODULE__{mode: :paste} = state) do
    {[{:paste_error, :incomplete}], discard(state)}
  end

  def flush(%__MODULE__{mode: :discard} = state), do: {[], state}

  defp scan(%{mode: :idle} = state, bytes, events) do
    case :binary.match(bytes, @start) do
      {offset, length} ->
        {before, rest} = split_match(bytes, offset, length)
        state = %{state | mode: :paste, body: [], body_bytes: 0, sequence: state.sequence + 1}
        events = [{:paste_start, state.sequence} | emit_data(events, before)]
        scan(state, rest, events)

      :nomatch ->
        {before, pending} = split_prefix(bytes, @start)
        {Enum.reverse(emit_data(events, before)), %{state | pending: pending}}
    end
  end

  # Escape has already been delivered. Keep only its possible opening marker
  # tail so delayed framing can never reinterpret a paste body's CR as Enter.
  defp scan(%{mode: :retired_prefix} = state, bytes, events) do
    cond do
      byte_size(bytes) < byte_size(@start) and String.starts_with?(@start, bytes) ->
        {Enum.reverse(events), %{state | pending: bytes}}

      String.starts_with?(bytes, @start) ->
        state = %{state | sequence: state.sequence + 1, pending: ""}
        rest = binary_part(bytes, byte_size(@start), byte_size(bytes) - byte_size(@start))
        scan(discard(state), rest, [{:paste_error, state.sequence, :incomplete} | events])

      String.starts_with?(bytes, "\e[") ->
        state = %{state | sequence: state.sequence + 1, pending: ""}
        scan(discard(state), bytes, [{:paste_error, state.sequence, :incomplete} | events])

      true ->
        # The original Escape was sent once; a fresh Escape/CSI or ordinary
        # character after it remains independent input.
        rest = binary_part(bytes, 1, byte_size(bytes) - 1)
        scan(%{state | mode: :idle, pending: ""}, rest, events)
    end
  end

  defp scan(%{mode: mode} = state, bytes, events) when mode in [:paste, :discard] do
    case :binary.match(bytes, @finish) do
      {offset, length} ->
        {body, rest} = split_match(bytes, offset, length)
        {state, events} = append_body(state, body, events)
        events = complete_paste(state, events)
        state = %{state | mode: :idle, pending: "", body: [], body_bytes: 0}
        scan(state, rest, events)

      :nomatch ->
        {body, pending} = split_prefix(bytes, @finish)
        {state, events} = append_body(state, body, events)
        {Enum.reverse(events), %{state | pending: pending}}
    end
  end

  defp append_body(%{mode: :discard} = state, _body, events), do: {state, events}
  defp append_body(state, "", events), do: {state, events}

  defp append_body(state, body, events) do
    size = state.body_bytes + byte_size(body)

    if size > state.max_bytes do
      {discard(state), [{:paste_error, state.sequence, :too_large} | events]}
    else
      # Copy retained slices so a short body does not keep a much larger input
      # chunk alive. Reversed chunks keep one-byte readers linear in body size.
      {%{state | body: [:binary.copy(body) | state.body], body_bytes: size}, events}
    end
  end

  defp complete_paste(%{mode: :discard}, events), do: events

  defp complete_paste(state, events) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()

    if String.valid?(body) do
      text =
        body
        |> :binary.replace("\r\n", "\n", [:global])
        |> :binary.replace("\r", "\n", [:global])

      [{:paste, state.sequence, text} | events]
    else
      [{:paste_error, state.sequence, :invalid_utf8} | events]
    end
  end

  defp discard(state), do: %{state | mode: :discard, body: [], body_bytes: 0}

  defp emit_data(events, ""), do: events
  defp emit_data(events, bytes), do: [{:data, bytes} | events]

  defp split_match(bytes, offset, length) do
    before = binary_part(bytes, 0, offset)
    rest_offset = offset + length
    rest = binary_part(bytes, rest_offset, byte_size(bytes) - rest_offset)
    {before, rest}
  end

  defp split_prefix(bytes, marker) do
    size = byte_size(bytes)
    length = prefix_length(bytes, marker, min(size, byte_size(marker) - 1))
    before = binary_part(bytes, 0, size - length)
    pending = bytes |> binary_part(size - length, length) |> :binary.copy()
    {before, pending}
  end

  defp prefix_length(_bytes, _marker, 0), do: 0

  defp prefix_length(bytes, marker, length) do
    if binary_part(bytes, byte_size(bytes) - length, length) == binary_part(marker, 0, length) do
      length
    else
      prefix_length(bytes, marker, length - 1)
    end
  end
end
