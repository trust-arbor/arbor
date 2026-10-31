defmodule Arbor.LLM.ToolLoopHostDefaultsTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.{Client, ContentPart, Message, Request, Response, ToolLoop}
  alias Arbor.LLM.TestSupport.TransportContract

  @moduletag :fast

  defmodule Executor do
    def definitions do
      send(Application.fetch_env!(:arbor_llm, :test_host_executor_owner), :host_definitions)

      [
        %{
          "type" => "function",
          "function" => %{
            "name" => "host_effect",
            "description" => "owned test effect",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        }
      ]
    end

    def execute("host_effect", %{}, _workdir, _opts) do
      send(Application.fetch_env!(:arbor_llm, :test_host_executor_owner), :host_effect)
      {:ok, "effect"}
    end
  end

  defmodule Adapter do
    @behaviour Arbor.LLM.ProviderAdapter
    def provider, do: "host_default_fixture"

    def complete(request, _opts) do
      send(
        Application.fetch_env!(:arbor_llm, :test_host_executor_owner),
        {:host_adapter, request.tools}
      )

      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "done", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "",
           finish_reason: :tool_calls,
           raw: %{},
           content_parts: [ContentPart.tool_call("host_call", "host_effect", %{})]
         }}
      end
    end
  end

  setup do
    keys = [:tool_executor, :tool_invocation_auditor, :test_host_executor_owner]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:arbor_llm, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    Application.delete_env(:arbor_llm, :tool_executor)
    Application.put_env(:arbor_llm, :tool_invocation_auditor, :disabled)
    Application.put_env(:arbor_llm, :test_host_executor_owner, self())

    TransportContract.setup([
      TransportContract.route(Adapter.provider(), "fixture", :public, nil)
    ])

    :ok
  end

  test "missing and unavailable default executors return before provider or tool effects" do
    for setting <- [nil, false, "untrusted-module", __MODULE__.Unavailable] do
      Application.put_env(:arbor_llm, :tool_executor, setting)
      assert {:error, :tool_executor_unavailable} = ToolLoop.run(client(), request(), tools: [])
      refute_received {:host_adapter, _}
      refute_received :host_effect
    end
  end

  test "the host-selected default supplies definitions and executes the actual tool round" do
    Application.put_env(:arbor_llm, :tool_executor, Executor)
    assert {:ok, %{content: "done"}} = ToolLoop.run(client(), request(), max_turns: 3)
    assert_received :host_definitions
    assert_received {:host_adapter, [%{"function" => %{"name" => "host_effect"}}]}
    assert_received :host_effect
    refute_received :host_effect
  end

  test "explicit tools and executor work without a default product executor" do
    tools = Executor.definitions()

    assert {:ok, %{content: "done"}} =
             ToolLoop.run(client(), request(),
               tools: tools,
               tool_executor: Executor,
               max_turns: 3
             )

    assert_received :host_effect
    refute_received :host_effect
  end

  test "an explicit executor still needs explicit definitions when the host has none" do
    assert {:error, :tool_definitions_unavailable} =
             ToolLoop.run(client(), request(), tool_executor: Executor)

    refute_received {:host_adapter, _}
    refute_received :host_effect
  end

  defp client,
    do: Client.new(default_provider: Adapter.provider()) |> Client.register_adapter(Adapter)

  defp request,
    do: %Request{
      provider: Adapter.provider(),
      model: "fixture",
      messages: [Message.new(:user, "call the host tool")]
    }
end
