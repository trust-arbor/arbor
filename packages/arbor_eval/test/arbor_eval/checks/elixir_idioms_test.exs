defmodule ArborEval.Checks.ElixirIdiomsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias ArborEval.Checks.ElixirIdioms

  describe "defensive nil checks" do
    test "detects != nil pattern" do
      ast =
        quote do
          def test(x) do
            if x != nil, do: x
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :defensive_nil_check))
    end

    test "detects not is_nil/1 pattern" do
      ast =
        quote do
          def test(x) do
            if not is_nil(x), do: x
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :defensive_nil_check))
    end

    test "detects unless is_nil pattern" do
      ast =
        quote do
          def test(x) do
            unless is_nil(x), do: x
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :defensive_nil_check))
    end
  end

  describe "nested if detection" do
    test "detects nested if statements" do
      ast =
        quote do
          def test(x, y) do
            if x do
              if y do
                :both
              end
            end
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :nested_if))
    end

    test "does not flag single if" do
      ast =
        quote do
          def test(x) do
            if x, do: :yes, else: :no
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      refute Enum.any?(result.violations, &(&1.type == :nested_if))
    end
  end

  describe "try/rescue control flow" do
    test "detects bare try/rescue for control flow" do
      ast =
        quote do
          def test(x) do
            try do
              String.to_integer(x)
            rescue
              _ -> 0
            end
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      assert Enum.any?(result.violations, &(&1.type == :try_rescue_control_flow))
    end
  end

  describe "inefficient enum order" do
    test "detects Enum.map followed by Enum.filter (inefficient)" do
      # Map then filter is inefficient - filter first to reduce list size
      ast =
        quote do
          def test(list) do
            list
            |> Enum.map(&(&1 * 2))
            |> Enum.filter(&(&1 > 0))
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      # Check in violations (where it's added, with severity :suggestion)
      assert Enum.any?(result.violations, fn v ->
               v.type == :inefficient_enum_order
             end)
    end

    test "does not flag Enum.filter followed by Enum.map (efficient)" do
      # Filter then map is fine - reduces list size first
      ast =
        quote do
          def test(list) do
            list
            |> Enum.filter(&(&1 > 0))
            |> Enum.map(&(&1 * 2))
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      # Should NOT flag this pattern
      refute Enum.any?(result.violations, fn v ->
               v.type == :inefficient_enum_order
             end)
    end
  end

  describe "missing specs" do
    test "detects public function without @spec" do
      ast =
        quote do
          defmodule Test do
            def public_function(x), do: x
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      assert Enum.any?(result.suggestions, &(&1.type == :missing_spec))
    end
  end

  describe "GenServer.call without timeout" do
    test "detects call without timeout" do
      ast =
        quote do
          def get_state(pid) do
            GenServer.call(pid, :get_state)
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      # Violations with severity :warning
      assert Enum.any?(result.violations, &(&1.type == :genserver_call_no_timeout))
    end

    test "does not flag call with timeout" do
      ast =
        quote do
          def get_state(pid) do
            GenServer.call(pid, :get_state, 5000)
          end
        end

      result = ElixirIdioms.run(%{ast: ast})

      refute Enum.any?(result.violations, &(&1.type == :genserver_call_no_timeout))
    end
  end
end
