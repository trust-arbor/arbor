defmodule Arbor.Sandbox.CodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Sandbox.Code

  describe "validate/2" do
    test "allows safe code at pure level" do
      ast = quote do: Enum.map([1, 2, 3], &(&1 * 2))
      assert :ok = Code.validate(ast, :pure)
    end

    test "blocks File at pure level" do
      ast = quote do: File.read("/etc/passwd")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :pure)
      assert Enum.any?(violations, &(&1.type == :forbidden_module))
      assert Enum.any?(violations, &String.contains?(&1.description, "File"))
    end

    test "allows File at limited level" do
      ast = quote do: File.read("/tmp/safe.txt")
      assert :ok = Code.validate(ast, :limited)
    end

    test "blocks System.cmd at strict level" do
      ast = quote do: System.cmd("echo", ["hello"])
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :strict)
      assert Enum.any?(violations, &(&1.type == :level_restricted))
      assert Enum.any?(violations, &String.contains?(&1.description, "System.cmd"))
    end

    test "allows System.cmd at limited level" do
      # System.cmd is in @limited_functions, allowed at :limited and above
      ast = quote do: System.cmd("echo", ["hello"])
      assert :ok = Code.validate(ast, :limited)
    end

    test "blocks :os module calls" do
      # credo:disable-for-next-line
      ast = quote do: :os.cmd(~c"whoami")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert Enum.any?(violations, &(&1.type == :forbidden_module))
      assert Enum.any?(violations, &String.contains?(&1.description, ":os"))
    end

    test "blocks Code.eval_string at all levels" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
      ast = quote do: Code.eval_string("IO.puts(:hacked)")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert Enum.any?(violations, &(&1.type == :dangerous_call))
      assert Enum.any?(violations, &String.contains?(&1.description, "eval_string"))
    end

    test "blocks Process.exit at all levels" do
      ast = quote do: Process.exit(self(), :kill)
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :limited)
      assert Enum.any?(violations, &(&1.type == :dangerous_call))
      assert Enum.any?(violations, &String.contains?(&1.description, "Process.exit"))
    end

    test "blocks :erlang.halt at all levels" do
      ast = quote do: :erlang.halt()
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert Enum.any?(violations, &(&1.type == :dangerous_call))
    end

    test "blocks File.rm_rf! at all levels" do
      ast = quote do: File.rm_rf!("/tmp/test")
      assert {:error, {:code_violations, violations}} = Code.validate(ast, :full)
      assert Enum.any?(violations, &(&1.type == :dangerous_call))
    end

    test "allows everything in container level" do
      ast = quote do: SomeUnknownModule.do_anything()
      assert :ok = Code.validate(ast, :container)
    end
  end

  describe "validate_for_tier/2" do
    test "validates against untrusted tier (strict sandbox)" do
      # File should be blocked for untrusted (maps to :strict)
      ast = quote do: File.read("/etc/passwd")
      assert {:error, {:code_violations, _}} = Code.validate_for_tier(ast, :untrusted)
    end

    test "validates against trusted tier (standard sandbox)" do
      # File should be allowed for trusted (maps to :standard)
      ast = quote do: File.read("/tmp/safe.txt")
      assert :ok = Code.validate_for_tier(ast, :trusted)
    end

    test "blocks dangerous calls at autonomous tier" do
      # Code.eval_string should be blocked even for autonomous
      # credo:disable-for-next-line Credo.Check.Security.UnsafeCodeEval
      ast = quote do: Code.eval_string("1 + 1")
      assert {:error, {:code_violations, _}} = Code.validate_for_tier(ast, :autonomous)
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

  describe "check_module_for_tier/2" do
    test "blocks File for untrusted tier" do
      assert {:error, :module_not_allowed} = Code.check_module_for_tier(File, :untrusted)
    end

    test "allows File for trusted tier" do
      assert :ok = Code.check_module_for_tier(File, :trusted)
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

    test "returns :all for none level" do
      assert :all = Code.allowed_modules(:none)
    end
  end

  describe "restricted_functions/1" do
    test "includes limited functions at strict level" do
      restricted = Code.restricted_functions(:strict)
      assert {System, :cmd} in restricted
      assert {Port, :open} in restricted
    end

    test "excludes limited functions at standard level" do
      restricted = Code.restricted_functions(:standard)
      refute {System, :cmd} in restricted
      refute {Port, :open} in restricted
    end

    test "always includes dangerous functions" do
      for level <- [:strict, :standard, :permissive, :none] do
        restricted = Code.restricted_functions(level)
        # Use Elixir.Code to avoid confusion with Arbor.Sandbox.Code alias
        assert {Elixir.Code, :eval_string} in restricted
        assert {:erlang, :halt} in restricted
      end
    end
  end
end
