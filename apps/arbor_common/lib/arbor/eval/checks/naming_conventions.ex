defmodule Arbor.Eval.Checks.NamingConventions do
  @moduledoc """
  Checks for AI-readable naming conventions in Arbor libraries.

  ## Naming Principles

  Arbor uses verbose, self-documenting names optimized for LLM comprehension:

  - Function names should be descriptive verb phrases
  - Module names should expose concepts, not implementation details
  - Avoid abbreviations unless universally understood

  ## Checks

  - Module names don't expose implementation technology
  - Public function names are descriptive (minimum word count)
  - No single-letter variable names in function signatures
  - Consistent naming patterns within a module

  ## Configuration

  Strictness levels:
  - `:relaxed` - Only flag egregious violations
  - `:standard` - Default checks (recommended for existing code)
  - `:strict` - Full AI-readable naming (for new libraries)

  ## Example

      # Bad: exposes implementation
      defmodule Arbor.Core.HordeSupervisor

      # Good: exposes concept
      defmodule Arbor.Core.DistributedAgentSupervisor

      # Bad: abbreviated, unclear
      def proc_msg(m), do: ...

      # Good: descriptive
      def process_incoming_message(message), do: ...
  """

  use Arbor.Eval,
    name: "naming_conventions",
    category: :code_quality,
    description: "Checks for AI-readable naming conventions"

  # Implementation technology terms that shouldn't appear in public module names
  @implementation_terms [
    "Horde",
    "GenServer",
    "GenStage",
    "Ecto",
    "Phoenix",
    "Plug",
    "Oban",
    "Redis",
    "Postgres",
    "ETS",
    "DETS",
    "Mnesia"
  ]

  # Common abbreviations to flag (excludes widely-accepted Elixir conventions)
  @abbreviations %{
    "msg" => "message",
    "proc" => "process",
    "req" => "request",
    "res" => "response",
    "resp" => "response",
    "cfg" => "config",
    "val" => "value",
    "vals" => "values",
    "num" => "number",
    "cnt" => "count",
    "idx" => "index",
    "len" => "length",
    "buf" => "buffer",
    "tmp" => "temporary",
    "err" => "error",
    "cb" => "callback",
    "prev" => "previous",
    "curr" => "current"
  }

  # Abbreviations that are acceptable in Elixir community
  # (not flagged even in strict mode)
  @acceptable_abbreviations [
    # Very common Elixir convention
    "opts",
    # Common in Phoenix
    "params",
    # Standard term
    "args",
    # Common context abbreviation
    "ctx",
    # Standard accumulator in reduce
    "acc",
    # Elixir keyword
    "fn",
    # @impl attribute
    "impl",
    # Common in OTP (__info__, handle_info)
    "info",
    # @attr convention
    "attr",
    # Common in Phoenix
    "attrs",
    # OTP callback
    "init",
    # @spec
    "spec",
    # @doc
    "doc",
    # Macro metadata
    "meta",
    # Common with Enum.with_index
    "idx"
  ]

  # Minimum words for public function names (in strict mode)
  @min_words_strict 2
  @min_words_standard 1

  # Common well-known short names that are acceptable
  @acceptable_short_names [
    "new",
    "get",
    "put",
    "set",
    "add",
    "run",
    "call",
    "cast",
    "send",
    "init",
    "start",
    "stop",
    "load",
    "save",
    "read",
    "write",
    "open",
    "close",
    "emit",
    "subscribe",
    "unsubscribe",
    "create",
    "update",
    "delete",
    "list",
    "fetch",
    "count",
    "encode",
    "decode",
    "parse",
    "format",
    "validate",
    "to_string",
    "to_map",
    "to_list",
    "from_map",
    "from_list",
    "child_spec",
    "start_link",
    "handle_call",
    "handle_cast",
    "handle_info",
    "terminate",
    "code_change",
    "mount",
    "render",
    "update"
  ]

  @impl Arbor.Eval
  def run(%{ast: ast} = context) do
    strictness = Map.get(context, :strictness, :standard)

    violations =
      []
      |> check_module_names(ast, strictness)
      |> check_function_names(ast, strictness)
      |> check_parameter_names(ast, strictness)

    suggestions =
      []
      |> suggest_abbreviation_expansions(ast)

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
  # Module Name Checks
  # ============================================================================

  defp check_module_names(violations, ast, strictness) do
    case ast do
      {:defmodule, meta, [{:__aliases__, _, parts}, _]} ->
        module_name = Enum.map_join(parts, ".", &to_string/1)
        first_part = to_string(hd(parts))

        naming_violations = check_arbor_module_naming(module_name, first_part, meta, strictness)
        tech_violations = check_implementation_terms(module_name, meta, strictness)

        violations ++ naming_violations ++ tech_violations

      _ ->
        violations
    end
  end

  defp check_implementation_terms(_module_name, _meta, strictness)
       when strictness not in [:standard, :strict],
       do: []

  defp check_implementation_terms(module_name, meta, strictness) do
    @implementation_terms
    |> Enum.filter(fn term -> String.contains?(module_name, term) end)
    |> Enum.map(fn term ->
      %{
        type: :implementation_in_module_name,
        message: "Module name '#{module_name}' exposes implementation technology '#{term}'",
        line: meta[:line],
        column: nil,
        severity: if(strictness == :strict, do: :warning, else: :suggestion),
        suggestion:
          "Rename to expose concept, not implementation (e.g., DistributedSupervisor instead of HordeSupervisor)"
      }
    end)
  end

  # Check that Arbor modules use dotted naming (Arbor.Foo) not concatenated (ArborFoo)
  defp check_arbor_module_naming(module_name, first_part, meta, _strictness) do
    # ArborEval, ArborCommon, etc. - should be Arbor.Eval, Arbor.Common
    if String.starts_with?(first_part, "Arbor") and first_part != "Arbor" do
      expected = "Arbor." <> String.replace_prefix(first_part, "Arbor", "")
      rest = module_name |> String.split(".") |> tl() |> Enum.join(".")
      full_expected = if rest == "", do: expected, else: "#{expected}.#{rest}"

      [
        %{
          type: :arbor_module_naming,
          message: "Module '#{module_name}' uses concatenated naming instead of dotted namespace",
          line: meta[:line],
          column: nil,
          severity: :error,
          suggestion: "Rename to '#{full_expected}' (use Arbor.* namespace, not Arbor* prefix)"
        }
      ]
    else
      []
    end
  end

  # ============================================================================
  # Function Name Checks
  # ============================================================================

  defp check_function_names(violations, ast, strictness) do
    min_words = if strictness == :strict, do: @min_words_strict, else: @min_words_standard

    # Find public function definitions
    public_funs = find_public_functions(ast)

    new_violations =
      Enum.flat_map(public_funs, fn {name, arity, meta} ->
        name_str = to_string(name)
        words = split_into_words(name_str)

        cond do
          # Skip acceptable short names
          name_str in @acceptable_short_names ->
            []

          # Check for single-letter function names
          String.length(name_str) == 1 ->
            [
              %{
                type: :single_letter_function,
                message: "Single-letter function name '#{name_str}/#{arity}'",
                line: meta[:line],
                column: nil,
                severity: :error,
                suggestion: "Use a descriptive name"
              }
            ]

          # Check minimum word count
          length(words) < min_words and strictness == :strict ->
            [
              %{
                type: :short_function_name,
                message:
                  "Function '#{name_str}/#{arity}' has only #{length(words)} word(s), consider more descriptive name",
                line: meta[:line],
                column: nil,
                severity: :suggestion,
                suggestion:
                  "Use descriptive verb phrases like 'process_user_request' instead of '#{name_str}'"
              }
            ]

          true ->
            []
        end
      end)

    violations ++ new_violations
  end

  # ============================================================================
  # Parameter Name Checks
  # ============================================================================

  defp check_parameter_names(violations, _ast, strictness) when strictness != :strict,
    do: violations

  defp check_parameter_names(violations, ast, :strict) do
    funs_with_params = find_functions_with_params(ast)

    new_violations =
      Enum.flat_map(funs_with_params, fn {fun_name, params, meta} ->
        find_single_letter_params(params, fun_name, meta)
      end)

    violations ++ new_violations
  end

  defp find_single_letter_params(params, fun_name, meta) do
    params
    |> Enum.filter(&single_letter_param?/1)
    |> Enum.map(fn {name, _, _} ->
      %{
        type: :single_letter_parameter,
        message: "Single-letter parameter '#{name}' in function '#{fun_name}'",
        line: meta[:line],
        column: nil,
        severity: :suggestion,
        suggestion: "Use descriptive parameter names"
      }
    end)
  end

  defp single_letter_param?({name, _, _}) when is_atom(name) do
    name_str = to_string(name)

    String.length(name_str) == 1 and name_str != "_" and
      name_str not in ["x", "y", "n", "i", "k", "v"]
  end

  defp single_letter_param?(_), do: false

  # ============================================================================
  # Abbreviation Suggestions
  # ============================================================================

  defp suggest_abbreviation_expansions(suggestions, ast) do
    # Find all atoms in the AST that might be abbreviated names
    atoms = find_all_atoms(ast)

    new_suggestions =
      atoms
      |> Enum.flat_map(fn {name, meta} ->
        name_str = to_string(name)
        words = split_into_words(name_str)

        # Check each word for known abbreviations (excluding acceptable ones)
        words
        |> Enum.filter(fn word ->
          Map.has_key?(@abbreviations, word) and word not in @acceptable_abbreviations
        end)
        |> Enum.map(fn abbrev ->
          %{
            type: :abbreviation_used,
            message: "Abbreviated term '#{abbrev}' in '#{name_str}'",
            line: meta[:line],
            column: nil,
            severity: :suggestion,
            suggestion: "Consider using '#{@abbreviations[abbrev]}' instead of '#{abbrev}'"
          }
        end)
      end)
      |> Enum.uniq_by(fn v -> {v.line, v.message} end)

    suggestions ++ new_suggestions
  end

  # ============================================================================
  # AST Helpers
  # ============================================================================

  defp find_public_functions(ast) do
    {_, funs} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{name, _, args}, _]} = node, acc when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0
          {node, [{name, arity, meta} | acc]}

        {:def, meta, [{:when, _, [{name, _, args} | _]}, _]} = node, acc when is_atom(name) ->
          arity = if is_list(args), do: length(args), else: 0
          {node, [{name, arity, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(funs)
  end

  defp find_functions_with_params(ast) do
    {_, funs} =
      Macro.prewalk(ast, [], fn
        {:def, meta, [{name, _, args}, _]} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{name, args, meta} | acc]}

        {:defp, meta, [{name, _, args}, _]} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{name, args, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(funs)
  end

  defp find_all_atoms(ast) do
    {_, atoms} =
      Macro.prewalk(ast, [], fn
        {name, meta, _} = node, acc when is_atom(name) ->
          {node, [{name, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    atoms
  end

  defp split_into_words(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end
end
