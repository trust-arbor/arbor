defmodule Arbor.LLM.Adapter.ReqLLMReasoningDetailsTest do
  use ExUnit.Case, async: true

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Adapter.ReqLLM.BoundedStream
  alias Arbor.LLM.Request

  @moduletag :fast

  test "regression: OpenRouter wire reasoning details survive streamed response assembly" do
    model = LLMDB.Model.new!(%{id: "openrouter/free", provider: :openrouter})

    events = [
      %{
        "choices" => [
          %{
            "delta" => %{
              "reasoning_details" => [
                %{"type" => "reasoning.text", "text" => "Synthetic reasoning."},
                %{"type" => "reasoning.encrypted", "data" => "opaque ciphertext"}
              ]
            }
          }
        ]
      },
      %{"choices" => [%{"delta" => %{"content" => "CHAT_"}}]},
      %{"choices" => [%{"delta" => %{"content" => "OK"}, "finish_reason" => "stop"}]},
      %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 3, "total_tokens" => 7}
      }
    ]

    chunks =
      Enum.flat_map(events, fn data ->
        ReqLLM.Provider.Defaults.default_decode_stream_event(%{data: data}, model)
      end)

    stream = %BoundedStream{
      stream: chunks,
      model: model,
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

    test_pid = self()

    assert {:ok, response} =
             BoundedStream.process(stream, on_result: &send(test_pid, {:delta, &1}))

    assert_receive {:delta, "CHAT_"}
    assert_receive {:delta, "OK"}

    result = Adapter.translate_response(response, request())

    assert result.text == "CHAT_OK"
    assert result.reasoning_content == "Synthetic reasoning."
    assert result.finish_reason == :stop
    assert result.usage.input_tokens == 4
    assert result.usage.output_tokens == 3
    assert Enum.any?(result.content_parts, &(&1.kind == :text and &1.text == "CHAT_OK"))
  end

  test "mixed typed and wire details retain only explicit binary text in order" do
    details = [
      %ReqLLM.Message.ReasoningDetails{text: "Typed text", signature: "opaque signature"},
      %{"type" => "reasoning.text", "text" => "Wire text", "signature" => "opaque signature"},
      %{"type" => "reasoning.encrypted", "data" => "opaque ciphertext"},
      %ReqLLM.Message.ReasoningDetails{signature: "opaque signature"},
      %{"text" => nil},
      %{"text" => 42},
      %{"text" => ["not text"]},
      nil
    ]

    result = Adapter.translate_response(response(details), request())

    assert result.text == "Final answer"
    assert result.reasoning_content == "Typed text\nWire text"

    assert Enum.filter(result.content_parts, &(&1.kind == :thinking)) == [
             Arbor.LLM.ContentPart.thinking("Typed text\nWire text")
           ]
  end

  test "non-text reasoning details preserve the thinking-content fallback" do
    details = [
      %{"type" => "reasoning.encrypted", "data" => "opaque ciphertext"},
      %{"text" => %{"nested" => "not text"}},
      %ReqLLM.Message.ReasoningDetails{text: 42},
      %ReqLLM.Message.ReasoningDetails{text: nil}
    ]

    response = response(details)

    message = %{
      response.message
      | content: [
          %ReqLLM.Message.ContentPart{type: :thinking, text: "Fallback thought"}
          | response.message.content
        ]
    }

    result = Adapter.translate_response(%{response | message: message}, request())

    assert result.text == "Final answer"
    assert result.reasoning_content == "Fallback thought"
  end

  test "opaque reasoning details do not become display text when no fallback exists" do
    details = [
      %{"type" => "reasoning.encrypted", "data" => "opaque ciphertext"},
      %{"signature" => "opaque signature"},
      %{"text" => ""},
      %{"text" => false}
    ]

    result = Adapter.translate_response(response(details), request())

    assert result.text == "Final answer"
    assert result.reasoning_content == nil
    refute Enum.any?(result.content_parts, &(&1.kind == :thinking))
  end

  defp request, do: %Request{provider: "openrouter", model: "openrouter/free"}

  defp response(details) do
    %ReqLLM.Response{
      id: "synthetic-response",
      model: "openrouter/free",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Final answer"}],
        reasoning_details: details
      },
      stream?: false,
      usage: %{},
      finish_reason: :stop,
      provider_meta: %{}
    }
  end
end
