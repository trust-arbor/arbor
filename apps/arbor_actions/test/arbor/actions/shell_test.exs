defmodule Arbor.Actions.ShellTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Shell

  # Start shell system for tests
  setup_all do
    # Ensure shell system is running
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end

    :ok
  end

  describe "Execute" do
    test "runs a simple command" do
      assert {:ok, result} = Shell.Execute.run(%{command: "echo hello"}, %{})
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello")
      refute result.timed_out
    end

    test "captures stderr" do
      assert {:ok, result} = Shell.Execute.run(%{command: "ls /nonexistent_path_12345"}, %{})
      assert result.exit_code != 0
      assert result.stderr != "" or String.contains?(result.stdout, "No such file")
    end

    test "respects timeout" do
      assert {:ok, result} = Shell.Execute.run(%{command: "sleep 5", timeout: 100}, %{})
      assert result.timed_out
    end

    test "uses working directory" do
      assert {:ok, result} = Shell.Execute.run(%{command: "pwd", cwd: "/tmp"}, %{})

      assert String.contains?(result.stdout, "/tmp") or
               String.contains?(result.stdout, "/private/tmp")
    end

    test "sets environment variables" do
      assert {:ok, result} =
               Shell.Execute.run(
                 %{command: "echo $TEST_VAR", env: %{"TEST_VAR" => "test_value"}},
                 %{}
               )

      assert String.contains?(result.stdout, "test_value")
    end

    test "validates action metadata" do
      assert Shell.Execute.name() == "shell_execute"
      assert Shell.Execute.description() =~ "shell command"
      assert Shell.Execute.category() == "shell"
      assert "shell" in Shell.Execute.tags()
    end

    test "generates tool schema" do
      tool = Shell.Execute.to_tool()
      assert is_map(tool)
      assert tool[:name] == "shell_execute"
      assert is_map(tool[:parameters_schema])
    end

    test "context can override options" do
      context = %{cwd: "/tmp"}
      assert {:ok, result} = Shell.Execute.run(%{command: "pwd"}, context)
      assert String.contains?(result.stdout, "tmp")
    end
  end

  describe "ExecuteScript" do
    test "runs a multi-line script", %{tmp_dir: tmp_dir} do
      script = """
      echo "line 1"
      echo "line 2"
      """

      assert {:ok, result} = Shell.ExecuteScript.run(%{script: script, cwd: tmp_dir}, %{})
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "line 1")
      assert String.contains?(result.stdout, "line 2")
    end

    test "handles script with variables", %{tmp_dir: tmp_dir} do
      script = """
      NAME="world"
      echo "hello $NAME"
      """

      assert {:ok, result} = Shell.ExecuteScript.run(%{script: script, cwd: tmp_dir}, %{})
      assert result.exit_code == 0
      assert String.contains?(result.stdout, "hello world")
    end

    test "captures script failure" do
      script = """
      exit 42
      """

      assert {:ok, result} = Shell.ExecuteScript.run(%{script: script}, %{})
      assert result.exit_code == 42
    end

    test "cleans up temporary script file" do
      script = "echo test"

      # Run the script
      {:ok, _} = Shell.ExecuteScript.run(%{script: script}, %{})

      # Check that no arbor_script files remain
      tmp_files = File.ls!(System.tmp_dir!())
      arbor_scripts = Enum.filter(tmp_files, &String.starts_with?(&1, "arbor_script_"))
      assert Enum.empty?(arbor_scripts)
    end

    test "validates action metadata" do
      assert Shell.ExecuteScript.name() == "shell_execute_script"
      assert Shell.ExecuteScript.description() =~ "script"
      assert "script" in Shell.ExecuteScript.tags()
    end

    test "generates tool schema" do
      tool = Shell.ExecuteScript.to_tool()
      assert is_map(tool)
      assert tool[:name] == "shell_execute_script"
    end
  end
end
