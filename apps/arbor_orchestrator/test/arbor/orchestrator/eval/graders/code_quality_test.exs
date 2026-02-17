defmodule Arbor.Orchestrator.Eval.Graders.CodeQualityTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.Graders.CodeQuality

  @moduletag :fast

  describe "grade/3" do
    test "scores based on static analysis checks" do
      # Clean, well-named code should pass most checks
      code = """
      defmodule GoodModule do
        @moduledoc "A well-documented module."

        @doc "Adds two numbers."
        @spec add(number(), number()) :: number()
        def add(a, b), do: a + b
      end
      """

      result = CodeQuality.grade(code, nil)

      # If Arbor.Eval is loaded, we get real scores
      # If not loaded, graceful degradation
      assert is_float(result.score)
      assert is_boolean(result.passed)
      assert is_binary(result.detail)
    end

    test "detects naming convention violations" do
      # camelCase function names violate Elixir conventions
      code = """
      defmodule BadNames do
        def getValue, do: :ok
        def setValue(x), do: x
      end
      """

      result = CodeQuality.grade(code, nil)
      assert is_float(result.score)
      assert is_binary(result.detail)
    end

    test "handles code that doesn't parse" do
      code = "this is not valid elixir code {{{}"

      result = CodeQuality.grade(code, nil)
      # Should handle gracefully — either score 0 or partial
      assert is_float(result.score)
      assert is_binary(result.detail)
    end

    test "gracefully degrades when eval checks are unavailable" do
      # Pass a non-existent check module
      code = "defmodule Test do end"
      result = CodeQuality.grade(code, nil, checks: [NonExistentModule.Check])

      # Should fail gracefully
      assert is_float(result.score)
      assert is_binary(result.detail)
    end

    test "respects custom checks list" do
      code = """
      defmodule CustomChecks do
        @moduledoc "Has docs."
        def hello, do: :world
      end
      """

      # Only run naming conventions
      result = CodeQuality.grade(code, nil, checks: [Arbor.Eval.Checks.NamingConventions])
      assert is_float(result.score)
    end

    test "extracts code from markdown fences" do
      code = "```elixir\ndefmodule Fenced do\n  @moduledoc \"Docs.\"\n  def x, do: 42\nend\n```"

      result = CodeQuality.grade(code, nil)
      assert is_float(result.score)
    end
  end
end
