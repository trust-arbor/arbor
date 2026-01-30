defmodule Arbor.EvalTest do
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

      {:ok, result} = Arbor.Eval.run(Arbor.Eval.Checks.Documentation, code: code)

      assert result.eval == Arbor.Eval.Checks.Documentation
      assert result.name == "documentation"
      assert result.category == :code_quality
    end

    test "returns error for invalid code" do
      assert {:error, {:parse_error, _, _}} = Arbor.Eval.run(Arbor.Eval.Checks.Documentation, code: "def invalid(")
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

      {:ok, results} = Arbor.Eval.run_all(
        [Arbor.Eval.Checks.Documentation, Arbor.Eval.Checks.ElixirIdioms],
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
      path = Path.join(System.tmp_dir!(), "test_#{System.unique_integer([:positive])}.ex")

      File.write!(path, """
      defmodule TempTest do
        @moduledoc "Temp module"
        def test(), do: :ok
      end
      """)

      try do
        {:ok, results} = Arbor.Eval.check_file(path)
        assert is_list(results)
      after
        File.rm!(path)
      end
    end

    test "returns error for missing file" do
      assert {:error, {:file_read_failed, _, :enoent}} = Arbor.Eval.check_file("/nonexistent/file.ex")
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

      {:ok, results} = Arbor.Eval.check_code(code)
      assert is_list(results)
      assert results != []
    end

    test "allows specifying evals" do
      code = """
      defmodule Test do
        @moduledoc "Test"
        def test(), do: :ok
      end
      """

      {:ok, results} = Arbor.Eval.check_code(code, evals: [Arbor.Eval.Checks.Documentation])
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

      {:ok, results} = Arbor.Eval.check_code(code)
      summary = Arbor.Eval.summary(results)

      assert is_integer(summary.total)
      assert is_integer(summary.passed)
      assert is_integer(summary.failed)
      assert is_integer(summary.violations)
      assert is_integer(summary.suggestions)
      assert is_map(summary.by_category)
    end
  end
end
