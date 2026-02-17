defmodule Arbor.Orchestrator.UnifiedLLM.Conformance87Test do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.{Client, Message, Request, Response, Tool}

  defmodule ToolLoopAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "tool-loop-conformance"

    @impl true
    def complete(%Request{} = request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:request_messages, request.messages})

      has_tool_result = Enum.any?(request.messages, &(&1.role == :tool))

      if has_tool_result do
        {:ok, %Response{text: "final", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "need tools",
           finish_reason: :tool_calls,
           raw: %{
             "tool_calls" => [
               %{"id" => "1", "name" => "lookup", "arguments" => %{"k" => "a"}},
               %{"id" => "2", "name" => "lookup", "arguments" => %{"k" => "b"}}
             ]
           }
         }}
      end
    end
  end

  defmodule EndlessToolAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "endless-tool-conformance"

    @impl true
    def complete(%Request{} = request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:endless_request_messages, request.messages})

      {:ok,
       %Response{
         text: "still wants tools",
         finish_reason: :tool_calls,
         raw: %{
           "tool_calls" => [%{"id" => "1", "name" => "lookup", "arguments" => %{"k" => "a"}}]
         }
       }}
    end
  end

  defmodule UnknownToolAdapter do
    @behaviour Arbor.Orchestrator.UnifiedLLM.ProviderAdapter

    @impl true
    def provider, do: "unknown-tool-conformance"

    @impl true
    def complete(%Request{} = request, opts) do
      parent = Keyword.fetch!(opts, :parent)
      send(parent, {:unknown_request_messages, request.messages})

      if Enum.any?(request.messages, &(&1.role == :tool)) do
        {:ok, %Response{text: "recovered", finish_reason: :stop, raw: %{}}}
      else
        {:ok,
         %Response{
           text: "unknown tool requested",
           finish_reason: :tool_calls,
           raw: %{
             "tool_calls" => [%{"id" => "404", "name" => "missing_tool", "arguments" => %{}}]
           }
         }}
      end
    end
  end

  test "8.7 active tools execute automatically and loop to final response" do
    client =
      Client.new(default_provider: "tool-loop-conformance")
      |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "go")]}

    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [tool],
               max_tool_rounds: 4,
               parent: self()
             )

    assert response.text == "final"
  end

  test "8.7 passive tools do not auto-loop and return tool calls to caller" do
    client =
      Client.new(default_provider: "tool-loop-conformance")
      |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "go")]}

    passive_tool = %Tool{name: "lookup", execute: nil}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [passive_tool],
               max_tool_rounds: 4,
               parent: self()
             )

    assert response.finish_reason == :tool_calls
    assert is_list(response.raw["tool_calls"])
    assert length(response.raw["tool_calls"]) == 2
  end

  test "8.7 max_tool_rounds=0 disables automatic execution entirely" do
    client =
      Client.new(default_provider: "tool-loop-conformance")
      |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "go")]}
    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [tool],
               max_tool_rounds: 0,
               parent: self()
             )

    assert response.finish_reason == :tool_calls
    assert_receive {:request_messages, msgs}
    refute Enum.any?(msgs, &(&1.role == :tool))
  end

  test "8.7 max_tool_rounds limit is respected without raising" do
    client =
      Client.new(default_provider: "endless-tool-conformance")
      |> Client.register_adapter(EndlessToolAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "go")]}
    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [tool],
               max_tool_rounds: 1,
               parent: self()
             )

    assert response.finish_reason == :tool_calls
  end

  test "8.7 parallel tool results are batched into a single continuation request" do
    client =
      Client.new(default_provider: "tool-loop-conformance")
      |> Client.register_adapter(ToolLoopAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "go")]}
    tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, _response} =
             Client.generate_with_tools(client, request, [tool],
               max_tool_rounds: 4,
               parallel_tool_execution: true,
               parent: self()
             )

    assert_receive {:request_messages, first_msgs}
    refute Enum.any?(first_msgs, &(&1.role == :tool))

    assert_receive {:request_messages, second_msgs}
    assert Enum.count(second_msgs, &(&1.role == :tool)) == 2
  end

  test "8.7 unknown tool calls are returned to model as error results, not exceptions" do
    client =
      Client.new(default_provider: "unknown-tool-conformance")
      |> Client.register_adapter(UnknownToolAdapter)

    request = %Request{model: "demo", messages: [Message.new(:user, "go")]}
    unrelated_tool = %Tool{name: "lookup", execute: fn _ -> %{"ok" => true} end}

    assert {:ok, response} =
             Client.generate_with_tools(client, request, [unrelated_tool],
               max_tool_rounds: 2,
               parent: self()
             )

    assert response.text == "recovered"

    assert_receive {:unknown_request_messages, _first}
    assert_receive {:unknown_request_messages, second}

    tool_msg = Enum.find(second, &(&1.role == :tool))
    assert tool_msg

    {:ok, payload} = Jason.decode(tool_msg.content)
    assert payload["status"] == "error"
  end
end
