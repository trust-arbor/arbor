defmodule Arbor.AI.AgentSDK.PermissionsTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AgentSDK.Permissions

  describe "cli_flags/1" do
    test "default returns empty list" do
      assert [] = Permissions.cli_flags(:default)
    end

    test "accept_edits returns allowedTools for edit tools" do
      flags = Permissions.cli_flags(:accept_edits)
      assert ["--allowedTools", tools] = flags
      assert "Edit" in String.split(tools, ",")
      assert "Write" in String.split(tools, ",")
    end

    test "plan returns read-only tools" do
      flags = Permissions.cli_flags(:plan)
      assert ["--allowedTools", tools] = flags
      assert "Read" in String.split(tools, ",")
      refute "Edit" in String.split(tools, ",")
    end

    test "bypass returns skip permissions flag" do
      assert ["--dangerously-skip-permissions"] = Permissions.cli_flags(:bypass)
    end
  end

  describe "tool_restriction_flags/1" do
    test "empty when no restrictions" do
      assert [] = Permissions.tool_restriction_flags([])
    end

    test "allowed_tools generates allowedTools flag" do
      flags = Permissions.tool_restriction_flags(allowed_tools: ["Read", "Write"])
      assert ["--allowedTools", "Read,Write"] = flags
    end

    test "disallowed_tools generates disallowedTools flag" do
      flags = Permissions.tool_restriction_flags(disallowed_tools: ["Bash"])
      assert ["--disallowedTools", "Bash"] = flags
    end

    test "handles atom tool names" do
      flags = Permissions.tool_restriction_flags(allowed_tools: [:Read, :Write])
      assert ["--allowedTools", "Read,Write"] = flags
    end

    test "allowed_tools takes precedence over disallowed" do
      flags =
        Permissions.tool_restriction_flags(
          allowed_tools: ["Read"],
          disallowed_tools: ["Bash"]
        )

      assert ["--allowedTools", "Read"] = flags
    end
  end

  describe "validate_mode/1" do
    test "accepts valid modes" do
      assert {:ok, :default} = Permissions.validate_mode(:default)
      assert {:ok, :accept_edits} = Permissions.validate_mode(:accept_edits)
      assert {:ok, :plan} = Permissions.validate_mode(:plan)
      assert {:ok, :bypass} = Permissions.validate_mode(:bypass)
    end

    test "rejects invalid modes" do
      assert {:error, msg} = Permissions.validate_mode(:invalid)
      assert is_binary(msg)
      assert String.contains?(msg, "invalid")
    end
  end

  describe "resolve_mode/1" do
    test "uses provided mode" do
      assert :accept_edits = Permissions.resolve_mode(permission_mode: :accept_edits)
    end

    test "defaults to :default when not provided" do
      assert :default = Permissions.resolve_mode([])
    end
  end

  describe "check_tool_allowed?/2" do
    test "allows all tools in default mode with no restrictions" do
      assert :ok = Permissions.check_tool_allowed?("Bash", [])
    end

    test "denies non-read tools in plan mode" do
      assert {:error, msg} = Permissions.check_tool_allowed?("Bash", permission_mode: :plan)
      assert msg =~ "plan mode"
    end

    test "allows read tools in plan mode" do
      assert :ok = Permissions.check_tool_allowed?("Read", permission_mode: :plan)
      assert :ok = Permissions.check_tool_allowed?("Grep", permission_mode: :plan)
      assert :ok = Permissions.check_tool_allowed?("Glob", permission_mode: :plan)
      assert :ok = Permissions.check_tool_allowed?("WebFetch", permission_mode: :plan)
      assert :ok = Permissions.check_tool_allowed?("WebSearch", permission_mode: :plan)
    end

    test "respects allowed_tools list" do
      opts = [allowed_tools: ["Read", "Write"]]
      assert :ok = Permissions.check_tool_allowed?("Read", opts)
      assert {:error, _} = Permissions.check_tool_allowed?("Bash", opts)
    end

    test "respects disallowed_tools list" do
      opts = [disallowed_tools: ["Bash"]]
      assert :ok = Permissions.check_tool_allowed?("Read", opts)
      assert {:error, _} = Permissions.check_tool_allowed?("Bash", opts)
    end

    test "plan mode + allowed_tools combines both filters" do
      opts = [permission_mode: :plan, allowed_tools: ["Read"]]
      assert :ok = Permissions.check_tool_allowed?("Read", opts)
      # Grep is plan-allowed but not in allowed_tools list
      assert {:error, _} = Permissions.check_tool_allowed?("Grep", opts)
      # Bash is denied by plan mode before allowed_tools check
      assert {:error, _} = Permissions.check_tool_allowed?("Bash", opts)
    end

    test "handles atom tool names in restriction lists" do
      opts = [allowed_tools: [:Read, :Write]]
      assert :ok = Permissions.check_tool_allowed?("Read", opts)
    end

    test "bypass mode allows everything" do
      assert :ok = Permissions.check_tool_allowed?("Bash", permission_mode: :bypass)
    end

    test "accept_edits mode allows all tools (restrictions via lists only)" do
      assert :ok = Permissions.check_tool_allowed?("Bash", permission_mode: :accept_edits)
      assert :ok = Permissions.check_tool_allowed?("Write", permission_mode: :accept_edits)
    end
  end
end
