defmodule ArborEval.Checks.Documentation do
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

  use ArborEval,
    name: "documentation",
    category: :code_quality,
    description: "Checks for documentation coverage"

  @impl ArborEval
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

        case moduledoc do
          nil ->
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

          false ->
            # @moduledoc false is intentional
            violations

          doc when is_binary(doc) ->
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

          _ ->
            violations
        end

      _ ->
        violations
    end
  end

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

    # Second pass: check only the first occurrence of each function
    {_, violations} =
      Enum.reduce(statements, {nil, violations}, fn statement, {last_doc, acc} ->
        case statement do
          # @doc "..."
          {:@, _, [{:doc, _, [doc]}]} ->
            {doc, acc}

          # @doc false
          {:@, _, [{:doc, _, [false]}]} ->
            {false, acc}

          # def function
          {:def, meta, [{name, _, args}, _]} when is_atom(name) ->
            arity = if is_list(args), do: length(args), else: 0
            fun_key = {name, arity}

            # Only check the first occurrence of this function
            acc =
              if Map.get(function_first_occurrence, fun_key) == meta[:line] do
                # This is the first clause - check if it has docs
                check_function_doc(
                  acc,
                  name,
                  arity,
                  meta,
                  last_doc,
                  allow_doc_false,
                  min_length,
                  MapSet.member?(documented_functions, fun_key)
                )
              else
                # Not the first clause, skip (docs should be on first clause only)
                acc
              end

            {nil, acc}

          {:def, meta, [{:when, _, [{name, _, args} | _]}, _]} when is_atom(name) ->
            arity = if is_list(args), do: length(args), else: 0
            fun_key = {name, arity}

            # Only check the first occurrence of this function
            acc =
              if Map.get(function_first_occurrence, fun_key) == meta[:line] do
                check_function_doc(
                  acc,
                  name,
                  arity,
                  meta,
                  last_doc,
                  allow_doc_false,
                  min_length,
                  MapSet.member?(documented_functions, fun_key)
                )
              else
                acc
              end

            {nil, acc}

          _ ->
            {last_doc, acc}
        end
      end)

    violations
  end

  defp check_body_for_docs(violations, _body, _allow_doc_false, _min_length), do: violations

  # Collect which functions are documented and where their first clause appears
  defp collect_function_docs(statements) do
    {documented, first_occurrence, _} =
      Enum.reduce(statements, {MapSet.new(), %{}, nil}, fn statement,
                                                           {documented, first_occ, last_doc} ->
        case statement do
          {:@, _, [{:doc, _, [doc]}]} when is_binary(doc) ->
            {documented, first_occ, doc}

          {:@, _, [{:doc, _, [false]}]} ->
            {documented, first_occ, false}

          {:def, meta, [{name, _, args}, _]} when is_atom(name) ->
            arity = if is_list(args), do: length(args), else: 0
            fun_key = {name, arity}

            # Record first occurrence
            first_occ =
              if Map.has_key?(first_occ, fun_key) do
                first_occ
              else
                Map.put(first_occ, fun_key, meta[:line])
              end

            # Mark as documented if this is the first clause and has docs
            documented =
              if not Map.has_key?(first_occ, fun_key) or
                   Map.get(first_occ, fun_key) == meta[:line] do
                if is_binary(last_doc) or last_doc == false do
                  MapSet.put(documented, fun_key)
                else
                  documented
                end
              else
                documented
              end

            {documented, first_occ, nil}

          {:def, meta, [{:when, _, [{name, _, args} | _]}, _]} when is_atom(name) ->
            arity = if is_list(args), do: length(args), else: 0
            fun_key = {name, arity}

            first_occ =
              if Map.has_key?(first_occ, fun_key) do
                first_occ
              else
                Map.put(first_occ, fun_key, meta[:line])
              end

            documented =
              if not Map.has_key?(first_occ, fun_key) or
                   Map.get(first_occ, fun_key) == meta[:line] do
                if is_binary(last_doc) or last_doc == false do
                  MapSet.put(documented, fun_key)
                else
                  documented
                end
              else
                documented
              end

            {documented, first_occ, nil}

          _ ->
            {documented, first_occ, last_doc}
        end
      end)

    {documented, first_occurrence}
  end

  defp check_function_doc(
         violations,
         name,
         arity,
         meta,
         doc,
         allow_doc_false,
         min_length,
         already_documented
       ) do
    cond do
      # Already documented from previous analysis (handles multi-clause edge cases)
      already_documented ->
        violations

      # Has doc
      is_binary(doc) and String.length(doc) >= min_length ->
        violations

      # Short doc
      is_binary(doc) ->
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

      # @doc false and allowed
      doc == false and allow_doc_false ->
        violations

      # @doc false but not allowed
      doc == false ->
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

      # No doc at all - skip callbacks and common overrides
      name in [
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
      ] ->
        violations

      # No doc
      true ->
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
