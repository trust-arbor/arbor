defmodule Arbor.Actions.CliAgent.PermissionMapperTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.CliAgent.PermissionMapper

  @moduletag :fast

  describe "capabilities_to_tools/1" do
    test "maps shell/exec to Bash" do
      assert PermissionMapper.capabilities_to_tools(["arbor://shell/exec"]) == ["Bash"]
    end

    test "maps fs/read to Read, Glob, Grep" do
      tools = PermissionMapper.capabilities_to_tools(["arbor://fs/read"])
      assert "Read" in tools
      assert "Glob" in tools
      assert "Grep" in tools
    end

    test "maps fs/write to Edit, Write, NotebookEdit" do
      tools = PermissionMapper.capabilities_to_tools(["arbor://fs/write"])
      assert "Edit" in tools
      assert "Write" in tools
      assert "NotebookEdit" in tools
    end

    test "maps net/http to WebFetch" do
      assert PermissionMapper.capabilities_to_tools(["arbor://net/http"]) == ["WebFetch"]
    end

    test "maps net/search to WebSearch" do
      assert PermissionMapper.capabilities_to_tools(["arbor://net/search"]) == ["WebSearch"]
    end

    test "tool/use wildcard returns :all" do
      assert PermissionMapper.capabilities_to_tools(["arbor://tool/use"]) == :all
    end

    test "wildcard takes precedence over other capabilities" do
      caps = ["arbor://fs/read", "arbor://tool/use", "arbor://shell/exec"]
      assert PermissionMapper.capabilities_to_tools(caps) == :all
    end

    test "combines multiple capabilities and deduplicates" do
      caps = ["arbor://fs/read", "arbor://shell/exec"]
      tools = PermissionMapper.capabilities_to_tools(caps)
      assert "Bash" in tools
      assert "Read" in tools
      assert "Glob" in tools
      assert "Grep" in tools
      assert length(tools) == 4
    end

    test "results are sorted" do
      caps = ["arbor://shell/exec", "arbor://fs/read"]
      tools = PermissionMapper.capabilities_to_tools(caps)
      assert tools == Enum.sort(tools)
    end

    test "empty capabilities returns empty list" do
      assert PermissionMapper.capabilities_to_tools([]) == []
    end

    test "unknown capability URI returns empty tools for that entry" do
      assert PermissionMapper.capabilities_to_tools(["arbor://unknown/thing"]) == []
    end

    test "handles prefix-matched capability URIs" do
      caps = ["arbor://fs/read/some/path"]
      tools = PermissionMapper.capabilities_to_tools(caps)
      assert "Read" in tools
      assert "Glob" in tools
    end

    test "handles map-format capabilities with resource key" do
      caps = [%{resource: "arbor://shell/exec"}]
      assert PermissionMapper.capabilities_to_tools(caps) == ["Bash"]
    end

    test "handles string-keyed map capabilities" do
      caps = [%{"resource" => "arbor://fs/read"}]
      tools = PermissionMapper.capabilities_to_tools(caps)
      assert "Read" in tools
    end
  end

  describe "tool_to_capability_uri/1" do
    test "Bash maps to shell/exec" do
      assert PermissionMapper.tool_to_capability_uri("Bash") == {:ok, "arbor://shell/exec"}
    end

    test "Read maps to fs/read" do
      assert PermissionMapper.tool_to_capability_uri("Read") == {:ok, "arbor://fs/read"}
    end

    test "Edit maps to fs/write" do
      assert PermissionMapper.tool_to_capability_uri("Edit") == {:ok, "arbor://fs/write"}
    end

    test "WebFetch maps to net/http" do
      assert PermissionMapper.tool_to_capability_uri("WebFetch") == {:ok, "arbor://net/http"}
    end

    test "unknown tool falls back to tool/use" do
      assert PermissionMapper.tool_to_capability_uri("UnknownTool") == {:ok, "arbor://tool/use"}
    end
  end

  describe "capabilities_to_tool_flags/1" do
    test "returns empty flags when Security is unavailable" do
      {:ok, flags} = PermissionMapper.capabilities_to_tool_flags("nonexistent_agent")
      assert flags == []
    end
  end

  describe "capability_mapping/0" do
    test "returns the full mapping" do
      mapping = PermissionMapper.capability_mapping()
      assert is_map(mapping)
      assert Map.has_key?(mapping, "arbor://shell/exec")
      assert Map.has_key?(mapping, "arbor://tool/use")
      assert mapping["arbor://tool/use"] == :all
    end
  end

  describe "tool_mapping/0" do
    test "returns the reverse mapping" do
      mapping = PermissionMapper.tool_mapping()
      assert is_map(mapping)
      assert mapping["Bash"] == "arbor://shell/exec"
      assert mapping["Read"] == "arbor://fs/read"
    end
  end
end
