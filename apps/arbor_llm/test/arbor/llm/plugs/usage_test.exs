defmodule Arbor.LLM.Plugs.UsageTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Usage

  @event [:arbor, :llm, :usage]
  @moduletag :fast

  setup do
    handler_id = "usage-test-#{System.unique_integer([:positive])}"
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

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "extracts complete usage and authoritative response cost" do
    result =
      {:ok,
       response(%{
         input_tokens: 11,
         output_tokens: 7,
         total_tokens: 18,
         cached_tokens: 2,
         total_cost: 0.42
       })}

    call = Usage.call(build_call(:complete, result))

    assert_receive {:usage_event, @event, measurements, metadata}

    assert measurements == %{
             count: 1,
             input: 11,
             output: 7,
             total: 18,
             cached: 2,
             marginal_cost_usd: 0.42
           }

    assert metadata.source == :req_llm
    assert metadata.operation == :complete
    assert metadata.provider == "openai"
    assert metadata.model == "gpt-4"
    assert metadata.usage_status == :authoritative
    assert is_binary(metadata.event_id)
    assert byte_size(metadata.event_id) <= 64
    assert call.metadata.usage_emitted
  end

  for operation <- [:embed_cloud, :embed_local] do
    test "extracts #{operation} usage" do
      result = {:ok, [%{index: 0, embedding: [0.1, 0.2]}], %{prompt_tokens: 5, total_tokens: 5}}
      Usage.call(build_call(unquote(operation), result, embed_model()))

      assert_receive {:usage_event, @event, %{input: 5, output: 0, total: 5, cached: 0}, metadata}
      assert metadata.operation == unquote(operation)
      assert metadata.usage_status == :authoritative
    end
  end

  test "emits bounded observations for missing, invalid, negative, and oversized usage" do
    results = [
      response(%{}),
      response(%{input_tokens: "secret"}),
      response(%{input_tokens: -1, output_tokens: 1}),
      response(%{input_tokens: 1_000_000_001, output_tokens: 0})
    ]

    Enum.each(results, fn response ->
      Usage.call(build_call(:complete, {:ok, response}))
      assert_receive {:usage_event, @event, measurements, %{usage_status: status}}
      assert status in [:missing, :invalid]
      assert measurements == %{count: 1, input: 0, output: 0, total: 0, cached: 0}
    end)
  end

  test "skips halted replay results and streaming calls" do
    halted =
      build_call(:complete, {:ok, response(%{input_tokens: 1, output_tokens: 1})}) |> Call.halt()

    Usage.call(halted)
    Usage.call(build_call(:stream, {:ok, response(%{input_tokens: 1, output_tokens: 1})}))

    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "streaming finalizer emits only authoritative usage and preserves event id" do
    event_id = "stream-event-123"
    call = build_call(:stream, {:ok, :bounded_stream}) |> Call.put_metadata(%{event_id: event_id})
    response = arbor_response(%{input_tokens: 4, output_tokens: 3, total_tokens: 7})

    state = Usage.finalize_streaming(response, Usage.streaming_provenance(call))

    assert_receive {:usage_event, @event, %{input: 4, output: 3, total: 7}, metadata}

    assert metadata == %{
             event_id: event_id,
             source: :req_llm,
             operation: :complete,
             provider: "openai",
             model: "gpt-4",
             usage_status: :authoritative
           }

    assert state.usage_finalized?
    assert state.usage_emitted?

    Usage.finalize_streaming(response, state)
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "streaming finalizer emits nothing for missing or invalid usage" do
    for usage <- [%{}, %{input_tokens: "not-a-count"}, %{input_tokens: -1, output_tokens: 1}] do
      state = Usage.streaming_provenance(build_call(:stream, {:ok, :bounded_stream}))
      Usage.finalize_streaming(arbor_response(usage), state)
      refute_receive {:usage_event, @event, _, _}, 50
    end
  end

  test "streaming finalizer emits nothing for halted or replayed provenance" do
    halted =
      build_call(:stream, {:ok, :bounded_stream})
      |> Call.halt()
      |> Usage.streaming_provenance()

    replayed =
      build_call(:stream, {:ok, :bounded_stream})
      |> Call.put_metadata(%{replayed_from: "bounded-fixture"})
      |> Usage.streaming_provenance()

    response = arbor_response(%{input_tokens: 4, output_tokens: 3, total_tokens: 7})
    Usage.finalize_streaming(response, halted)
    Usage.finalize_streaming(response, replayed)

    refute_receive {:usage_event, @event, _, _}, 50

    live_after_invalid =
      build_call(:stream, {:ok, :bounded_stream})
      |> Call.put_metadata(%{fixture_invalid: true})
      |> Usage.streaming_provenance()

    refute live_after_invalid.replayed?
    Usage.finalize_streaming(response, live_after_invalid)
    assert_receive {:usage_event, @event, %{input: 4, output: 3, total: 7}, _}
  end

  test "calling the final plug twice emits once for the stamped invocation" do
    call = build_call(:complete, {:ok, response(%{input_tokens: 2, output_tokens: 3})})
    Usage.call(call) |> Usage.call()

    assert_receive {:usage_event, @event, %{input: 2, output: 3}, _}
    refute_receive {:usage_event, @event, _, _}, 50
  end

  test "telemetry is closed and contains no prompt or response material" do
    prompt = "prompt-secret-should-never-appear"

    call =
      Call.new(:complete, {model(), [%{role: :user, content: prompt}], []})
      |> Map.put(:result, {:ok, response(%{input_tokens: 1, output_tokens: 1})})

    Usage.call(call)
    assert_receive {:usage_event, @event, measurements, metadata}
    assert Enum.sort(Map.keys(measurements)) == [:cached, :count, :input, :output, :total]

    assert Map.keys(metadata) |> Enum.sort() == [
             :event_id,
             :model,
             :operation,
             :provider,
             :source,
             :usage_status
           ]

    refute :erlang.term_to_binary({measurements, metadata}) =~ prompt
  end

  defp build_call(operation, result, model \\ model()) do
    Call.new(operation, {model, [], []})
    |> Map.put(:result, result)
  end

  defp model do
    LLMDB.Model.new!(%{id: "gpt-4", provider: :openai})
  end

  defp embed_model do
    LLMDB.Model.new!(%{id: "text-embedding-3-small", provider: :openai})
  end

  defp response(usage) do
    %ReqLLM.Response{
      id: "resp-test",
      model: "gpt-4",
      context: ReqLLM.Context.new([]),
      message: nil,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }
  end

  defp arbor_response(usage) do
    %Arbor.LLM.Response{text: "answer", usage: usage}
  end
end
