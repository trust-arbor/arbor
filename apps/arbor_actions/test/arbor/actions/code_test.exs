defmodule Arbor.Actions.CodeTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Code

  @moduletag :fast

  describe "CompileAndTest" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Code.CompileAndTest.validate_params(%{})

      # Test that schema accepts valid params
      assert {:ok, _} = Code.CompileAndTest.validate_params(%{file: "lib/my_module.ex"})

      # Test with optional params
      assert {:ok, _} =
               Code.CompileAndTest.validate_params(%{
                 file: "lib/my_module.ex",
                 test_files: ["test/my_module_test.exs"],
                 compile_only: true
               })
    end

    test "validates action metadata" do
      assert Code.CompileAndTest.name() == "code_compile_and_test"
      assert Code.CompileAndTest.category() == "code"
      assert "compile" in Code.CompileAndTest.tags()
      assert "test" in Code.CompileAndTest.tags()
    end

    test "generates tool schema" do
      tool = Code.CompileAndTest.to_tool()
      assert is_map(tool)
      assert tool[:name] == "code_compile_and_test"
      assert tool[:description] =~ "Compile"
    end

    test "returns error when worktree_path not provided" do
      assert {:error, "worktree_path required in params or context"} =
               Code.CompileAndTest.run(%{file: "lib/my_module.ex"}, %{})
    end

    test "accepts worktree_path from context" do
      # This will fail since the path doesn't exist, but it should get past validation
      result = Code.CompileAndTest.run(
        %{file: "lib/my_module.ex", compile_only: true},
        %{worktree_path: "/nonexistent/path"}
      )

      # Should fail at compilation, not at validation
      assert {:ok, %{compiled: false}} = result
    end
  end

  describe "HotLoad" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Code.HotLoad.validate_params(%{})
      assert {:error, _} = Code.HotLoad.validate_params(%{module: "MyModule"})

      # Test that schema accepts valid params
      assert {:ok, _} =
               Code.HotLoad.validate_params(%{
                 module: "MyModule",
                 source: "defmodule MyModule do end"
               })

      # Test with optional params
      assert {:ok, _} =
               Code.HotLoad.validate_params(%{
                 module: "MyModule",
                 source: "defmodule MyModule do end",
                 verify_fn: "MyModule.health_check/0",
                 rollback_timeout_ms: 5000
               })
    end

    test "validates action metadata" do
      assert Code.HotLoad.name() == "code_hot_load"
      assert Code.HotLoad.category() == "code"
      assert "hot_load" in Code.HotLoad.tags()
      assert "dangerous" in Code.HotLoad.tags()
    end

    test "generates tool schema" do
      tool = Code.HotLoad.to_tool()
      assert is_map(tool)
      assert tool[:name] == "code_hot_load"
      assert tool[:description] =~ "Hot-load"
    end

    test "rejects protected modules" do
      # Arbor.Security is a protected module
      result = Code.HotLoad.run(
        %{
          module: "Arbor.Security",
          source: "defmodule Arbor.Security do end"
        },
        %{}
      )

      assert {:error, msg} = result
      assert msg =~ "protected module"
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      # Use Elixir's Code module, not the aliased Arbor.Actions.Code
      assert Elixir.Code.ensure_loaded?(Code.CompileAndTest)
      assert Elixir.Code.ensure_loaded?(Code.HotLoad)

      assert function_exported?(Code.CompileAndTest, :run, 2)
      assert function_exported?(Code.HotLoad, :run, 2)
    end
  end
end
