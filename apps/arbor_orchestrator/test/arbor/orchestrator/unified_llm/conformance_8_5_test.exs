defmodule Arbor.Orchestrator.UnifiedLLM.Conformance85Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{Anthropic, Gemini, OpenAI}
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request}

  test "8.5 openai maps reasoning_tokens and reasoning_effort" do
    request = %Request{
      model: "gpt-5",
      reasoning_effort: "high",
      messages: [Message.new(:user, "hi")]
    }

    built = OpenAI.build_request(request, "sk-test", [])
    assert built.body["reasoning"] == %{"effort" => "high"}

    http_client = fn _ ->
      {:ok,
       %{
         status: 200,
         body: %{
           "output_text" => "ok",
           "usage" => %{
             "input_tokens" => 10,
             "output_tokens" => 5,
             "total_tokens" => 15,
             "output_tokens_details" => %{"reasoning_tokens" => 3}
           }
         }
       }}
    end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert response.usage.reasoning_tokens == 3
  end

  test "8.5 anthropic thinking blocks become thinking content parts and estimated reasoning tokens" do
    request = %Request{model: "claude-sonnet-4-0", messages: [Message.new(:user, "hi")]}

    http_client = fn _ ->
      {:ok,
       %{
         status: 200,
         body: %{
           "content" => [
             %{"type" => "thinking", "text" => "step one step two", "signature" => "sig-think"},
             %{"type" => "text", "text" => "answer"}
           ],
           "usage" => %{"input_tokens" => 9, "output_tokens" => 7}
         }
       }}
    end

    assert {:ok, response} =
             Anthropic.complete(request, api_key: "ak-test", http_client: http_client)

    assert Enum.any?(
             response.content_parts,
             &(&1.kind == :thinking and &1.signature == "sig-think")
           )

    assert response.usage.reasoning_tokens == 4
  end

  test "8.5 gemini maps thoughtsTokenCount to reasoning_tokens" do
    request = %Request{model: "gemini-2.5-pro", messages: [Message.new(:user, "hi")]}

    http_client = fn _ ->
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}],
           "usageMetadata" => %{
             "promptTokenCount" => 6,
             "candidatesTokenCount" => 4,
             "totalTokenCount" => 10,
             "thoughtsTokenCount" => 2
           }
         }
       }}
    end

    assert {:ok, response} =
             Gemini.complete(request, api_key: "gk-test", http_client: http_client)

    assert response.usage.reasoning_tokens == 2
  end
end
