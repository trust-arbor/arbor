defmodule Arbor.LLM.Adapter.ReqLLMBoundedTransportTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.{Client, Message, OwnedStream, Request, StreamEvent}

  test "security regression: Enum.take closes the owned producer and TCP connection synchronously" do
    chunks = List.duplicate(openai_sse("x"), 200)
    {url, server} = start_chunked_server(chunks, 3)

    assert %OwnedStream{producer: producer} =
             stream = Adapter.stream(request(), transport_opts(url))

    started = System.monotonic_time(:millisecond)
    assert [%StreamEvent{type: :delta, data: %{text: "x"}}] = Enum.take(stream, 1)
    latency = System.monotonic_time(:millisecond) - started

    refute Process.alive?(producer)
    assert latency < 1_000
    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: aggregate stream bytes close the producer before the full body" do
    chunks = List.duplicate(openai_sse(String.duplicate("x", 80)), 200)
    {url, server} = start_chunked_server(chunks, 2)

    opts = transport_opts(url) ++ [max_response_bytes: 512, max_stream_event_bytes: 256]
    assert %OwnedStream{producer: producer} = stream = Adapter.stream(request(), opts)
    events = Enum.to_list(stream)

    assert Enum.any?(events, fn
             %StreamEvent{
               type: :error,
               data: %{reason: {:stream_limit_exceeded, boundary, 512}}
             }
             when boundary in [:response_bytes, :decoded_bytes] ->
               true

             _ ->
               false
           end)

    refute Process.alive?(producer)
    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: tiny SSE event floods are work bounded without mailbox residue" do
    chunks = List.duplicate("data: {\"choices\":[]}\n\n", 200)
    {url, server} = start_chunked_server(chunks, 2)

    opts = transport_opts(url) ++ [max_stream_events: 5, max_response_bytes: 4_096]
    assert %OwnedStream{producer: producer} = stream = Adapter.stream(request(), opts)

    task =
      Task.async(fn ->
        events = Enum.to_list(stream)
        {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)
        {events, queue_len}
      end)

    assert {events, 0} = Task.await(task, 2_000)

    assert [
             %StreamEvent{
               type: :error,
               data: %{reason: {:stream_limit_exceeded, :events, 5}}
             }
           ] = events

    refute Process.alive?(producer)
    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: tiny transport chunks consume the absolute work budget" do
    chunks = List.duplicate("x", 500)
    {url, server} = start_chunked_server(chunks, 3)

    opts =
      transport_opts(url) ++
        [max_stream_events: 1, max_response_bytes: 4_096, max_stream_event_bytes: 1_024]

    assert %OwnedStream{producer: producer} = stream = Adapter.stream(request(), opts)

    assert [
             %StreamEvent{
               type: :error,
               data: %{reason: {:stream_limit_exceeded, :work, 16}}
             }
           ] = Enum.to_list(stream)

    refute Process.alive?(producer)
    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: malformed media types and encoded streams fail before body buffering" do
    for {content_type, extra_headers, expected} <- [
          {"application/json", [], :text_event_stream_required},
          {"text/event-stream", [{"content-type", "application/json"}],
           :text_event_stream_required},
          {"text/event-stream", [{"content-encoding", "gzip"}], :content_encoding_forbidden}
        ] do
      {url, server} =
        start_chunked_server([openai_sse("ignored")], 1, content_type, 200, extra_headers)

      assert %OwnedStream{producer: producer} =
               stream = Adapter.stream(request(), transport_opts(url))

      assert [
               %StreamEvent{
                 type: :error,
                 data: %{reason: {:invalid_stream_headers, ^expected}}
               }
             ] = Enum.to_list(stream)

      refute Process.alive?(producer)
      _ = Task.await(server, 2_000)
    end
  end

  test "security regression: split invalid UTF-8 and partial JSON fail closed" do
    invalid_utf8 = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"",
      <<0xC3>>,
      <<0x28>> <> "\"}}]}\n\n"
    ]

    for chunks <- [invalid_utf8, ["data: {\"choices\":[\n\n"], ["data: {\"choices\":[]}"]] do
      {url, server} = start_chunked_server(chunks, 1)

      assert %OwnedStream{producer: producer} =
               stream = Adapter.stream(request(), transport_opts(url))

      assert [%StreamEvent{type: :error}] = Enum.to_list(stream)
      refute Process.alive?(producer)
      _ = Task.await(server, 2_000)
    end
  end

  test "security regression: a huge single chunk and HTTP error body do not escape stream bounds" do
    {huge_url, huge_server} = start_chunked_server([String.duplicate("x", 2_048)], 1)

    assert %OwnedStream{producer: huge_producer} =
             huge_stream =
             Adapter.stream(
               request(),
               transport_opts(huge_url) ++
                 [max_response_bytes: 512, max_stream_event_bytes: 512]
             )

    assert [
             %StreamEvent{
               type: :error,
               data: %{reason: {:stream_limit_exceeded, :response_bytes, 512}}
             }
           ] = Enum.to_list(huge_stream)

    refute Process.alive?(huge_producer)
    _ = Task.await(huge_server, 2_000)

    {error_url, error_server} =
      start_chunked_server([String.duplicate("sensitive", 1_000)], 1, "text/plain", 500)

    assert %OwnedStream{producer: error_producer} =
             error_stream =
             Adapter.stream(request(), transport_opts(error_url))

    assert [
             %StreamEvent{type: :error, data: %{reason: {:stream_http_error, 500}}}
           ] = Enum.to_list(error_stream)

    refute Process.alive?(error_producer)
    _ = Task.await(error_server, 2_000)
  end

  test "security regression: facade abort preserves demand and closes the true socket owner" do
    chunks = List.duplicate(openai_sse("x"), 200)
    {url, server} = start_chunked_server(chunks, 3)
    abort_state = :atomics.new(1, [])
    client = req_llm_client()

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "lm_studio",
               model: "bounded-test",
               prompt: "hello",
               abort?: fn -> :atomics.get(abort_state, 1) == 1 end,
               stream_read_timeout_ms: 2_000,
               client_opts: transport_opts(url)
             )

    assert_raise Arbor.LLM.AbortError, fn ->
      Enum.reduce(stream, 0, fn _event, count ->
        :atomics.put(abort_state, 1, 1)
        count + 1
      end)
    end

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: absolute facade timeout closes a stalled true socket owner" do
    chunks = [openai_sse("x") | List.duplicate(openai_sse("late"), 20)]

    {url, server} =
      start_chunked_server(chunks, fn
        1 -> 250
        _ -> 2
      end)

    client = req_llm_client()

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "lm_studio",
               model: "bounded-test",
               prompt: "hello",
               stream_read_timeout_ms: 50,
               client_opts: transport_opts(url) ++ [receive_timeout: 5_000]
             )

    started = System.monotonic_time(:millisecond)
    assert_raise Arbor.LLM.RequestTimeoutError, fn -> Enum.to_list(stream) end
    assert System.monotonic_time(:millisecond) - started < 1_000

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: continuous activity cannot reset the absolute stream deadline" do
    chunks = List.duplicate(openai_sse("active"), 200)
    {url, server} = start_chunked_server(chunks, 10)
    client = req_llm_client()

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "lm_studio",
               model: "bounded-test",
               prompt: "hello",
               stream_read_timeout_ms: 50,
               client_opts: transport_opts(url) ++ [receive_timeout: 5_000]
             )

    started = System.monotonic_time(:millisecond)
    assert_raise Arbor.LLM.RequestTimeoutError, fn -> Enum.to_list(stream) end
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 40
    assert elapsed < 1_000

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent > 1
    assert sent < length(chunks)
  end

  test "security regression: cloud embedding dispatch consumes the private cap before ReqLLM validation" do
    chunks = List.duplicate(String.duplicate("x", 128), 200)
    {url, server} = start_chunked_server(chunks, 2, "application/json")

    assert {:error, {:response_bytes_exceeded, 512}} =
             Adapter.embed(["hello"], "text-embedding-3-small",
               provider: "openai",
               base_url: url,
               api_key: "test-key",
               receive_timeout: 2_000,
               max_response_bytes: 512
             )

    assert %{sent: sent, closed?: true, request: request} = Task.await(server, 2_000)
    assert request =~ "POST /v1/embeddings "
    assert sent < length(chunks)
  end

  test "security regression: local embedding dispatch consumes the private cap before ReqLLM validation" do
    chunks = List.duplicate(String.duplicate("x", 128), 200)
    {url, server} = start_chunked_server(chunks, 2, "application/json")

    assert {:error, {:response_bytes_exceeded, 512}} =
             Adapter.embed(["hello"], "operator-local-embedding",
               provider: "ollama",
               base_url: url,
               receive_timeout: 2_000,
               max_response_bytes: 512
             )

    assert %{sent: sent, closed?: true, request: request} = Task.await(server, 2_000)
    assert request =~ "POST /v1/embeddings "
    assert sent < length(chunks)
  end

  test "security regression: embedding indices are complete, unique, bounded, and reordered" do
    reversed = [
      %{"index" => 1, "embedding" => [0.0, 1.0]},
      %{"index" => 0, "embedding" => [1.0, 0.0]}
    ]

    {url, server} = embedding_server(reversed)

    assert {:ok, result} =
             Adapter.embed(["first", "second"], "text-embedding-3-small",
               provider: "openai",
               base_url: url,
               api_key: "test-key",
               receive_timeout: 2_000
             )

    assert result.embeddings == [[1.0, 0.0], [0.0, 1.0]]

    _ = Task.await(server, 2_000)

    invalid_batches = [
      [
        %{"index" => 0, "embedding" => [1.0]},
        %{"index" => 0, "embedding" => [2.0]}
      ],
      [%{"index" => 0, "embedding" => [1.0]}],
      [
        %{"index" => -1, "embedding" => [1.0]},
        %{"index" => 1, "embedding" => [2.0]}
      ],
      [
        %{"index" => 1_000_000, "embedding" => [1.0]},
        %{"index" => 1, "embedding" => [2.0]}
      ],
      [
        %{"index" => 0.0, "embedding" => [1.0]},
        %{"index" => 1, "embedding" => [2.0]}
      ],
      [
        %{"embedding" => [1.0]},
        %{"index" => 1, "embedding" => [2.0]}
      ]
    ]

    for data <- invalid_batches do
      {url, server} = embedding_server(data)

      assert {:error, _reason} =
               Adapter.embed(["first", "second"], "text-embedding-3-small",
                 provider: "openai",
                 base_url: url,
                 api_key: "test-key",
                 receive_timeout: 2_000
               )

      _ = Task.await(server, 2_000)
    end
  end

  defp request do
    %Request{
      provider: "lm_studio",
      model: "bounded-test",
      messages: [%Message{role: :user, content: "hello"}]
    }
  end

  defp req_llm_client do
    Client.new(
      adapters: %{"lm_studio" => Adapter},
      default_provider: "lm_studio"
    )
  end

  defp transport_opts(url) do
    [base_url: url, api_key: "test-key", receive_timeout: 2_000]
  end

  defp openai_sse(text) do
    Jason.encode!(%{"choices" => [%{"delta" => %{"content" => text}}]})
    |> then(&("data: " <> &1 <> "\n\n"))
  end

  defp embedding_server(data) do
    body = Jason.encode!(%{"data" => data, "usage" => %{}})
    start_chunked_server([body], 0, "application/json")
  end

  defp start_chunked_server(
         chunks,
         delay,
         content_type \\ "text/event-stream",
         status \\ 200,
         extra_headers \\ []
       ) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        {:ok, request} = receive_request_headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Test\r\n" <>
              "content-type: #{content_type}\r\n" <>
              Enum.map_join(extra_headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end) <>
              "transfer-encoding: chunked\r\n" <>
              "connection: keep-alive\r\n\r\n"
          )

        {sent, closed?} = send_chunks(socket, chunks, delay, 0)
        safe_close(socket)
        %{sent: sent, closed?: closed?, request: request}
      end)

    {"http://127.0.0.1:#{port}/v1", task}
  end

  defp receive_request_headers(socket, acc) when byte_size(acc) <= 65_536 do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> receive_request_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_chunks(socket, [], _delay, sent) do
    case :gen_tcp.send(socket, "0\r\n\r\n") do
      :ok -> {sent, false}
      {:error, _reason} -> {sent, true}
    end
  end

  defp send_chunks(socket, [chunk | rest], delay, sent) do
    frame = Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"

    case :gen_tcp.send(socket, frame) do
      :ok ->
        Process.sleep(chunk_delay(delay, sent + 1))
        send_chunks(socket, rest, delay, sent + 1)

      {:error, _reason} ->
        {sent, true}
    end
  end

  defp chunk_delay(delay, count) when is_function(delay, 1), do: delay.(count)
  defp chunk_delay(delay, _count), do: delay

  defp safe_close(socket) do
    :gen_tcp.close(socket)
  catch
    :error, :badarg -> :ok
  end
end
