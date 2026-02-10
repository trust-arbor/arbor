defmodule Arbor.Orchestrator.UnifiedLLM.Conformance83Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.ContentPart
  alias Arbor.Orchestrator.UnifiedLLM.Adapters.{Anthropic, Gemini, OpenAI}
  alias Arbor.Orchestrator.UnifiedLLM.{Message, Request}

  test "8.3 text-only messages translate for all providers" do
    request = %Request{model: "demo", messages: [Message.new(:user, "hello")]}

    openai = OpenAI.build_request(%{request | model: "gpt-5"}, "sk-test", [])

    assert get_in(openai, [:body, "input", Access.at(0), "content", Access.at(0), "text"]) ==
             "hello"

    anthropic = Anthropic.build_request(%{request | model: "claude-sonnet-4-0"}, "ak-test", [])

    assert get_in(anthropic, [:body, "messages", Access.at(0), "content", Access.at(0), "text"]) ==
             "hello"

    gemini = Gemini.build_request(%{request | model: "gemini-2.5-pro"}, "gk-test", [])

    assert get_in(gemini, [:body, "contents", Access.at(0), "parts", Access.at(0), "text"]) ==
             "hello"
  end

  test "8.3 image inputs support url/base64/local-file translation" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "arbor_orchestrator_83_#{System.unique_integer([:positive])}.png"
      )

    assert :ok = File.write(tmp, <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4>>)

    message =
      Message.new(:user, [
        ContentPart.image_url("https://example.com/x.png"),
        ContentPart.image_base64(<<1, 2, 3>>, "image/png"),
        ContentPart.image_file(tmp)
      ])

    openai = OpenAI.build_request(%Request{model: "gpt-5", messages: [message]}, "sk-test", [])
    openai_parts = get_in(openai, [:body, "input", Access.at(0), "content"])
    assert Enum.count(openai_parts, &(&1["type"] == "input_image")) == 3

    anthropic =
      Anthropic.build_request(
        %Request{model: "claude-sonnet-4-0", messages: [message]},
        "ak-test",
        []
      )

    anth_parts = get_in(anthropic, [:body, "messages", Access.at(0), "content"])
    assert Enum.count(anth_parts, &(&1["type"] == "image")) == 3

    gemini =
      Gemini.build_request(%Request{model: "gemini-2.5-pro", messages: [message]}, "gk-test", [])

    gem_parts = get_in(gemini, [:body, "contents", Access.at(0), "parts"])

    assert Enum.count(
             gem_parts,
             &(Map.has_key?(&1, "fileData") or Map.has_key?(&1, "inlineData"))
           ) == 3
  end

  test "8.3 tool_call/tool_result and thinking round-trip parsing works" do
    request = %Request{model: "gpt-5", messages: [Message.new(:user, "hi")]}

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
             %{
               "type" => "function_call_output",
               "call_id" => "c1",
               "output" => "{\"ok\":true}",
               "is_error" => false
             },
             %{"type" => "reasoning", "encrypted_content" => "opaque", "signature" => "sig-r"}
           ]
         }
       }}
    end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert Enum.any?(response.content_parts, &(&1.kind == :tool_call and &1.id == "c1"))

    assert Enum.any?(
             response.content_parts,
             &(&1.kind == :tool_result and &1.tool_call_id == "c1")
           )

    assert Enum.any?(response.content_parts, &(&1.kind == :thinking and &1.redacted == true))
  end

  test "8.3 unsupported audio/document kinds are gracefully downgraded with warnings" do
    message =
      Message.new(:user, [
        ContentPart.audio_base64(<<1, 2, 3>>, "audio/wav"),
        ContentPart.document_url("https://example.com/spec.pdf")
      ])

    request = %Request{model: "gpt-5", messages: [message]}
    http_client = fn _req -> {:ok, %{status: 200, body: %{"output_text" => "ok"}}} end

    assert {:ok, response} =
             OpenAI.complete(request, api_key: "sk-test", http_client: http_client)

    assert Enum.any?(response.warnings, &String.contains?(&1, "Unsupported content kind"))
  end

  test "8.3 thinking signatures round-trip across continuation requests" do
    openai_req = %Request{model: "gpt-5", messages: [Message.new(:user, "hi")]}

    openai_http = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "output" => [
             %{
               "type" => "reasoning",
               "encrypted_content" => "opaque",
               "signature" => "sig-openai"
             }
           ]
         }
       }}
    end

    assert {:ok, openai_response} =
             OpenAI.complete(openai_req, api_key: "sk-test", http_client: openai_http)

    openai_cont =
      OpenAI.build_request(
        %Request{
          model: "gpt-5",
          messages: [Message.new(:assistant, openai_response.content_parts)]
        },
        "sk-test",
        []
      )

    openai_part = get_in(openai_cont, [:body, "input", Access.at(0), "content", Access.at(0)])
    assert openai_part["type"] == "reasoning"
    assert openai_part["signature"] == "sig-openai"

    anth_req = %Request{model: "claude-sonnet-4-0", messages: [Message.new(:user, "hi")]}

    anth_http = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "content" => [
             %{"type" => "redacted_thinking", "text" => "opaque", "signature" => "sig-anth"}
           ]
         }
       }}
    end

    assert {:ok, anth_response} =
             Anthropic.complete(anth_req, api_key: "ak-test", http_client: anth_http)

    anth_cont =
      Anthropic.build_request(
        %Request{
          model: "claude-sonnet-4-0",
          messages: [Message.new(:assistant, anth_response.content_parts)]
        },
        "ak-test",
        []
      )

    anth_part = get_in(anth_cont, [:body, "messages", Access.at(0), "content", Access.at(0)])
    assert anth_part["type"] == "redacted_thinking"
    assert anth_part["signature"] == "sig-anth"

    gem_req = %Request{model: "gemini-2.5-pro", messages: [Message.new(:user, "hi")]}

    gem_http = fn _req ->
      {:ok,
       %{
         status: 200,
         body: %{
           "candidates" => [
             %{
               "content" => %{
                 "parts" => [%{"text" => "thought", "thought" => true, "signature" => "sig-gem"}]
               }
             }
           ]
         }
       }}
    end

    assert {:ok, gem_response} =
             Gemini.complete(gem_req, api_key: "gk-test", http_client: gem_http)

    gem_cont =
      Gemini.build_request(
        %Request{
          model: "gemini-2.5-pro",
          messages: [Message.new(:assistant, gem_response.content_parts)]
        },
        "gk-test",
        []
      )

    gem_part = get_in(gem_cont, [:body, "contents", Access.at(0), "parts", Access.at(0)])
    assert gem_part["thought"] == true
    assert gem_part["signature"] == "sig-gem"
  end
end
