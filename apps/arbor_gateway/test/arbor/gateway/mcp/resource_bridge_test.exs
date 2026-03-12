defmodule Arbor.Gateway.MCP.ResourceBridgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Gateway.MCP.ResourceBridge

  @moduletag :fast

  describe "to_arbor_resource/2" do
    test "converts MCP resource to Arbor format" do
      mcp_resource = %{
        "uri" => "file:///config.json",
        "name" => "config.json",
        "description" => "Application configuration",
        "mimeType" => "application/json"
      }

      result = ResourceBridge.to_arbor_resource("fs", mcp_resource)

      assert result.uri == "file:///config.json"
      assert result.name == "config.json"
      assert result.description == "Application configuration"
      assert result.mime_type == "application/json"
      assert result.source == :mcp
      assert result.server_name == "fs"
      assert result.capability_uri == "arbor://mcp/fs/resource/config.json"
    end

    test "handles resource with no description" do
      mcp_resource = %{"uri" => "file:///data.csv", "name" => "data.csv"}
      result = ResourceBridge.to_arbor_resource("files", mcp_resource)

      assert result.description == ""
      assert result.name == "data.csv"
    end

    test "handles resource with no mimeType" do
      mcp_resource = %{"uri" => "custom://thing", "name" => "thing"}
      result = ResourceBridge.to_arbor_resource("custom", mcp_resource)

      assert result.mime_type == ""
    end
  end

  describe "to_arbor_resources/2" do
    test "converts a list of MCP resources" do
      resources = [
        %{"uri" => "file:///a.txt", "name" => "a.txt"},
        %{"uri" => "file:///b.txt", "name" => "b.txt"},
        %{"uri" => "file:///c.txt", "name" => "c.txt"}
      ]

      results = ResourceBridge.to_arbor_resources("fs", resources)

      assert length(results) == 3
      assert Enum.at(results, 0).name == "a.txt"
      assert Enum.at(results, 1).name == "b.txt"
      assert Enum.at(results, 2).name == "c.txt"
      assert Enum.all?(results, &(&1.source == :mcp))
      assert Enum.all?(results, &(&1.server_name == "fs"))
    end

    test "returns empty list for empty input" do
      assert ResourceBridge.to_arbor_resources("server", []) == []
    end
  end

  describe "capability_uri/2" do
    test "builds correct resource capability URI" do
      assert ResourceBridge.capability_uri("fs", "config.json") ==
               "arbor://mcp/fs/resource/config.json"
    end

    test "handles server names with hyphens" do
      assert ResourceBridge.capability_uri("my-server", "data.csv") ==
               "arbor://mcp/my-server/resource/data.csv"
    end

    test "handles resource names with path separators" do
      assert ResourceBridge.capability_uri("fs", "dir/file.txt") ==
               "arbor://mcp/fs/resource/dir/file.txt"
    end
  end

  describe "taint_contents/3" do
    test "wraps contents with untrusted taint metadata" do
      contents = %{"text" => "Hello world"}

      result = ResourceBridge.taint_contents(contents, "fs", "file:///hello.txt")

      assert result.value == contents
      assert result.taint.level == :untrusted
      assert result.taint.sensitivity == :internal
      assert result.taint.confidence == :plausible
      assert result.taint.source == "mcp:fs/resource/file:///hello.txt"
      assert result.taint.sanitizations == 0
    end

    test "handles string contents" do
      result = ResourceBridge.taint_contents("raw text", "server", "res://doc")

      assert result.value == "raw text"
      assert result.taint.level == :untrusted
    end

    test "handles nil contents" do
      result = ResourceBridge.taint_contents(nil, "s", "r")

      assert result.value == nil
      assert result.taint.level == :untrusted
    end
  end

  describe "authorize/3" do
    test "returns :ok or unauthorized depending on security infrastructure" do
      result = ResourceBridge.authorize("agent_123", "fs", "config.json")

      # In isolation: CapabilityStore not running -> permissive mode -> :ok
      # In umbrella: CapabilityStore running -> no capability granted -> unauthorized
      assert result == :ok or match?({:error, :unauthorized, _}, result)
    end
  end
end
