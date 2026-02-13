defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenRouter
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request, Response}

  @moduletag :fast

  defp mock_http(response) do
    [api_key: "sk-or-test-key", http_client: fn _req -> {:ok, response} end]
  end

  defp mock_stream(events) do
    [api_key: "sk-or-test-key", stream_client: fn _req -> {:ok, Stream.map(events, & &1)} end]
  end

  defp request(attrs \\ []) do
    defaults = [
      model: "arcee-ai/trinity-large-preview:free",
      messages: [Message.new(:user, "Hi")]
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

  describe "OpenRouter adapter" do
    test "provider name" do
      assert OpenRouter.provider() == "openrouter"
    end

    test "completes successfully" do
      opts = mock_http(success_response("Hello from OpenRouter!"))
      {:ok, response} = OpenRouter.complete(request(), opts)

      assert %Response{} = response
      assert response.text == "Hello from OpenRouter!"
      assert response.finish_reason == :stop
    end

    test "uses OpenRouter API endpoint" do
      opts = [
        api_key: "sk-or-test",
        http_client: fn req ->
          assert req.url == "https://openrouter.ai/api/v1/chat/completions"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = OpenRouter.complete(request(), opts)
    end

    test "passes provider/model format through" do
      opts = [
        api_key: "sk-or-test",
        http_client: fn req ->
          assert req.body["model"] == "anthropic/claude-3.5-sonnet"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = OpenRouter.complete(request(model: "anthropic/claude-3.5-sonnet"), opts)
    end

    test "passes provider_options through" do
      opts = [
        api_key: "sk-or-test",
        http_client: fn req ->
          assert req.body["route"] == "fallback"
          assert req.body["transforms"] == ["middle-out"]
          {:ok, success_response("ok")}
        end
      ]

      req =
        request(
          provider_options: %{
            "openrouter" => %{
              "route" => "fallback",
              "transforms" => ["middle-out"]
            }
          }
        )

      {:ok, _} = OpenRouter.complete(req, opts)
    end

    test "includes attribution headers when configured" do
      Application.put_env(:arbor_orchestrator, :openrouter,
        app_referer: "https://arbor.dev",
        app_title: "Arbor"
      )

      opts = [
        api_key: "sk-or-test",
        http_client: fn req ->
          headers_map = Map.new(req.headers)
          assert headers_map["HTTP-Referer"] == "https://arbor.dev"
          assert headers_map["X-Title"] == "Arbor"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = OpenRouter.complete(request(), opts)
    after
      Application.delete_env(:arbor_orchestrator, :openrouter)
    end

    test "omits attribution headers when not configured" do
      Application.delete_env(:arbor_orchestrator, :openrouter)

      opts = [
        api_key: "sk-or-test",
        http_client: fn req ->
          header_names = Enum.map(req.headers, fn {name, _} -> name end)
          refute "HTTP-Referer" in header_names
          refute "X-Title" in header_names
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = OpenRouter.complete(request(), opts)
    end

    test "streams text deltas" do
      events = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = OpenRouter.stream(request(), opts)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      assert length(deltas) == 2
      assert Enum.at(deltas, 0).data["text"] == "Hello"
    end

    test "returns error for missing API key" do
      original = System.get_env("OPENROUTER_API_KEY")
      if original, do: System.delete_env("OPENROUTER_API_KEY")

      try do
        {:error, error} = OpenRouter.complete(request(), [])
        assert error.status == 401
        assert String.contains?(error.message, "OPENROUTER_API_KEY")
      after
        if original, do: System.put_env("OPENROUTER_API_KEY", original)
      end
    end

    test "handles rate limiting" do
      error_resp = %{
        status: 429,
        body: %{"error" => %{"message" => "rate limited"}},
        headers: [{"retry-after", "10"}]
      }

      opts = mock_http(error_resp)
      {:error, error} = OpenRouter.complete(request(), opts)

      assert error.retryable == true
      assert error.retry_after_ms == 10_000
    end
  end

  describe "client auto-discovery" do
    test "OpenRouter adapter is discoverable" do
      Code.ensure_loaded!(OpenRouter)
      assert function_exported?(OpenRouter, :provider, 0)
      assert function_exported?(OpenRouter, :complete, 2)
      assert function_exported?(OpenRouter, :stream, 2)
    end
  end
end
