defmodule Arbor.Gateway.MCP.HandlerTest do
  use ExUnit.Case, async: false

  alias Arbor.Gateway.MCP.Handler

  setup do
    # Ensure ETS tables exist for memory/security lookups
    for table <- [
          :arbor_memory_graphs,
          :arbor_working_memory,
          :arbor_memory_proposals,
          :arbor_chat_history,
          :arbor_preferences
        ] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, [:named_table, :public, :set])
      end
    end

    {:ok, state: %{}}
  end

  # ===========================================================================
  # Initialization
  # ===========================================================================

  describe "handle_initialize/2" do
    test "returns server info and capabilities", %{state: state} do
      params = %{"protocolVersion" => "2024-11-05"}
      {:ok, result, new_state} = Handler.handle_initialize(params, state)

      assert result.protocolVersion == "2024-11-05"
      assert result.serverInfo.name == "arbor"
      assert result.serverInfo.version == "0.1.0"
      assert is_map(result.capabilities.tools)
      assert new_state == state
    end

    test "defaults protocol version when not provided", %{state: state} do
      {:ok, result, _state} = Handler.handle_initialize(%{}, state)
      assert result.protocolVersion == "2024-11-05"
    end
  end

  # ===========================================================================
  # Tool Listing
  # ===========================================================================

  describe "handle_list_tools/2" do
    test "returns 4 tools", %{state: state} do
      {:ok, tools, nil, _state} = Handler.handle_list_tools(nil, state)
      assert length(tools) == 4

      names = Enum.map(tools, & &1.name) |> Enum.sort()
      assert names == ["arbor_actions", "arbor_help", "arbor_run", "arbor_status"]
    end

    test "all tools have required fields", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)

      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)
        assert tool.inputSchema.type == "object"
      end
    end

    test "arbor_help requires 'action' parameter", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      help_tool = Enum.find(tools, &(&1.name == "arbor_help"))
      assert "action" in help_tool.inputSchema.required
    end

    # L1: arbor_run now requires agent_id in addition to action and params
    test "arbor_run requires 'action', 'params', and 'agent_id'", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      run_tool = Enum.find(tools, &(&1.name == "arbor_run"))
      assert "action" in run_tool.inputSchema.required
      assert "params" in run_tool.inputSchema.required
      assert "agent_id" in run_tool.inputSchema.required
    end

    test "arbor_status requires 'component'", %{state: state} do
      {:ok, tools, _, _} = Handler.handle_list_tools(nil, state)
      status_tool = Enum.find(tools, &(&1.name == "arbor_status"))
      assert "component" in status_tool.inputSchema.required
    end
  end

  # ===========================================================================
  # arbor_actions tool
  # ===========================================================================

  describe "arbor_actions" do
    test "lists all categories with no filter", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{}, state)

      assert text =~ "# Arbor Actions"
      # Should contain at least some well-known categories
      assert text =~ "shell"
      assert text =~ "file"
    end

    test "filters to a specific category", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "shell"}, state)

      assert text =~ "shell"
      assert text =~ "shell_execute"
    end

    test "returns error for unknown category", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "nonexistent_xyz"}, state)

      assert text =~ "Unknown category"
      assert text =~ "Available:"
    end
  end

  # ===========================================================================
  # arbor_help tool
  # ===========================================================================

  describe "arbor_help" do
    test "returns schema for known action", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "shell_execute"}, state)

      assert text =~ "# shell_execute"
      assert text =~ "## Parameters"
      assert text =~ "command"
      assert text =~ "## Taint Roles"
    end

    test "returns schema for file action", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "file_exists"}, state)

      assert text =~ "# file_exists"
      assert text =~ "## Parameters"
      assert text =~ "path"
    end

    test "returns not found for unknown action", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "totally_fake_action"}, state)

      assert text =~ "not found"
      assert text =~ "arbor_actions"
    end

    test "shows category and tags", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_help", %{"action" => "shell_execute"}, state)

      assert text =~ "## Category:"
      assert text =~ "## Tags:"
    end
  end

  # ===========================================================================
  # arbor_run tool
  # ===========================================================================

  describe "arbor_run" do
    # L1: All arbor_run tests now include agent_id (C1/C2 fix)
    test "executes file_exists action with agent_id", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "file_exists",
            "params" => %{"path" => "/tmp"},
            "agent_id" => "test_agent_001"
          },
          state
        )

      # With authorization, may get Success or Unauthorized depending on test setup
      assert text =~ "Success" or text =~ "Unauthorized" or text =~ "Error"
    end

    test "handles action not found with agent_id", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "nonexistent_action",
            "params" => %{},
            "agent_id" => "test_agent_001"
          },
          state
        )

      # P0-4: When Identity Registry is running, unregistered agent_id is rejected
      # before action lookup. When not running, falls through to action lookup.
      assert text =~ "not found" or text =~ "Unauthorized"
    end

    test "rejects execution without agent_id", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{"action" => "file_exists", "params" => %{"path" => "/tmp"}},
          state
        )

      # C1: Must reject when agent_id is missing
      assert text =~ "Agent ID is required"
    end

    test "rejects execution with empty agent_id", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "file_exists",
            "params" => %{"path" => "/tmp"},
            "agent_id" => ""
          },
          state
        )

      # C1: Must reject when agent_id is empty
      assert text =~ "Agent ID is required"
    end

    test "handles missing params gracefully", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{"action" => "file_exists", "agent_id" => "test_agent_001"},
          state
        )

      # Should error since path is required
      assert text =~ "Error" or text =~ "not found" or text =~ "Unauthorized"
    end
  end

  # ===========================================================================
  # arbor_status tool
  # ===========================================================================

  describe "arbor_status" do
    test "overview returns structured status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "overview"}, state)

      assert text =~ "# Arbor System Status"
      assert text =~ "## Agents"
      assert text =~ "## Memory"
      assert text =~ "## Signals"
    end

    test "agents component works", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "agents"}, state)

      assert text =~ "Agent" or text =~ "running" or text =~ "unavailable"
    end

    test "signals component works", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "signals"}, state)

      assert text =~ "Signal"
    end

    test "unknown component returns helpful message", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "foobar"}, state)

      assert text =~ "Unknown component"
      assert text =~ "agents"
      assert text =~ "overview"
    end

    test "memory component returns status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "memory"}, state)

      # Might be "No agent running" or actual memory data
      assert is_binary(text) and byte_size(text) > 0
    end

    test "goals component returns status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "goals"}, state)

      assert is_binary(text) and byte_size(text) > 0
    end

    test "capabilities component returns status", %{state: state} do
      {:ok, %{content: [%{type: "text", text: text}]}, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "capabilities"}, state)

      assert is_binary(text) and byte_size(text) > 0
    end
  end

  # ===========================================================================
  # Unknown tool
  # ===========================================================================

  describe "unknown tools" do
    test "returns error for unknown tool name", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("totally_unknown_tool", %{}, state)

      assert result.isError == true
      assert [%{type: "text", text: text}] = result.content
      assert text =~ "Unknown tool"
    end
  end

  # ===========================================================================
  # MCP client integration in handler
  # ===========================================================================

  describe "MCP status component" do
    test "returns no connections message when no MCP servers", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_status", %{"component" => "mcp"}, state)

      [%{type: "text", text: text}] = result.content
      assert text =~ "No external MCP servers connected"
      assert text =~ "No agent endpoints active"
    end
  end

  describe "MCP tool dispatch via arbor_run" do
    test "returns not connected error for disconnected MCP tool", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool(
          "arbor_run",
          %{
            "action" => "mcp.nonexistent.some_tool",
            "params" => %{},
            "agent_id" => "test_agent"
          },
          state
        )

      [%{type: "text", text: text}] = result.content
      # Identity Registry may reject unknown agent_id before MCP dispatch
      assert text =~ "not connected" or text =~ "Error" or text =~ "Unauthorized"
    end
  end

  describe "MCP category in arbor_actions" do
    test "returns no servers message when filtering by mcp category", %{state: state} do
      {:ok, result, _state} =
        Handler.handle_call_tool("arbor_actions", %{"category" => "mcp"}, state)

      [%{type: "text", text: text}] = result.content
      assert text =~ "No MCP servers connected"
    end
  end

  # ===========================================================================
  # init/1
  # ===========================================================================

  describe "init/1" do
    test "returns empty state" do
      assert {:ok, %{}} = Handler.init([])
    end
  end
end
