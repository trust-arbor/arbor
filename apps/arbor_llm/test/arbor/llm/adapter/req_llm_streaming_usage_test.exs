defmodule Arbor.LLM.Adapter.ReqLLMStreamingUsageTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Adapter.ReqLLM.BoundedStream
  alias Arbor.LLM.Plugs.Usage
  alias Arbor.LLM.Request

  @event [:arbor, :llm, :usage]
  @moduletag :fast

  defmodule FakeBoundedDispatch do
    use Arbor.LLM.Plug

    alias Arbor.LLM.Call
    alias Arbor.LLM.Adapter.ReqLLM.BoundedStream

    def call(%Call{operation: :stream, result: nil} = call) do
      send(
        Application.fetch_env!(:arbor_llm, :streaming_usage_test_pid),
        {:pipeline_event_id, call.metadata.event_id}
      )

      %{
        call
        | result:
            {:ok, bounded_stream(Application.get_env(:arbor_llm, :streaming_usage_test_mode))}
      }
    end

    def call(%Call{} = call), do: call

    defp bounded_stream(:process_error) do
      %{bounded_stream(:success) | stream: [{:arbor_stream_error, :transport_failed}]}
    end

    defp bounded_stream(:missing_usage) do
      %{
        bounded_stream(:success)
        | stream: [ReqLLM.StreamChunk.text("answer"), ReqLLM.StreamChunk.meta(%{usage: %{}})]
      }
    end

    defp bounded_stream(_mode) do
      %BoundedStream{
        stream: [
          ReqLLM.StreamChunk.text("answer"),
          ReqLLM.StreamChunk.meta(%{
            usage: %{input_tokens: 4, output_tokens: 3, total_tokens: 7},
            finish_reason: :stop
          })
        ],
        model: LLMDB.Model.new!(%{id: "gpt-4", provider: :openai}),
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
  end

  setup do
    original_pipeline = Application.get_env(:arbor_llm, :pipeline)
    original_pid = Application.get_env(:arbor_llm, :streaming_usage_test_pid)
    original_mode = Application.get_env(:arbor_llm, :streaming_usage_test_mode)
    Application.put_env(:arbor_llm, :pipeline, [FakeBoundedDispatch, Usage])
    Application.put_env(:arbor_llm, :streaming_usage_test_pid, self())
    Application.delete_env(:arbor_llm, :streaming_usage_test_mode)

    handler_id = "streaming-usage-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:usage_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(:pipeline, original_pipeline)
      restore_env(:streaming_usage_test_pid, original_pid)
      restore_env(:streaming_usage_test_mode, original_mode)
    end)

    :ok
  end

  test "complete_streaming accounts only after the bounded final response crosses the boundary" do
    request = %Request{provider: "openai", model: "gpt-4"}
    test_pid = self()
    callback = fn event -> send(test_pid, {:callback, event}) end

    assert {:ok, response} = Adapter.complete_streaming(request, callback)
    assert response.text == "answer"
    assert response.usage.input_tokens == 4
    assert response.usage.output_tokens == 3

    assert_receive {:callback, %Arbor.LLM.StreamEvent{type: :delta, data: %{text: "answer"}}}
    assert_receive {:pipeline_event_id, event_id}

    assert_receive {:usage_event, @event, measurements, metadata}
    assert measurements == %{count: 1, input: 4, output: 3, total: 7, cached: 0}

    assert metadata == %{
             event_id: event_id,
             source: :req_llm,
             operation: :complete,
             provider: "openai",
             model: "gpt-4",
             usage_status: :authoritative
           }

    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "a final response rejected by Boundary emits no usage" do
    request = %Request{provider: "openai", model: "gpt-4"}

    assert {:error, _reason} =
             Adapter.complete_streaming(request, fn _event -> :ok end, max_response_bytes: 1)

    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "bounded stream transport or assembly errors emit no usage" do
    Application.put_env(:arbor_llm, :streaming_usage_test_mode, :process_error)
    request = %Request{provider: "openai", model: "gpt-4"}

    assert {:error, _reason} = Adapter.complete_streaming(request, fn _event -> :ok end)
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "callback failure emits no usage" do
    request = %Request{provider: "openai", model: "gpt-4"}
    callback = fn _event -> raise "callback rejected" end

    assert {:error, _reason} = Adapter.complete_streaming(request, callback)
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "adapter eager completion emits no usage when final usage is missing" do
    Application.put_env(:arbor_llm, :streaming_usage_test_mode, :missing_usage)
    request = %Request{provider: "openai", model: "gpt-4"}

    assert {:ok, _response} = Adapter.complete_streaming(request, fn _event -> :ok end)
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "lazy stream accounts only after full accepted collection" do
    alias Arbor.LLM.Client
    alias Arbor.LLM.Plugs.Usage.AccountedStream

    request = %Request{provider: "openai", model: "gpt-4"}

    assert %AccountedStream{} = partial = Adapter.stream(request)
    assert_receive {:pipeline_event_id, _partial_event_id}
    refute_receive {:usage_event, @event, _, _}, 50

    # Partial consumption must not bill.
    assert [%Arbor.LLM.StreamEvent{type: :delta} | _] = Enum.take(partial, 1)
    refute_receive {:usage_event, @event, _, _}, 50

    assert %AccountedStream{} = full_stream = Adapter.stream(request)
    assert_receive {:pipeline_event_id, event_id}

    assert {:ok, response} = Client.collect_stream(full_stream)
    assert response.text == "answer"
    assert response.usage.input_tokens == 4
    assert response.usage.output_tokens == 3

    assert_receive {:usage_event, @event, measurements, metadata}
    assert measurements == %{count: 1, input: 4, output: 3, total: 7, cached: 0}

    assert metadata == %{
             event_id: event_id,
             source: :req_llm,
             operation: :complete,
             provider: "openai",
             model: "gpt-4",
             usage_status: :authoritative
           }

    # Exactly once for this collection.
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "lazy stream rejected by Boundary emits no usage" do
    alias Arbor.LLM.Client

    request = %Request{provider: "openai", model: "gpt-4"}
    stream = Adapter.stream(request)
    flush_pipeline_event_ids()

    assert {:error, _reason} = Client.collect_stream(stream, max_response_bytes: 1)
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "lazy stream with missing usage emits no observation" do
    alias Arbor.LLM.Client

    Application.put_env(:arbor_llm, :streaming_usage_test_mode, :missing_usage)
    request = %Request{provider: "openai", model: "gpt-4"}
    stream = Adapter.stream(request)
    flush_pipeline_event_ids()

    assert {:ok, _response} = Client.collect_stream(stream)
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "Client.stream preserves provenance through OwnedStream for collect_stream" do
    alias Arbor.LLM.Client

    client =
      Client.new(
        default_provider: "openai",
        adapters: %{"openai" => Adapter}
      )

    request = %Request{provider: "openai", model: "gpt-4"}

    assert {:ok, stream} = Client.stream(client, request)
    assert_receive {:pipeline_event_id, event_id}

    # Middleware-style Stream.each must not strip peelable provenance.
    assert {:ok, response} =
             stream
             |> Stream.each(fn _ -> :ok end)
             |> Client.collect_stream()

    assert response.text == "answer"
    assert_receive {:usage_event, @event, %{input: 4, output: 3, total: 7}, metadata}
    assert metadata.event_id == event_id
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "repeated collect_stream on the same replayable wrapper emits usage once" do
    alias Arbor.LLM.Client
    alias Arbor.LLM.StreamEvent

    provenance =
      Usage.streaming_provenance(
        Arbor.LLM.Call.new(:stream, {LLMDB.Model.new!(%{id: "gpt-4", provider: :openai}), [], []})
      )

    events = [
      %StreamEvent{type: :delta, data: %{text: "answer"}},
      %StreamEvent{
        type: :step_finish,
        data: %{
          usage: %{input_tokens: 4, output_tokens: 3, total_tokens: 7},
          finish_reason: :stop
        }
      }
    ]

    stream = Usage.accounted_stream(events, provenance)

    assert {:ok, first} = Client.collect_stream(stream)
    assert first.text == "answer"
    assert_receive {:usage_event, @event, %{input: 4, output: 3, total: 7}, _}

    # Same wrapper, discarded finalize map — atomics gate must suppress second bill.
    assert {:ok, second} = Client.collect_stream(stream)
    assert second.text == "answer"
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "concurrent collect_stream on the same replayable wrapper emits usage once" do
    alias Arbor.LLM.Client
    alias Arbor.LLM.StreamEvent

    provenance =
      Usage.streaming_provenance(
        Arbor.LLM.Call.new(:stream, {LLMDB.Model.new!(%{id: "gpt-4", provider: :openai}), [], []})
      )

    events = [
      %StreamEvent{type: :delta, data: %{text: "answer"}},
      %StreamEvent{
        type: :step_finish,
        data: %{
          usage: %{input_tokens: 4, output_tokens: 3, total_tokens: 7},
          finish_reason: :stop
        }
      }
    ]

    stream = Usage.accounted_stream(events, provenance)

    tasks =
      for _ <- 1..8 do
        Task.async(fn -> Client.collect_stream(stream) end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.all?(results, &match?({:ok, %Arbor.LLM.Response{text: "answer"}}, &1))

    assert_receive {:usage_event, @event, %{input: 4, output: 3, total: 7}, _}
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "error after step_finish usage suppresses usage finalization" do
    alias Arbor.LLM.Client
    alias Arbor.LLM.StreamEvent

    provenance =
      Usage.streaming_provenance(
        Arbor.LLM.Call.new(:stream, {LLMDB.Model.new!(%{id: "gpt-4", provider: :openai}), [], []})
      )

    events = [
      %StreamEvent{type: :delta, data: %{text: "answer"}},
      %StreamEvent{
        type: :step_finish,
        data: %{
          usage: %{input_tokens: 4, output_tokens: 3, total_tokens: 7},
          finish_reason: :stop
        }
      },
      %StreamEvent{type: :error, data: %{reason: :transport_failed}}
    ]

    stream = Usage.accounted_stream(events, provenance)

    assert {:ok, response} = Client.collect_stream(stream)
    assert response.text == "answer"
    assert response.usage.input_tokens == 4
    assert response.warnings != []
    refute_receive {:usage_event, @event, _, _}, 50
  end

  defp flush_pipeline_event_ids do
    receive do
      {:pipeline_event_id, _} -> flush_pipeline_event_ids()
    after
      0 -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_llm, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_llm, key, value)
end
