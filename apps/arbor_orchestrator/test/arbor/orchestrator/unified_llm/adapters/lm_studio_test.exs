defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.LMStudioTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.LMStudio
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request, Response}

  @moduletag :fast

  defp mock_http(response) do
    [http_client: fn _req -> {:ok, response} end]
  end

  defp mock_stream(events) do
    [stream_client: fn _req -> {:ok, Stream.map(events, & &1)} end]
  end

  defp request(attrs \\ []) do
    defaults = [
      model: "llama-3.2-3b-instruct",
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

  describe "LM Studio adapter" do
    test "provider name" do
      assert LMStudio.provider() == "lm_studio"
    end

    test "completes successfully" do
      opts = mock_http(success_response("Hello from LM Studio!"))
      {:ok, response} = LMStudio.complete(request(), opts)

      assert %Response{} = response
      assert response.text == "Hello from LM Studio!"
      assert response.finish_reason == :stop
    end

    test "uses default localhost endpoint" do
      opts = [
        http_client: fn req ->
          assert req.url == "http://localhost:1234/v1/chat/completions"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = LMStudio.complete(request(), opts)
    end

    test "uses configured base_url" do
      Application.put_env(:arbor_orchestrator, :lm_studio,
        base_url: "http://192.168.1.50:1234/v1"
      )

      opts = [
        http_client: fn req ->
          assert req.url == "http://192.168.1.50:1234/v1/chat/completions"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = LMStudio.complete(request(), opts)
    after
      Application.delete_env(:arbor_orchestrator, :lm_studio)
    end

    test "does not send authorization header" do
      opts = [
        http_client: fn req ->
          header_names = Enum.map(req.headers, fn {name, _} -> name end)
          refute "authorization" in header_names
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = LMStudio.complete(request(), opts)
    end

    test "passes model through" do
      opts = [
        http_client: fn req ->
          assert req.body["model"] == "qwen2.5-coder-7b"
          {:ok, success_response("ok")}
        end
      ]

      {:ok, _} = LMStudio.complete(request(model: "qwen2.5-coder-7b"), opts)
    end

    test "passes provider_options through" do
      opts = [
        http_client: fn req ->
          assert req.body["repeat_penalty"] == 1.1
          {:ok, success_response("ok")}
        end
      ]

      req =
        request(
          provider_options: %{
            "lm_studio" => %{"repeat_penalty" => 1.1}
          }
        )

      {:ok, _} = LMStudio.complete(req, opts)
    end

    test "streams text deltas" do
      events = [
        %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => " local"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = LMStudio.stream(request(), opts)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      assert length(deltas) == 2
      assert Enum.at(deltas, 0).data["text"] == "Hello"
    end

    test "handles tool calls" do
      tool_calls = [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "get_weather", "arguments" => ~s({"city": "SF"})}
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
      {:ok, resp} = LMStudio.complete(request(), opts)

      assert resp.finish_reason == :tool_calls
      tool_parts = Enum.filter(resp.content_parts, &(&1.kind == :tool_call))
      assert [%{name: "get_weather", arguments: %{"city" => "SF"}}] = tool_parts
    end
  end

  describe "client auto-discovery" do
    test "LM Studio adapter is discoverable" do
      Code.ensure_loaded!(LMStudio)
      assert function_exported?(LMStudio, :provider, 0)
      assert function_exported?(LMStudio, :complete, 2)
      assert function_exported?(LMStudio, :stream, 2)
      assert function_exported?(LMStudio, :available?, 0)
    end
  end
end
