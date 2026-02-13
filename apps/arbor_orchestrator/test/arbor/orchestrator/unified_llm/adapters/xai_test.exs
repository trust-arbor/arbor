defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.XAITest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.XAI
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request, Response}

  @moduletag :fast

  defp mock_http(response) do
    [api_key: "xai-test-key", http_client: fn _req -> {:ok, response} end]
  end

  defp mock_stream(events) do
    [api_key: "xai-test-key", stream_client: fn _req -> {:ok, Stream.map(events, & &1)} end]
  end

  defp request(attrs \\ []) do
    defaults = [
      model: "grok-4-1-fast",
      messages: [Message.new(:user, "Hello")]
    ]

    struct!(Request, Keyword.merge(defaults, attrs))
  end

  defp success_response(content) do
    %{
      status: 200,
      body: %{
        "choices" => [%{"message" => %{"content" => content}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 10, "total_tokens" => 15}
      },
      headers: []
    }
  end

  describe "XAI adapter" do
    test "provider name" do
      assert XAI.provider() == "xai"
    end

    test "completes successfully" do
      opts = mock_http(success_response("Hello from Grok!"))
      {:ok, response} = XAI.complete(request(), opts)

      assert %Response{} = response
      assert response.text == "Hello from Grok!"
      assert response.finish_reason == :stop
    end

    test "uses x.ai API endpoint" do
      opts = [
        api_key: "xai-test",
        http_client: fn req ->
          assert req.url == "https://api.x.ai/v1/chat/completions"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = XAI.complete(request(), opts)
    end

    test "passes model through" do
      opts = [
        api_key: "xai-test",
        http_client: fn req ->
          assert req.body["model"] == "grok-3-mini-fast"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = XAI.complete(request(model: "grok-3-mini-fast"), opts)
    end

    test "passes provider_options through" do
      opts = [
        api_key: "xai-test",
        http_client: fn req ->
          assert req.body["reasoning_effort"] == "high"
          {:ok, success_response("ok")}
        end
      ]

      req =
        request(
          model: "grok-3-mini",
          provider_options: %{
            "xai" => %{"reasoning_effort" => "high"}
          }
        )

      {:ok, _} = XAI.complete(req, opts)
    end

    test "streams text deltas" do
      events = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => " from Grok"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = XAI.stream(request(), opts)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      assert length(deltas) == 2
      assert Enum.at(deltas, 0).data["text"] == "Hello"
    end

    test "returns error for missing API key" do
      original = System.get_env("XAI_API_KEY")
      if original, do: System.delete_env("XAI_API_KEY")

      try do
        {:error, error} = XAI.complete(request(), [])
        assert error.status == 401
        assert String.contains?(error.message, "XAI_API_KEY")
      after
        if original, do: System.put_env("XAI_API_KEY", original)
      end
    end

    test "handles tool calls" do
      tool_calls = [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "search", "arguments" => ~s({"query": "elixir"})}
        }
      ]

      response = %{
        status: 200,
        body: %{
          "choices" => [
            %{
              "message" => %{"content" => nil, "tool_calls" => tool_calls},
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 10, "total_tokens" => 15}
        },
        headers: []
      }

      opts = mock_http(response)
      {:ok, resp} = XAI.complete(request(), opts)

      assert resp.finish_reason == :tool_calls
      tool_parts = Enum.filter(resp.content_parts, &(&1.kind == :tool_call))
      assert [%{name: "search", arguments: %{"query" => "elixir"}}] = tool_parts
    end
  end

  describe "client auto-discovery" do
    test "XAI adapter is discoverable" do
      Code.ensure_loaded!(XAI)
      assert function_exported?(XAI, :provider, 0)
      assert function_exported?(XAI, :complete, 2)
      assert function_exported?(XAI, :stream, 2)
    end
  end
end
