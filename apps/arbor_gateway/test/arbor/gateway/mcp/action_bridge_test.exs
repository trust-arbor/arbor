defmodule Arbor.Gateway.MCP.ActionBridgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.MCP.ActionBridge

  @moduletag :fast

  # Define a fake action module for testing
  defmodule FakeAction do
    def to_tool do
      %{
        name: "fake_action",
        description: "A fake action for testing",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{
            "input" => %{"type" => "string", "description" => "Input value"}
          },
          "required" => ["input"]
        }
      }
    end
  end

  defmodule MinimalAction do
    def to_tool do
      %{
        name: "minimal",
        description: nil,
        parameters_schema: nil
      }
    end
  end

  describe "to_mcp_tool/1" do
    test "converts action module with full schema" do
      result = ActionBridge.to_mcp_tool(FakeAction)

      assert result["name"] == "fake_action"
      assert result["description"] == "A fake action for testing"
      assert result["inputSchema"]["type"] == "object"
      assert result["inputSchema"]["properties"]["input"]["type"] == "string"
      assert result["inputSchema"]["required"] == ["input"]
    end

    test "handles action with nil description" do
      result = ActionBridge.to_mcp_tool(MinimalAction)

      assert result["name"] == "minimal"
      assert result["description"] == "Arbor action: minimal"
    end

    test "handles action with nil parameters_schema" do
      result = ActionBridge.to_mcp_tool(MinimalAction)

      assert result["inputSchema"] == %{"type" => "object", "properties" => %{}}
    end

    test "falls back to module name when to_tool raises" do
      # Module that doesn't have to_tool/0 at all
      result = ActionBridge.to_mcp_tool(String)

      assert result["name"] == "string"
      assert result["description"] == "Arbor action: string"
      assert result["inputSchema"] == %{"type" => "object", "properties" => %{}}
    end

    test "extracts last segment of nested module name as fallback" do
      result = ActionBridge.to_mcp_tool(Enum.EmptyError)

      assert result["name"] == "empty_error"
    end
  end

  describe "to_mcp_tools/1" do
    test "converts a list of action modules" do
      results = ActionBridge.to_mcp_tools([FakeAction, MinimalAction])

      assert length(results) == 2
      assert Enum.at(results, 0)["name"] == "fake_action"
      assert Enum.at(results, 1)["name"] == "minimal"
    end

    test "returns empty list for empty input" do
      assert ActionBridge.to_mcp_tools([]) == []
    end
  end

  describe "all_mcp_tools/0" do
    test "returns a list (may be empty if Arbor.Actions not available)" do
      result = ActionBridge.all_mcp_tools()
      assert is_list(result)
    end
  end
end
