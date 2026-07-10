defmodule Arbor.Actions.MixTest do
  @moduledoc """
  Tests for `Arbor.Actions.Mix.{Compile, Test, Quality, Format}`.

  These actions wrap real `mix` invocations and are slow (each `mix test`
  warm-up is ~3s). We tag them `:slow` and run them against a tiny
  one-module mix project the setup builds in tmp_dir, not against the
  umbrella itself.
  """

  use Arbor.Actions.ActionCase, async: false
  @moduletag :slow

  alias Arbor.Actions.Mix, as: MixAction

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    project_path = Path.join(tmp_dir, "tiny_project")
    create_tiny_mix_project(project_path)
    {:ok, project_path: project_path}
  end

  describe "Mix.Compile" do
    test "passes for a compiling project", %{project_path: project_path} do
      assert {:ok, result} =
               MixAction.Compile.run(
                 %{path: project_path, warnings_as_errors: true},
                 %{}
               )

      assert result.path == project_path
      assert result.exit_code == 0
      assert result.passed == true
      assert result.feedback["exit_code"] == 0
      assert result.feedback["passed"]
      assert Jason.decode!(result.feedback_json) == result.feedback
    end

    test "exposes Jido action metadata" do
      assert MixAction.Compile.name() == "mix_compile"
      assert MixAction.Compile.category() == "mix"
      assert "compile" in MixAction.Compile.tags()
    end

    test "builds deterministic, bounded, JSON-clean compile feedback" do
      stdout = String.duplicate("stdout ", MixAction.compile_feedback_text_limit())
      stderr = String.duplicate("stderr ", MixAction.compile_feedback_text_limit())
      result = %{exit_code: 1, stdout: stdout, stderr: stderr}

      feedback = MixAction.compile_feedback(result)

      assert feedback == MixAction.compile_feedback(result)
      assert Jason.encode!(feedback) == Jason.encode!(MixAction.compile_feedback(result))
      assert feedback["exit_code"] == 1
      refute feedback["passed"]
      assert feedback["stdout_truncated"]
      assert feedback["stderr_truncated"]
      assert String.length(feedback["stdout_excerpt"]) == MixAction.compile_feedback_text_limit()
      assert String.length(feedback["stderr_excerpt"]) == MixAction.compile_feedback_text_limit()

      assert feedback["stdout_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, stdout), case: :lower)

      assert feedback["stderr_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, stderr), case: :lower)

      assert {:ok, _json} = Jason.encode(feedback)
    end
  end

  describe "Mix.Test" do
    test "passes for a passing project", %{project_path: project_path} do
      assert {:ok, result} = MixAction.Test.run(%{path: project_path}, %{})

      assert result.path == project_path
      assert result.exit_code == 0
      assert result.passed == true
      # ExUnit wording varies by version ("1 passed" vs "1 test, 0 failures").
      assert result.stdout =~ ~r/1 (passed|test)/
      assert_structured_feedback(result)
    end

    test "fails for a project with a failing test", %{project_path: project_path} do
      add_failing_test(project_path)

      assert {:ok, result} = MixAction.Test.run(%{path: project_path}, %{})

      assert result.exit_code != 0
      assert result.passed == false
      assert_structured_feedback(result)
    end

    test "respects tag filter via --only", %{project_path: project_path} do
      assert {:ok, result} = MixAction.Test.run(%{path: project_path, tags: "nonexistent"}, %{})

      # No tests matched the tag → mix test reports "no tests to run"
      assert result.stdout =~ "0 tests" or result.stdout =~ "no tests"
    end

    test "exposes Jido action metadata" do
      assert MixAction.Test.name() == "mix_test"
      assert MixAction.Test.category() == "mix"
      assert "test" in MixAction.Test.tags()
    end
  end

  describe "Mix.Format" do
    test "check_only mode passes for formatted code", %{project_path: project_path} do
      assert {:ok, result} =
               MixAction.Format.run(%{path: project_path, check_only: true}, %{})

      assert result.exit_code == 0
      assert result.passed == true
    end

    test "check_only mode fails for unformatted code", %{project_path: project_path} do
      # Write deliberately misformatted code.
      lib_path = Path.join([project_path, "lib", "tiny.ex"])
      original = File.read!(lib_path)
      File.write!(lib_path, "defmodule    Tiny do\n  def hi,    do:     :hi\nend\n")

      assert {:ok, result} =
               MixAction.Format.run(%{path: project_path, check_only: true}, %{})

      assert result.exit_code != 0
      assert result.passed == false

      File.write!(lib_path, original)
    end

    test "write mode rewrites unformatted code", %{project_path: project_path} do
      lib_path = Path.join([project_path, "lib", "tiny.ex"])
      File.write!(lib_path, "defmodule    Tiny do\ndef hi,do: :hi\nend\n")

      assert {:ok, result} = MixAction.Format.run(%{path: project_path}, %{})
      assert result.passed == true

      # File got rewritten.
      formatted = File.read!(lib_path)
      assert formatted == "defmodule Tiny do\n  def hi, do: :hi\nend\n"
    end

    test "exposes Jido action metadata" do
      assert MixAction.Format.name() == "mix_format"
      assert MixAction.Format.category() == "mix"
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp create_tiny_mix_project(path) do
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project

      def project do
        [app: :tiny, version: "0.0.1", elixir: "~> 1.14"]
      end
    end
    """)

    File.write!(Path.join([path, "lib", "tiny.ex"]), """
    defmodule Tiny do
      def hi, do: :hi
    end
    """)

    File.write!(Path.join([path, "test", "test_helper.exs"]), "ExUnit.start()\n")

    File.write!(Path.join([path, "test", "tiny_test.exs"]), """
    defmodule TinyTest do
      use ExUnit.Case

      test "hi returns :hi" do
        assert Tiny.hi() == :hi
      end
    end
    """)

    File.write!(Path.join(path, ".formatter.exs"), """
    [inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"]]
    """)

    path
  end

  defp add_failing_test(path) do
    File.write!(Path.join([path, "test", "failing_test.exs"]), """
    defmodule FailingTest do
      use ExUnit.Case

      test "this fails" do
        assert 1 == 2
      end
    end
    """)
  end

  defp assert_structured_feedback(result) do
    feedback = result.feedback
    text_limit = MixAction.compile_feedback_text_limit()

    assert feedback == MixAction.compile_feedback(result)
    assert Jason.decode!(result.feedback_json) == feedback
    assert Jason.decode!(Jason.encode!(feedback)) == feedback
    assert Enum.all?(Map.keys(feedback), &is_binary/1)

    assert feedback["exit_code"] == result.exit_code
    assert feedback["passed"] == result.passed

    assert String.length(feedback["stdout_excerpt"]) <= text_limit
    assert String.length(feedback["stderr_excerpt"]) <= text_limit
    assert feedback["stdout_excerpt"] == String.slice(result.stdout || "", 0, text_limit)
    assert feedback["stderr_excerpt"] == String.slice(result.stderr || "", 0, text_limit)

    assert feedback["stdout_truncated"] == String.length(result.stdout || "") > text_limit
    assert feedback["stderr_truncated"] == String.length(result.stderr || "") > text_limit

    assert feedback["stdout_sha256"] == sha256(result.stdout || "")
    assert feedback["stderr_sha256"] == sha256(result.stderr || "")
    assert feedback["stdout_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert feedback["stderr_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp sha256(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
