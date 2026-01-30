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
      assert actions != []
      assert Arbor.Actions.Shell.Execute in actions
      assert Arbor.Actions.File.Read in actions
      assert Arbor.Actions.Git.Status in actions
    end
  end

  describe "all_tools/0" do
    test "returns tool schemas for all actions" do
      tools = Actions.all_tools()

      assert is_list(tools)
      assert tools != []

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

    test "returns tools for git category" do
      tools = Actions.tools_for_category(:git)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "git_status" in tool_names
      assert "git_diff" in tool_names
      assert "git_commit" in tool_names
      assert "git_log" in tool_names
    end

    test "returns tools for comms category" do
      tools = Actions.tools_for_category(:comms)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "comms_send_message" in tool_names
      assert "comms_poll_messages" in tool_names
    end

    test "returns tools for jobs category" do
      tools = Actions.tools_for_category(:jobs)

      assert is_list(tools)
      tool_names = Enum.map(tools, & &1[:name])
      assert "jobs_create" in tool_names
      assert "jobs_list" in tool_names
    end

    test "returns empty list for unknown category" do
      tools = Actions.tools_for_category(:unknown)
      assert tools == []
    end
  end

  describe "emit functions" do
    test "emit_started returns :ok" do
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, %{command: "test"})
    end

    test "emit_started sanitizes sensitive params" do
      # Params with sensitive keys should not crash - sanitization strips them
      assert :ok =
               Actions.emit_started(Arbor.Actions.Shell.Execute, %{
                 command: "test",
                 password: "secret123",
                 secret: "hidden",
                 token: "tok_abc",
                 api_key: "key_xyz",
                 content: "large content"
               })
    end

    test "emit_started handles non-map params" do
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, "string params")
      assert :ok = Actions.emit_started(Arbor.Actions.Shell.Execute, nil)
    end

    test "emit_completed returns :ok" do
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, %{exit_code: 0})
    end

    test "emit_completed truncates large result values" do
      large_value = String.duplicate("x", 600)

      assert :ok =
               Actions.emit_completed(Arbor.Actions.Shell.Execute, %{
                 stdout: large_value,
                 exit_code: 0
               })
    end

    test "emit_completed handles non-map result" do
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, "string result")
      assert :ok = Actions.emit_completed(Arbor.Actions.Shell.Execute, 42)
    end

    test "emit_failed returns :ok" do
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, "error reason")
    end

    test "emit_failed handles complex error terms" do
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, {:error, :timeout})
      assert :ok = Actions.emit_failed(Arbor.Actions.Shell.Execute, %{code: 500, msg: "fail"})
    end
  end
end
