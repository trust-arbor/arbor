defmodule Arbor.LLM.OAuth.ResponsesTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.OAuth.Responses

  test "bounded Responses SSE parsing preserves text and decoded tool arguments" do
    raw =
      sse(%{"type" => "response.output_text.delta", "delta" => "hello "}) <>
        sse(%{"type" => "response.output_text.delta", "delta" => "world"}) <>
        sse(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call-1",
            "name" => "lookup",
            "arguments" => Jason.encode!(%{"q" => "bounded"})
          }
        }) <>
        "data: [DONE]\n\n"

    assert {:ok,
            %{
              text: "hello world",
              tool_calls: [
                %{id: "call-1", name: "lookup", arguments: %{"q" => "bounded"}}
              ]
            }} = Responses.parse_sse(raw)
  end

  test "security regression: Responses events enforce byte, event, work, and depth ceilings" do
    valid = sse(%{"type" => "response.output_text.delta", "delta" => "x"})
    deep = String.duplicate("[", 33) <> "0" <> String.duplicate("]", 33)
    deep_event = "data: {\"nested\":#{deep}}\n\n"

    assert {:error, {:response_bytes_exceeded, 8}} =
             Responses.parse_sse(valid, max_response_bytes: 8, max_event_bytes: 8)

    assert {:error, {:stream_limit_exceeded, :events, 1}} =
             Responses.parse_sse(valid <> valid, max_events: 1)

    assert {:error, {:invalid_responses_event, {:stream_limit_exceeded, :work, 2}}} =
             Responses.parse_sse(valid, max_work: 2)

    assert {:error, {:invalid_responses_event, {:decoded_term_limit_exceeded, :depth, 32}}} =
             Responses.parse_sse(deep_event)

    assert {:error, :valid_utf8_sse_required} = Responses.parse_sse("data: " <> <<255>>)

    assert {:error, :invalid_responses_limits} =
             Responses.parse_sse(valid, %{timeout: 100})
  end

  test "security regression: aggregate tool argument nodes fail before decoded retention" do
    arguments = Jason.encode!(%{"items" => List.duplicate(0, 4_500)})

    raw =
      1..30
      |> Enum.map(fn index ->
        sse(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call-#{index}",
            "name" => "bounded",
            "arguments" => arguments
          }
        })
      end)
      |> IO.iodata_to_binary()

    assert {:error, {:invalid_responses_event, {:stream_limit_exceeded, boundary, 100_000}}} =
             Responses.parse_sse(raw)

    assert boundary in [:decoded_nodes, :decoded_list_items]
  end

  test "security regression: thousands of tiny Responses events collect linearly" do
    raw =
      1..4_000
      |> Enum.map(fn _index ->
        sse(%{"type" => "response.output_text.delta", "delta" => "x"})
      end)
      |> IO.iodata_to_binary()

    task = Task.async(fn -> Responses.parse_sse(raw, max_events: 4_000) end)
    assert {:ok, {:ok, %{text: text, tool_calls: []}}} = Task.yield(task, 2_000)
    assert byte_size(text) == 4_000
  end

  test "security regression: drip-fed Responses TCP is owned by one absolute deadline" do
    {url, server} = start_drip_server(100, 10)
    started = System.monotonic_time(:millisecond)

    assert Responses.request_sse(url, [], %{}, receive_timeout: 120) ==
             {:error, {:responses_deadline_exceeded, 120}}

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 100
    assert elapsed < 300

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < 100
    assert {:messages, []} = Process.info(self(), :messages)
  end

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\n\n"

  defp start_drip_server(chunk_count, delay_ms) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        {:ok, _request} = receive_http_headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
              "transfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n"
          )

        result = send_drip_chunks(socket, chunk_count, delay_ms, 0)
        :gen_tcp.close(socket)
        result
      end)

    {"http://127.0.0.1:#{port}/responses", server}
  end

  defp receive_http_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> receive_http_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_drip_chunks(_socket, maximum, _delay_ms, sent) when sent >= maximum,
    do: %{sent: sent, closed?: false}

  defp send_drip_chunks(socket, maximum, delay_ms, sent) do
    chunk = sse(%{"type" => "response.output_text.delta", "delta" => "x"})
    frame = Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"

    case :gen_tcp.send(socket, frame) do
      :ok ->
        Process.sleep(delay_ms)
        send_drip_chunks(socket, maximum, delay_ms, sent + 1)

      {:error, _reason} ->
        %{sent: sent, closed?: true}
    end
  end
end
