defmodule Arbor.Orchestrator.Session.ToolDisclosureTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Session.ToolDisclosure

  describe "core_tools/1" do
    test "base tier includes find_tools and core file/memory/skill/git tools" do
      tools = ToolDisclosure.core_tools(:new)

      assert "tool_find_tools" in tools
      assert "file_read" in tools
      assert "file_write" in tools
      assert "file_edit" in tools
      assert "memory_recall" in tools
      assert "memory_remember" in tools
      assert "skill_search" in tools
      assert "skill_activate" in tools
      assert "git_status" in tools
      assert "git_diff" in tools
      # shell_execute requires established tier
      refute "shell_execute" in tools
    end

    test "base tier does not include elevated tools" do
      tools = ToolDisclosure.core_tools(:new)

      refute "shell_execute" in tools
      refute "code_compile_and_test" in tools
      refute "ai_generate_text" in tools
      refute "git_commit" in tools
      refute "shell_execute_script" in tools
      refute "code_hot_load" in tools
    end

    test "established tier adds shell/code/ai/git_commit tools" do
      tools = ToolDisclosure.core_tools(:established)

      assert "shell_execute" in tools
      assert "code_compile_and_test" in tools
      assert "ai_generate_text" in tools
      assert "git_commit" in tools
      assert "git_log" in tools
      # But not trusted-only
      refute "shell_execute_script" in tools
      refute "code_hot_load" in tools
    end

    test "trusted tier includes all tools" do
      for tier <- [:trusted, :full_partner, :system] do
        tools = ToolDisclosure.core_tools(tier)

        assert "shell_execute_script" in tools, "#{tier} missing shell_execute_script"
        assert "code_hot_load" in tools, "#{tier} missing code_hot_load"
        assert "shell_execute" in tools
        assert "code_compile_and_test" in tools
        assert "tool_find_tools" in tools
      end
    end

    test "provisional tier gets base tools only" do
      tools = ToolDisclosure.core_tools(:provisional)
      assert tools == ToolDisclosure.core_tools(:new)
    end
  end

  describe "resolve_tools/3" do
    test "returns core tools when no explicit config" do
      config = %{}
      tools = ToolDisclosure.resolve_tools(config, :new, MapSet.new())
      assert "tool_find_tools" in tools
      assert "file_read" in tools
    end

    test "uses explicit config when set, returns exactly those tools" do
      config = %{"tools" => ["custom_tool_a", "custom_tool_b"]}
      tools = ToolDisclosure.resolve_tools(config, :new, MapSet.new())

      assert "custom_tool_a" in tools
      assert "custom_tool_b" in tools
      # Explicit tool lists are used as-is — find_tools is NOT force-injected.
      # This allows workers with scoped trust profiles to get exactly the tools
      # they need without discovery overhead.
      assert length(tools) == 2
    end

    test "explicit config with find_tools already present doesn't duplicate" do
      config = %{"tools" => ["tool_find_tools", "custom_tool"]}
      tools = ToolDisclosure.resolve_tools(config, :new, MapSet.new())

      assert Enum.count(tools, &(&1 == "tool_find_tools")) == 1
    end

    test "explicit config with legacy find_tools name doesn't add duplicate" do
      config = %{"tools" => ["find_tools", "custom_tool"]}
      tools = ToolDisclosure.resolve_tools(config, :new, MapSet.new())

      # find_tools is recognized as a valid name, so tool_find_tools is NOT added
      refute "tool_find_tools" in tools
      assert "find_tools" in tools
    end

    test "merges discovered tools with core tools" do
      discovered = MapSet.new(["web_browse", "ai_generate_text"])
      tools = ToolDisclosure.resolve_tools(%{}, :new, discovered)

      assert "web_browse" in tools
      assert "ai_generate_text" in tools
      assert "file_read" in tools
    end

    test "deduplicates core + discovered" do
      # file_read is already in core
      discovered = MapSet.new(["file_read", "web_browse"])
      tools = ToolDisclosure.resolve_tools(%{}, :new, discovered)

      assert Enum.count(tools, &(&1 == "file_read")) == 1
    end
  end

  describe "merge_discovered/2" do
    test "adds new names to set" do
      existing = MapSet.new(["a", "b"])
      merged = ToolDisclosure.merge_discovered(existing, ["c", "d"])

      assert MapSet.member?(merged, "a")
      assert MapSet.member?(merged, "c")
      assert MapSet.member?(merged, "d")
    end

    test "deduplicates existing names" do
      existing = MapSet.new(["a", "b"])
      merged = ToolDisclosure.merge_discovered(existing, ["b", "c"])

      assert MapSet.size(merged) == 3
    end

    test "respects max_discovered_tools cap" do
      existing = MapSet.new(Enum.map(1..35, &"tool_#{&1}"))
      new_names = Enum.map(36..50, &"tool_#{&1}")
      merged = ToolDisclosure.merge_discovered(existing, new_names)

      assert MapSet.size(merged) <= ToolDisclosure.max_discovered_tools()
    end

    test "empty new_names returns existing unchanged" do
      existing = MapSet.new(["a"])
      assert ToolDisclosure.merge_discovered(existing, []) == existing
    end
  end

  describe "max_discovered_tools/0" do
    test "returns 40" do
      assert ToolDisclosure.max_discovered_tools() == 40
    end
  end

  describe "ensure_tool_capabilities/2" do
    test "returns :ok without crashing even when modules unavailable" do
      # In test env, Security/Actions may not be running, but it should not crash
      assert :ok ==
               ToolDisclosure.ensure_tool_capabilities("test_agent", [
                 "file_read",
                 "memory_recall"
               ])
    end

    test "handles empty tool list" do
      assert :ok == ToolDisclosure.ensure_tool_capabilities("test_agent", [])
    end

    test "handles unknown tool names gracefully" do
      assert :ok ==
               ToolDisclosure.ensure_tool_capabilities("test_agent", ["nonexistent_tool_xyz"])
    end
  end
end
