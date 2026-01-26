defmodule ArborEvalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  describe "run/2" do
    test "runs a single eval" do
      code = """
      defmodule Test do
        @moduledoc "Test module"
        def test(), do: :ok
      end
      """

      {:ok, result} = ArborEval.run(ArborEval.Checks.Documentation, code: code)

      assert result.eval == ArborEval.Checks.Documentation
      assert result.name == "documentation"
      assert result.category == :code_quality
    end

    test "returns error for invalid code" do
      assert {:error, {:parse_error, _, _}} = ArborEval.run(ArborEval.Checks.Documentation, code: "def invalid(")
    end
  end

  describe "run_all/2" do
    test "runs multiple evals" do
      code = """
      defmodule Test do
        @moduledoc "Test module"
        def test(), do: :ok
      end
      """

      {:ok, results} = ArborEval.run_all(
        [ArborEval.Checks.Documentation, ArborEval.Checks.ElixirIdioms],
        code: code
      )

      assert length(results) == 2
      assert Enum.any?(results, &(&1.name == "documentation"))
      assert Enum.any?(results, &(&1.name == "elixir_idioms"))
    end
  end

  describe "check_file/2" do
    test "checks a file" do
      # Create a temp file
      path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(10000)}.ex")

      File.write!(path, """
      defmodule TempTest do
        @moduledoc "Temp module"
        def test(), do: :ok
      end
      """)

      try do
        {:ok, results} = ArborEval.check_file(path)
        assert is_list(results)
      after
        File.rm!(path)
      end
    end

    test "returns error for missing file" do
      assert {:error, {:file_read_failed, _, :enoent}} = ArborEval.check_file("/nonexistent/file.ex")
    end
  end

  describe "check_code/2" do
    test "checks code string" do
      code = """
      defmodule Test do
        @moduledoc "Test"
        def test(), do: :ok
      end
      """

      {:ok, results} = ArborEval.check_code(code)
      assert is_list(results)
      assert length(results) > 0
    end

    test "allows specifying evals" do
      code = """
      defmodule Test do
        @moduledoc "Test"
        def test(), do: :ok
      end
      """

      {:ok, results} = ArborEval.check_code(code, evals: [ArborEval.Checks.Documentation])
      assert length(results) == 1
      assert hd(results).name == "documentation"
    end
  end

  describe "summary/1" do
    test "summarizes results" do
      code = """
      defmodule Test do
        def test(), do: :ok
      end
      """

      {:ok, results} = ArborEval.check_code(code)
      summary = ArborEval.summary(results)

      assert is_integer(summary.total)
      assert is_integer(summary.passed)
      assert is_integer(summary.failed)
      assert is_integer(summary.violations)
      assert is_integer(summary.suggestions)
      assert is_map(summary.by_category)
    end
  end
end
