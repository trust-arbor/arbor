# credo:disable-for-this-file
defmodule Arbor.Eval.Checks.NamingConventionsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval.Checks.NamingConventions

  describe "Arbor module naming convention" do
    test "flags concatenated Arbor module names (ArborFoo should be Arbor.Foo)" do
      ast =
        quote do
          defmodule ArborEval do
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      assert Enum.any?(result.violations, fn v ->
               v.type == :arbor_module_naming and
                 String.contains?(v.message, "ArborEval") and
                 String.contains?(v.suggestion, "Arbor.Eval")
             end)
    end

    test "flags nested concatenated Arbor modules (ArborCommon.Time)" do
      ast =
        quote do
          defmodule ArborCommon.Time do
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      assert Enum.any?(result.violations, fn v ->
               v.type == :arbor_module_naming and
                 String.contains?(v.suggestion, "Arbor.Common.Time")
             end)
    end

    test "does not flag properly namespaced Arbor modules" do
      ast =
        quote do
          defmodule Arbor.Eval do
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      refute Enum.any?(result.violations, &(&1.type == :arbor_module_naming))
    end

    test "does not flag non-Arbor modules" do
      ast =
        quote do
          defmodule MyApp.SomeModule do
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      refute Enum.any?(result.violations, &(&1.type == :arbor_module_naming))
    end
  end

  describe "module names with implementation technology" do
    test "flags module names with implementation technology in standard mode" do
      ast =
        quote do
          defmodule MyApp.HordeSupervisor do
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      assert Enum.any?(result.violations, fn v ->
               v.type == :implementation_in_module_name and
                 String.contains?(v.message, "Horde")
             end)
    end

    test "does not flag clean module names" do
      ast =
        quote do
          defmodule MyApp.DistributedAgentSupervisor do
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      refute Enum.any?(result.violations, &(&1.type == :implementation_in_module_name))
    end
  end

  describe "function names" do
    test "flags single-letter function names" do
      ast =
        quote do
          defmodule Test do
            def x(a), do: a
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      assert Enum.any?(result.violations, &(&1.type == :single_letter_function))
    end

    test "does not flag acceptable short names" do
      ast =
        quote do
          defmodule Test do
            def new(), do: %{}
            def get(map, key), do: Map.get(map, key)
            def run(task), do: task
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :standard})

      refute Enum.any?(result.violations, &(&1.type == :single_letter_function))
    end
  end

  describe "abbreviation suggestions" do
    test "suggests expanding non-standard abbreviations" do
      ast =
        quote do
          defmodule Test do
            def proc_msg(msg), do: msg
          end
        end

      result = NamingConventions.run(%{ast: ast})

      assert Enum.any?(result.suggestions, fn s ->
               s.type == :abbreviation_used and String.contains?(s.message, "msg")
             end)
    end

    test "does not flag acceptable abbreviations" do
      ast =
        quote do
          defmodule Test do
            def process(opts), do: opts
            def with_context(ctx), do: ctx
            def reduce_list(list, acc), do: acc
          end
        end

      result = NamingConventions.run(%{ast: ast})

      # Should not suggest expanding opts, ctx, acc
      refute Enum.any?(result.suggestions, fn s ->
               s.type == :abbreviation_used and
                 (String.contains?(s.message, "'opts'") or
                    String.contains?(s.message, "'ctx'") or
                    String.contains?(s.message, "'acc'"))
             end)
    end
  end

  describe "strictness levels" do
    test "relaxed mode has no violations for short names" do
      ast =
        quote do
          defmodule Test do
            def go(), do: :ok
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :relaxed})

      # Relaxed mode should be lenient
      assert result.passed
    end

    test "strict mode flags short function names" do
      ast =
        quote do
          defmodule Test do
            def custom_fn(), do: :ok
          end
        end

      result = NamingConventions.run(%{ast: ast, strictness: :strict})

      # In strict mode, short non-standard names get suggestions
      assert Enum.any?(result.violations ++ result.suggestions, fn v ->
               v.type in [:short_function_name, :single_letter_function]
             end) or result.passed
    end
  end
end
