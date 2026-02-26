defmodule Arbor.Gateway.MCP.ToolBridgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.MCP.ToolBridge

  @moduletag :fast

  describe "to_arbor_tool/2" do
    test "converts MCP tool to Arbor format" do
      mcp_tool = %{
        "name" => "create_issue",
        "description" => "Create a GitHub issue",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string"},
            "body" => %{"type" => "string"}
          },
          "required" => ["title"]
        }
      }

      result = ToolBridge.to_arbor_tool("github", mcp_tool)

      assert result.name == "mcp.github.create_issue"
      assert result.description == "Create a GitHub issue"
      assert result.source == :mcp
      assert result.server_name == "github"
      assert result.mcp_tool_name == "create_issue"
      assert result.capability_uri == "arbor://mcp/github/create_issue"
      assert result.input_schema["type"] == "object"
      assert result.input_schema["properties"]["title"]["type"] == "string"
    end

    test "handles tool with no description" do
      mcp_tool = %{"name" => "list_files"}
      result = ToolBridge.to_arbor_tool("fs", mcp_tool)

      assert result.name == "mcp.fs.list_files"
      assert result.description == "MCP tool: list_files"
    end

    test "handles tool with no input schema" do
      mcp_tool = %{"name" => "get_status", "description" => "Get status"}
      result = ToolBridge.to_arbor_tool("monitor", mcp_tool)

      assert result.input_schema["type"] == "object"
    end

    test "normalizes schema without type field" do
      mcp_tool = %{
        "name" => "query",
        "inputSchema" => %{"properties" => %{"q" => %{"type" => "string"}}}
      }

      result = ToolBridge.to_arbor_tool("search", mcp_tool)
      assert result.input_schema["type"] == "object"
      assert result.input_schema["properties"]["q"]["type"] == "string"
    end
  end

  describe "to_arbor_tools/2" do
    test "converts a list of MCP tools" do
      tools = [
        %{"name" => "read", "description" => "Read file"},
        %{"name" => "write", "description" => "Write file"}
      ]

      results = ToolBridge.to_arbor_tools("filesystem", tools)

      assert length(results) == 2
      assert Enum.at(results, 0).name == "mcp.filesystem.read"
      assert Enum.at(results, 1).name == "mcp.filesystem.write"
    end

    test "returns empty list for empty input" do
      assert ToolBridge.to_arbor_tools("server", []) == []
    end
  end

  describe "capability_uri/2" do
    test "builds correct URI" do
      assert ToolBridge.capability_uri("github", "create_issue") ==
               "arbor://mcp/github/create_issue"
    end

    test "handles names with special characters" do
      assert ToolBridge.capability_uri("my-server", "list_all") ==
               "arbor://mcp/my-server/list_all"
    end
  end

  describe "parse_tool_name/1" do
    test "parses valid MCP tool names" do
      assert {:ok, "github", "create_issue"} =
               ToolBridge.parse_tool_name("mcp.github.create_issue")
    end

    test "rejects non-MCP tool names" do
      assert :error = ToolBridge.parse_tool_name("file.read")
      assert :error = ToolBridge.parse_tool_name("regular_tool")
    end

    test "rejects malformed names" do
      assert :error = ToolBridge.parse_tool_name("mcp.")
      assert :error = ToolBridge.parse_tool_name("mcp.server.")
      assert :error = ToolBridge.parse_tool_name("mcp..tool")
    end
  end

  describe "taint_result/3" do
    test "wraps result with untrusted taint" do
      result = ToolBridge.taint_result("hello world", "server", "tool")

      assert result.value == "hello world"
      assert result.taint.level == :untrusted
      assert result.taint.sensitivity == :internal
      assert result.taint.confidence == :plausible
      assert result.taint.source == "mcp:server/tool"
      assert result.taint.sanitizations == 0
    end

    test "handles complex result values" do
      complex = %{"items" => [1, 2, 3], "nested" => %{"key" => "value"}}
      result = ToolBridge.taint_result(complex, "db", "query")

      assert result.value == complex
      assert result.taint.level == :untrusted
    end
  end

  describe "authorize/3" do
    test "returns :ok when security not available (permissive mode)" do
      # Security processes aren't running in test by default
      assert :ok = ToolBridge.authorize("agent_123", "github", "create_issue")
    end
  end
end
