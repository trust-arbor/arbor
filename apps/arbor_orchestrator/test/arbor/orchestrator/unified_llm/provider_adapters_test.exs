defmodule Arbor.Orchestrator.UnifiedLLM.ProviderAdaptersTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.ContentPart
  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{Anthropic, Gemini, OpenAI}
  alias Arbor.Orchestrator.UnifiedLLM.{ProviderError, Request, StreamEvent}

  test "openai adapter targets responses api and maps successful response" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    parent = self()

    http_client = fn req ->
      send(parent, {:openai_req, req})
      {:ok, %{status: 200, body: %{"output_text" => "hello"}}}
    end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert response.text == "hello"

    assert_receive {:openai_req, req}
    assert req.url == "https://api.openai.com/v1/responses"

    assert Enum.any?(req.headers, fn {k, v} ->
             k == "authorization" and String.starts_with?(v, "Bearer ")
           end)
  end

  test "openai adapter parses tool-call and reasoning response parts" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{
               "type" => "message",
               "content" => [%{"type" => "output_text", "text" => "hello"}]
             },
             %{
               "type" => "function_call",
               "call_id" => "c1",
               "name" => "lookup",
               "arguments" => "{\"q\":\"x\"}"
             },
             %{"type" => "reasoning", "encrypted_content" => "opaque", "signature" => "sig-r"}
           ]
         }
       }}
    end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert response.text == "hello"
    assert Enum.any?(response.content_parts, &(&1.kind == :tool_call and &1.id == "c1"))

    assert Enum.any?(
             response.content_parts,
             &(&1.kind == :thinking and &1.redacted == true and &1.signature == "sig-r")
           )
  end

  test "openai adapter maps usage including reasoning and cache read tokens" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "output_text" => "hello",
           "usage" => %{
             "prompt_tokens" => 100,
             "completion_tokens" => 20,
             "total_tokens" => 120,
             "prompt_tokens_details" => %{"cached_tokens" => 80},
             "output_tokens_details" => %{"reasoning_tokens" => 7}
           }
         }
       }}
    end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert response.usage.input_tokens == 100
    assert response.usage.output_tokens == 20
    assert response.usage.total_tokens == 120
    assert response.usage.reasoning_tokens == 7
    assert response.usage.cache_read_tokens == 80
  end

  test "openai adapter maps responses-style usage keys (input/output tokens)" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "output_text" => "hello",
           "usage" => %{
             "input_tokens" => 9,
             "output_tokens" => 4,
             "total_tokens" => 13,
             "input_tokens_details" => %{"cached_tokens" => 3},
             "output_tokens_details" => %{"reasoning_tokens" => 2}
           }
         }
       }}
    end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert response.usage.input_tokens == 9
    assert response.usage.output_tokens == 4
    assert response.usage.total_tokens == 13
    assert response.usage.reasoning_tokens == 2
    assert response.usage.cache_read_tokens == 3
  end

  test "anthropic adapter includes beta header when configured" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}],
      provider_options: %{"anthropic" => %{"beta" => ["prompt-caching-2024-07-31"]}}
    }

    parent = self()

    http_client = fn req ->
      send(parent, {:anthropic_req, req})
      {:ok, %{status: 200, body: %{"content" => [%{"type" => "text", "text" => "ok"}]}}}
    end

    assert {:ok, response} =
             Anthropic.complete(request,
               api_key: "ak-test",
               http_client: http_client
             )

    assert response.text == "ok"
    assert_receive {:anthropic_req, req}
    assert req.url == "https://api.anthropic.com/v1/messages"

    assert Enum.any?(req.headers, fn {k, v} ->
             k == "anthropic-beta" and v =~ "prompt-caching-2024-07-31"
           end)
  end

  test "anthropic adapter accepts beta_headers and merges provider options into body" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}],
      provider_options: %{
        "anthropic" => %{
          "beta_headers" => ["interleaved-thinking-2025-05-14"],
          "thinking" => %{"type" => "enabled", "budget_tokens" => 1000}
        }
      }
    }

    built = Anthropic.build_request(request, "ak-test", [])

    assert Enum.any?(built.headers, fn {k, v} ->
             k == "anthropic-beta" and v =~ "interleaved-thinking-2025-05-14"
           end)

    assert built.body["thinking"] == %{"type" => "enabled", "budget_tokens" => 1000}
  end

  test "anthropic adapter parses tool/thinking content blocks" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "content" => [
             %{"type" => "text", "text" => "ok"},
             %{"type" => "tool_use", "id" => "c2", "name" => "lookup", "input" => %{"q" => "x"}},
             %{"type" => "redacted_thinking", "text" => "opaque", "signature" => "sig-1"}
           ]
         }
       }}
    end

    assert {:ok, response} =
             Anthropic.complete(request, api_key: "ak-test", http_client: http_client)

    assert response.text == "ok"
    assert Enum.any?(response.content_parts, &(&1.kind == :tool_call and &1.id == "c2"))

    assert Enum.any?(
             response.content_parts,
             &(&1.kind == :thinking and &1.signature == "sig-1" and &1.redacted == true)
           )
  end

  test "anthropic adapter maps stop_reason and usage fields" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "stop_reason" => "tool_use",
           "usage" => %{
             "input_tokens" => 40,
             "output_tokens" => 10,
             "cache_read_input_tokens" => 25,
             "cache_creation_input_tokens" => 30
           },
           "content" => [
             %{"type" => "tool_use", "id" => "c2", "name" => "lookup", "input" => %{"q" => "x"}}
           ]
         }
       }}
    end

    assert {:ok, response} =
             Anthropic.complete(request, api_key: "ak-test", http_client: http_client)

    assert response.finish_reason == :tool_calls
    assert response.usage.input_tokens == 40
    assert response.usage.output_tokens == 10
    assert response.usage.total_tokens == 50
    assert response.usage.cache_read_tokens == 25
    assert response.usage.cache_write_tokens == 30
  end

  test "anthropic adapter extracts system/developer instructions and normalizes roles" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :system, content: "system rules"},
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :developer, content: "developer rules"},
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "user question"},
        %Arbor.Orchestrator.UnifiedLLM.Message{
          role: :tool,
          content: "tool result",
          metadata: %{"name" => "search"}
        }
      ]
    }

    built = Anthropic.build_request(request, "ak-test", [])
    body = built.body

    assert body["system"] =~ "system rules"
    assert body["system"] =~ "developer rules"
    assert Enum.map(body["messages"], & &1["role"]) == ["user", "user"]
    assert Enum.at(body["messages"], 1)["content"] |> hd() |> Map.get("text") =~ "[tool search]"
  end

  test "anthropic adapter maps tool role with tool_call_id to tool_result block" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [
        %Arbor.Orchestrator.UnifiedLLM.Message{
          role: :tool,
          content: ~s({"status":"ok","result":{"value":"x"}}),
          metadata: %{"tool_call_id" => "c77", "name" => "lookup"}
        }
      ]
    }

    built = Anthropic.build_request(request, "ak-test", [])
    part = get_in(built, [:body, "messages", Access.at(0), "content", Access.at(0)])
    assert part["type"] == "tool_result"
    assert part["tool_use_id"] == "c77"
    assert part["is_error"] == false
  end

  test "openai adapter maps text+image parts to native input content" do
    message = %Arbor.Orchestrator.UnifiedLLM.Message{
      role: :user,
      content: [
        ContentPart.text("look at this"),
        ContentPart.image_url("https://example.com/image.png", detail: "high")
      ]
    }

    built = OpenAI.build_request(%Request{model: "gpt-5", messages: [message]}, "sk-test", [])
    parts = built.body["input"] |> hd() |> Map.get("content")

    assert Enum.at(parts, 0) == %{"type" => "input_text", "text" => "look at this"}
    assert Enum.at(parts, 1)["type"] == "input_image"
    assert Enum.at(parts, 1)["image_url"] == "https://example.com/image.png"
    assert Enum.at(parts, 1)["detail"] == "high"
  end

  test "openai adapter extracts system/developer messages into instructions" do
    request = %Request{
      model: "gpt-5",
      messages: [
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :system, content: "system rules"},
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :developer, content: "developer rules"},
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "user question"}
      ]
    }

    built = OpenAI.build_request(request, "sk-test", [])
    assert built.body["instructions"] =~ "system rules"
    assert built.body["instructions"] =~ "developer rules"
    assert length(built.body["input"]) == 1
    assert get_in(built, [:body, "input", Access.at(0), "role"]) == "user"
  end

  test "openai adapter maps tool role with tool_call_id to function_call_output" do
    request = %Request{
      model: "gpt-5",
      messages: [
        %Arbor.Orchestrator.UnifiedLLM.Message{
          role: :tool,
          content: ~s({"status":"error","error":"boom"}),
          metadata: %{"tool_call_id" => "c88", "name" => "lookup"}
        }
      ]
    }

    built = OpenAI.build_request(request, "sk-test", [])
    part = get_in(built, [:body, "input", Access.at(0), "content", Access.at(0)])
    assert get_in(built, [:body, "input", Access.at(0), "role"]) == "user"
    assert part["type"] == "function_call_output"
    assert part["call_id"] == "c88"
    assert part["is_error"] == true
  end

  test "openai adapter merges provider options into request body" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}],
      provider_options: %{
        "openai" => %{
          "reasoning" => %{"effort" => "high"},
          "metadata" => %{"trace_id" => "abc-123"}
        }
      }
    }

    built = OpenAI.build_request(request, "sk-test", [])
    assert built.body["reasoning"] == %{"effort" => "high"}
    assert built.body["metadata"] == %{"trace_id" => "abc-123"}
  end

  test "openai adapter maps reasoning_effort to reasoning.effort" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}],
      reasoning_effort: "medium"
    }

    built = OpenAI.build_request(request, "sk-test", [])
    assert built.body["reasoning"] == %{"effort" => "medium"}
  end

  test "gemini adapter maps local image file to inlineData" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_img_#{System.unique_integer([:positive])}.png"
      )

    assert :ok = File.write(tmp, <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4>>)

    message = %Arbor.Orchestrator.UnifiedLLM.Message{
      role: :user,
      content: [ContentPart.image_file(tmp)]
    }

    built =
      Gemini.build_request(%Request{model: "gemini-2.5-pro", messages: [message]}, "gk-test", [])

    part = built.body["contents"] |> hd() |> Map.get("parts") |> hd()

    assert Map.has_key?(part, "inlineData")
    assert part["inlineData"]["mimeType"] == "image/png"
    assert is_binary(part["inlineData"]["data"])
  end

  test "gemini adapter extracts system/developer messages into systemInstruction" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :system, content: "system rules"},
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :developer, content: "developer rules"},
        %Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "user question"}
      ]
    }

    built = Gemini.build_request(request, "gk-test", [])

    assert get_in(built, [:body, "systemInstruction", "parts", Access.at(0), "text"]) =~
             "system rules"

    assert get_in(built, [:body, "systemInstruction", "parts", Access.at(0), "text"]) =~
             "developer rules"

    assert length(built.body["contents"]) == 1
    assert get_in(built, [:body, "contents", Access.at(0), "role"]) == "user"
  end

  test "gemini adapter maps tool role with metadata into functionResponse" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [
        %Arbor.Orchestrator.UnifiedLLM.Message{
          role: :tool,
          content: ~s({"status":"ok","result":{"value":"x"}}),
          metadata: %{"tool_call_id" => "c99", "name" => "lookup"}
        }
      ]
    }

    built = Gemini.build_request(request, "gk-test", [])

    fr =
      get_in(built, [:body, "contents", Access.at(0), "parts", Access.at(0), "functionResponse"])

    assert fr["id"] == "c99"
    assert fr["name"] == "lookup"
    assert fr["response"]["is_error"] == false
  end

  test "gemini adapter merges provider options into request body" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}],
      provider_options: %{
        "gemini" => %{
          "safetySettings" => [
            %{"category" => "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold" => "BLOCK_NONE"}
          ],
          "cachedContent" => "cachedContents/abc"
        }
      }
    }

    built = Gemini.build_request(request, "gk-test", [])
    assert built.body["cachedContent"] == "cachedContents/abc"
    assert is_list(built.body["safetySettings"])
  end

  test "adapters gracefully degrade unsupported content kinds to text markers" do
    message = %Arbor.Orchestrator.UnifiedLLM.Message{
      role: :user,
      content: [ContentPart.audio_base64(<<1, 2, 3, 4>>, "audio/wav")]
    }

    openai = OpenAI.build_request(%Request{model: "gpt-5", messages: [message]}, "sk-test", [])
    openai_part = openai.body["input"] |> hd() |> Map.get("content") |> hd()
    assert openai_part["type"] == "input_text"
    assert openai_part["text"] =~ "[unsupported part audio]"

    anthropic =
      Anthropic.build_request(
        %Request{model: "claude-sonnet-4-0", messages: [message]},
        "ak-test",
        []
      )

    anth_part = anthropic.body["messages"] |> hd() |> Map.get("content") |> hd()
    assert anth_part["type"] == "text"
    assert anth_part["text"] =~ "[unsupported part audio]"

    gemini =
      Gemini.build_request(%Request{model: "gemini-2.5-pro", messages: [message]}, "gk-test", [])

    gem_part = gemini.body["contents"] |> hd() |> Map.get("parts") |> hd()
    assert gem_part["text"] =~ "[unsupported part audio]"
  end

  test "adapters degrade unsupported document parts to text markers" do
    message = %Arbor.Orchestrator.UnifiedLLM.Message{
      role: :user,
      content: [ContentPart.document_url("https://example.com/spec.pdf")]
    }

    openai = OpenAI.build_request(%Request{model: "gpt-5", messages: [message]}, "sk-test", [])
    openai_part = openai.body["input"] |> hd() |> Map.get("content") |> hd()
    assert openai_part["type"] == "input_text"
    assert openai_part["text"] =~ "[unsupported part document]"

    anthropic =
      Anthropic.build_request(
        %Request{model: "claude-sonnet-4-0", messages: [message]},
        "ak-test",
        []
      )

    anth_part = anthropic.body["messages"] |> hd() |> Map.get("content") |> hd()
    assert anth_part["type"] == "text"
    assert anth_part["text"] =~ "[unsupported part document]"

    gemini =
      Gemini.build_request(%Request{model: "gemini-2.5-pro", messages: [message]}, "gk-test", [])

    gem_part = gemini.body["contents"] |> hd() |> Map.get("parts") |> hd()
    assert gem_part["text"] =~ "[unsupported part document]"
  end

  test "adapters return warnings for downgraded unsupported kinds" do
    message = %Arbor.Orchestrator.UnifiedLLM.Message{
      role: :user,
      content: [ContentPart.audio_base64(<<1, 2, 3, 4>>, "audio/wav")]
    }

    request = %Request{model: "gpt-5", messages: [message]}

    http_client = fn _req ->
      {:ok, %{status: 200, body: %{"output_text" => "ok"}}}
    end

    assert {:ok, openai_response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert Enum.any?(openai_response.warnings, &String.contains?(&1, "Unsupported content kind"))

    anth_req = %Request{model: "claude-sonnet-4-0", messages: [message]}

    anth_http = fn _req ->
      {:ok, %{status: 200, body: %{"content" => [%{"type" => "text", "text" => "ok"}]}}}
    end

    assert {:ok, anth_response} =
             Anthropic.complete(anth_req, api_key: "ak-test", http_client: anth_http)

    assert Enum.any?(anth_response.warnings, &String.contains?(&1, "Unsupported content kind"))

    gem_req = %Request{model: "gemini-2.5-pro", messages: [message]}

    gem_http = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "ok"}]}}]}
       }}
    end

    assert {:ok, gem_response} =
             Gemini.complete(gem_req, api_key: "gk-test", http_client: gem_http)

    assert Enum.any?(gem_response.warnings, &String.contains?(&1, "Unsupported content kind"))
  end

  test "gemini adapter targets native generateContent endpoint" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    parent = self()

    http_client = fn req ->
      send(parent, {:gemini_req, req})

      {:ok,
       %{
         status: 200,
         body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hello gemini"}]}}]}
       }}
    end

    assert {:ok, response} =
             Gemini.complete(request, api_key: "gk-test", http_client: http_client)

    assert response.text == "hello gemini"

    assert_receive {:gemini_req, req}

    assert req.url =~
             "generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent"
  end

  test "gemini adapter parses functionCall/functionResponse/thinking parts" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [
             %{
               "content" => %{
                 "parts" => [
                   %{"text" => "hello"},
                   %{
                     "functionCall" => %{
                       "id" => "c3",
                       "name" => "lookup",
                       "args" => %{"q" => "x"}
                     }
                   },
                   %{"functionResponse" => %{"id" => "c3", "response" => %{"content" => "done"}}},
                   %{"text" => "thought", "thought" => true, "signature" => "sig-g"}
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:ok, response} =
             Gemini.complete(request, api_key: "gk-test", http_client: http_client)

    assert response.text == "hello"
    assert Enum.any?(response.content_parts, &(&1.kind == :tool_call and &1.id == "c3"))

    assert Enum.any?(
             response.content_parts,
             &(&1.kind == :tool_result and &1.tool_call_id == "c3")
           )

    assert Enum.any?(response.content_parts, &(&1.kind == :thinking and &1.signature == "sig-g"))
  end

  test "gemini adapter preserves functionResponse name on parse and serialize" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [
             %{
               "content" => %{
                 "parts" => [
                   %{
                     "functionResponse" => %{
                       "id" => "c55",
                       "name" => "lookup",
                       "response" => %{"content" => "done"}
                     }
                   }
                 ]
               }
             }
           ]
         }
       }}
    end

    assert {:ok, parsed} = Gemini.complete(request, api_key: "gk-test", http_client: http_client)
    tool_result = Enum.find(parsed.content_parts, &(&1.kind == :tool_result))
    assert tool_result.name == "lookup"

    message = %Arbor.Orchestrator.UnifiedLLM.Message{role: :assistant, content: [tool_result]}

    built =
      Gemini.build_request(%Request{model: "gemini-2.5-pro", messages: [message]}, "gk-test", [])

    part =
      get_in(built, [:body, "contents", Access.at(0), "parts", Access.at(0), "functionResponse"])

    assert part["name"] == "lookup"
  end

  test "gemini adapter maps finish reason and usage metadata" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [
             %{"finishReason" => "MAX_TOKENS", "content" => %{"parts" => [%{"text" => "hello"}]}}
           ],
           "usageMetadata" => %{
             "promptTokenCount" => 11,
             "candidatesTokenCount" => 22,
             "totalTokenCount" => 33,
             "thoughtsTokenCount" => 4,
             "cachedContentTokenCount" => 7
           }
         }
       }}
    end

    assert {:ok, response} =
             Gemini.complete(request, api_key: "gk-test", http_client: http_client)

    assert response.finish_reason == :length
    assert response.usage.input_tokens == 11
    assert response.usage.output_tokens == 22
    assert response.usage.total_tokens == 33
    assert response.usage.reasoning_tokens == 4
    assert response.usage.cache_read_tokens == 7
  end

  test "gemini adapter maps image-specific finish reasons to content_filter" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [
             %{
               "finishReason" => "IMAGE_SAFETY",
               "content" => %{"parts" => [%{"text" => "blocked"}]}
             }
           ]
         }
       }}
    end

    assert {:ok, response} =
             Gemini.complete(request, api_key: "gk-test", http_client: http_client)

    assert response.finish_reason == :content_filter
  end

  test "http errors map retryable and retry-after on provider error" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    http_client = fn _req ->
      {:ok,
       %{
         status: 429,
         headers: [{"retry-after", "3"}],
         body: %{"error" => %{"message" => "rate limited", "code" => "rate_limit"}}
       }}
    end

    assert {:error, %ProviderError{} = error} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert error.retryable == true
    assert error.retry_after_ms == 3000
    assert error.code == "rate_limit"
  end

  test "missing api key maps to auth provider error" do
    request = %Request{model: "gpt-5", messages: []}

    assert {:error, %ProviderError{} = error} = OpenAI.complete(request, api_key: "")
    assert error.status == 401
    assert error.retryable == false
  end

  test "openai adapter stream maps responses events to stream events" do
    request = %Request{
      model: "gpt-5",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    stream_client = fn _req ->
      {:ok,
       [
         %{"type" => "response.created"},
         %{"type" => "response.output_text.delta", "delta" => "hel"},
         %{"type" => "response.output_text.delta", "delta" => "lo"},
         %{
           "type" => "response.function_call_arguments.delta",
           "call_id" => "c1",
           "name" => "lookup",
           "delta" => "{\"q\":\"x\"}"
         },
         %{
           "type" => "response.completed",
           "finish_reason" => "stop",
           "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}
         }
       ]}
    end

    assert {:ok, events} =
             OpenAI.stream(request,
               api_key: "sk-test",
               stream_client: stream_client
             )

    mapped = Enum.to_list(events)
    assert %StreamEvent{type: :start} = Enum.at(mapped, 0)
    assert %StreamEvent{type: :delta, data: %{"text" => "hel"}} = Enum.at(mapped, 1)
    assert %StreamEvent{type: :delta, data: %{"text" => "lo"}} = Enum.at(mapped, 2)
    assert %StreamEvent{type: :tool_call, data: %{"id" => "c1"}} = Enum.at(mapped, 3)
    assert %StreamEvent{type: :finish, data: %{"reason" => :stop}} = List.last(mapped)
  end

  test "anthropic adapter stream maps content deltas and finish" do
    request = %Request{
      model: "claude-sonnet-4-0",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    stream_client = fn _req ->
      {:ok,
       [
         %{"type" => "message_start"},
         %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => "hel"}
         },
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => "lo"}},
         %{
           "type" => "message_delta",
           "delta" => %{"stop_reason" => "end_turn"},
           "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
         },
         %{"type" => "message_stop"}
       ]}
    end

    assert {:ok, events} =
             Anthropic.stream(request,
               api_key: "ak-test",
               stream_client: stream_client
             )

    mapped = Enum.to_list(events)
    assert %StreamEvent{type: :start} = Enum.at(mapped, 0)
    assert %StreamEvent{type: :delta, data: %{"text" => "hel"}} = Enum.at(mapped, 1)
    assert %StreamEvent{type: :delta, data: %{"text" => "lo"}} = Enum.at(mapped, 2)
    assert %StreamEvent{type: :finish, data: %{"reason" => :stop}} = List.last(mapped)
  end

  test "gemini adapter stream maps chunk deltas tool calls and finish" do
    request = %Request{
      model: "gemini-2.5-pro",
      messages: [%Arbor.Orchestrator.UnifiedLLM.Message{role: :user, content: "hi"}]
    }

    stream_client = fn _req ->
      {:ok,
       [
         %{
           "candidates" => [
             %{
               "content" => %{
                 "parts" => [
                   %{"text" => "hel"},
                   %{
                     "functionCall" => %{
                       "id" => "c1",
                       "name" => "lookup",
                       "args" => %{"q" => "x"}
                     }
                   }
                 ]
               }
             }
           ]
         },
         %{
           "candidates" => [
             %{"finishReason" => "STOP", "content" => %{"parts" => [%{"text" => "lo"}]}}
           ],
           "usageMetadata" => %{
             "promptTokenCount" => 1,
             "candidatesTokenCount" => 2,
             "totalTokenCount" => 3
           }
         }
       ]}
    end

    assert {:ok, events} =
             Gemini.stream(request,
               api_key: "gk-test",
               stream_client: stream_client
             )

    mapped = Enum.to_list(events)
    assert %StreamEvent{type: :start} = Enum.at(mapped, 0)
    assert Enum.any?(mapped, &match?(%StreamEvent{type: :delta, data: %{"text" => "hel"}}, &1))
    assert Enum.any?(mapped, &match?(%StreamEvent{type: :tool_call, data: %{"id" => "c1"}}, &1))
    assert %StreamEvent{type: :finish, data: %{"reason" => :stop}} = List.last(mapped)
  end
end
