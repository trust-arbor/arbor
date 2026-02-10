defmodule Arbor.Orchestrator.UnifiedLLM.Conformance42Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{Anthropic, Gemini, OpenAI}
  alias Arbor.Orchestrator.UnifiedLLM.{Request, StreamEvent}

  test "4.2 stream returns enumerable StreamEvent values for all providers" do
    openai_request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    openai_stream = fn _req ->
      {:ok,
       [
         %{"type" => "response.created"},
         %{"type" => "response.output_text.delta", "delta" => "hello"},
         %{"type" => "response.completed", "finish_reason" => "stop", "usage" => %{}}
       ]}
    end

    assert {:ok, openai_events} =
             OpenAI.stream(openai_request, api_key: "sk-test", stream_client: openai_stream)

    assert [%StreamEvent{type: :start}, %StreamEvent{type: :delta}, %StreamEvent{type: :finish}] =
             Enum.to_list(openai_events)

    anthropic_request = %Request{
      model: "claude-sonnet-4-0",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    anthropic_stream = fn _req ->
      {:ok,
       [
         %{"type" => "message_start"},
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => "hello"}
         },
         %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
         %{"type" => "message_stop"}
       ]}
    end

    assert {:ok, anthropic_events} =
             Anthropic.stream(anthropic_request,
               api_key: "ak-test",
               stream_client: anthropic_stream
             )

    assert [%StreamEvent{type: :start}, %StreamEvent{type: :delta}, %StreamEvent{type: :finish}] =
             Enum.to_list(anthropic_events)

    gemini_request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    gemini_stream = fn _req ->
      {:ok,
       [
         %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hello"}]}}]},
         %{"candidates" => [%{"finishReason" => "STOP", "content" => %{"parts" => []}}]}
       ]}
    end

    assert {:ok, gemini_events} =
             Gemini.stream(gemini_request, api_key: "gk-test", stream_client: gemini_stream)

    assert [%StreamEvent{type: :start}, %StreamEvent{type: :delta}, %StreamEvent{type: :finish}] =
             Enum.to_list(gemini_events)
  end
end
