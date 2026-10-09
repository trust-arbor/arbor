defmodule Arbor.Orchestrator.Eval.Graders.FunctionalTestTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Eval.Graders.FunctionalTest

  @moduletag :fast

  @detail "functional execution disabled: isolated evaluator required"

  describe "grade/3" do
    test "security regression: untrusted subject is not compiled or executed" do
      code = """
      defmodule AdderFT do
        def add(a, b), do: a + b
        def zero, do: 0
      end
      """

      expected = %{
        "module" => "AdderFT",
        "tests" => [
          %{"call" => "AdderFT.add(1, 2)", "expect" => "3"},
          %{"call" => "AdderFT.add(0, 0)", "expect" => "0"},
          %{"call" => "AdderFT.zero()", "expect" => "0"}
        ]
      }

      assert FunctionalTest.grade(code, expected) == %{
               score: 0.0,
               passed: false,
               detail: @detail
             }

      refute :code.is_loaded(AdderFT)
    end

    test "security regression: partial, broken, match, setup, and fenced subjects stay unexecuted" do
      subjects = [
        {"""
         defmodule PartialCalcFT do
           def add(a, b), do: a + b
         end
         """, %{"tests" => [%{"call" => "PartialCalcFT.add(2, 3)", "expect" => "5"}]}, []},
        {"defmodule BrokenFT do\n  def foo(, do: :bar\nend",
         %{"tests" => [%{"call" => "BrokenFT.foo()", "expect" => ":bar"}]}, []},
        {"""
         defmodule MatchTestFT do
           def ok_tuple(x), do: {:ok, x}
         end
         """, %{"tests" => [%{"call" => "MatchTestFT.ok_tuple(42)", "match" => "{:ok, _}"}]}, []},
        {"```elixir\ndefmodule FencedFT do\n  def x, do: 42\nend\n```",
         %{"tests" => [%{"call" => "FencedFT.x()", "expect" => "42"}]}, []},
        {"defmodule EmptyFT do end", %{}, []}
      ]

      for {code, expected, opts} <- subjects do
        assert FunctionalTest.grade(code, expected, opts) == %{
                 score: 0.0,
                 passed: false,
                 detail: @detail
               }
      end

      refute :code.is_loaded(PartialCalcFT)
      refute :code.is_loaded(FencedFT)
    end

    test "security regression: a timeout option cannot start the subject" do
      code = """
      defmodule SlowTestFT do
        def slow do
          Process.sleep(10_000)
          :done
        end
      end
      """

      result =
        FunctionalTest.grade(
          code,
          %{"tests" => [%{"call" => "SlowTestFT.slow()", "expect" => ":done"}]},
          timeout: 100
        )

      assert result == %{score: 0.0, passed: false, detail: @detail}
      refute :code.is_loaded(SlowTestFT)
    end
  end
end
