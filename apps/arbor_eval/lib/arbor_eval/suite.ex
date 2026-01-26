defmodule ArborEval.Suite do
  @moduledoc """
  A suite is a collection of evals that run together.

  Suites provide:
  - Grouped execution of related evals
  - Aggregated results and reporting
  - Configurable severity thresholds
  - Support for baseline/incremental checking

  ## Defining a Suite

      defmodule MySuite do
        use ArborEval.Suite,
          name: "my_suite",
          description: "Checks for my specific needs"

        @impl true
        def evals do
          [
            ArborEval.Checks.ElixirIdioms,
            ArborEval.Checks.PIIDetection,
            MyCustomCheck
          ]
        end
      end

  ## Running a Suite

      # Check a single file
      {:ok, results} = MySuite.check_file("lib/my_module.ex")

      # Check a directory
      {:ok, results} = MySuite.check_directory("apps/my_app/lib/")

      # Check with options
      {:ok, results} = MySuite.check_directory("lib/",
        fail_on: :warning,  # or :error (default)
        exclude: ["test/support/"]
      )
  """

  @type check_result :: %{
          file: String.t(),
          results: [ArborEval.result()],
          passed: boolean()
        }

  @type suite_result :: %{
          suite: module(),
          name: String.t(),
          files_checked: non_neg_integer(),
          passed: boolean(),
          fail_on: :error | :warning,
          summary: map(),
          file_results: [check_result()]
        }

  @doc "Returns the list of eval modules in this suite"
  @callback evals() :: [module()]

  @doc "Optional: filter or transform files before checking"
  @callback filter_files([String.t()]) :: [String.t()]

  @doc "Optional: pre-suite setup"
  @callback setup(map()) :: {:ok, map()} | {:error, term()}

  @doc "Optional: post-suite teardown"
  @callback teardown(map()) :: :ok

  @doc "Returns suite metadata"
  @callback __suite_info__() :: %{name: String.t(), description: String.t()}

  defmacro __using__(opts) do
    quote do
      @behaviour ArborEval.Suite

      @suite_name unquote(opts[:name]) || to_string(__MODULE__)
      @suite_description unquote(opts[:description]) || ""

      @impl ArborEval.Suite
      def filter_files(files), do: files

      @impl ArborEval.Suite
      def setup(context), do: {:ok, context}

      @impl ArborEval.Suite
      def teardown(_context), do: :ok

      @impl ArborEval.Suite
      def __suite_info__ do
        %{name: @suite_name, description: @suite_description}
      end

      defoverridable filter_files: 1, setup: 1, teardown: 1

      # Convenience functions
      def check_file(path, opts \\ []) do
        ArborEval.Suite.check_file(__MODULE__, path, opts)
      end

      def check_files(paths, opts \\ []) do
        ArborEval.Suite.check_files(__MODULE__, paths, opts)
      end

      def check_directory(path, opts \\ []) do
        ArborEval.Suite.check_directory(__MODULE__, path, opts)
      end
    end
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check a single file with a suite.
  """
  @spec check_file(module(), String.t(), keyword()) :: {:ok, suite_result()} | {:error, term()}
  def check_file(suite_module, path, opts \\ []) do
    check_files(suite_module, [path], opts)
  end

  @doc """
  Check multiple files with a suite.
  """
  @spec check_files(module(), [String.t()], keyword()) :: {:ok, suite_result()} | {:error, term()}
  def check_files(suite_module, paths, opts \\ []) do
    info = suite_module.__suite_info__()
    evals = suite_module.evals()
    fail_on = Keyword.get(opts, :fail_on, :error)

    with {:ok, context} <- suite_module.setup(%{opts: opts}) do
      # Filter files
      files = suite_module.filter_files(paths)

      # Check each file
      file_results =
        Enum.map(files, fn path ->
          case check_single_file(path, evals, opts) do
            {:ok, results} ->
              %{
                file: path,
                results: results,
                passed: file_passed?(results, fail_on)
              }

            {:error, reason} ->
              %{
                file: path,
                results: [],
                passed: false,
                error: reason
              }
          end
        end)

      suite_module.teardown(context)

      suite_passed = Enum.all?(file_results, & &1.passed)

      {:ok,
       %{
         suite: suite_module,
         name: info.name,
         files_checked: length(file_results),
         passed: suite_passed,
         fail_on: fail_on,
         summary: build_summary(file_results),
         file_results: file_results
       }}
    end
  end

  @doc """
  Check all Elixir files in a directory.
  """
  @spec check_directory(module(), String.t(), keyword()) ::
          {:ok, suite_result()} | {:error, term()}
  def check_directory(suite_module, path, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])

    files =
      Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      |> Enum.reject(fn file ->
        Enum.any?(exclude, &String.contains?(file, &1))
      end)
      |> Enum.sort()

    if files == [] do
      {:error, {:no_files_found, path}}
    else
      check_files(suite_module, files, opts)
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp check_single_file(path, evals, _opts) do
    case File.read(path) do
      {:ok, code} ->
        ArborEval.run_all(evals, %{code: code, file: path})

      {:error, reason} ->
        {:error, {:file_read_failed, path, reason}}
    end
  end

  defp file_passed?(results, :error) do
    # Pass if no error-level violations
    not Enum.any?(results, fn result ->
      Enum.any?(result.violations, &(&1.severity == :error))
    end)
  end

  defp file_passed?(results, :warning) do
    # Pass if no error or warning-level violations
    not Enum.any?(results, fn result ->
      Enum.any?(result.violations, &(&1.severity in [:error, :warning]))
    end)
  end

  defp build_summary(file_results) do
    all_results = Enum.flat_map(file_results, & &1.results)
    all_violations = Enum.flat_map(all_results, & &1.violations)
    all_suggestions = Enum.flat_map(all_results, & &1.suggestions)

    %{
      files: length(file_results),
      files_passed: Enum.count(file_results, & &1.passed),
      files_failed: Enum.count(file_results, &(!&1.passed)),
      errors: Enum.count(all_violations, &(&1.severity == :error)),
      warnings: Enum.count(all_violations, &(&1.severity == :warning)),
      suggestions:
        length(all_suggestions) + Enum.count(all_violations, &(&1.severity == :suggestion)),
      by_type:
        all_violations
        |> Enum.group_by(& &1.type)
        |> Enum.map(fn {type, violations} -> {type, length(violations)} end)
        |> Map.new()
    }
  end
end
