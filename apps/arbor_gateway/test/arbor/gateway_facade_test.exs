defmodule Arbor.GatewayFacadeTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway

  @moduletag :fast

  # -- Bridge delegation --

  describe "agent_id/1" do
    test "returns prefixed agent ID for session" do
      assert Gateway.agent_id("abc-123") == "agent_claude_abc-123"
    end

    test "handles empty session ID" do
      assert Gateway.agent_id("") == "agent_claude_"
    end

    test "preserves UUID format in agent ID" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert Gateway.agent_id(uuid) == "agent_claude_#{uuid}"
    end
  end

  # -- MCP Client (no ClientSupervisor running) --

  describe "connect_mcp_server/2" do
    test "returns error when ClientSupervisor is not running" do
      # DynamicSupervisor not started => exit
      assert catch_exit(Gateway.connect_mcp_server("test", %{transport: :stdio}))
    end
  end

  describe "disconnect_mcp_server/1" do
    test "returns error when ClientSupervisor is not running" do
      # find_connection returns :error when supervisor not running
      assert {:error, :not_found} = Gateway.disconnect_mcp_server("nonexistent")
    end
  end

  describe "list_mcp_connections/0" do
    test "returns empty list when ClientSupervisor is not running" do
      assert Gateway.list_mcp_connections() == []
    end
  end

  describe "list_mcp_tools/1" do
    test "returns empty list when no connections exist" do
      assert Gateway.list_mcp_tools() == []
    end

    test "returns empty list for unknown server" do
      assert Gateway.list_mcp_tools("nonexistent") == []
    end
  end

  describe "call_mcp_tool/4" do
    test "returns not_connected error when server not found" do
      result = Gateway.call_mcp_tool("missing", "tool", %{}, skip_auth: true)
      assert {:error, {:not_connected, "missing"}} = result
    end

    test "skips auth when skip_auth is true" do
      # Even with agent_id, skip_auth bypasses authorization
      # Will still fail on find_connection
      result = Gateway.call_mcp_tool("missing", "tool", %{}, agent_id: "agent_1", skip_auth: true)
      assert {:error, {:not_connected, "missing"}} = result
    end

    test "skips auth when no agent_id provided" do
      result = Gateway.call_mcp_tool("missing", "tool", %{})
      assert {:error, {:not_connected, "missing"}} = result
    end
  end

  # -- MCP Resources --

  describe "list_mcp_resources/1" do
    test "returns empty list when no connections exist" do
      assert Gateway.list_mcp_resources() == []
    end

    test "returns empty list for unknown server" do
      assert Gateway.list_mcp_resources("nonexistent") == []
    end
  end

  describe "read_mcp_resource/3" do
    test "returns not_connected error when server not found" do
      result = Gateway.read_mcp_resource("missing", "file:///config.json", skip_auth: true)
      assert {:error, {:not_connected, "missing"}} = result
    end

    test "skips auth when skip_auth is true" do
      result =
        Gateway.read_mcp_resource("missing", "file:///x", agent_id: "a1", skip_auth: true)

      assert {:error, {:not_connected, "missing"}} = result
    end
  end

  # -- MCP Server Status --

  describe "mcp_server_status/1" do
    test "returns not_found for unknown server" do
      assert {:error, :not_found} = Gateway.mcp_server_status("nonexistent")
    end
  end

  # -- Agent Endpoints (with EndpointRegistry) --

  describe "stop_agent_endpoint/1 without registry" do
    test "returns not_found when registry is not running" do
      assert {:error, :not_found} = Gateway.stop_agent_endpoint("agent_1")
    end
  end

  describe "list_agent_endpoints/0 without registry" do
    test "returns empty list when registry is not running" do
      assert Gateway.list_agent_endpoints() == []
    end
  end

  describe "connect_to_agent/2 without registry" do
    test "returns error when target agent endpoint not found" do
      result = Gateway.connect_to_agent("agent_unknown")
      assert {:error, {:agent_endpoint_not_found, "agent_unknown"}} = result
    end
  end

  # -- Agent Endpoints (with EndpointRegistry started) --
  # EndpointRegistry may already be started by the supervision tree.
  # These tests work regardless since EndpointRegistry gracefully handles
  # the ETS table existing or not.

  describe "agent endpoint lifecycle with registry" do
    setup do
      # Ensure EndpointRegistry is running (may already be started by app)
      case Arbor.Gateway.MCP.EndpointRegistry.start_link([]) do
        {:ok, pid} -> %{registry_pid: pid}
        {:error, {:already_started, pid}} -> %{registry_pid: pid}
      end
    end

    test "list_agent_endpoints returns empty when no endpoints registered" do
      assert Gateway.list_agent_endpoints() == []
    end

    test "stop_agent_endpoint returns not_found for unregistered agent" do
      assert {:error, :not_found} = Gateway.stop_agent_endpoint("agent_missing")
    end

    test "connect_to_agent returns error for unregistered agent" do
      result = Gateway.connect_to_agent("agent_not_here")
      assert {:error, {:agent_endpoint_not_found, "agent_not_here"}} = result
    end
  end
end
