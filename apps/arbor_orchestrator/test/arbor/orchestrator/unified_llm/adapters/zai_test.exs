defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.ZaiTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{Zai, ZaiCodingPlan}
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request, Response}

  @moduletag :fast

  defp mock_http(response) do
    [api_key: "test-zai-key", http_client: fn _req -> {:ok, response} end]
  end

  defp mock_stream(events) do
    [api_key: "test-zai-key", stream_client: fn _req -> {:ok, Stream.map(events, & &1)} end]
  end

  defp request(attrs \\ []) do
    defaults = [model: "glm-4.7", messages: [Message.new(:user, "Hello")]]
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

  # --- Zai (General) ---

  describe "Zai adapter" do
    test "provider name" do
      assert Zai.provider() == "zai"
    end

    test "completes successfully" do
      opts = mock_http(success_response("Hello from GLM!"))
      {:ok, response} = Zai.complete(request(), opts)

      assert %Response{} = response
      assert response.text == "Hello from GLM!"
      assert response.finish_reason == :stop
    end

    test "uses general API endpoint" do
      opts = [
        api_key: "test-key",
        http_client: fn req ->
          assert req.url == "https://api.z.ai/api/paas/v4/chat/completions"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = Zai.complete(request(), opts)
    end

    test "passes model through" do
      opts = [
        api_key: "test-key",
        http_client: fn req ->
          assert req.body["model"] == "glm-4.7-flash"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = Zai.complete(request(model: "glm-4.7-flash"), opts)
    end

    test "handles reasoning_content in response" do
      response = %{
        status: 200,
        body: %{
          "choices" => [
            %{
              "message" => %{
                "reasoning_content" => "Step 1: analyze...",
                "content" => "The answer is 42."
              },
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 20, "total_tokens" => 25}
        },
        headers: []
      }

      opts = mock_http(response)
      {:ok, resp} = Zai.complete(request(), opts)

      assert resp.text == "The answer is 42."
      thinking = Enum.filter(resp.content_parts, &(&1.kind == :thinking))
      assert [%{text: "Step 1: analyze..."}] = thinking
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
      {:ok, resp} = Zai.complete(request(), opts)

      assert resp.finish_reason == :tool_calls
      tool_parts = Enum.filter(resp.content_parts, &(&1.kind == :tool_call))
      assert [%{name: "search", arguments: %{"query" => "elixir"}}] = tool_parts
    end

    test "streams text deltas" do
      events = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = Zai.stream(request(), opts)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      assert length(deltas) == 2
      assert Enum.at(deltas, 0).data["text"] == "Hello"
    end

    test "returns error for missing API key" do
      # Temporarily unset env var in case it's configured
      original = System.get_env("ZAI_API_KEY")
      if original, do: System.delete_env("ZAI_API_KEY")

      try do
        {:error, error} = Zai.complete(request(), [])
        assert error.status == 401
        assert String.contains?(error.message, "ZAI_API_KEY")
      after
        if original, do: System.put_env("ZAI_API_KEY", original)
      end
    end

    test "handles rate limiting" do
      error_resp = %{
        status: 429,
        body: %{"error" => %{"message" => "rate limited"}},
        headers: [{"retry-after", "5"}]
      }

      opts = mock_http(error_resp)
      {:error, error} = Zai.complete(request(), opts)

      assert error.retryable == true
      assert error.retry_after_ms == 5000
    end
  end

  # --- ZaiCodingPlan ---

  describe "ZaiCodingPlan adapter" do
    test "provider name" do
      assert ZaiCodingPlan.provider() == "zai_coding_plan"
    end

    test "completes successfully" do
      opts = mock_http(success_response("Generated code"))
      {:ok, response} = ZaiCodingPlan.complete(request(), opts)

      assert response.text == "Generated code"
    end

    test "uses coding plan endpoint" do
      opts = [
        api_key: "test-coding-key",
        http_client: fn req ->
          assert req.url == "https://api.z.ai/api/coding/paas/v4/chat/completions"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = ZaiCodingPlan.complete(request(), opts)
    end

    test "error message references correct env var" do
      {:error, error} = ZaiCodingPlan.complete(request(), [])
      assert String.contains?(error.message, "ZAI_CODING_PLAN_API_KEY")
    end

    test "streams through coding plan endpoint" do
      events = [
        %{"choices" => [%{"delta" => %{"content" => "def foo"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = ZaiCodingPlan.stream(request(), opts)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      assert [%{data: %{"text" => "def foo"}}] = deltas
    end
  end

  # --- Client Auto-Discovery ---

  describe "client auto-discovery" do
    test "Zai adapter is discoverable" do
      Code.ensure_loaded!(Zai)
      assert function_exported?(Zai, :provider, 0)
      assert function_exported?(Zai, :complete, 2)
      assert function_exported?(Zai, :stream, 2)
    end

    test "ZaiCodingPlan adapter is discoverable" do
      Code.ensure_loaded!(ZaiCodingPlan)
      assert function_exported?(ZaiCodingPlan, :provider, 0)
      assert function_exported?(ZaiCodingPlan, :complete, 2)
      assert function_exported?(ZaiCodingPlan, :stream, 2)
    end
  end
end
