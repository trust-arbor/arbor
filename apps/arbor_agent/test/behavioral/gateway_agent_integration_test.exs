defmodule Arbor.Behavioral.GatewayAgentIntegrationTest do
  @moduledoc """
  Behavioral test: Gateway + Agent cross-app integration.

  Verifies that Gateway facade operations correctly interact with the
  Agent subsystem — endpoint lifecycle, MCP bridges, and boundary handling.
  """
  use Arbor.Test.BehavioralCase

  @moduletag :integration

  describe "gateway availability" do
    test "gateway module is loaded and accessible" do
      assert Code.ensure_loaded?(Arbor.Gateway)
    end

    test "gateway exposes MCP connection functions" do
      assert function_exported?(Arbor.Gateway, :list_mcp_connections, 0)
      assert function_exported?(Arbor.Gateway, :connect_mcp_server, 2)
      assert function_exported?(Arbor.Gateway, :disconnect_mcp_server, 1)
    end
  end

  describe "MCP connections" do
    test "list_mcp_connections returns a list" do
      result = Arbor.Gateway.list_mcp_connections()
      assert is_list(result)
    end

    test "disconnect nonexistent server returns error" do
      result = Arbor.Gateway.disconnect_mcp_server("nonexistent_server")
      assert match?({:error, _}, result)
    end
  end

  describe "MCP bridge modules available" do
    test "resource bridge is loaded" do
      assert Code.ensure_loaded?(Arbor.Gateway.MCP.ResourceBridge)
    end

    test "action bridge is loaded" do
      assert Code.ensure_loaded?(Arbor.Gateway.MCP.ActionBridge)
    end
  end

  describe "agent-gateway boundary" do
    test "agent registry is running" do
      assert Process.whereis(Arbor.Agent.Registry) != nil
    end

    test "gateway list_agent_endpoints returns a list" do
      result = Arbor.Gateway.list_agent_endpoints()
      assert is_list(result)
    end
  end
end
