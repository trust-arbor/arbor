defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.OpenAICompatible
  alias Arbor.Orchestrator.UnifiedLLM.{ContentPart, Message, Request, Response}

  @moduletag :fast

  @test_config %{
    provider: "test_provider",
    base_url: "https://api.test.ai/v1",
    api_key_env: "TEST_API_KEY",
    chat_path: "/chat/completions",
    extra_headers: nil
  }

  defp mock_http(response) do
    [api_key: "test-key", http_client: fn _req -> {:ok, response} end]
  end

  defp mock_stream(events) do
    [api_key: "test-key", stream_client: fn _req -> {:ok, Stream.map(events, & &1)} end]
  end

  defp request(attrs \\ []) do
    defaults = [
      model: "test-model",
      messages: [Message.new(:user, "Hello")]
    ]

    struct!(Request, Keyword.merge(defaults, attrs))
  end

  defp success_response(content, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, nil)
    finish_reason = Keyword.get(opts, :finish_reason, "stop")

    message =
      %{"role" => "assistant", "content" => content}
      |> then(fn m ->
        if tool_calls, do: Map.put(m, "tool_calls", tool_calls), else: m
      end)

    %{
      status: 200,
      body: %{
        "choices" => [
          %{
            "message" => message,
            "finish_reason" => finish_reason
          }
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      },
      headers: []
    }
  end

  # --- Request Building ---

  describe "build_request/3" do
    test "builds standard chat completions request" do
      req = request(model: "glm-4.7", temperature: 0.5, max_tokens: 1024)
      result = OpenAICompatible.build_request(req, "test-key", @test_config)

      assert result.method == :post
      assert result.url == "https://api.test.ai/v1/chat/completions"
      assert {"authorization", "Bearer test-key"} in result.headers
      assert {"content-type", "application/json"} in result.headers
      assert result.body["model"] == "glm-4.7"
      assert result.body["temperature"] == 0.5
      assert result.body["max_tokens"] == 1024
      assert is_list(result.body["messages"])
    end

    test "omits nil optional fields" do
      req = request()
      result = OpenAICompatible.build_request(req, "key", @test_config)

      refute Map.has_key?(result.body, "temperature")
      refute Map.has_key?(result.body, "max_tokens")
      refute Map.has_key?(result.body, "tools")
      refute Map.has_key?(result.body, "tool_choice")
    end

    test "includes tools when present" do
      tools = [%{"type" => "function", "function" => %{"name" => "get_weather"}}]
      req = request(tools: tools, tool_choice: "auto")
      result = OpenAICompatible.build_request(req, "key", @test_config)

      assert result.body["tools"] == tools
      assert result.body["tool_choice"] == "auto"
    end

    test "handles no auth for local providers" do
      config = %{@test_config | api_key_env: nil, base_url: "http://localhost:1234/v1"}
      req = request()
      result = OpenAICompatible.build_request(req, nil, config)

      refute Enum.any?(result.headers, fn {k, _} -> k == "authorization" end)
      assert {"content-type", "application/json"} in result.headers
    end

    test "appends extra headers from config" do
      config = %{
        @test_config
        | extra_headers: fn _req ->
            [{"x-title", "Arbor"}, {"http-referer", "https://arbor.dev"}]
          end
      }

      req = request()
      result = OpenAICompatible.build_request(req, "key", config)

      assert {"x-title", "Arbor"} in result.headers
      assert {"http-referer", "https://arbor.dev"} in result.headers
    end

    test "uses custom chat_path" do
      config = %{@test_config | chat_path: "/api/chat"}
      req = request()
      result = OpenAICompatible.build_request(req, "key", config)

      assert result.url == "https://api.test.ai/v1/api/chat"
    end

    test "trims trailing slash from base_url" do
      config = %{@test_config | base_url: "https://api.test.ai/v1/"}
      req = request()
      result = OpenAICompatible.build_request(req, "key", config)

      assert result.url == "https://api.test.ai/v1/chat/completions"
    end

    test "merges provider_options into body" do
      req = request(provider_options: %{"test_provider" => %{"top_p" => 0.9}})
      result = OpenAICompatible.build_request(req, "key", @test_config)

      assert result.body["top_p"] == 0.9
    end
  end

  # --- Message Translation ---

  describe "message translation" do
    test "translates system message" do
      req = request(messages: [Message.new(:system, "You are helpful"), Message.new(:user, "Hi")])
      result = OpenAICompatible.build_request(req, "key", @test_config)
      messages = result.body["messages"]

      assert [%{"role" => "system", "content" => "You are helpful"}, %{"role" => "user"} | _] =
               messages
    end

    test "translates developer role to system" do
      req = request(messages: [Message.new(:developer, "Instructions")])
      result = OpenAICompatible.build_request(req, "key", @test_config)

      assert [%{"role" => "system", "content" => "Instructions"}] = result.body["messages"]
    end

    test "translates user text message" do
      req = request(messages: [Message.new(:user, "Hello world")])
      result = OpenAICompatible.build_request(req, "key", @test_config)

      assert [%{"role" => "user", "content" => "Hello world"}] = result.body["messages"]
    end

    test "translates multimodal user message" do
      content = [
        ContentPart.text("What is this?"),
        ContentPart.image_url("https://example.com/img.png")
      ]

      req = request(messages: [Message.new(:user, content)])
      result = OpenAICompatible.build_request(req, "key", @test_config)

      [msg] = result.body["messages"]
      assert msg["role"] == "user"
      assert is_list(msg["content"])
      assert [%{"type" => "text"}, %{"type" => "image_url"}] = msg["content"]
    end

    test "translates assistant message with tool calls" do
      content = [
        ContentPart.text("Let me check."),
        ContentPart.tool_call("call_1", "get_weather", %{"city" => "NYC"})
      ]

      req = request(messages: [Message.new(:assistant, content)])
      result = OpenAICompatible.build_request(req, "key", @test_config)

      [msg] = result.body["messages"]
      assert msg["role"] == "assistant"
      assert msg["content"] == "Let me check."
      assert [%{"id" => "call_1", "type" => "function", "function" => func}] = msg["tool_calls"]
      assert func["name"] == "get_weather"
    end

    test "translates tool result message" do
      msg = Message.new(:tool, "Sunny, 72F", %{tool_call_id: "call_1"})
      req = request(messages: [msg])
      result = OpenAICompatible.build_request(req, "key", @test_config)

      [chat_msg] = result.body["messages"]
      assert chat_msg["role"] == "tool"
      assert chat_msg["tool_call_id"] == "call_1"
      assert chat_msg["content"] == "Sunny, 72F"
    end
  end

  # --- Response Parsing ---

  describe "complete/3" do
    test "parses successful text response" do
      opts = mock_http(success_response("Hello from the API!"))
      {:ok, response} = OpenAICompatible.complete(request(), opts, @test_config)

      assert %Response{} = response
      assert response.text == "Hello from the API!"
      assert response.finish_reason == :stop
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 20
      assert response.usage.total_tokens == 30
    end

    test "parses response with tool calls" do
      tool_calls = [
        %{
          "id" => "call_abc",
          "type" => "function",
          "function" => %{
            "name" => "get_weather",
            "arguments" => ~s({"city": "NYC"})
          }
        }
      ]

      opts = mock_http(success_response(nil, tool_calls: tool_calls, finish_reason: "tool_calls"))
      {:ok, response} = OpenAICompatible.complete(request(), opts, @test_config)

      assert response.finish_reason == :tool_calls
      tool_parts = Enum.filter(response.content_parts, &(&1.kind == :tool_call))
      assert [%{name: "get_weather", id: "call_abc", arguments: %{"city" => "NYC"}}] = tool_parts
    end

    test "parses response with reasoning_content (Z.ai/DeepSeek)" do
      response_body = %{
        status: 200,
        body: %{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "reasoning_content" => "Let me think step by step...",
                "content" => "The answer is 42."
              },
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 15, "total_tokens" => 20}
        },
        headers: []
      }

      opts = mock_http(response_body)
      {:ok, response} = OpenAICompatible.complete(request(), opts, @test_config)

      assert response.text == "The answer is 42."
      thinking_parts = Enum.filter(response.content_parts, &(&1.kind == :thinking))
      assert [%{text: "Let me think step by step..."}] = thinking_parts
    end

    test "handles HTTP error response" do
      error_body = %{
        status: 429,
        body: %{"error" => %{"message" => "rate limited", "code" => "rate_limit_exceeded"}},
        headers: [{"retry-after", "30"}]
      }

      opts = mock_http(error_body)
      {:error, error} = OpenAICompatible.complete(request(), opts, @test_config)

      assert error.retryable == true
      assert error.retry_after_ms == 30_000
      assert error.provider == "test_provider"
    end

    test "handles transport error" do
      opts = [api_key: "test-key", http_client: fn _req -> {:error, :econnrefused} end]
      {:error, error} = OpenAICompatible.complete(request(), opts, @test_config)

      assert error.retryable == true
      assert error.provider == "test_provider"
    end

    test "returns error for missing API key" do
      {:error, error} = OpenAICompatible.complete(request(), [], @test_config)

      assert error.status == 401
    end

    test "skips API key check when api_key_env is nil" do
      config = %{@test_config | api_key_env: nil}
      opts = mock_http(success_response("works"))
      {:ok, response} = OpenAICompatible.complete(request(), opts, config)

      assert response.text == "works"
    end

    test "handles empty choices" do
      opts = mock_http(%{status: 200, body: %{"choices" => []}, headers: []})
      {:ok, response} = OpenAICompatible.complete(request(), opts, @test_config)

      assert response.text == ""
      assert response.finish_reason == :stop
    end

    test "computes total_tokens from parts when missing" do
      body = %{
        status: 200,
        body: %{
          "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
        },
        headers: []
      }

      opts = mock_http(body)
      {:ok, response} = OpenAICompatible.complete(request(), opts, @test_config)

      assert response.usage.total_tokens == 15
    end
  end

  # --- Streaming ---

  describe "stream/3" do
    test "translates text delta events" do
      events = [
        %{"choices" => [%{"delta" => %{"role" => "assistant"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => "Hello"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{"content" => " world"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = OpenAICompatible.stream(request(), opts, @test_config)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      assert length(deltas) == 2
      assert Enum.at(deltas, 0).data["text"] == "Hello"
      assert Enum.at(deltas, 1).data["text"] == " world"

      finishes = Enum.filter(collected, &(&1.type == :finish))
      assert length(finishes) == 1
      assert Enum.at(finishes, 0).data["reason"] == :stop
    end

    test "accumulates and flushes tool call deltas" do
      events = [
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "get_weather", "arguments" => ""}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "function" => %{"arguments" => ~s({"city":)}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        },
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "function" => %{"arguments" => ~s( "NYC"})}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        },
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = OpenAICompatible.stream(request(), opts, @test_config)
      collected = Enum.to_list(stream)

      tool_events = Enum.filter(collected, &(&1.type == :tool_call))
      assert length(tool_events) == 1
      tc = Enum.at(tool_events, 0).data
      assert tc["id"] == "call_1"
      assert tc["name"] == "get_weather"
      assert tc["arguments"] == ~s({"city": "NYC"})

      finishes = Enum.filter(collected, &(&1.type == :finish))
      assert [%{data: %{"reason" => :tool_calls}}] = finishes
    end

    test "handles reasoning_content delta (Z.ai thinking)" do
      events = [
        %{
          "choices" => [
            %{"delta" => %{"reasoning_content" => "Thinking..."}, "finish_reason" => nil}
          ]
        },
        %{"choices" => [%{"delta" => %{"content" => "Answer"}, "finish_reason" => nil}]},
        %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
      ]

      opts = mock_stream(events)
      {:ok, stream} = OpenAICompatible.stream(request(), opts, @test_config)
      collected = Enum.to_list(stream)

      deltas = Enum.filter(collected, &(&1.type == :delta))
      thinking = Enum.find(deltas, &Map.has_key?(&1.data, "thinking"))
      assert thinking.data["thinking"] == "Thinking..."
    end

    test "returns error for missing stream_client" do
      {:error, error} = OpenAICompatible.stream(request(), [], @test_config)

      assert error.provider == "test_provider"
    end
  end

  # --- Stream Request ---

  describe "build_stream_request/3" do
    test "adds stream: true to body" do
      req = request()
      result = OpenAICompatible.build_stream_request(req, "key", @test_config)

      assert result.body["stream"] == true
      assert result.body["model"] == "test-model"
    end
  end

  # --- Unsupported Content Warnings ---

  describe "unsupported content warnings" do
    test "warns about unsupported content kinds" do
      content = [
        ContentPart.text("Hello"),
        ContentPart.audio_url("https://example.com/audio.wav"),
        ContentPart.document_url("https://example.com/doc.pdf")
      ]

      req = request(messages: [Message.new(:user, content)])
      opts = mock_http(success_response("ok"))
      {:ok, response} = OpenAICompatible.complete(req, opts, @test_config)

      assert length(response.warnings) == 2
      assert Enum.any?(response.warnings, &String.contains?(&1, "audio"))
      assert Enum.any?(response.warnings, &String.contains?(&1, "document"))
    end

    test "no warnings for supported content" do
      req = request(messages: [Message.new(:user, "Hello")])
      opts = mock_http(success_response("ok"))
      {:ok, response} = OpenAICompatible.complete(req, opts, @test_config)

      assert response.warnings == []
    end
  end
end
