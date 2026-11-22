defmodule Arbor.LLM.Adapter.ReqLLMSSEBufferTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.Adapter.ReqLLM.SSEBuffer

  @limits %{max_event_bytes: 1_048_576}

  @json ~s({"choices":[{"delta":{"content":"hello"}}]})
  @cost ~s({"choices":[],"cost":"0"})
  @payload "data: #{@json}\n\ndata: [DONE]\n\ndata: #{@cost}\n\n"

  test "reassembles SSE events split mid-data prefix, mid-JSON, and between blank-line bytes" do
    {json_head, json_tail} = split_binary(@json, 12)

    assert {:ok, [@json]} = parse_chunks(["da", "ta: #{@json}\n\n"])
    assert {:ok, [@json]} = parse_chunks(["data: #{json_head}", json_tail <> "\n\n"])
    assert {:ok, [@json]} = parse_chunks(["data: #{@json}\n", "\n"])
  end

  test "every byte-offset split of an OpenCode-style stream yields the same complete events" do
    expected = [@json, "[DONE]", @cost]
    assert {:ok, ^expected} = parse_chunks([@payload])

    for index <- 0..byte_size(@payload) do
      left = binary_part(@payload, 0, index)
      right = binary_part(@payload, index, byte_size(@payload) - index)

      assert {:ok, ^expected} = parse_chunks([left, right]),
             "reassembly failed at split offset #{index}"
    end
  end

  test "one-byte Finch frames still produce complete data lines" do
    chunks = for <<byte <- @payload>>, do: <<byte>>
    assert {:ok, [@json, "[DONE]", @cost]} = parse_chunks(chunks)
  end

  test "CRLF framing and a leading BOM do not change event data" do
    bom = <<0xEF, 0xBB, 0xBF>>
    crlf = bom <> "data: #{@json}\r\n\r\ndata: [DONE]\r\n\r\n"
    assert {:ok, [@json, "[DONE]"]} = parse_chunks([crlf])

    {json_head, json_tail} = split_binary(@json, 8)

    assert {:ok, [@json]} =
             parse_chunks([bom <> "data: #{json_head}", json_tail <> "\r\n\r\n"])
  end

  test "keep-alive comments are ignored and do not complete a pending event" do
    assert {:ok, [@json]} =
             parse_chunks([": ping\n\ndata: #{@json}\n", ": still-pending\n", "\n"])
  end

  test "a stream that ends mid-line or mid-event is incomplete" do
    assert {:error, {:invalid_stream, :partial_sse_event}, [], _} =
             parse_chunks(["data: #{@json}"])

    assert {:error, {:invalid_stream, :partial_sse_event}, [], _} =
             parse_chunks(["data: #{@json}\n"])

    assert {:error, {:invalid_stream, :partial_sse_event}, [@json], _} =
             parse_chunks(["data: #{@json}\n\ndata: [DO"])
  end

  test "a blank line still terminates an event whose JSON is truncated" do
    # Framing succeeded; JSON validity is BoundedStream's job. This is the
    # case that must NOT be confused with a Finch split that has no newline.
    truncated = "{\"choices\":["
    assert {:ok, [^truncated]} = parse_chunks(["data: " <> truncated <> "\n\n"])
  end

  test "incomplete-line bytes are bounded before a newline arrives" do
    limits = %{max_event_bytes: 8}
    state = SSEBuffer.new()

    assert {:error, {:stream_limit_exceeded, :incomplete_sse_bytes, 8}, [], 0, _} =
             SSEBuffer.feed(state, String.duplicate("x", 9), limits)
  end

  defp split_binary(binary, index) do
    {binary_part(binary, 0, index), binary_part(binary, index, byte_size(binary) - index)}
  end

  defp parse_chunks(chunks, limits \\ @limits) do
    result =
      Enum.reduce_while(chunks, {:ok, [], SSEBuffer.new()}, fn chunk, {:ok, acc, state} ->
        case SSEBuffer.feed(state, chunk, limits) do
          {:ok, events, _lines, state} ->
            {:cont, {:ok, acc ++ Enum.map(events, & &1.data), state}}

          {:error, reason, events, _lines, state} ->
            {:halt, {:error, reason, acc ++ Enum.map(events, & &1.data), state}}
        end
      end)

    case result do
      {:ok, events, state} ->
        if SSEBuffer.incomplete?(state) do
          {:error, {:invalid_stream, :partial_sse_event}, events, state}
        else
          {:ok, events}
        end

      other ->
        other
    end
  end
end
