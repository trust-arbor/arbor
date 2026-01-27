defmodule Arbor.ActionsTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions

  describe "list_actions/0" do
    test "returns actions organized by category" do
      actions = Actions.list_actions()

      assert Map.has_key?(actions, :shell)
      assert Map.has_key?(actions, :file)
      assert Map.has_key?(actions, :git)

      assert Arbor.Actions.Shell.Execute in actions.shell
      assert Arbor.Actions.File.Read in actions.file
      assert Arbor.Actions.Git.Status in actions.git
    end
  end

  describe "all_actions/0" do
    test "returns flat list of all action modules" do
      actions = Actions.all_actions()

      assert is_list(actions)
      assert length(actions) > 0
      assert Arbor.Actions.Shell.Execute in actions
      assert Arbor.Actions.File.Read in actions
      assert Arbor.Actions.Git.Status in actions
    end
  end

  describe "all_tools/0" do
    test "returns tool schemas for all actions" do
      tools = Actions.all_tools()

      assert is_list(tools)
      assert length(tools) > 0

      # Each tool should be a map with name and parameters_schema (atom keys)
      Enum.each(tools, fn tool ->
        assert is_map(tool)
        assert Map.has_key?(tool, :name)
        assert Map.has_key?(tool, :parameters_schema)
      end)
    end

    test "tool names match action names" do
      tools = Actions.all_tools()
      tool_names = Enum.map(tools, & &1[:name])

      assert "shell_execute" in tool_names
      assert "file_read" in tool_names
      assert "git_status" in tool_names
    end
  end

  describe "tools_for_category/1" do
    test "returns tools for shell category" do
      tools = Actions.tools_for_category(:shell)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "shell_execute" in tool_names
      assert "shell_execute_script" in tool_names
    end

    test "returns tools for file category" do
      tools = Actions.tools_for_category(:file)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "file_read" in tool_names
      assert "file_write" in tool_names
    end

    test "returns empty list for unknown category" do
      tools = Actions.tools_for_category(:unknown)
      assert tools == []
    end
  end

  describe "emit functions" do
    test "emit_started returns :ok" do
      # This tests that the function doesn't crash
      # Actual signal emission is tested via integration tests
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, %{command: "test"})
    end

    test "emit_completed returns :ok" do
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, %{exit_code: 0})
    end

    test "emit_failed returns :ok" do
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, "error reason")
    end
  end
end
