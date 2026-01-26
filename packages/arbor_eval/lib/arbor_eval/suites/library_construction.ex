defmodule ArborEval.Suites.LibraryConstruction do
  @moduledoc """
  Comprehensive evaluation suite for Arbor library construction.

  This suite runs all quality checks required for new Arbor libraries:

  - **ElixirIdioms** - Idiomatic Elixir patterns
  - **PIIDetection** - No personal information in code
  - **NamingConventions** - AI-readable naming
  - **Documentation** - Module and function documentation

  ## Usage

      # Check a library
      {:ok, result} = LibraryConstruction.check_directory("apps/arbor_eval/lib/")

      # Strict mode for new libraries
      {:ok, result} = LibraryConstruction.check_directory("apps/arbor_eval/lib/",
        strictness: :strict,
        fail_on: :warning
      )

      # Check with PII names to look for
      {:ok, result} = LibraryConstruction.check_directory("apps/my_lib/lib/",
        additional_names: ["alice", "bob"]
      )

  ## CI Integration

  Use the mix task for CI:

      mix arbor.check_library apps/arbor_eval/lib/ --ci

  ## Strictness Levels

  - `:relaxed` - Only critical issues (for legacy code audits)
  - `:standard` - Reasonable defaults (for existing code)
  - `:strict` - Full AI-readable requirements (for new libraries)
  """

  use ArborEval.Suite,
    name: "library_construction",
    description: "Quality checks for Arbor library construction"

  alias ArborEval.Checks.{
    ElixirIdioms,
    PIIDetection,
    NamingConventions,
    Documentation
  }

  @impl ArborEval.Suite
  def evals do
    [
      ElixirIdioms,
      PIIDetection,
      NamingConventions,
      Documentation
    ]
  end

  @impl ArborEval.Suite
  def filter_files(files) do
    Enum.reject(files, fn file ->
      # Skip test files and scripts by default
      String.contains?(file, "/test/") or
        String.contains?(file, "_test.exs") or
        String.ends_with?(file, ".exs")
    end)
  end

  @impl ArborEval.Suite
  def setup(context) do
    # Pass through configuration to individual evals
    opts = Map.get(context, :opts, [])

    eval_context = %{
      strictness: Keyword.get(opts, :strictness, :standard),
      additional_names: Keyword.get(opts, :additional_names, []),
      additional_patterns: Keyword.get(opts, :additional_patterns, []),
      require_moduledoc: Keyword.get(opts, :require_moduledoc, true),
      require_doc: Keyword.get(opts, :require_doc, true)
    }

    {:ok, Map.put(context, :eval_context, eval_context)}
  end
end
