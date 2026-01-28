defmodule Arbor.Eval.Checks.Documentation do
  @moduledoc """
  Checks for documentation coverage in modules.

  Ensures that:
  - Modules have @moduledoc
  - Public functions have @doc
  - @doc is not just `false` (intentionally hidden)

  ## Configuration

  - `:require_moduledoc` - Require @moduledoc (default: true)
  - `:require_doc` - Require @doc on public functions (default: true)
  - `:allow_doc_false` - Allow @doc false for intentionally hidden functions (default: true)
  - `:min_doc_length` - Minimum documentation length in characters (default: 10)

  ## Multi-Clause Functions

  This check correctly handles multi-clause functions. When a function has multiple
  clauses (pattern matching on different inputs), only the first clause needs @doc.
  Subsequent clauses are correctly recognized as belonging to the same function.

  ## Example

      @doc "Check if session has expired."
      def expired?(%__MODULE__{expires_at: nil}), do: false
      def expired?(%__MODULE__{expires_at: expires_at}) do  # No violation here
        DateTime.compare(DateTime.utc_now(), expires_at) == :gt
      end
  """

  use Arbor.Eval,
    name: "documentation",
    category: :code_quality,
    description: "Checks for documentation coverage"

  @impl Arbor.Eval
  def run(%{ast: ast} = context) do
    require_moduledoc = Map.get(context, :require_moduledoc, true)
    require_doc = Map.get(context, :require_doc, true)
    allow_doc_false = Map.get(context, :allow_doc_false, true)
    min_doc_length = Map.get(context, :min_doc_length, 10)

    violations =
      []
      |> maybe_check_moduledoc(ast, require_moduledoc, min_doc_length)
      |> maybe_check_function_docs(ast, require_doc, allow_doc_false, min_doc_length)

    %{
      passed: Enum.empty?(Enum.filter(violations, &(&1.severity == :error))),
      violations: violations,
      suggestions: []
    }
  end

  def run(_context) do
    %{passed: false, violations: [%{type: :no_ast, message: "No AST provided", severity: :error}]}
  end

  # ============================================================================
  # Moduledoc Check
  # ============================================================================

  defp maybe_check_moduledoc(violations, _ast, false, _min_length), do: violations

  defp maybe_check_moduledoc(violations, ast, true, min_length) do
    case ast do
      {:defmodule, meta, [{:__aliases__, _, parts}, [do: body]]} ->
        module_name = Enum.map_join(parts, ".", &to_string/1)
        moduledoc = find_moduledoc(body)
        validate_moduledoc(violations, moduledoc, module_name, meta, min_length)

      _ ->
        violations
    end
  end

  defp validate_moduledoc(violations, nil, module_name, meta, _min_length) do
    [
      %{
        type: :missing_moduledoc,
        message: "Module '#{module_name}' is missing @moduledoc",
        line: meta[:line],
        column: nil,
        severity: :warning,
        suggestion: "Add @moduledoc describing the module's purpose"
      }
      | violations
    ]
  end

  defp validate_moduledoc(violations, false, _module_name, _meta, _min_length), do: violations

  defp validate_moduledoc(violations, doc, module_name, meta, min_length) when is_binary(doc) do
    if String.length(doc) < min_length do
      [
        %{
          type: :short_moduledoc,
          message:
            "Module '#{module_name}' has very short @moduledoc (#{String.length(doc)} chars)",
          line: meta[:line],
          column: nil,
          severity: :suggestion,
          suggestion: "Expand @moduledoc to better describe the module"
        }
        | violations
      ]
    else
      violations
    end
  end

  defp validate_moduledoc(violations, _doc, _module_name, _meta, _min_length), do: violations

  # ============================================================================
  # Function Doc Checks
  # ============================================================================

  defp maybe_check_function_docs(violations, _ast, false, _allow_false, _min_length),
    do: violations

  defp maybe_check_function_docs(violations, ast, true, allow_doc_false, min_length) do
    case ast do
      {:defmodule, _meta, [_name, [do: body]]} ->
        check_body_for_docs(violations, body, allow_doc_false, min_length)

      _ ->
        violations
    end
  end

  defp check_body_for_docs(violations, {:__block__, _, statements}, allow_doc_false, min_length) do
    # First pass: collect all function definitions grouped by {name, arity}
    # and which have docs on their first occurrence
    {documented_functions, function_first_occurrence} =
      collect_function_docs(statements)

    check_context = %{
      documented: documented_functions,
      first_occurrence: function_first_occurrence,
      allow_doc_false: allow_doc_false,
      min_length: min_length
    }

    # Second pass: check only the first occurrence of each function
    {_, violations} =
      Enum.reduce(statements, {nil, violations}, fn statement, {last_doc, acc} ->
        reduce_doc_statement(statement, last_doc, acc, check_context)
      end)

    violations
  end

  defp check_body_for_docs(violations, _body, _allow_doc_false, _min_length), do: violations

  defp reduce_doc_statement({:@, _, [{:doc, _, [doc]}]}, _last_doc, acc, _check_context) do
    {doc, acc}
  end

  defp reduce_doc_statement({:@, _, [{:doc, _, [false]}]}, _last_doc, acc, _check_context) do
    {false, acc}
  end

  defp reduce_doc_statement({:def, meta, [{name, _, args}, _]}, last_doc, acc, check_context)
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    acc = maybe_check_first_clause({name, arity}, meta, last_doc, acc, check_context)
    {nil, acc}
  end

  defp reduce_doc_statement(
         {:def, meta, [{:when, _, [{name, _, args} | _]}, _]},
         last_doc,
         acc,
         check_context
       )
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    acc = maybe_check_first_clause({name, arity}, meta, last_doc, acc, check_context)
    {nil, acc}
  end

  defp reduce_doc_statement(_statement, last_doc, acc, _check_context) do
    {last_doc, acc}
  end

  defp maybe_check_first_clause(fun_key, meta, last_doc, acc, check_context) do
    if Map.get(check_context.first_occurrence, fun_key) == meta[:line] do
      {name, arity} = fun_key

      check_function_doc(
        acc,
        name,
        arity,
        meta,
        last_doc,
        check_context.allow_doc_false,
        check_context.min_length,
        MapSet.member?(check_context.documented, fun_key)
      )
    else
      acc
    end
  end

  # Collect which functions are documented and where their first clause appears
  defp collect_function_docs(statements) do
    {documented, first_occurrence, _} =
      Enum.reduce(statements, {MapSet.new(), %{}, nil}, fn statement, acc ->
        reduce_collect_statement(statement, acc)
      end)

    {documented, first_occurrence}
  end

  defp reduce_collect_statement({:@, _, [{:doc, _, [doc]}]}, {documented, first_occ, _last_doc})
       when is_binary(doc) do
    {documented, first_occ, doc}
  end

  defp reduce_collect_statement({:@, _, [{:doc, _, [false]}]}, {documented, first_occ, _last_doc}) do
    {documented, first_occ, false}
  end

  defp reduce_collect_statement(
         {:def, meta, [{name, _, args}, _]},
         {documented, first_occ, last_doc}
       )
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    record_function_doc({name, arity}, meta, documented, first_occ, last_doc)
  end

  defp reduce_collect_statement(
         {:def, meta, [{:when, _, [{name, _, args} | _]}, _]},
         {documented, first_occ, last_doc}
       )
       when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    record_function_doc({name, arity}, meta, documented, first_occ, last_doc)
  end

  defp reduce_collect_statement(_statement, acc), do: acc

  defp record_function_doc(fun_key, meta, documented, first_occ, last_doc) do
    first_occ = Map.put_new(first_occ, fun_key, meta[:line])
    documented = maybe_mark_documented(fun_key, meta, documented, first_occ, last_doc)
    {documented, first_occ, nil}
  end

  defp maybe_mark_documented(fun_key, meta, documented, first_occ, last_doc) do
    is_first_clause = Map.get(first_occ, fun_key) == meta[:line]
    has_doc = is_binary(last_doc) or last_doc == false

    if is_first_clause and has_doc do
      MapSet.put(documented, fun_key)
    else
      documented
    end
  end

  # OTP callbacks and common overrides that don't require docs
  @otp_callbacks [
    :init,
    :handle_call,
    :handle_cast,
    :handle_info,
    :terminate,
    :code_change,
    :mount,
    :render,
    :update,
    :handle_event,
    :handle_params,
    :child_spec,
    :start_link
  ]

  # Already documented from previous analysis (handles multi-clause edge cases)
  defp check_function_doc(violations, _name, _arity, _meta, _doc, _allow, _min, true),
    do: violations

  # Has doc string - evaluate its length
  defp check_function_doc(violations, name, arity, meta, doc, _allow, min_length, _already)
       when is_binary(doc) do
    evaluate_doc_length(violations, name, arity, meta, doc, min_length)
  end

  # @doc false and allowed
  defp check_function_doc(violations, _name, _arity, _meta, false, true, _min, _already),
    do: violations

  # @doc false but not allowed
  defp check_function_doc(violations, name, arity, meta, false, _allow, _min, _already) do
    [
      %{
        type: :doc_false,
        message: "Function '#{name}/#{arity}' has @doc false",
        line: meta[:line],
        column: nil,
        severity: :warning,
        suggestion: "Add documentation or make the function private"
      }
      | violations
    ]
  end

  # No doc at all - skip OTP callbacks and common overrides
  defp check_function_doc(violations, name, _arity, _meta, _doc, _allow, _min, _already)
       when name in @otp_callbacks,
       do: violations

  # No doc
  defp check_function_doc(violations, name, arity, meta, _doc, _allow, _min, _already) do
    [
      %{
        type: :missing_doc,
        message: "Public function '#{name}/#{arity}' is missing @doc",
        line: meta[:line],
        column: nil,
        severity: :warning,
        suggestion: "Add @doc describing what the function does"
      }
      | violations
    ]
  end

  defp evaluate_doc_length(violations, name, arity, meta, doc, min_length) do
    if String.length(doc) >= min_length do
      violations
    else
      [
        %{
          type: :short_doc,
          message:
            "Function '#{name}/#{arity}' has very short @doc (#{String.length(doc)} chars)",
          line: meta[:line],
          column: nil,
          severity: :suggestion,
          suggestion: "Expand @doc to better describe the function"
        }
        | violations
      ]
    end
  end

  # ============================================================================
  # AST Helpers
  # ============================================================================

  defp find_moduledoc({:__block__, _, statements}) do
    # Use find_value with {:found, doc} wrapper to handle @moduledoc false
    # (false is falsy so find_value would skip it otherwise)
    case Enum.find_value(statements, fn
           {:@, _, [{:moduledoc, _, [doc]}]} -> {:found, doc}
           _ -> nil
         end) do
      {:found, doc} -> doc
      nil -> nil
    end
  end

  defp find_moduledoc({:@, _, [{:moduledoc, _, [doc]}]}), do: doc
  defp find_moduledoc(_), do: nil
end
