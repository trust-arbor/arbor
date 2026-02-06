defmodule Arbor.Agent.ToolBridgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ToolBridge
  alias Arbor.AI.AgentSDK.ToolServer

  setup do
    # Start a fresh tool server for each test
    {:ok, server} = ToolServer.start_link(name: nil)
    %{server: server}
  end

  describe "register_actions/4" do
    test "registers all actions as tools", %{server: server} do
      :ok = ToolBridge.register_actions(server, "test_agent", %{})

      tools = ToolServer.list_tools(server)
      names = Enum.map(tools, & &1["name"])

      # Should have file actions
      assert "file_read" in names
      assert "file_write" in names

      # Should have git actions
      assert "git_status" in names

      # Should have shell actions
      assert "shell_execute" in names
    end

    test "registers only specified categories", %{server: server} do
      :ok = ToolBridge.register_actions(server, "test_agent", %{}, categories: [:file])

      tools = ToolServer.list_tools(server)
      names = Enum.map(tools, & &1["name"])

      # Should have file actions
      assert "file_read" in names

      # Should NOT have git or shell actions
      refute "git_status" in names
      refute "shell_execute" in names
    end

    test "excludes specified actions", %{server: server} do
      :ok = ToolBridge.register_actions(server, "test_agent", %{},
        exclude: ["shell_execute", "shell_execute_script"]
      )

      tools = ToolServer.list_tools(server)
      names = Enum.map(tools, & &1["name"])

      # Should have file actions
      assert "file_read" in names

      # Should NOT have excluded shell actions
      refute "shell_execute" in names
      refute "shell_execute_script" in names
    end
  end

  describe "unregister_actions/2" do
    test "removes all action tools", %{server: server} do
      :ok = ToolBridge.register_actions(server, "test_agent", %{})
      assert ToolServer.has_tool?("file_read", server)

      :ok = ToolBridge.unregister_actions(server)
      refute ToolServer.has_tool?("file_read", server)
    end

    test "removes only specified category tools", %{server: server} do
      :ok = ToolBridge.register_actions(server, "test_agent", %{})
      assert ToolServer.has_tool?("file_read", server)
      assert ToolServer.has_tool?("git_status", server)

      :ok = ToolBridge.unregister_actions(server, categories: [:file])

      # File actions removed
      refute ToolServer.has_tool?("file_read", server)

      # Git actions still there
      assert ToolServer.has_tool?("git_status", server)
    end
  end

  describe "register_action/4" do
    test "registers a single action", %{server: server} do
      :ok = ToolBridge.register_action(
        server,
        Arbor.Actions.File.Read,
        "test_agent",
        %{}
      )

      assert ToolServer.has_tool?("file_read", server)
      refute ToolServer.has_tool?("file_write", server)
    end
  end

  describe "tool execution" do
    @tag :integration
    test "unauthorized agent gets error", %{server: server} do
      # Skip if security infrastructure not running
      # This test requires the full application stack
      :ok = ToolBridge.register_actions(server, "unauthorized_agent", %{})

      # This agent has no capabilities, so action should fail
      result = ToolServer.call_tool("file_read", %{path: "/tmp/test.txt"}, server)

      assert {:ok, error_msg} = result
      assert error_msg =~ "Unauthorized"
    end
  end

  describe "handler construction" do
    test "builds handler that wraps action", %{server: server} do
      :ok = ToolBridge.register_action(
        server,
        Arbor.Actions.File.Read,
        "test_agent",
        %{}
      )

      # Verify the handler is registered
      assert ToolServer.has_tool?("file_read", server)

      # Verify the schema is correct
      [tool] = ToolServer.list_tools(server)
      assert tool["name"] == "file_read"
      assert tool["description"] =~ "Read"
      assert is_map(tool["input_schema"])
    end
  end
end
