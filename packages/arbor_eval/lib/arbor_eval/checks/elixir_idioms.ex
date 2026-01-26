defmodule ArborEval.Checks.ElixirIdioms do
  @moduledoc """
  Checks for idiomatic Elixir patterns and flags common AI-generated anti-patterns.

  Based on community best practices from authoritative repos (elixir, phoenix, ecto)
  and common issues identified in AI-generated Elixir code.

  ## Anti-Patterns Detected

  - Defensive nil-checking (`if x != nil`)
  - Nested if/else chains
  - Inefficient Enum ordering (map before filter)
  - Try/rescue for control flow
  - Missing @spec on public functions
  - GenServer.call without timeout

  ## Reference

  - ADR-012: Eval Framework Plan
  - https://getboothiq.com/blog/150k-lines-vibe-coded-elixir-good-bad-ugly
  """

  use ArborEval,
    name: "elixir_idioms",
    category: :code_quality,
    description: "Checks for idiomatic Elixir patterns"

  @impl ArborEval
  def run(%{ast: ast} = context) do
    violations =
      []
      |> check_defensive_nil(ast)
      |> check_nested_if(ast)
      |> check_inefficient_enum_order(ast)
      |> check_try_rescue_control_flow(ast)
      |> check_genserver_call_no_timeout(ast)
      |> check_string_interpolation_inspect(ast)

    suggestions =
      []
      |> suggest_with_clause(ast)
      |> check_missing_specs(ast, context)

    %{
      passed: Enum.empty?(Enum.filter(violations, &(&1.severity == :error))),
      violations: violations,
      suggestions: suggestions
    }
  end

  def run(_context) do
    %{passed: false, violations: [%{type: :no_ast, message: "No AST provided", severity: :error}]}
  end

  # ============================================================================
  # Anti-Pattern Checks
  # ============================================================================

  @doc """
  Detect: `if x != nil do` or `if !is_nil(x) do`

  These defensive patterns mask bugs and aren't idiomatic.
  Use pattern matching instead.
  """
  def check_defensive_nil(violations, ast) do
    found =
      find_nodes(ast, fn
        # if x != nil do
        {:if, meta, [{:!=, _, [_, nil]}, _]} ->
          {:found, meta}

        # if !is_nil(x) do OR if not is_nil(x) do
        {:if, meta, [{:not, _, [{:is_nil, _, _}]}, _]} ->
          {:found, meta}

        # unless is_nil(x) do
        {:unless, meta, [{:is_nil, _, _}, _]} ->
          {:found, meta}

        _ ->
          nil
      end)

    new_violations =
      Enum.map(found, fn meta ->
        %{
          type: :defensive_nil_check,
          message: "Defensive nil check - use pattern matching instead of `if x != nil`",
          line: meta[:line],
          column: meta[:column],
          severity: :warning,
          suggestion: "Pattern match in function head: `def foo(%{x: x}) when not is_nil(x)`"
        }
      end)

    violations ++ new_violations
  end

  @doc """
  Detect: Nested if/else statements.

  These are hard to read and usually indicate imperative thinking.
  Use `with`, `case`, or pattern matching.
  """
  def check_nested_if(violations, ast) do
    found =
      find_nodes(ast, fn
        # if ... do if ... end end
        {:if, meta, [_, [do: {:if, _, _}]]} ->
          {:found, meta}

        {:if, meta, [_, [do: {:if, _, _}, else: _]]} ->
          {:found, meta}

        {:if, meta, [_, [do: _, else: {:if, _, _}]]} ->
          {:found, meta}

        # if ... do: if ...
        {:if, meta, [_, [do: {:if, _, _}]]} ->
          {:found, meta}

        _ ->
          nil
      end)

    new_violations =
      Enum.map(found, fn meta ->
        %{
          type: :nested_if,
          message: "Nested if/else - use `with` clause or pattern matching",
          line: meta[:line],
          column: meta[:column],
          severity: :warning,
          suggestion:
            "Refactor using `with {:ok, a} <- check1(), {:ok, b} <- check2() do ... end`"
        }
      end)

    violations ++ new_violations
  end

  @doc """
  Detect: `Enum.map(...) |> Enum.filter(...)`

  Filter should come before map to reduce intermediate list size.
  """
  def check_inefficient_enum_order(violations, ast) do
    found =
      find_nodes(ast, fn
        # |> Enum.map(...) |> Enum.filter(...)
        {:|>, meta,
         [
           {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
           {{:., _, [{:__aliases__, _, [:Enum]}, :filter]}, _, _}
         ]} ->
          {:found, meta}

        # Enum.filter(Enum.map(...), ...)
        {{:., meta, [{:__aliases__, _, [:Enum]}, :filter]}, _,
         [{{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}, _]} ->
          {:found, meta}

        _ ->
          nil
      end)

    new_violations =
      Enum.map(found, fn meta ->
        %{
          type: :inefficient_enum_order,
          message: "Enum.map before Enum.filter - filter first to reduce intermediate list",
          line: meta[:line],
          column: meta[:column],
          severity: :suggestion,
          suggestion: "Reorder: `|> Enum.filter(...) |> Enum.map(...)`"
        }
      end)

    violations ++ new_violations
  end

  @doc """
  Detect: try/rescue used for control flow.

  Exceptions should be exceptional, not used for normal control flow.
  """
  def check_try_rescue_control_flow(violations, ast) do
    found =
      find_nodes(ast, fn
        # try do ... rescue _ -> default end
        {:try, meta, [[do: _, rescue: [{:->, _, [[{:_, _, _}], _]}]]]} ->
          {:found, meta}

        # try do ... rescue _e -> default end
        {:try, meta, [[do: _, rescue: [{:->, _, [[{name, _, _}], _]}]]]}
        when is_atom(name) and name != :_ ->
          # Check if it's a catch-all pattern (single var, no match)
          {:found, meta}

        _ ->
          nil
      end)

    new_violations =
      Enum.map(found, fn meta ->
        %{
          type: :try_rescue_control_flow,
          message: "try/rescue with catch-all - don't use exceptions for control flow",
          line: meta[:line],
          column: meta[:column],
          severity: :warning,
          suggestion: "Use pattern matching, `with`, or `case` for expected error handling"
        }
      end)

    violations ++ new_violations
  end

  @doc """
  Detect: GenServer.call without explicit timeout.

  Always specify timeout to avoid hanging indefinitely.
  """
  def check_genserver_call_no_timeout(violations, ast) do
    found =
      find_nodes(ast, fn
        # GenServer.call(pid, msg) - only 2 args, missing timeout
        {{:., meta, [{:__aliases__, _, [:GenServer]}, :call]}, _, [_pid, _msg]} ->
          {:found, meta}

        _ ->
          nil
      end)

    new_violations =
      Enum.map(found, fn meta ->
        %{
          type: :genserver_call_no_timeout,
          message: "GenServer.call without timeout - add explicit timeout as third argument",
          line: meta[:line],
          column: meta[:column],
          severity: :warning,
          suggestion:
            "Add timeout: `GenServer.call(pid, msg, 5_000)` or `GenServer.call(pid, msg, :infinity)`"
        }
      end)

    violations ++ new_violations
  end

  @doc """
  Detect: Excessive `"\#{inspect(x)}"` usage.

  Often indicates wrong type coercion or lazy debugging.
  """
  def check_string_interpolation_inspect(violations, ast) do
    found =
      find_nodes(ast, fn
        # "#{inspect(...)}"
        {:<<>>, meta,
         [
           _,
           {:"::", _,
            [
              {{:., _, [Kernel, :to_string]}, _,
               [{{:., _, [{:__aliases__, _, [:Kernel]}, :inspect]}, _, _}]},
              _
            ]}
           | _
         ]} ->
          {:found, meta}

        # More common form: "#{inspect(x)}"
        {:<<>>, meta, parts} when is_list(parts) ->
          has_inspect =
            Enum.any?(parts, fn
              {:"::", _,
               [
                 {{:., _, [Kernel, :to_string]}, _, [{:inspect, _, _}]},
                 _
               ]} ->
                true

              _ ->
                false
            end)

          if has_inspect, do: {:found, meta}, else: nil

        _ ->
          nil
      end)

    new_violations =
      Enum.map(found, fn meta ->
        %{
          type: :string_interpolation_inspect,
          message: "String interpolation with inspect - consider proper formatting",
          line: meta[:line],
          column: meta[:column],
          severity: :suggestion,
          suggestion: "Use Logger for debugging, or proper type conversion for display"
        }
      end)

    violations ++ new_violations
  end

  # ============================================================================
  # Suggestion Checks (things that could be better)
  # ============================================================================

  @doc """
  Suggest using `with` for sequences of pattern matches.
  """
  def suggest_with_clause(suggestions, ast) do
    found =
      find_nodes(ast, fn
        # case x do {:ok, a} -> case y do {:ok, b} -> ...
        {:case, meta, [_, [do: [{:->, _, [[{:ok, _}], {:case, _, _}]}]]]} ->
          {:found, meta}

        _ ->
          nil
      end)

    new_suggestions =
      Enum.map(found, fn meta ->
        %{
          type: :could_use_with,
          message: "Nested case statements could be simplified with `with`",
          line: meta[:line],
          column: meta[:column],
          severity: :suggestion,
          suggestion: "Use `with {:ok, a} <- step1(), {:ok, b} <- step2() do ... end`"
        }
      end)

    suggestions ++ new_suggestions
  end

  @doc """
  Check for missing @spec on public functions.
  """
  def check_missing_specs(suggestions, ast, _context) do
    # Only check if we have module-level AST
    case ast do
      {:defmodule, _, [_, [do: {:__block__, _, body}]]} ->
        check_specs_in_body(suggestions, body)

      {:defmodule, _, [_, [do: body]]} when not is_list(body) ->
        check_specs_in_body(suggestions, [body])

      _ ->
        # Not a module definition, skip
        suggestions
    end
  end

  defp check_specs_in_body(suggestions, body) do
    # Find all public function definitions
    public_funs =
      Enum.flat_map(body, fn
        {:def, meta, [{name, _, args}, _]} when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0
          [{name, arity, meta}]

        {:def, meta, [{:when, _, [{name, _, args} | _]}, _]} when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0
          [{name, arity, meta}]

        _ ->
          []
      end)

    # Find all specs
    specs =
      Enum.flat_map(body, fn
        {:@, _, [{:spec, _, [{:"::", _, [{name, _, args}, _]}]}]} when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0
          [{name, arity}]

        {:@, _, [{:spec, _, [{:when, _, [{:"::", _, [{name, _, args}, _]} | _]}]}]}
        when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0
          [{name, arity}]

        _ ->
          []
      end)

    # Find functions without specs
    spec_set = MapSet.new(specs)

    missing =
      Enum.filter(public_funs, fn {name, arity, _meta} ->
        not MapSet.member?(spec_set, {name, arity})
      end)

    new_suggestions =
      Enum.map(missing, fn {name, arity, meta} ->
        %{
          type: :missing_spec,
          message: "Public function #{name}/#{arity} missing @spec",
          line: meta[:line],
          column: meta[:column],
          severity: :suggestion,
          suggestion: "Add @spec #{name}(...) :: return_type"
        }
      end)

    suggestions ++ new_suggestions
  end

  # ============================================================================
  # AST Traversal Helpers
  # ============================================================================

  defp find_nodes(ast, finder) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case finder.(node) do
          {:found, meta} -> {node, [meta | acc]}
          nil -> {node, acc}
        end
      end)

    Enum.reverse(found)
  end
end
