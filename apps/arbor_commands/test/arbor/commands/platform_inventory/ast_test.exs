defmodule Arbor.Commands.PlatformInventory.AstTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.PlatformInventory.Ast

  @moduletag :fast

  test "never executes the source it is given (parse-only, unsafe-to-run fixture)" do
    bytes = """
    defmodule Arbor.Dangerous.Example do
      raise "this must never execute during a pure AST scan"

      def loop, do: loop()
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/dangerous.ex", bytes)
    assert facts["modules"] == ["Arbor.Dangerous.Example"]
  end

  test "extracts a defmodule declaration" do
    bytes = """
    defmodule Arbor.Shell.Example do
      def hello, do: :world
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/example.ex", bytes)
    assert facts["modules"] == ["Arbor.Shell.Example"]
  end

  test "extracts multiple nested module declarations" do
    bytes = """
    defmodule Arbor.Shell.Outer do
      defmodule Inner do
        def go, do: :ok
      end
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/nested.ex", bytes)
    assert "Arbor.Shell.Outer" in facts["modules"]
    assert "Arbor.Shell.Outer.Inner" in facts["modules"]
  end

  test "detects OTP roles from use" do
    bytes = """
    defmodule Arbor.Shell.Server do
      use GenServer

      def init(state), do: {:ok, state}
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/server.ex", bytes)
    assert facts["otp_roles"] == ["genserver"]
  end

  test "detects application/config ownership" do
    bytes = """
    defmodule Arbor.Shell.Config do
      def timeout, do: Application.get_env(:arbor_shell, :timeout)
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/config.ex", bytes)
    assert facts["configuration"] == true
    assert facts["native"] == false
  end

  test "detects registered process and ETS table ownership as distinct facts" do
    bytes = """
    defmodule Arbor.Shell.Registry do
      def start do
        Process.register(self(), __MODULE__)
        :ets.new(:arbor_shell_table, [:named_table])
      end
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/registry.ex", bytes)
    assert facts["process"] == true
    assert facts["ownership"] == true
  end

  test "detects registry/callback seams via @behaviour and @impl" do
    bytes = """
    defmodule Arbor.Shell.Adapter do
      @behaviour Arbor.Shell.Adapter.Behaviour

      @impl true
      def run(_arg), do: :ok
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/adapter.ex", bytes)
    assert facts["registry"] == true
  end

  test "detects ports, NIF loading, and native command execution" do
    bytes = """
    defmodule Arbor.Shell.Native do
      @on_load :init_nif

      def init_nif, do: :erlang.load_nif(~c"priv/native", 0)
      def run(cmd), do: System.cmd(cmd, [])
      def open, do: Port.open({:spawn, "cat"}, [:binary])
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/native.ex", bytes)
    assert facts["native"] == true
  end

  test "detects network listener/client and connection-pool use" do
    bytes = """
    defmodule Arbor.Shell.Net do
      def listen, do: :gen_tcp.listen(4000, [])
      def pool, do: Finch.start_link(name: MyFinch)
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/net.ex", bytes)
    assert facts["network"] == true
  end

  test "detects filesystem scanning" do
    bytes = """
    defmodule Arbor.Shell.Scanner do
      def scan(dir), do: File.ls!(dir)
      def find(pattern), do: Path.wildcard(pattern)
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/scanner.ex", bytes)
    assert facts["filesystem_scan"] == true
  end

  test "detects dynamic module/code dispatch" do
    bytes = """
    defmodule Arbor.Shell.Dynamic do
      def dispatch(mod, fun, args), do: apply(mod, fun, args)
      def build(parts), do: Module.concat(parts)
      def run_string(code), do: Code.eval_string(code)
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/dynamic.ex", bytes)
    assert facts["dynamic_code"] == true
  end

  test "detects telemetry and logger handler attachment" do
    bytes = """
    defmodule Arbor.Shell.Telemetry do
      def attach, do: :telemetry.attach("id", [:arbor, :shell], &__MODULE__.handle/4, nil)
      def handle(_, _, _, _), do: :ok
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/telemetry.ex", bytes)
    assert facts["telemetry"] == true
  end

  test "an unrelated file has every boolean fact false and empty lists" do
    bytes = """
    defmodule Arbor.Shell.Plain do
      def add(a, b), do: a + b
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/plain.ex", bytes)

    for key <-
          ~w(configuration ownership registry process native network filesystem_scan dynamic_code telemetry) do
      assert facts[key] == false, "expected #{key} to be false"
    end

    assert facts["otp_roles"] == []
  end

  test "non-ASCII content in strings, docs, and identifiers parses cleanly" do
    bytes = """
    defmodule Arbor.Shell.Unicode do
      @moduledoc "Handles ünïcödé — café, naïve, 日本語"

      def greet, do: "こんにちは, señor"
    end
    """

    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/unicode.ex", bytes)
    assert facts["modules"] == ["Arbor.Shell.Unicode"]
  end

  test "malformed source returns a parse error instead of a false-empty report" do
    bytes = "defmodule Broken do\n  def oops(\n"

    assert {:error, {:parse_error, "apps/arbor_shell/lib/broken.ex", _}} =
             Ast.facts("apps/arbor_shell/lib/broken.ex", bytes)
  end

  test "empty file yields empty, non-error facts" do
    assert {:ok, facts} = Ast.facts("apps/arbor_shell/lib/empty.ex", "")
    assert facts["modules"] == []
    assert facts["otp_roles"] == []
  end

  test "rejects invalid and oversized path input before parsing" do
    assert {:error, :path_empty} = Ast.facts("", "defmodule Ignored do end")
    assert {:error, :path_invalid_utf8} = Ast.facts(<<255>>, "defmodule Ignored do end")
    assert {:error, :path_nul_byte} = Ast.facts("apps/\0ignored.ex", "defmodule Ignored do end")

    oversized = String.duplicate("p", 4_097)
    assert {:error, :path_too_long} = Ast.facts(oversized, "defmodule Ignored do end")
  end

  test "rejects invalid and oversized source input before parsing" do
    assert {:error, :source_invalid_utf8} = Ast.facts("apps/example.ex", <<255>>)

    oversized = String.duplicate("x", 1_048_577)
    assert {:error, :source_too_large} = Ast.facts("apps/example.ex", oversized)
  end

  test "fails closed at the AST node and depth ceilings" do
    repeated_calls = Enum.map_join(1..50_000, "\n", fn _ -> "noop(:a, :b, :c)" end)

    assert {:error, :ast_node_limit} = Ast.facts("apps/example.ex", repeated_calls)

    deeply_nested =
      Enum.reduce(1..300, ":ok", fn _, expression ->
        "{:ok, #{expression}}"
      end)

    assert {:error, :ast_depth_limit} = Ast.facts("apps/example.ex", deeply_nested)
  end

  test "fails closed at declared module, lexical alias, and OTP role ceilings" do
    modules =
      Enum.map_join(1..65, "\n", fn index ->
        "defmodule Ceiling.Module#{index} do\nend"
      end)

    assert {:error, :ast_module_limit} = Ast.facts("apps/example.ex", modules)

    aliases =
      Enum.map_join(1..65, "\n", fn index ->
        "alias Ceiling.Target#{index}"
      end)

    assert {:error, :ast_alias_limit} = Ast.facts("apps/example.ex", aliases)

    roles = Enum.map_join(1..17, "\n", fn _ -> "use GenServer" end)
    assert {:error, :ast_role_limit} = Ast.facts("apps/example.ex", roles)
  end

  test "keeps declared module names bounded and duplicate-free" do
    long_name = Enum.map_join(1..130, ".", fn _ -> "A" end)

    assert {:error, {:module_name, :too_long}} =
             Ast.facts("apps/example.ex", "defmodule #{long_name} do end")

    source = "defmodule Duplicate do end\ndefmodule Duplicate do end"
    assert {:ok, facts} = Ast.facts("apps/example.ex", source)
    assert facts["modules"] == ["Duplicate"]
  end

  test "resolves nested, absolute, and __MODULE__-relative declarations without composite atoms" do
    source = """
    defmodule Arbor.Inventory.Outer do
      defmodule Inner do
      end

      defmodule __MODULE__.Child do
      end

      defmodule Elixir.Inventory.Absolute do
      end
    end
    """

    assert {:ok, facts} = Ast.facts("apps/example.ex", source)

    assert facts["modules"] == [
             "Arbor.Inventory.Outer",
             "Arbor.Inventory.Outer.Inner",
             "Arbor.Inventory.Outer.Child",
             "Inventory.Absolute"
           ]
  end

  test "recognizes ordinary and as aliases only after declaration and keeps scope lexical" do
    source = """
    defmodule Arbor.Inventory.Aliases do
      Before.get_env(:app, :key)
      alias Application
      Application.get_env(:app, :key)
      alias File, as: Fs
      Fs.ls!()
    end

    defmodule Arbor.Inventory.NestedAliasScope do
      alias File, as: Fs

      defmodule Inner do
        Fs.ls!()
      end
    end
    """

    assert {:ok, facts} = Ast.facts("apps/example.ex", source)
    assert facts["configuration"] == true
    assert facts["filesystem_scan"] == true

    nested_only = """
    defmodule Arbor.Inventory.NestedAliasOnly do
      alias File, as: Fs

      defmodule Inner do
        Fs.ls!()
      end
    end
    """

    assert {:ok, nested_facts} = Ast.facts("apps/example.ex", nested_only)
    assert nested_facts["filesystem_scan"] == true

    non_leaking = """
    defmodule Arbor.Inventory.NonLeakingAlias do
      defmodule Inner do
        alias File, as: InnerFs
      end

      InnerFs.ls!()
    end
    """

    assert {:ok, non_leaking_facts} = Ast.facts("apps/example.ex", non_leaking)
    assert non_leaking_facts["filesystem_scan"] == false
  end

  test "resolves aliased watched receivers and traverses every watched form child" do
    source = """
    defmodule Arbor.Inventory.WatchedAliases do
      alias Application, as: App
      alias File, as: Fs
      alias GenServer, as: Server

      use Server, option: App.get_env(:app, :key)
      @behaviour App.get_env(:app, :key)
      @impl App.get_env(:app, :key)
      Fs.ls!(App.get_env(:app, :key))
    end
    """

    assert {:ok, facts} = Ast.facts("apps/example.ex", source)
    assert facts["configuration"] == true
    assert facts["filesystem_scan"] == true
    assert facts["registry"] == true
    assert facts["otp_roles"] == ["genserver"]
  end

  test "fails closed when a remote receiver exceeds the bounded name limit" do
    receiver = Enum.map_join(1..130, ".", fn _ -> "A" end)

    assert {:error, {:receiver_name, :too_long}} =
             Ast.facts("apps/example.ex", "#{receiver}.ping()")
  end

  test "does not expand dynamic aliases or execute unsafe syntax" do
    source = """
    defmodule Arbor.Inventory.Unsafe do
      alias unquote(raise("alias expansion must not execute")), as: App
      raise "source body must not execute"
      App.get_env(:app, :key)
    end
    """

    assert {:ok, facts} = Ast.facts("apps/example.ex", source)
    assert facts["modules"] == ["Arbor.Inventory.Unsafe"]
    assert facts["configuration"] == false
  end

  test "scans do not intern composite module atoms beyond parser-created parts" do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    module = "AstAtomProof#{suffix}"
    composite = "Elixir.#{module}.Nested"

    refute existing_atom?(composite)

    source = """
    defmodule #{module} do
      defmodule Nested do
      end

      Elixir.#{module}.Nested.ping()
    end
    """

    assert {:ok, _facts} = Ast.facts("apps/example.ex", source)
    refute existing_atom?(composite)
  end

  defp existing_atom?(value) do
    String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
