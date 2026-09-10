defmodule Arbor.LLM.Adapter.ReqLLMFacadeToolsRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM
  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.{Client, Message, Request, Response, Tool}
  alias Arbor.LLM.Plugs.{Dispatch, ResponseLimit}

  @moduletag :fast

  setup do
    # Requests pass through the real provider preparation and decoding. Only
    # the HTTP transport is stubbed, including in deadline-owned children.
    Req.Test.set_req_test_to_shared()
    previous_pipeline = Application.fetch_env(:arbor_llm, :pipeline)
    Application.put_env(:arbor_llm, :pipeline, [ResponseLimit, Dispatch])

    on_exit(fn ->
      case previous_pipeline do
        {:ok, pipeline} -> Application.put_env(:arbor_llm, :pipeline, pipeline)
        :error -> Application.delete_env(:arbor_llm, :pipeline)
      end
    end)

    observer = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(observer, {:http_request, conn.method, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "fixture_response",
        "object" => "chat.completion",
        "created" => 0,
        "model" => "arbor-tools-fixture",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => "Checking the fixture",
              "tool_calls" => [
                %{
                  "id" => "fixture_call",
                  "type" => "function",
                  "function" => %{
                    "name" => "lookup_fixture",
                    "arguments" => ~s({"key":"example"})
                  }
                }
              ]
            }
          }
        ],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      })
    end)

    client = Client.new(adapters: %{"openai" => Adapter}, default_provider: "openai")

    transport_opts = [
      api_key: "fixture-key-not-real",
      req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
    ]

    {:ok, client: client, transport_opts: transport_opts}
  end

  test "public generate advertises canonical facade tools through the real ReqLLM adapter", %{
    client: client,
    transport_opts: transport_opts
  } do
    observer = self()

    tool = %Tool{
      name: "lookup_fixture",
      description: "Look up an exact fixture key",
      input_schema: schema(),
      execute: fn _arguments ->
        send(observer, :unexpected_auto_execution)
        %{}
      end
    }

    assert {:ok, %Response{} = response} =
             LLM.generate(
               client: client,
               provider: "openai",
               model: "arbor-tools-fixture",
               prompt: "Use the fixture tool",
               tools: [tool],
               max_tool_rounds: 0,
               client_opts: transport_opts
             )

    assert_received {:http_request, "POST", request}

    assert [%{"type" => "function", "function" => definition}] = request["tools"]
    assert definition["name"] == tool.name
    assert definition["description"] == tool.description
    assert definition["parameters"] == schema()
    assert response.text == "Checking the fixture"
    assert response.finish_reason == :tool_calls
    assert response.usage.input_tokens == 3
    assert response.usage.output_tokens == 2
    assert response.usage.total_tokens == 5

    assert [%{kind: :tool_call, id: "fixture_call", name: "lookup_fixture"} | _] =
             response.content_parts

    refute_received :unexpected_auto_execution
    refute_received {:http_request, _, _}
  end

  test "nested tool definitions retain their existing transport representation", %{
    client: client,
    transport_opts: transport_opts
  } do
    definition = %{
      "type" => "function",
      "function" => %{
        "name" => "lookup_fixture",
        "description" => "Existing nested definition",
        "parameters" => schema()
      }
    }

    request = %Request{
      provider: "openai",
      model: "arbor-tools-fixture",
      messages: [Message.new(:user, "Use the fixture tool")],
      tools: [definition]
    }

    assert {:ok, %Response{}} = Client.complete(client, request, transport_opts)
    assert_received {:http_request, "POST", body}
    assert body["tools"] == [definition]
    refute_received {:http_request, _, _}
  end

  test "invalid canonical names and schemas remain excluded at tool validation", %{
    client: client,
    transport_opts: transport_opts
  } do
    assert {:ok, %Response{}} =
             LLM.generate(
               client: client,
               provider: "openai",
               model: "arbor-tools-fixture",
               prompt: "No valid tool definitions",
               tools: [
                 %Tool{name: "", input_schema: schema()},
                 %Tool{name: "bad_schema", input_schema: "not a schema"}
               ],
               max_tool_rounds: 0,
               client_opts: transport_opts
             )

    assert_received {:http_request, "POST", request}
    assert request["tools"] in [nil, []]
    refute_received {:http_request, _, _}
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{"key" => %{"type" => "string"}},
      "required" => ["key"],
      "additionalProperties" => false
    }
  end
end
