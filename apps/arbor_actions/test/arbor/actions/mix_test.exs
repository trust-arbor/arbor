defmodule Arbor.Actions.MixTest do
  @moduledoc """
  Tests for `Arbor.Actions.Mix.{Test, Quality, Format}`.

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

  describe "Mix.Test" do
    test "passes for a passing project", %{project_path: project_path} do
      assert {:ok, result} = MixAction.Test.run(%{path: project_path}, %{})

      assert result.path == project_path
      assert result.exit_code == 0
      assert result.passed? == true
      assert result.stdout =~ "test"
    end

    test "fails for a project with a failing test", %{project_path: project_path} do
      add_failing_test(project_path)

      assert {:ok, result} = MixAction.Test.run(%{path: project_path}, %{})

      assert result.exit_code != 0
      assert result.passed? == false
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
      assert result.passed? == true
    end

    test "check_only mode fails for unformatted code", %{project_path: project_path} do
      # Write deliberately misformatted code.
      lib_path = Path.join([project_path, "lib", "tiny.ex"])
      original = File.read!(lib_path)
      File.write!(lib_path, "defmodule    Tiny do\n  def hi,    do:     :hi\nend\n")

      assert {:ok, result} =
               MixAction.Format.run(%{path: project_path, check_only: true}, %{})

      assert result.exit_code != 0
      assert result.passed? == false

      File.write!(lib_path, original)
    end

    test "write mode rewrites unformatted code", %{project_path: project_path} do
      lib_path = Path.join([project_path, "lib", "tiny.ex"])
      File.write!(lib_path, "defmodule    Tiny do\ndef hi,do: :hi\nend\n")

      assert {:ok, result} = MixAction.Format.run(%{path: project_path}, %{})
      assert result.passed? == true

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
end
