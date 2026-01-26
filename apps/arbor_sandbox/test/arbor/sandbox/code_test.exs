defmodule Arbor.Sandbox.CodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Sandbox.Code

  # Elixir's stdlib Code module (not our alias)
  @elixir_code Elixir.Code

  describe "validate/2" do
    test "allows safe code at pure level" do
      ast = quote do: Enum.map([1, 2, 3], &(&1 * 2))
      assert :ok = Code.validate(ast, :pure)
    end

    test "blocks File at pure level" do
      ast = quote do: File.read("/etc/passwd")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :pure)
      assert {:module_not_allowed, File, :pure} in violations
    end

    test "allows File at limited level" do
      ast = quote do: File.read("/tmp/safe.txt")
      assert :ok = Code.validate(ast, :limited)
    end

    test "blocks System.cmd at all levels" do
      ast = quote do: System.cmd("rm", ["-rf", "/"])
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert {:forbidden_function, {System, :cmd}} in violations
    end

    test "blocks :os module calls" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
      ast = quote do: :os.cmd(~c"whoami")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert {:forbidden_module, :os} in violations
    end

    test "blocks Code.eval_string" do
      ast = quote do: Code.eval_string("IO.puts(:hacked)")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert {:forbidden_function, {@elixir_code, :eval_string}} in violations
    end

    test "blocks Process.exit" do
      ast = quote do: Process.exit(self(), :kill)
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :limited)
      assert {:forbidden_function, {Process, :exit}} in violations
    end

    test "allows everything in container level" do
      ast = quote do: SomeUnknownModule.do_anything()
      assert :ok = Code.validate(ast, :container)
    end
  end

  describe "check_module/2" do
    test "allows Enum at pure level" do
      assert :ok = Code.check_module(Enum, :pure)
    end

    test "blocks File at pure level" do
      assert {:error, :module_not_allowed} = Code.check_module(File, :pure)
    end

    test "allows File at limited level" do
      assert :ok = Code.check_module(File, :limited)
    end

    test "allows custom modules at full level" do
      assert :ok = Code.check_module(MyCustomModule, :full)
    end
  end

  describe "allowed_modules/1" do
    test "returns core modules for pure level" do
      modules = Code.allowed_modules(:pure)
      assert Enum in modules
      assert Map in modules
      assert String in modules
      refute File in modules
    end

    test "returns extended modules for limited level" do
      modules = Code.allowed_modules(:limited)
      assert Enum in modules
      assert File in modules
      assert GenServer in modules
    end
  end
end
