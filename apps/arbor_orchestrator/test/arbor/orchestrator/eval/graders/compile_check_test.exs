defmodule Arbor.Orchestrator.Eval.Graders.CompileCheckTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.Graders.CompileCheck

  @moduletag :fast

  describe "grade/3" do
    test "scores 1.0 for clean-compiling code" do
      code = """
      defmodule CleanModule_CC1 do
        def hello, do: :world
      end
      """

      result = CompileCheck.grade(code, nil)
      assert result.score == 1.0
      assert result.passed == true
      assert result.detail == "compiles clean"
    end

    test "scores 0.0 for syntax errors" do
      code = "defmodule Bad_CC do\n  def foo(, do: :bar\nend"

      result = CompileCheck.grade(code, nil)
      assert result.score == 0.0
      assert result.passed == false
      assert result.detail =~ "compilation failed"
    end

    test "scores 1.0 when code compiles with warnings (e.g., @impl without behaviour)" do
      # Code uses @impl true without `use GenServer` — compiles with warnings only
      code = """
      defmodule NoUse_CC do
        @impl true
        def init(state), do: {:ok, state}

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}

        def start_link(init) do
          GenServer.start_link(__MODULE__, init)
        end
      end
      """

      result = CompileCheck.grade(code, nil)
      # Elixir compiles this with warnings (not errors), so it scores 1.0
      assert result.score == 1.0
      assert result.passed == true
    end

    test "scores 0.5 when boilerplate injection fixes a compile error" do
      # Use code that's broken in a way injection can't fix
      broken_code = """
      defmodule BrokenCC do
        # Missing closing end for inner function
        def foo do
          if true do
            :ok
        end
      end
      """

      # This won't be fixed by boilerplate injection either, so it should score 0.0
      result = CompileCheck.grade(broken_code, nil)
      assert result.score == 0.0
      assert result.passed == false
    end

    test "scores 0.0 when boilerplate injection doesn't help" do
      code = """
      defmodule TotallyBroken_CC do
        def foo do
          unknown_function_that_doesnt_exist()
      end
      """

      result = CompileCheck.grade(code, nil)
      assert result.score == 0.0
      assert result.passed == false
    end

    test "handles empty string" do
      result = CompileCheck.grade("", nil)
      # Empty string compiles as nil (valid Elixir)
      assert result.score == 1.0
    end

    test "respects custom pass_threshold" do
      # Clean code always scores 1.0, which passes any threshold
      code = """
      defmodule ThresholdCC do
        def hello, do: :world
      end
      """

      result = CompileCheck.grade(code, nil, pass_threshold: 0.9)
      assert result.score == 1.0
      assert result.passed == true

      # Broken code scores 0.0, which fails any positive threshold
      broken = "defmodule Broken_T_CC do\n  def foo(, do: :bar\nend"
      result2 = CompileCheck.grade(broken, nil, pass_threshold: 0.1)
      assert result2.score == 0.0
      assert result2.passed == false
    end

    test "respects custom inject_boilerplate list" do
      # Test that custom boilerplate list is used
      code = """
      defmodule CustomBPCC do
        def hello, do: :world
      end
      """

      # Clean code compiles regardless of boilerplate list
      result = CompileCheck.grade(code, nil, inject_boilerplate: [])
      assert result.score == 1.0

      # Broken code with empty boilerplate = no recovery
      broken = "defmodule BrokenBPCC do\n  def foo(, do: :bar\nend"
      result2 = CompileCheck.grade(broken, nil, inject_boilerplate: [])
      assert result2.score == 0.0
    end
  end

  describe "extract_code/1" do
    test "extracts from elixir markdown fence" do
      text =
        "Here's the code:\n```elixir\ndefmodule Foo do\n  def bar, do: :baz\nend\n```\nThat's it."

      assert CompileCheck.extract_code(text) == "defmodule Foo do\n  def bar, do: :baz\nend"
    end

    test "extracts from plain markdown fence" do
      text = "```\ndef hello, do: :world\n```"
      assert CompileCheck.extract_code(text) == "def hello, do: :world"
    end

    test "returns trimmed text when no fence" do
      text = "  defmodule Foo do end  "
      assert CompileCheck.extract_code(text) == "defmodule Foo do end"
    end
  end
end
