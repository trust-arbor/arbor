defmodule Arbor.Orchestrator.UnifiedLLM.Conformance82Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{Anthropic, Gemini, OpenAI}
  alias Arbor.Orchestrator.UnifiedLLM.{Message, ProviderError, Request, StreamEvent}

  test "8.2 adapters use native endpoints and auth headers/keys" do
    openai =
      OpenAI.build_request(
        %Request{model: "gpt-5", messages: [Message.new(:user, "hi")]},
        "sk-test",
        []
      )

    assert openai.url == "https://api.openai.com/v1/responses"

    assert Enum.any?(openai.headers, fn {k, v} ->
             k == "authorization" and String.contains?(v, "Bearer")
           end)

    anthropic =
      Anthropic.build_request(
        %Request{model: "claude-sonnet-4-0", messages: [Message.new(:user, "hi")]},
        "ak-test",
        []
      )

    assert anthropic.url == "https://api.anthropic.com/v1/messages"
    assert Enum.any?(anthropic.headers, fn {k, _} -> k == "x-api-key" end)

    gemini =
      Gemini.build_request(
        %Request{model: "gemini-2.5-pro", messages: [Message.new(:user, "hi")]},
        "gk-test",
        []
      )

    assert gemini.url =~ "/v1beta/models/gemini-2.5-pro:generateContent"
  end

  test "8.2 all five roles are translated across providers" do
    request = %Request{
      model: "demo",
      messages: [
        Message.new(:system, "system"),
        Message.new(:developer, "developer"),
        Message.new(:user, "user"),
        Message.new(:assistant, "assistant"),
        Message.new(:tool, ~s({"status":"ok","result":{"value":"x"}}), %{
          "tool_call_id" => "c1",
          "name" => "lookup"
        })
      ]
    }

    openai = OpenAI.build_request(%{request | model: "gpt-5"}, "sk-test", [])
    assert openai.body["instructions"] =~ "system"
    assert openai.body["instructions"] =~ "developer"
    assert Enum.any?(openai.body["input"], &(&1["role"] == "assistant"))

    assert Enum.any?(openai.body["input"], fn m ->
             Enum.any?(m["content"], &(&1["type"] == "function_call_output"))
           end)

    anthropic = Anthropic.build_request(%{request | model: "claude-sonnet-4-0"}, "ak-test", [])
    assert anthropic.body["system"] =~ "system"
    assert anthropic.body["system"] =~ "developer"
    assert Enum.any?(anthropic.body["messages"], &(&1["role"] == "assistant"))

    assert Enum.any?(anthropic.body["messages"], fn m ->
             Enum.any?(m["content"], &(&1["type"] == "tool_result"))
           end)

    gemini = Gemini.build_request(%{request | model: "gemini-2.5-pro"}, "gk-test", [])
    assert get_in(gemini, [:body, "systemInstruction", "parts", Access.at(0), "text"]) =~ "system"
    assert Enum.any?(gemini.body["contents"], &(&1["role"] == "model"))

    assert Enum.any?(gemini.body["contents"], fn m ->
             Enum.any?(m["parts"], &Map.has_key?(&1, "functionResponse"))
           end)
  end

  test "8.2 provider options and anthropic beta header pass through" do
    openai =
      OpenAI.build_request(
        %Request{
          model: "gpt-5",
          messages: [Message.new(:user, "hi")],
          provider_options: %{"openai" => %{"metadata" => %{"trace_id" => "t1"}}}
        },
        "sk-test",
        []
      )

    assert openai.body["metadata"]["trace_id"] == "t1"

    anthropic =
      Anthropic.build_request(
        %Request{
          model: "claude-sonnet-4-0",
          messages: [Message.new(:user, "hi")],
          provider_options: %{"anthropic" => %{"beta_headers" => ["prompt-caching-2024-07-31"]}}
        },
        "ak-test",
        []
      )

    assert Enum.any?(anthropic.headers, fn {k, v} ->
             k == "anthropic-beta" and v =~ "prompt-caching-2024-07-31"
           end)

    gemini =
      Gemini.build_request(
        %Request{
          model: "gemini-2.5-pro",
          messages: [Message.new(:user, "hi")],
          provider_options: %{"gemini" => %{"cachedContent" => "cachedContents/abc"}}
        },
        "gk-test",
        []
      )

    assert gemini.body["cachedContent"] == "cachedContents/abc"
  end

  test "8.2 stream emits typed StreamEvent values for each provider" do
    request_o = %Request{model: "gpt-5", messages: [Message.new(:user, "hi")]}

    assert {:ok, o_stream} =
             OpenAI.stream(request_o,
               api_key: "sk-test",
               stream_client: fn _ ->
                 {:ok,
                  [
                    %{"type" => "response.created"},
                    %{"type" => "response.output_text.delta", "delta" => "x"},
                    %{"type" => "response.completed", "finish_reason" => "stop"}
                  ]}
               end
             )

    assert Enum.all?(Enum.to_list(o_stream), &match?(%StreamEvent{}, &1))

    request_a = %Request{model: "claude-sonnet-4-0", messages: [Message.new(:user, "hi")]}

    assert {:ok, a_stream} =
             Anthropic.stream(request_a,
               api_key: "ak-test",
               stream_client: fn _ ->
                 {:ok,
                  [
                    %{"type" => "message_start"},
                    %{
                      "type" => "content_block_delta",
                      "delta" => %{"type" => "text_delta", "text" => "x"}
                    },
                    %{"type" => "message_stop"}
                  ]}
               end
             )

    assert Enum.all?(Enum.to_list(a_stream), &match?(%StreamEvent{}, &1))

    request_g = %Request{model: "gemini-2.5-pro", messages: [Message.new(:user, "hi")]}

    assert {:ok, g_stream} =
             Gemini.stream(request_g,
               api_key: "gk-test",
               stream_client: fn _ ->
                 {:ok,
                  [
                    %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "x"}]}}]},
                    %{
                      "candidates" => [%{"finishReason" => "STOP", "content" => %{"parts" => []}}]
                    }
                  ]}
               end
             )

    assert Enum.all?(Enum.to_list(g_stream), &match?(%StreamEvent{}, &1))
  end

  test "8.2 http errors and retry-after map to ProviderError" do
    request = %Request{model: "gpt-5", messages: [Message.new(:user, "hi")]}

    assert {:error, %ProviderError{} = error} =
             OpenAI.complete(request,
               api_key: "sk-test",
               http_client: fn _ ->
                 {:ok,
                  %{
                    status: 429,
                    headers: [{"retry-after", "2"}],
                    body: %{"error" => %{"message" => "rate limited"}}
                  }}
               end
             )

    assert error.retryable == true
    assert error.retry_after_ms == 2000
  end
end
