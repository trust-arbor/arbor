defmodule Arbor.Orchestrator.Eval.Graders.FunctionalTestTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Eval.Graders.FunctionalTest

  @moduletag :fast

  describe "grade/3" do
    test "scores 1.0 when all assertions pass" do
      code = """
      defmodule Adder do
        def add(a, b), do: a + b
        def zero, do: 0
      end
      """

      expected = %{
        "module" => "Adder",
        "tests" => [
          %{"call" => "Adder.add(1, 2)", "expect" => "3"},
          %{"call" => "Adder.add(0, 0)", "expect" => "0"},
          %{"call" => "Adder.zero()", "expect" => "0"}
        ]
      }

      result = FunctionalTest.grade(code, expected)
      assert result.score == 1.0
      assert result.passed == true
      assert result.detail =~ "3/3 tests passed"
    end

    test "scores fractionally when some assertions fail" do
      code = """
      defmodule PartialCalc do
        def add(a, b), do: a + b
        def multiply(a, b), do: a + b
      end
      """

      expected = %{
        "tests" => [
          %{"call" => "PartialCalc.add(2, 3)", "expect" => "5"},
          %{"call" => "PartialCalc.multiply(2, 3)", "expect" => "6"}
        ]
      }

      result = FunctionalTest.grade(code, expected)
      assert result.score == 0.5
      assert result.detail =~ "1/2 tests passed"
    end

    test "scores 0.0 when code doesn't compile" do
      code = "defmodule Broken do\n  def foo(, do: :bar\nend"
      expected = %{"tests" => [%{"call" => "Broken.foo()", "expect" => ":bar"}]}

      result = FunctionalTest.grade(code, expected)
      assert result.score == 0.0
      assert result.passed == false
      assert result.detail =~ "compilation failed"
    end

    test "handles match pattern assertions" do
      code = """
      defmodule MatchTest do
        def ok_tuple(x), do: {:ok, x}
      end
      """

      expected = %{
        "tests" => [
          %{"call" => "MatchTest.ok_tuple(42)", "match" => "{:ok, _}"}
        ]
      }

      result = FunctionalTest.grade(code, expected)
      assert result.score == 1.0
      assert result.passed == true
    end

    test "handles setup code before call" do
      code = """
      defmodule WithSetup do
        def greet(name), do: "Hello, \#{name}!"
      end
      """

      expected = %{
        "tests" => [
          %{
            "setup" => "name = \"World\"",
            "call" => "WithSetup.greet(name)",
            "expect" => "\"Hello, World!\""
          }
        ]
      }

      result = FunctionalTest.grade(code, expected)
      assert result.score == 1.0
    end

    test "returns 0.0 when no tests in expected" do
      result = FunctionalTest.grade("defmodule Empty do end", %{})
      assert result.score == 0.0
      assert result.detail =~ "no test assertions"
    end

    test "cleans up compiled modules after grading" do
      code = """
      defmodule CleanupCheck do
        def hello, do: :world
      end
      """

      expected = %{
        "tests" => [%{"call" => "CleanupCheck.hello()", "expect" => ":world"}]
      }

      FunctionalTest.grade(code, expected)

      # The actual module should be cleaned up (munged name shouldn't persist)
      # Original name was never compiled — only munged version was
      refute :code.is_loaded(CleanupCheck)
    end

    test "handles test timeout gracefully" do
      code = """
      defmodule SlowTest do
        def slow do
          Process.sleep(10_000)
          :done
        end
      end
      """

      expected = %{
        "tests" => [%{"call" => "SlowTest.slow()", "expect" => ":done"}]
      }

      result = FunctionalTest.grade(code, expected, timeout: 100)
      assert result.score == 0.0
      assert result.detail =~ "timeout"
    end

    test "extracts code from markdown fences" do
      code = "```elixir\ndefmodule Fenced do\n  def x, do: 42\nend\n```"

      expected = %{
        "tests" => [%{"call" => "Fenced.x()", "expect" => "42"}]
      }

      result = FunctionalTest.grade(code, expected)
      assert result.score == 1.0
    end
  end
end
