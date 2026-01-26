defmodule ArborEval do
  @moduledoc """
  Evaluation framework for code quality, safety, and behavior.

  This module provides the core behaviour for evals and a simple runner.
  Evals analyze code, agent behavior, or system state and return structured results.

  ## Usage

      # Run a single eval
      {:ok, result} = ArborEval.run(ArborEval.Checks.ElixirIdioms, code: code_string)

      # Run multiple evals
      {:ok, results} = ArborEval.run_all([
        ArborEval.Checks.ElixirIdioms,
        ArborEval.Checks.Documentation
      ], code: code_string)

      # Check a file
      {:ok, result} = ArborEval.check_file("lib/my_module.ex")

  ## Defining an Eval

      defmodule MyEval do
        use ArborEval,
          name: "my_eval",
          category: :code_quality,
          description: "Checks for something specific"

        @impl true
        def run(context) do
          # Analyze context.code, context.ast, etc.
          %{
            passed: true,
            violations: [],
            suggestions: []
          }
        end
      end

  ## Result Structure

      %{
        eval: MyEval,
        name: "my_eval",
        category: :code_quality,
        passed: true | false,
        violations: [%{type: atom, message: string, line: integer, ...}],
        suggestions: [%{type: atom, message: string, ...}],
        metadata: %{}
      }
  """

  @type violation :: %{
          type: atom(),
          message: String.t(),
          line: non_neg_integer() | nil,
          column: non_neg_integer() | nil,
          severity: :error | :warning | :suggestion
        }

  @type result :: %{
          eval: module(),
          name: String.t(),
          category: atom(),
          passed: boolean(),
          violations: [violation()],
          suggestions: [violation()],
          metadata: map()
        }

  @type context :: %{
          optional(:code) => String.t(),
          optional(:ast) => Macro.t(),
          optional(:file) => String.t(),
          optional(:module) => module(),
          optional(atom()) => any()
        }

  @doc "Called before run/1 to set up context. Override for custom setup."
  @callback setup(context()) :: {:ok, context()} | {:error, term()}

  @doc "Main evaluation logic. Must return result map with :passed, :violations, etc."
  @callback run(context()) :: map()

  @doc "Called after run/1 for cleanup. Override for custom teardown."
  @callback teardown(context()) :: :ok

  @doc "Returns eval metadata (name, category, description)."
  @callback __eval_info__() :: %{name: String.t(), category: atom(), description: String.t()}

  defmacro __using__(opts) do
    quote do
      @behaviour ArborEval

      @eval_name unquote(opts[:name]) || to_string(__MODULE__)
      @eval_category unquote(opts[:category]) || :general
      @eval_description unquote(opts[:description]) || ""

      @impl ArborEval
      def setup(context), do: {:ok, context}

      @impl ArborEval
      def teardown(_context), do: :ok

      @impl ArborEval
      def __eval_info__ do
        %{
          name: @eval_name,
          category: @eval_category,
          description: @eval_description
        }
      end

      defoverridable setup: 1, teardown: 1
    end
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Run a single eval with the given context.
  """
  @spec run(module(), keyword() | map()) :: {:ok, result()} | {:error, term()}
  def run(eval_module, context) when is_list(context) do
    run(eval_module, Map.new(context))
  end

  def run(eval_module, context) when is_map(context) do
    info = eval_module.__eval_info__()

    with {:ok, context} <- maybe_parse_code(context),
         {:ok, context} <- eval_module.setup(context) do
      result = eval_module.run(context)
      eval_module.teardown(context)

      {:ok,
       Map.merge(
         %{
           eval: eval_module,
           name: info.name,
           category: info.category,
           passed: result[:passed] || false,
           violations: result[:violations] || [],
           suggestions: result[:suggestions] || [],
           metadata: result[:metadata] || %{}
         },
         Map.take(result, [:details])
       )}
    end
  end

  @doc """
  Run multiple evals and collect results.
  """
  @spec run_all([module()], keyword() | map()) :: {:ok, [result()]} | {:error, term()}
  def run_all(eval_modules, context) when is_list(context) do
    run_all(eval_modules, Map.new(context))
  end

  def run_all(eval_modules, context) when is_map(context) do
    # Parse code once for all evals
    with {:ok, context} <- maybe_parse_code(context) do
      results =
        Enum.map(eval_modules, fn eval_module ->
          case run(eval_module, context) do
            {:ok, result} -> result
            {:error, reason} -> %{eval: eval_module, passed: false, error: reason}
          end
        end)

      {:ok, results}
    end
  end

  @doc """
  Check a file with all registered code quality evals.
  """
  @spec check_file(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def check_file(file_path, opts \\ []) do
    evals = Keyword.get(opts, :evals, default_code_quality_evals())

    case File.read(file_path) do
      {:ok, code} ->
        run_all(evals, %{code: code, file: file_path})

      {:error, reason} ->
        {:error, {:file_read_failed, file_path, reason}}
    end
  end

  @doc """
  Check a code string with all registered code quality evals.
  """
  @spec check_code(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def check_code(code, opts \\ []) do
    evals = Keyword.get(opts, :evals, default_code_quality_evals())
    run_all(evals, %{code: code})
  end

  @doc """
  Get summary of eval results.
  """
  @spec summary([result()]) :: map()
  def summary(results) do
    %{
      total: length(results),
      passed: Enum.count(results, & &1.passed),
      failed: Enum.count(results, &(!&1.passed)),
      violations: results |> Enum.flat_map(& &1.violations) |> length(),
      suggestions: results |> Enum.flat_map(& &1.suggestions) |> length(),
      by_category:
        results
        |> Enum.group_by(& &1.category)
        |> Enum.map(fn {cat, rs} -> {cat, Enum.count(rs, & &1.passed), length(rs)} end)
        |> Map.new(fn {cat, passed, total} -> {cat, %{passed: passed, total: total}} end)
    }
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp maybe_parse_code(%{code: code, ast: _} = context) when is_binary(code) do
    # Already has AST
    {:ok, context}
  end

  defp maybe_parse_code(%{code: code} = context) when is_binary(code) do
    case Code.string_to_quoted(code, columns: true, token_metadata: true) do
      {:ok, ast} ->
        {:ok, Map.put(context, :ast, ast)}

      {:error, {line, message, _}} ->
        {:error, {:parse_error, line, message}}
    end
  end

  defp maybe_parse_code(context) do
    {:ok, context}
  end

  defp default_code_quality_evals do
    [
      ArborEval.Checks.ElixirIdioms,
      ArborEval.Checks.Documentation,
      ArborEval.Checks.PIIDetection,
      ArborEval.Checks.NamingConventions
    ]
  end
end
