defmodule Arbor.LLM.Adapter.ReqLLMBoundedTransportTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Adapter.ReqLLM.BoundedStream
  alias Arbor.LLM.Plugs.Usage.AccountedStream
  alias Arbor.LLM.{Client, Message, OwnedStream, ProviderError, Request, Response, ResponseBudget}
  alias Arbor.LLM.StreamEvent

  setup do
    original = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:arbor_llm, :trusted_proxy_endpoints),
        else: Application.put_env(:arbor_llm, :trusted_proxy_endpoints, original)
    end)

    :ok
  end

  test "security regression: Enum.take closes the owned producer and TCP connection synchronously" do
    chunks = List.duplicate(openai_sse("x"), 200)
    {url, server} = start_chunked_server(chunks, 3)

    assert {:ok,
            %AccountedStream{
              source: %OwnedStream{producer: producer}
            } = stream} =
             Client.stream(req_llm_client(), request(), transport_opts(url))

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

    assert {:ok,
            %AccountedStream{
              source: %OwnedStream{producer: producer}
            } = stream} =
             Client.stream(req_llm_client(), request(), opts)

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

    assert {:ok,
            %AccountedStream{
              source: %OwnedStream{producer: producer}
            } = stream} =
             Client.stream(req_llm_client(), request(), opts)

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

    assert {:ok,
            %AccountedStream{
              source: %OwnedStream{producer: producer}
            } = stream} =
             Client.stream(req_llm_client(), request(), opts)

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

      assert {:ok,
              %AccountedStream{
                source: %OwnedStream{producer: producer}
              } = stream} =
               Client.stream(req_llm_client(), request(), transport_opts(url))

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

  test "OpenAI tool-call argument fragments are not rejected as malformed envelope JSON" do
    envelopes = [
      ~s({"id":"abc","object":"chat.completion.chunk","created":1787635097,"model":"x-preview-f-free","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_b0bcac3972eb44eb92165a9d","type":"function","function":{"name":"memory_recall","arguments":"{\\""}}]}}]}),
      Jason.encode!(%{
        "id" => "abc",
        "object" => "chat.completion.chunk",
        "created" => 1,
        "model" => "m",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_empty",
                  "type" => "function",
                  "function" => %{"name" => "memory_recall", "arguments" => ""}
                }
              ]
            }
          }
        ]
      })
    ]

    for data <- envelopes do
      payload = "data: #{data}\n\ndata: [DONE]\n\n"
      {url, server} = start_chunked_server([payload], 0)

      assert {:ok, stream} = Client.stream(req_llm_client(), request(), transport_opts(url))
      events = Enum.to_list(stream)

      refute Enum.any?(events, &match?(%StreamEvent{type: :error}, &1)),
             "stream rejected a valid tool-call envelope: #{inspect(events)}"

      _ = Task.await(server, 2_000)
    end
  end

  test "reassembles OpenAI SSE JSON split across one-byte HTTP chunks including [DONE] and cost trailer" do
    json = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "hello"}}]})
    cost = Jason.encode!(%{"choices" => [], "cost" => "0"})
    payload = "data: #{json}\n\ndata: [DONE]\n\ndata: #{cost}\n\n"
    chunks = for <<byte <- payload>>, do: <<byte>>
    {url, server} = start_chunked_server(chunks, 0)

    assert {:ok, stream} = Client.stream(req_llm_client(), request(), transport_opts(url))
    events = Enum.to_list(stream)

    refute Enum.any?(events, &match?(%StreamEvent{type: :error}, &1)),
           "stream failed closed on a chunk boundary: #{inspect(events)}"

    assert Enum.any?(events, fn
             %StreamEvent{type: :delta, data: %{text: "hello"}} -> true
             _ -> false
           end)

    _ = Task.await(server, 2_000)
  end

  test "security regression: split invalid UTF-8 and partial JSON fail closed" do
    invalid_utf8 = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"",
      <<0xC3>>,
      <<0x28>> <> "\"}}]}\n\n"
    ]

    for chunks <- [invalid_utf8, ["data: {\"choices\":[\n\n"], ["data: {\"choices\":[]}"]] do
      {url, server} = start_chunked_server(chunks, 1)

      assert {:ok,
              %AccountedStream{
                source: %OwnedStream{producer: producer}
              } = stream} =
               Client.stream(req_llm_client(), request(), transport_opts(url))

      assert [%StreamEvent{type: :error}] = Enum.to_list(stream)
      refute Process.alive?(producer)
      _ = Task.await(server, 2_000)
    end
  end

  test "security regression: a huge single chunk and HTTP error body do not escape stream bounds" do
    {huge_url, huge_server} = start_chunked_server([String.duplicate("x", 2_048)], 1)

    assert {:ok,
            %AccountedStream{
              source: %OwnedStream{producer: huge_producer}
            } = huge_stream} =
             Client.stream(
               req_llm_client(),
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

    assert {:ok,
            %AccountedStream{
              source: %OwnedStream{producer: error_producer}
            } = error_stream} =
             Client.stream(req_llm_client(), request(), transport_opts(error_url))

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
        1 -> 1_000
        _ -> 2
      end)

    client = req_llm_client()

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "lm_studio",
               model: "bounded-test",
               prompt: "hello",
               stream_read_timeout_ms: 500,
               client_opts: transport_opts(url) ++ [receive_timeout: 5_000]
             )

    started = System.monotonic_time(:millisecond)
    assert_raise Arbor.LLM.RequestTimeoutError, fn -> Enum.to_list(stream) end
    assert System.monotonic_time(:millisecond) - started < 1_500

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < length(chunks)
  end

  test "security regression: continuous activity cannot reset the absolute stream deadline" do
    chunks = List.duplicate(openai_sse("active"), 200)
    {url, server} = start_chunked_server(chunks, 10)
    client = req_llm_client()
    active_events = :atomics.new(1, [])

    assert {:ok, stream} =
             LLM.stream(
               client: client,
               provider: "lm_studio",
               model: "bounded-test",
               prompt: "hello",
               # This key is the absolute deadline. 500ms still ends the stream
               # well before 200 chunks at 10ms, and leaves room for more than
               # one event when the socket is slow to start.
               stream_read_timeout_ms: 500,
               client_opts: transport_opts(url) ++ [receive_timeout: 5_000]
             )

    started = System.monotonic_time(:millisecond)

    assert_raise Arbor.LLM.RequestTimeoutError, fn ->
      Enum.each(stream, fn %StreamEvent{type: :delta, data: %{text: "active"}} ->
        :atomics.add_get(active_events, 1, 1)
      end)
    end

    elapsed = System.monotonic_time(:millisecond) - started
    assert :atomics.get(active_events, 1) > 1
    assert elapsed < 1_500

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent > 1
    assert sent < length(chunks)
  end

  test "security regression: cloud embedding dispatch consumes the private cap before ReqLLM validation" do
    chunks = List.duplicate(String.duplicate("x", 128), 200)
    {url, server} = start_chunked_server(chunks, 2, "application/json")

    assert {:error, %ProviderError{retryable: false, original: {:response_bytes_exceeded, 512}}} =
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

    assert {:error, %ProviderError{retryable: false, original: {:response_bytes_exceeded, 512}}} =
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

  test "security regression: embedding indices must preserve authoritative input order" do
    reversed = [
      %{"index" => 1, "embedding" => [0.0, 1.0]},
      %{"index" => 0, "embedding" => [1.0, 0.0]}
    ]

    {url, server} = embedding_server(reversed)

    assert {:error,
            %ProviderError{retryable: false, original: {:embedding_index_reordered, 0, 1}}} =
             Adapter.embed(["first", "second"], "text-embedding-3-small",
               provider: "openai",
               base_url: url,
               api_key: "test-key",
               receive_timeout: 2_000
             )

    _ = Task.await(server, 2_000)

    ordered = [
      %{"index" => 0, "embedding" => [1.0, 0.0]},
      %{"index" => 1, "embedding" => [0.0, 1.0]}
    ]

    {url, server} = embedding_server(ordered)

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

  test "regression: a tool-call delta packing name with a partial argument fragment still assembles" do
    # The provider packs `name` and the object's opening bytes into one delta.
    # ReqLLM's decoder runs Jason.decode/1 on that partial, fails, and falls
    # back to tool_call(name, %{}) — dropping the `{"`. Later deltas carry no
    # name, so they accumulate normally, and assembly then sees
    # `query":"onboarding"}` and rejects it as malformed. Assert on the
    # ASSEMBLED arguments: "no error event" alone passes even while the
    # opening fragment is being dropped.
    deltas = [
      ~s({"index":0,"id":"call_1","type":"function","function":{"name":"memory_recall","arguments":"{\\""}}),
      ~s({"index":0,"function":{"arguments":"query\\":\\""}}),
      ~s({"index":0,"function":{"arguments":"onboarding"}}),
      ~s({"index":0,"function":{"arguments":"\\"}"}})
    ]

    payload =
      Enum.map_join(deltas, "", fn delta ->
        ~s(data: {"id":"abc","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"index":0,"delta":{"tool_calls":[#{delta}]}}]}\n\n)
      end) <> "data: [DONE]\n\n"

    {url, server} = start_chunked_server([payload], 0)

    assert {:ok, stream} = Client.stream(req_llm_client(), request(), transport_opts(url))
    events = Enum.to_list(stream)

    refute Enum.any?(events, &match?(%StreamEvent{type: :error}, &1)),
           "tool-call assembly failed: #{inspect(events)}"

    assembled =
      events
      |> Enum.flat_map(fn
        %StreamEvent{data: %{tool_call_args: %{index: 0, fragment: fragment}}} -> [fragment]
        _ -> []
      end)
      |> Enum.join()

    # Pre-fix this is `query":"onboarding"}` — the opening `{"` never survives
    # ReqLLM's failed Jason.decode/1 on the first delta.
    assert assembled == ~s({"query":"onboarding"}),
           "tool arguments did not reassemble; got: #{inspect(assembled)}"

    assert {:ok, %{"query" => "onboarding"}} = Jason.decode(assembled)

    _ = Task.await(server, 2_000)
  end

  test "regression: a long stream of realistic chunks is not rejected by the per-event term caps" do
    # Until 2026-08-25 the per-event decoded-term caps (10_000 map keys,
    # 100_000 nodes) were also applied CUMULATIVELY over the stream. A real
    # OpenAI-style chunk carries ~9 keys, so a reasoning model's ~1,200-chunk
    # reply — the first OpenCode Zen turn of a fresh install — failed with
    # {:stream_limit_exceeded, :decoded_map_keys, 10_000}.
    chunk_count = 1_500
    chunks = for i <- 1..chunk_count, do: realistic_openai_sse("t#{i}")
    {url, server} = start_chunked_server(chunks ++ ["data: [DONE]\n\n"], 0)

    assert {:ok, stream} = Client.stream(req_llm_client(), request(), transport_opts(url))
    events = Enum.to_list(stream)

    refute Enum.any?(events, &match?(%StreamEvent{type: :error}, &1)),
           "long stream failed closed: #{inspect(Enum.filter(events, &match?(%StreamEvent{type: :error}, &1)))}"

    assert Enum.count(events, &match?(%StreamEvent{type: :delta}, &1)) == chunk_count

    _ = Task.await(server, 5_000)
  end

  @tag :stream_compatibility_regression
  test "security regression: eager streaming counts the initial tool argument prefix once" do
    chunks = tool_argument_chunks("{\"", ["value\":1}"])

    {url, server} =
      start_chunked_server(chunks, 0, "text/event-stream", 200, [], true)

    owner = self()
    ref = make_ref()
    handler = "stream-prefix-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:req_llm, :tool_call_args_lost],
        fn _event, _measurements, _metadata, pid -> send(pid, {ref, :args_lost}) end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    result =
      Client.complete_streaming(
        req_llm_client(),
        request(),
        fn _event -> :ok end,
        transport_opts(url)
      )

    wire = Task.await(server, 2_000)

    assert {:ok, %Response{} = response} = result
    assert response.finish_reason == :tool_calls

    assert [%{id: "cold_call_1", name: "cold_increment", arguments: arguments}] =
             Enum.filter(response.content_parts, &(&1.kind == :tool_call))

    assert is_binary(arguments)
    assert Jason.decode(arguments) == {:ok, %{"value" => 1}}
    assert response.usage.input_tokens == 3
    assert response.usage.output_tokens == 2
    assert response.usage.total_tokens == 5
    assert response.raw == nil
    assert wire.body["tools"] in [nil, []]
    assert wire.body["stream"] == true
    assert wire.body["model"] == "bounded-test"
    assert String.starts_with?(wire.request, "POST /v1/chat/completions HTTP/1.1\r\n")
    refute_received {^ref, :args_lost}
  end

  @tag :stream_compatibility_regression
  test "security regression: eager streaming accepts text with SDK callback-bearing tools" do
    tools = [stream_tool_schema()]
    assert [%ReqLLM.Tool{callback: callback}] = Adapter.translate_tools(tools)
    assert is_function(callback, 1)

    {url, server} =
      start_chunked_server(text_completion_chunks(), 0, "text/event-stream", 200, [], true)

    owner = self()
    ref = make_ref()

    result =
      Client.complete_streaming(
        req_llm_client(),
        %{request() | tools: tools},
        fn event -> send(owner, {ref, event}) end,
        transport_opts(url)
      )

    wire = Task.await(server, 2_000)

    assert {:ok, %Response{} = response} = result
    assert response.text == "done"
    assert response.finish_reason == :stop
    refute Enum.any?(response.content_parts, &(&1.kind == :tool_call))
    assert response.usage.input_tokens == 3
    assert response.usage.output_tokens == 2
    assert response.usage.total_tokens == 5
    assert response.raw == nil
    assert ResponseBudget.validate(response, []) == :ok
    assert_received {^ref, %StreamEvent{type: :delta, data: %{text: "done"}}}
    refute_received {^ref, _event}

    assert [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "cold_increment",
                 "parameters" => %{
                   "properties" => %{"value" => %{"type" => "integer"}},
                   "required" => ["value"]
                 }
               }
             }
           ] = wire.body["tools"]

    assert wire.body["stream"] == true
    assert wire.body["model"] == "bounded-test"
    assert String.starts_with?(wire.request, "POST /v1/chat/completions HTTP/1.1\r\n")
  end

  test "security regression: eager tool assembly still rejects malformed and incomplete JSON" do
    for tail <- ["value\":}", "value\":1"] do
      chunks = tool_argument_chunks("{\"", [tail])

      {url, server} =
        start_chunked_server(chunks, 0, "text/event-stream", 200, [], true)

      result =
        Client.complete_streaming(
          req_llm_client(),
          request(),
          fn _event -> :ok end,
          transport_opts(url)
        )

      _wire = Task.await(server, 2_000)

      assert {:error, {:invalid_tool_arguments, {:invalid_json, :malformed}}} = result
    end
  end

  test "security regression: eager tool assembly retains the argument depth ceiling" do
    nested = Enum.reduce(1..40, 0, fn _level, value -> [value] end)
    <<first::binary-size(2), rest::binary>> = Jason.encode!(%{"value" => nested})
    chunks = tool_argument_chunks(first, [rest])
    assert Enum.all?(chunks, &(byte_size(&1) < 1_024))
    assert IO.iodata_length(chunks) < 4_096

    {url, server} =
      start_chunked_server(chunks, 0, "text/event-stream", 200, [], true)

    result =
      Client.complete_streaming(
        req_llm_client(),
        request(),
        fn _event -> :ok end,
        transport_opts(url) ++ [max_response_bytes: 4_096, max_stream_event_bytes: 1_024]
      )

    _wire = Task.await(server, 2_000)

    assert {:error, {:invalid_tool_arguments, {:decoded_term_limit_exceeded, :depth, 32}}} =
             result
  end

  test "security regression: SDK tool handling does not admit executable provider metadata" do
    safe = ReqLLM.StreamChunk.meta(%{provider_meta: %{sentinel: "retained"}})
    assert {:ok, response} = BoundedStream.process(bounded_metadata_stream(safe))
    assert response.provider_meta.sentinel == "retained"

    for value <- [fn -> :untrusted end, make_ref(), self()] do
      metadata = %{provider_meta: %{untrusted: value}}

      assert {:error, {:decoded_term_invalid, :json_compatible_term_required}} =
               BoundedStream.process(bounded_metadata_stream(ReqLLM.StreamChunk.meta(metadata)))

      assert {:error, {:decoded_term_invalid, :json_compatible_term_required}} =
               ResponseBudget.validate(metadata, [])
    end
  end

  @tag :stream_prefix_ownership_regression
  test "security regression: a scalar initial argument is not replaced by a later object" do
    {url, server} =
      start_chunked_server(
        tool_argument_chunks("1", ["{\"value\":99}"]),
        0,
        "text/event-stream",
        200,
        [],
        true
      )

    ref = capture_lost_arguments()

    result =
      Client.complete_streaming(
        req_llm_client(),
        request(),
        fn _event -> :ok end,
        transport_opts(url)
      )

    wire = Task.await(server, 2_000)

    assert {:ok, %Response{} = response} = result

    assert [%{id: "cold_call_1", name: "cold_increment", arguments: arguments}] =
             Enum.filter(response.content_parts, &(&1.kind == :tool_call))

    # Preserve the SDK's existing args-lost fallback, rather than introduce a
    # different refusal policy or accept the later object as the whole call.
    assert Jason.decode(arguments) == {:ok, %{}}

    assert_received {^ref, :args_lost,
                     %{
                       reason: :json_decode_error,
                       tool_call_id: "cold_call_1",
                       tool_name: "cold_increment"
                     }}

    refute_received {^ref, :args_lost, _metadata}
    assert response.finish_reason == :tool_calls
    assert response.raw == nil
    assert wire.body["tools"] in [nil, []]
    assert wire.body["stream"] == true
    assert wire.body["model"] == "bounded-test"
    assert String.starts_with?(wire.request, "POST /v1/chat/completions HTTP/1.1\r\n")
  end

  @tag :stream_prefix_ownership_regression
  test "security regression: recovered prefix ownership remains specific to each tool index" do
    {url, server} =
      start_chunked_server(mixed_tool_argument_chunks(), 0, "text/event-stream", 200, [], true)

    ref = capture_lost_arguments()

    result =
      Client.complete_streaming(
        req_llm_client(),
        request(),
        fn _event -> :ok end,
        transport_opts(url)
      )

    wire = Task.await(server, 2_000)

    assert {:ok, %Response{} = response} = result

    assert [
             %{id: "cold_call_1", name: "cold_increment", arguments: recovered},
             %{id: "cold_scalar_1", name: "cold_increment", arguments: scalar}
           ] = Enum.filter(response.content_parts, &(&1.kind == :tool_call))

    assert Jason.decode(recovered) == {:ok, %{"value" => 1}}
    assert Jason.decode(scalar) == {:ok, %{}}

    assert_received {^ref, :args_lost,
                     %{
                       reason: :json_decode_error,
                       tool_call_id: "cold_scalar_1",
                       tool_name: "cold_increment"
                     }}

    refute_received {^ref, :args_lost, _metadata}
    assert response.finish_reason == :tool_calls
    assert response.raw == nil
    assert wire.body["tools"] in [nil, []]
    assert wire.body["stream"] == true
    assert wire.body["model"] == "bounded-test"
    assert String.starts_with?(wire.request, "POST /v1/chat/completions HTTP/1.1\r\n")
  end

  @tag :stream_prefix_ownership_regression
  test "security regression: an equal continuation does not own the initial scalar seed" do
    {url, server} =
      start_chunked_server(
        tool_argument_chunks("1", ["1"]),
        0,
        "text/event-stream",
        200,
        [],
        true
      )

    ref = capture_lost_arguments()

    result =
      Client.complete_streaming(
        req_llm_client(),
        request(),
        fn _event -> :ok end,
        transport_opts(url)
      )

    wire = Task.await(server, 2_000)

    assert {:ok, %Response{} = response} = result

    assert [%{id: "cold_call_1", name: "cold_increment", arguments: arguments}] =
             Enum.filter(response.content_parts, &(&1.kind == :tool_call))

    # Equal bytes do not establish ownership: this continuation follows the
    # scalar seed, so the existing SDK assembly is the valid JSON number 11.
    assert Jason.decode(arguments) == {:ok, 11}
    refute_received {^ref, :args_lost, _metadata}
    assert response.finish_reason == :tool_calls
    assert response.raw == nil
    assert wire.body["tools"] in [nil, []]
    assert wire.body["stream"] == true
    assert wire.body["model"] == "bounded-test"
    assert String.starts_with?(wire.request, "POST /v1/chat/completions HTTP/1.1\r\n")
  end

  defp capture_lost_arguments do
    ref = make_ref()
    handler = "stream-prefix-owner-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:req_llm, :tool_call_args_lost],
        fn _event, _measurements, metadata, {pid, tag} ->
          send(pid, {tag, :args_lost, Map.take(metadata, [:reason, :tool_call_id, :tool_name])})
        end,
        {self(), ref}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp mixed_tool_argument_chunks do
    calls = [
      %{
        "index" => 0,
        "id" => "cold_call_1",
        "type" => "function",
        "function" => %{"name" => "cold_increment", "arguments" => "{\""}
      },
      %{
        "index" => 1,
        "id" => "cold_scalar_1",
        "type" => "function",
        "function" => %{"name" => "cold_increment", "arguments" => "1"}
      },
      %{"index" => 0, "function" => %{"arguments" => "value\":1}"}},
      %{"index" => 1, "function" => %{"arguments" => "{\"value\":99}"}}
    ]

    Enum.map(calls, fn call ->
      stream_event(%{"choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [call]}}]})
    end) ++ stream_finish("tool_calls")
  end

  defp stream_tool_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => "cold_increment",
        "description" => "increment one synthetic value",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"]
        }
      }
    }
  end

  defp tool_argument_chunks(first, rest) do
    initial = %{
      "index" => 0,
      "id" => "cold_call_1",
      "type" => "function",
      "function" => %{"name" => "cold_increment", "arguments" => first}
    }

    continuations = Enum.map(rest, &%{"index" => 0, "function" => %{"arguments" => &1}})

    Enum.map([initial | continuations], fn call ->
      stream_event(%{"choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [call]}}]})
    end) ++ stream_finish("tool_calls")
  end

  defp text_completion_chunks do
    [stream_event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "done"}}]})] ++
      stream_finish("stop")
  end

  defp stream_finish(reason) do
    [
      stream_event(%{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      }),
      "data: [DONE]\n\n"
    ]
  end

  defp stream_event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"

  defp bounded_metadata_stream(chunk) do
    %BoundedStream{
      stream: [chunk],
      model: LLMDB.Model.new!(%{id: "bounded-test", provider: :openai}),
      context: ReqLLM.Context.new([]),
      limits: %{
        max_response_bytes: 16_777_216,
        max_events: 100_000,
        max_event_bytes: 1_048_576,
        max_work: 1_600_000,
        max_nodes: 100_000,
        max_depth: 32,
        max_map_keys: 10_000,
        max_list_items: 100_000
      }
    }
  end

  defp realistic_openai_sse(text) do
    Jason.encode!(%{
      "id" => "chatcmpl-regression",
      "object" => "chat.completion.chunk",
      "created" => 1_787_694_537,
      "model" => "x-preview-f-free",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"role" => "assistant", "content" => text},
          "finish_reason" => nil
        }
      ]
    })
    |> then(&("data: " <> &1 <> "\n\n"))
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
         extra_headers \\ [],
         capture_body? \\ false
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
        {:ok, body} = capture_request_body(socket, request, capture_body?)

        header_result =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Test\r\n" <>
              "content-type: #{content_type}\r\n" <>
              Enum.map_join(extra_headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end) <>
              "transfer-encoding: chunked\r\n" <>
              "connection: keep-alive\r\n\r\n"
          )

        {sent, closed?} =
          case header_result do
            :ok -> send_chunks(socket, chunks, delay, 0)
            {:error, _reason} -> {0, true}
          end

        safe_close(socket)
        result = %{sent: sent, closed?: closed?, request: request}
        if capture_body?, do: Map.put(result, :body, body), else: result
      end)

    if capture_body? do
      on_exit(fn -> stop_captured_server(task.pid, listener) end)
    end

    url = "http://127.0.0.1:#{port}/v1"

    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      "lm_studio" => [url],
      "ollama" => [url],
      "openai" => [url]
    })

    {url, task}
  end

  defp capture_request_body(_socket, _request, false), do: {:ok, nil}

  defp capture_request_body(socket, request, true) do
    [headers, body] = :binary.split(request, "\r\n\r\n")

    lengths =
      headers
      |> String.split("\r\n")
      |> Enum.drop(1)
      |> Enum.flat_map(fn header ->
        case String.split(header, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "content-length", do: [String.trim(value)], else: []

          _ ->
            []
        end
      end)

    with [length] <- lengths,
         {size, ""} when size >= 0 and size <= 65_536 <- Integer.parse(length) do
      receive_request_body(socket, body, size)
    else
      _ -> {:error, :invalid_request_content_length}
    end
  end

  defp receive_request_body(_socket, body, size) when byte_size(body) == size,
    do: Jason.decode(body)

  defp receive_request_body(socket, body, size) when byte_size(body) < size do
    case :gen_tcp.recv(socket, size - byte_size(body), 2_000) do
      {:ok, part} -> receive_request_body(socket, body <> part, size)
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_request_body(_socket, _body, _size), do: {:error, :oversized_request_body}

  defp stop_captured_server(pid, listener) do
    safe_close(listener)
    monitor = Process.monitor(pid)
    if Process.alive?(pid), do: Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      2_000 -> flunk("owned captured-request server did not stop")
    end

    Process.demonitor(monitor, [:flush])
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
