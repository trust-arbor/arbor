defmodule Arbor.Eval.SuiteTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Eval.Suites.LibraryConstruction

  describe "check_file/2" do
    test "checks a single file" do
      path = Path.join(System.tmp_dir!(), "suite_test_#{System.unique_integer([:positive])}.ex")

      File.write!(path, """
      defmodule SuiteTestModule do
        @moduledoc "Test module for suite"

        @doc "Test function"
        def test(), do: :ok
      end
      """)

      try do
        {:ok, result} = LibraryConstruction.check_file(path)
        assert result.suite == LibraryConstruction
        assert result.name == "library_construction"
        assert result.files_checked == 1
      after
        File.rm!(path)
      end
    end
  end

  describe "check_directory/2" do
    test "checks multiple files in directory" do
      dir = Path.join(System.tmp_dir!(), "suite_test_dir_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create two test files
      File.write!(Path.join(dir, "module_a.ex"), """
      defmodule ModuleA do
        @moduledoc "Module A"
        @doc "Test"
        def test(), do: :a
      end
      """)

      File.write!(Path.join(dir, "module_b.ex"), """
      defmodule ModuleB do
        @moduledoc "Module B"
        @doc "Test"
        def test(), do: :b
      end
      """)

      try do
        {:ok, result} = LibraryConstruction.check_directory(dir)
        assert result.files_checked == 2
        assert result.summary.files == 2
      after
        File.rm_rf!(dir)
      end
    end

    test "returns error for empty directory" do
      dir = Path.join(System.tmp_dir!(), "empty_suite_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      try do
        assert {:error, {:no_files_found, ^dir}} = LibraryConstruction.check_directory(dir)
      after
        File.rm_rf!(dir)
      end
    end

    test "excludes files matching exclude patterns" do
      dir = Path.join(System.tmp_dir!(), "exclude_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test"))

      # Create main file
      File.write!(Path.join(dir, "main.ex"), """
      defmodule Main do
        @moduledoc "Main"
        @doc "Test"
        def test(), do: :main
      end
      """)

      # Create test file (should be excluded by default)
      File.write!(Path.join([dir, "test", "main_test.exs"]), """
      defmodule MainTest do
        use ExUnit.Case
        test "works" do
          assert true
        end
      end
      """)

      try do
        {:ok, result} = LibraryConstruction.check_directory(dir)
        # Only the main file should be checked, test file filtered out
        assert result.files_checked == 1
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "summary" do
    test "provides comprehensive summary" do
      dir = Path.join(System.tmp_dir!(), "summary_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create file with violations
      File.write!(Path.join(dir, "has_issues.ex"), """
      defmodule HasIssues do
        def undocumented(), do: :no_doc
      end
      """)

      try do
        {:ok, result} = LibraryConstruction.check_directory(dir)

        assert is_integer(result.summary.files)
        assert is_integer(result.summary.files_passed)
        assert is_integer(result.summary.files_failed)
        assert is_integer(result.summary.errors)
        assert is_integer(result.summary.warnings)
        assert is_integer(result.summary.suggestions)
        assert is_map(result.summary.by_type)
      after
        File.rm_rf!(dir)
      end
    end
  end

  describe "fail_on option" do
    test "fail_on :error only fails on errors" do
      dir = Path.join(System.tmp_dir!(), "failon_error_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # Create file with only warnings (missing moduledoc is a warning)
      File.write!(Path.join(dir, "warnings_only.ex"), """
      defmodule WarningsOnly do
        def init(_), do: {:ok, []}
      end
      """)

      try do
        {:ok, result} = LibraryConstruction.check_directory(dir, fail_on: :error)
        # Should pass because missing_moduledoc is only a warning
        assert result.passed
      after
        File.rm_rf!(dir)
      end
    end
  end
end
