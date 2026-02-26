defmodule Arbor.Gateway.MCP.AgentEndpointTest do
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.{ActionBridge, AgentEndpoint, EndpointRegistry}

  # ============================================================================
  # Test Action Modules
  # ============================================================================

  defmodule EchoAction do
    use Jido.Action,
      name: "echo",
      description: "Returns the input as output",
      schema: [
        message: [type: :string, required: true, doc: "Message to echo"]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{echoed: params.message}}
    end
  end

  defmodule AddAction do
    use Jido.Action,
      name: "add",
      description: "Adds two numbers",
      schema: [
        a: [type: :integer, required: true, doc: "First number"],
        b: [type: :integer, required: true, doc: "Second number"]
      ]

    @impl true
    def run(params, _context) do
      {:ok, %{sum: params.a + params.b}}
    end
  end

  defmodule FailAction do
    use Jido.Action,
      name: "fail",
      description: "Always fails",
      schema: [
        reason: [type: :string, required: true, doc: "Failure reason"]
      ]

    @impl true
    def run(params, _context) do
      {:error, params.reason}
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Ensure EndpointRegistry is available
    if :ets.info(:arbor_mcp_endpoints) == :undefined do
      start_supervised!({EndpointRegistry, []})
    end

    :ok
  end

  # ============================================================================
  # ActionBridge
  # ============================================================================

  describe "ActionBridge.to_mcp_tool/1" do
    test "converts action module to MCP tool definition" do
      tool = ActionBridge.to_mcp_tool(EchoAction)

      assert tool["name"] == "echo"
      assert tool["description"] == "Returns the input as output"
      assert tool["inputSchema"]["type"] == "object"
      assert tool["inputSchema"]["required"] == ["message"]
      assert tool["inputSchema"]["properties"]["message"]["type"] == "string"
    end

    test "converts multiple actions" do
      tools = ActionBridge.to_mcp_tools([EchoAction, AddAction])

      assert length(tools) == 2
      names = Enum.map(tools, & &1["name"])
      assert "echo" in names
      assert "add" in names
    end

    test "handles action with multiple required params" do
      tool = ActionBridge.to_mcp_tool(AddAction)

      assert tool["name"] == "add"
      assert "a" in tool["inputSchema"]["required"]
      assert "b" in tool["inputSchema"]["required"]
      assert tool["inputSchema"]["properties"]["a"]["type"] == "integer"
    end
  end

  # ============================================================================
  # AgentEndpoint Lifecycle
  # ============================================================================

  describe "AgentEndpoint lifecycle" do
    test "starts with specified actions" do
      {:ok, pid} =
        AgentEndpoint.start_link(
          agent_id: "test-agent-1",
          actions: [EchoAction, AddAction]
        )

      assert Process.alive?(pid)
      tools = AgentEndpoint.list_tools(pid)
      assert length(tools) == 2

      GenServer.stop(pid)
    end

    test "status reports agent info" do
      {:ok, pid} =
        AgentEndpoint.start_link(
          agent_id: "test-agent-2",
          actions: [EchoAction]
        )

      status = AgentEndpoint.status(pid)
      assert status.agent_id == "test-agent-2"
      assert status.tool_count == 1
      assert status.connected == false
      assert status.initialized == false

      GenServer.stop(pid)
    end

    test "starts with empty actions list" do
      {:ok, pid} =
        AgentEndpoint.start_link(
          agent_id: "test-agent-3",
          actions: []
        )

      tools = AgentEndpoint.list_tools(pid)
      assert tools == []

      GenServer.stop(pid)
    end
  end

  # ============================================================================
  # MCP Protocol (via ExMCP.Client)
  # ============================================================================

  describe "MCP protocol via ExMCP.Client" do
    test "client connects and discovers tools" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-1",
          actions: [EchoAction, AddAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :native, server: endpoint)

      # Client should have connected
      status = AgentEndpoint.status(endpoint)
      assert status.connected == true

      # List tools
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client)
      assert length(tools) == 2

      tool_names = Enum.map(tools, & &1.name)
      assert "echo" in tool_names
      assert "add" in tool_names

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "client calls tool and gets result" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-2",
          actions: [EchoAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :native, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "echo", %{"message" => "hello"})

      assert result != nil

      # Result should contain content with the echoed message
      content = get_tool_result_text(result)
      assert content =~ "hello"

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "client calls tool with integer params" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-3",
          actions: [AddAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :native, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "add", %{"a" => 3, "b" => 7})

      content = get_tool_result_text(result)
      assert content =~ "10"

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "client gets error for unknown tool" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-4",
          actions: [EchoAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :native, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "nonexistent", %{})

      # Should return an error result (isError: true in MCP protocol)
      content = get_tool_result_text(result)
      assert content =~ "unknown_tool" or content =~ "Error"

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end

    test "client handles tool failure" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "proto-agent-5",
          actions: [FailAction]
        )

      {:ok, client} = ExMCP.Client.start_link(transport: :native, server: endpoint)

      {:ok, result} = ExMCP.Client.call_tool(client, "fail", %{"reason" => "test failure"})

      content = get_tool_result_text(result)
      assert content =~ "test failure" or content =~ "Error"

      ExMCP.Client.stop(client)
      GenServer.stop(endpoint)
    end
  end

  # ============================================================================
  # EndpointRegistry
  # ============================================================================

  describe "EndpointRegistry" do
    test "register and lookup" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "reg-agent-1",
          actions: [EchoAction]
        )

      tools = AgentEndpoint.list_tools(endpoint)
      :ok = EndpointRegistry.register("reg-agent-1", endpoint, tools)

      assert {:ok, ^endpoint, ^tools} = EndpointRegistry.lookup("reg-agent-1")

      GenServer.stop(endpoint)
    end

    test "unregister removes entry" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "reg-agent-2",
          actions: [EchoAction]
        )

      EndpointRegistry.register("reg-agent-2", endpoint, [])
      assert {:ok, _, _} = EndpointRegistry.lookup("reg-agent-2")

      EndpointRegistry.unregister("reg-agent-2")
      assert :error = EndpointRegistry.lookup("reg-agent-2")

      GenServer.stop(endpoint)
    end

    test "lookup returns error for dead process" do
      {:ok, endpoint} =
        AgentEndpoint.start_link(
          agent_id: "reg-agent-3",
          actions: []
        )

      EndpointRegistry.register("reg-agent-3", endpoint, [])
      GenServer.stop(endpoint)

      # Dead process should return :error
      Process.sleep(50)
      assert :error = EndpointRegistry.lookup("reg-agent-3")
    end

    test "list returns alive endpoints only" do
      {:ok, ep1} =
        AgentEndpoint.start_link(
          agent_id: "list-1",
          actions: [EchoAction]
        )

      {:ok, ep2} =
        AgentEndpoint.start_link(
          agent_id: "list-2",
          actions: [EchoAction, AddAction]
        )

      tools1 = AgentEndpoint.list_tools(ep1)
      tools2 = AgentEndpoint.list_tools(ep2)
      EndpointRegistry.register("list-1", ep1, tools1)
      EndpointRegistry.register("list-2", ep2, tools2)

      list = EndpointRegistry.list()
      assert length(list) >= 2

      ids = Enum.map(list, &elem(&1, 0))
      assert "list-1" in ids
      assert "list-2" in ids

      # Kill one, list should filter it
      GenServer.stop(ep1)
      Process.sleep(50)

      list2 = EndpointRegistry.list()
      ids2 = Enum.map(list2, &elem(&1, 0))
      refute "list-1" in ids2
      assert "list-2" in ids2

      GenServer.stop(ep2)
    end
  end

  # ============================================================================
  # Gateway Facade
  # ============================================================================

  describe "Gateway facade" do
    test "start_agent_endpoint registers in registry" do
      {:ok, pid} =
        Arbor.Gateway.start_agent_endpoint("facade-1",
          actions: [EchoAction, AddAction]
        )

      assert Process.alive?(pid)
      assert {:ok, ^pid, tools} = EndpointRegistry.lookup("facade-1")
      assert length(tools) == 2

      Arbor.Gateway.stop_agent_endpoint("facade-1")
    end

    test "stop_agent_endpoint cleans up" do
      {:ok, pid} =
        Arbor.Gateway.start_agent_endpoint("facade-2",
          actions: [EchoAction]
        )

      assert :ok = Arbor.Gateway.stop_agent_endpoint("facade-2")
      refute Process.alive?(pid)
      assert :error = EndpointRegistry.lookup("facade-2")
    end

    test "stop_agent_endpoint returns error for unknown agent" do
      assert {:error, :not_found} = Arbor.Gateway.stop_agent_endpoint("nonexistent")
    end

    test "list_agent_endpoints shows active endpoints" do
      {:ok, _} =
        Arbor.Gateway.start_agent_endpoint("facade-3",
          actions: [EchoAction]
        )

      list = Arbor.Gateway.list_agent_endpoints()
      ids = Enum.map(list, &elem(&1, 0))
      assert "facade-3" in ids

      Arbor.Gateway.stop_agent_endpoint("facade-3")
    end

    test "connect_to_agent creates client for registered endpoint" do
      {:ok, _} =
        Arbor.Gateway.start_agent_endpoint("facade-4",
          actions: [EchoAction]
        )

      {:ok, client} = Arbor.Gateway.connect_to_agent("facade-4")
      assert Process.alive?(client)

      # Use the client
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client)
      assert length(tools) == 1
      assert hd(tools).name == "echo"

      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint("facade-4")
    end

    test "connect_to_agent returns error for unknown agent" do
      assert {:error, {:agent_endpoint_not_found, "unknown-agent"}} =
               Arbor.Gateway.connect_to_agent("unknown-agent")
    end
  end

  # ============================================================================
  # Agent-to-Agent Communication
  # ============================================================================

  describe "agent-to-agent communication" do
    test "full agent-to-agent tool call lifecycle" do
      # Agent A starts an endpoint exposing its actions
      {:ok, _endpoint} =
        Arbor.Gateway.start_agent_endpoint("agent-a",
          actions: [EchoAction, AddAction]
        )

      # Agent B connects to Agent A
      {:ok, client} = Arbor.Gateway.connect_to_agent("agent-a")

      # Agent B discovers Agent A's tools
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client)
      assert length(tools) == 2

      # Agent B calls Agent A's echo tool
      {:ok, echo_result} = ExMCP.Client.call_tool(client, "echo", %{"message" => "from B"})
      echo_text = get_tool_result_text(echo_result)
      assert echo_text =~ "from B"

      # Agent B calls Agent A's add tool
      {:ok, add_result} = ExMCP.Client.call_tool(client, "add", %{"a" => 5, "b" => 3})
      add_text = get_tool_result_text(add_result)
      assert add_text =~ "8"

      # Cleanup
      ExMCP.Client.stop(client)
      Arbor.Gateway.stop_agent_endpoint("agent-a")
    end

    test "multiple clients can connect to same endpoint" do
      {:ok, _endpoint} =
        Arbor.Gateway.start_agent_endpoint("multi-agent",
          actions: [EchoAction]
        )

      # Note: Local transport uses last-connected client_pid
      # This test verifies the endpoint doesn't crash with multiple connections
      {:ok, client1} = Arbor.Gateway.connect_to_agent("multi-agent")
      {:ok, client2} = Arbor.Gateway.connect_to_agent("multi-agent")

      # The last client (client2) should work
      {:ok, %{tools: tools}} = ExMCP.Client.list_tools(client2)
      assert length(tools) == 1

      ExMCP.Client.stop(client1)
      ExMCP.Client.stop(client2)
      Arbor.Gateway.stop_agent_endpoint("multi-agent")
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  # Extract text content from MCP tool result
  defp get_tool_result_text(result) do
    cond do
      is_map(result) and is_list(result[:content]) ->
        Enum.map_join(result[:content], fn
          %{text: text} -> text
          %{"text" => text} -> text
          _ -> ""
        end)

      is_map(result) and is_list(result["content"]) ->
        Enum.map_join(result["content"], fn
          %{"text" => text} -> text
          _ -> ""
        end)

      is_map(result) ->
        inspect(result)

      true ->
        inspect(result)
    end
  end
end
