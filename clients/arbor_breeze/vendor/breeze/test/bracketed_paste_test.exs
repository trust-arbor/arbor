defmodule Breeze.BracketedPasteTest do
  use ExUnit.Case, async: true

  alias Breeze.BracketedPaste

  @start "\e[200~"
  @finish "\e[201~"

  defp decode(chunks, opts \\ []) do
    Enum.reduce(chunks, {[], BracketedPaste.new(opts)}, fn chunk, {events, state} ->
      {next, state} = BracketedPaste.feed(state, chunk)
      {events ++ next, state}
    end)
  end

  defp coalesce_data(events) do
    events
    |> Enum.reduce([], fn
      {:data, bytes}, [{:data, previous} | rest] -> [{:data, previous <> bytes} | rest]
      event, previous -> [event | previous]
    end)
    |> Enum.reverse()
  end

  test "ordinary Unicode, invalid bytes, control keys and escape sequences are unchanged" do
    bytes = "café 東京 🌿\t\r\n\x03\e[A\e[13;2u" <> <<255>>
    assert {[{:data, ^bytes}], _state} = decode([bytes])
  end

  test "a complete multiline paste is atomic, normalized and ordered among ordinary keys" do
    body = "日本語 👋\r\npaste é\rline\n\ttab"
    expected = "日本語 👋\npaste é\nline\n\ttab"
    bytes = "before" <> @start <> body <> @finish <> "after\r"

    assert {[{:data, "before"}, {:paste, ^expected}, {:data, "after\r"}], _state} =
             decode([bytes])
  end

  test "every two-chunk byte boundary preserves delimiters, Unicode and event ordering" do
    bytes = "東京" <> @start <> "é👋\r\nline\t" <> @finish <> "tail\e[A"
    expected = [{:data, "東京"}, {:paste, "é👋\nline\t"}, {:data, "tail\e[A"}]

    for offset <- 0..byte_size(bytes) do
      first = binary_part(bytes, 0, offset)
      rest = binary_part(bytes, offset, byte_size(bytes) - offset)
      {events, state} = decode([first, rest])
      assert coalesce_data(events) == expected, "split at byte #{offset}"
      assert {[], _state} = BracketedPaste.flush(state)
    end
  end

  test "one-byte reader chunks support split markers and split Unicode codepoints" do
    bytes = "a" <> @start <> "é👋日本語\r\nnext" <> @finish <> "z"
    {events, _state} = decode(for <<byte <- bytes>>, do: <<byte>>)
    assert coalesce_data(events) == [{:data, "a"}, {:paste, "é👋日本語\nnext"}, {:data, "z"}]
  end

  test "multiple pastes, empty paste and a start marker inside a body preserve order" do
    body = "literal " <> @start <> " body"

    bytes =
      @start <> @finish <> "middle" <> @start <> body <> @finish <> @start <> "last" <> @finish

    assert {[{:paste, ""}, {:data, "middle"}, {:paste, ^body}, {:paste, "last"}], _state} =
             decode([bytes])
  end

  test "stop keys and escape-like text inside a paste are never ordinary input" do
    body = "q\nF9\rEnter\x03\e[24~\e]52;c;payload\a"

    assert {[{:paste, "q\nF9\nEnter\x03\e[24~\e]52;c;payload\a"}], _state} =
             decode([@start, body, @finish])
  end

  test "paste UTF-8 validation waits for completion and rejects only the invalid body" do
    {[], state} = BracketedPaste.feed(BracketedPaste.new(), @start <> <<195>>)
    assert {[{:paste, "é"}], _state} = BracketedPaste.feed(state, <<169>> <> @finish)

    bytes = "before" <> @start <> <<195>> <> @finish <> "after" <> @start <> "valid" <> @finish

    assert {[
              {:data, "before"},
              {:paste_error, :invalid_utf8},
              {:data, "after"},
              {:paste, "valid"}
            ], _state} =
             decode([bytes])
  end

  test "the size limit applies to raw bytes before normalization and counts UTF-8 bytes" do
    assert {[{:paste, "é\n"}], _state} = decode([@start <> "é\r\n" <> @finish], max_bytes: 4)

    assert {[{:paste_error, :too_large}], _state} =
             decode([@start <> "é\r\n" <> @finish], max_bytes: 3)
  end

  test "overflow discards a late body and split end marker before ordinary recovery" do
    {[], state} = BracketedPaste.feed(BracketedPaste.new(max_bytes: 3), @start <> "abc")
    assert {[{:paste_error, :too_large}], state} = BracketedPaste.feed(state, "d\r\nF9\x03\e[20")
    assert {[], state} = BracketedPaste.flush(state)
    assert {[], state} = BracketedPaste.feed(state, "1")

    assert {[{:data, "normal"}, {:paste, "ok"}], _state} =
             BracketedPaste.feed(state, "~normal" <> @start <> "ok" <> @finish)
  end

  test "discarded overflow input is not retained even while the end marker is absent" do
    {events, state} = decode([@start, :binary.copy("x", 100_000)], max_bytes: 1)
    assert events == [{:paste_error, :too_large}]
    assert byte_size(:erlang.term_to_binary(state)) < 1_024
    assert {[], state} = BracketedPaste.feed(state, :binary.copy("\r\n", 100_000))
    assert byte_size(:erlang.term_to_binary(state)) < 1_024
    assert {[{:data, "ready"}], _state} = BracketedPaste.feed(state, @finish <> "ready")
  end

  test "flush aborts an unfinished paste without replaying it or any late body" do
    {[], state} = BracketedPaste.feed(BracketedPaste.new(), @start <> "private draft\r\n\e[20")
    assert {[{:paste_error, :incomplete}], state} = BracketedPaste.flush(state)
    assert {[], state} = BracketedPaste.flush(state)
    assert {[], state} = BracketedPaste.feed(state, "1")
    assert {[{:data, "ordinary\r"}], _state} = BracketedPaste.feed(state, "~ordinary\r")
  end

  test "flush releases standalone Escape but deeper framing discards late body" do
    {[], state} = BracketedPaste.feed(BracketedPaste.new(), "\e")
    assert {[{:data, "\e"}], state} = BracketedPaste.flush(state)
    assert {[{:data, "plain"}], _} = BracketedPaste.feed(state, "plain")

    for length <- 2..(byte_size(@start) - 1) do
      prefix = binary_part(@start, 0, length)
      {[], state} = BracketedPaste.feed(BracketedPaste.new(), prefix)
      assert {[{:paste_error, :incomplete}], state} = BracketedPaste.flush(state)
      remainder = binary_part(@start, length, byte_size(@start) - length)

      assert {[{:data, "fresh"}], _} =
               BracketedPaste.feed(state, remainder <> "private\r\n" <> @finish <> "fresh")
    end
  end

  test "retired Escape retains at most five framing bytes and late closure restores fresh input" do
    {[], state} = BracketedPaste.feed(BracketedPaste.new(), "\e")
    {[{:data, "\e"}], state} = BracketedPaste.flush(state)
    refute BracketedPaste.pending?(state)

    for length <- 1..4 do
      tail = binary_part("[200", 0, length)
      assert {[], pending} = BracketedPaste.feed(state, tail)
      assert byte_size(pending.pending) <= 5
      assert pending.body_bytes == 0
    end

    assert {[{:paste_error, :incomplete}], state} = BracketedPaste.feed(state, "[200~")
    assert state.mode == :discard
    assert state.pending == ""
    assert state.body_bytes == 0
    assert {[], state} = BracketedPaste.feed(state, :binary.copy("private\r\n", 100_000))
    assert byte_size(:erlang.term_to_binary(state)) < 1_024

    assert {[{:data, "fresh"}, {:paste, "new"}], state} =
             BracketedPaste.feed(state, @finish <> "fresh" <> @start <> "new" <> @finish)

    assert state.sequence == 2
  end

  test "pending state distinguishes settled ordinary input from prefixes and unfinished pastes" do
    state = BracketedPaste.new()
    refute BracketedPaste.pending?(state)
    {[{:data, "plain"}], state} = BracketedPaste.feed(state, "plain")
    refute BracketedPaste.pending?(state)
    {[], state} = BracketedPaste.feed(state, "\e[20")
    assert BracketedPaste.pending?(state)
    {[{:paste_error, :incomplete}], state} = BracketedPaste.flush(state)
    assert BracketedPaste.pending?(state)
    {[], state} = BracketedPaste.feed(state, @finish)
    refute BracketedPaste.pending?(state)
    {[], state} = BracketedPaste.feed(state, @start)
    assert BracketedPaste.pending?(state)
    {[{:paste_error, :incomplete}], state} = BracketedPaste.flush(state)
    assert BracketedPaste.pending?(state)
    {[], state} = BracketedPaste.feed(state, @finish)
    refute BracketedPaste.pending?(state)
  end

  test "false marker prefixes become ordinary bytes without delaying later complete pastes" do
    bytes = "\e[20X\e[201~\e[200?" <> @start <> "ok" <> @finish
    {events, _state} = decode(for <<byte <- bytes>>, do: <<byte>>)
    assert coalesce_data(events) == [{:data, "\e[20X\e[201~\e[200?"}, {:paste, "ok"}]
  end

  test "the default body limit is one MiB and a custom limit must be positive" do
    body = :binary.copy("x", 1024 * 1024)
    assert {[{:paste, ^body}], _state} = decode([@start <> body <> @finish])
    assert {[{:paste_error, :too_large}], _state} = decode([@start <> body <> "x" <> @finish])

    for invalid <- [0, -1, 1.5, nil, "10"] do
      assert_raise ArgumentError, fn -> BracketedPaste.new(max_bytes: invalid) end
    end
  end

  test "framed events preserve ordinary-input ordering and number complete opening markers" do
    bytes =
      "before" <>
        @start <>
        "first\r\n" <>
        @finish <>
        "middle" <> @start <> @finish <> "after"

    assert {[
              {:data, "before"},
              {:paste_start, 1},
              {:paste, 1, "first\n"},
              {:data, "middle"},
              {:paste_start, 2},
              {:paste, 2, ""},
              {:data, "after"}
            ], state} = BracketedPaste.feed_framed(BracketedPaste.new(), bytes)

    assert state.sequence == 2
    assert state.mode == :idle
  end

  test "split opening markers emit one start and nested body markers do not increment sequence" do
    for offset <- 0..(byte_size(@start) - 1) do
      first = binary_part(@start, 0, offset)
      rest = binary_part(@start, offset, byte_size(@start) - offset)
      assert {[], state} = BracketedPaste.feed_framed(BracketedPaste.new(), first)
      assert state.sequence == 0
      assert {[{:paste_start, 1}], state} = BracketedPaste.feed_framed(state, rest)
      assert state.sequence == 1
      assert {[], state} = BracketedPaste.feed_framed(state, "literal" <> @start)
      body = "literal" <> @start
      assert {[{:paste, 1, ^body}], state} = BracketedPaste.feed_framed(state, @finish)

      assert {[{:paste_start, 2}, {:paste, 2, "next"}], _state} =
               BracketedPaste.feed_framed(state, @start <> "next" <> @finish)
    end
  end

  test "framed overflow and invalid UTF-8 errors retain their sequence through discard recovery" do
    assert {[{:paste_start, 1}, {:paste_error, 1, :too_large}], state} =
             BracketedPaste.feed_framed(BracketedPaste.new(max_bytes: 3), @start <> "large")

    assert state.sequence == 1
    assert state.mode == :discard
    assert {[], state} = BracketedPaste.feed_framed(state, @start <> "late\r\n")
    assert state.sequence == 1
    assert {[], state} = BracketedPaste.flush(state)

    assert {[
              {:data, "ordinary"},
              {:paste_start, 2},
              {:paste_error, 2, :invalid_utf8},
              {:paste_start, 3},
              {:paste, 3, "ok"}
            ], state} =
             BracketedPaste.feed_framed(
               state,
               @finish <>
                 "ordinary" <>
                 @start <>
                 <<255>> <>
                 @finish <>
                 @start <> "ok" <> @finish
             )

    assert state.sequence == 3
  end

  test "flush exposes the unfinished sequence and legacy feeds stay compatible with framed feeds" do
    assert {[{:paste, "legacy"}], state} =
             BracketedPaste.feed(BracketedPaste.new(), @start <> "legacy" <> @finish)

    assert state.sequence == 1
    assert {[{:paste_start, 2}], state} = BracketedPaste.feed_framed(state, @start <> "body")
    assert {[{:paste_error, :incomplete}], state} = BracketedPaste.flush(state)
    assert state.sequence == 2
    assert state.mode == :discard

    assert {[{:data, "ordinary"}, {:paste_start, 3}], state} =
             BracketedPaste.feed_framed(state, @finish <> "ordinary" <> @start)

    assert {[{:paste, "mixed"}], state} = BracketedPaste.feed(state, "mixed" <> @finish)
    assert state.sequence == 3
  end
end
