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
    @tag :requires_pinned_mix
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
      assert feedback["stdout_excerpt"] =~ "...[omitted]..."
      assert feedback["stderr_excerpt"] =~ "...[omitted]..."
      assert String.starts_with?(feedback["stdout_excerpt"], String.slice(stdout, 0, 16))
      assert String.ends_with?(feedback["stdout_excerpt"], String.slice(stdout, -16, 16))
      assert String.starts_with?(feedback["stderr_excerpt"], String.slice(stderr, 0, 16))
      assert String.ends_with?(feedback["stderr_excerpt"], String.slice(stderr, -16, 16))

      assert feedback["stdout_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, stdout), case: :lower)

      assert feedback["stderr_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, stderr), case: :lower)

      assert {:ok, _json} = Jason.encode(feedback)
    end

    test "leaves short output unchanged" do
      result = %{exit_code: 0, stdout: "compile ok\n", stderr: "warning\n"}
      feedback = MixAction.compile_feedback(result)

      assert feedback["stdout_excerpt"] == result.stdout
      assert feedback["stderr_excerpt"] == result.stderr
      refute feedback["stdout_truncated"]
      refute feedback["stderr_truncated"]
    end

    test "retains a failure marker present only at the end of long output" do
      limit = MixAction.compile_feedback_text_limit()
      failure = "FAILURE_ONLY_AT_END"
      stdout = String.duplicate("progress\n", limit) <> failure

      feedback = MixAction.compile_feedback(%{exit_code: 1, stdout: stdout, stderr: ""})

      assert feedback["stdout_truncated"]
      assert String.length(feedback["stdout_excerpt"]) == limit
      assert feedback["stdout_excerpt"] =~ "...[omitted]..."
      assert String.ends_with?(feedback["stdout_excerpt"], failure)

      assert feedback ==
               MixAction.compile_feedback(%{exit_code: 1, stdout: stdout, stderr: ""})
    end
  end

  describe "Mix.Test" do
    @tag :requires_pinned_mix
    test "passes for a passing project", %{project_path: project_path} do
      assert {:ok, result} = MixAction.Test.run(%{path: project_path}, %{})

      assert result.path == project_path
      assert result.exit_code == 0
      assert result.passed == true
      # ExUnit wording varies by version ("1 passed" vs "1 test, 0 failures").
      assert result.stdout =~ ~r/1 (passed|test)/
      assert_structured_feedback(result)
    end

    @tag :requires_pinned_mix
    test "fails for a project with a failing test", %{project_path: project_path} do
      add_failing_test(project_path)

      assert {:ok, result} = MixAction.Test.run(%{path: project_path}, %{})

      assert result.exit_code != 0
      assert result.passed == false
      assert_structured_feedback(result)
    end

    @tag :requires_pinned_mix
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

    @tag :requires_pinned_mix
    test "run_mix defaults a direct test task to MIX_ENV=test", %{
      project_path: project_path
    } do
      add_mix_env_assertion(project_path)
      original = System.get_env("MIX_ENV")
      System.delete_env("MIX_ENV")

      try do
        assert {:ok, result} =
                 MixAction.run_mix(project_path, ["test"], env: %{"EXPECTED_MIX_ENV" => "test"})

        assert result.exit_code == 0
      after
        restore_env("MIX_ENV", original)
      end
    end

    @tag :requires_pinned_mix
    test "run_mix honors an explicit MIX_ENV override", %{project_path: project_path} do
      add_mix_env_assertion(project_path)

      assert {:ok, result} =
               MixAction.run_mix(project_path, ["test"],
                 env: %{"MIX_ENV" => "dev", "EXPECTED_MIX_ENV" => "dev"}
               )

      assert result.exit_code == 0
    end

    @tag :requires_pinned_mix
    test "security regression: structured test path keeps inert shell metacharacters", %{
      project_path: project_path
    } do
      relative_path = "test/fix_a_&_b_(safe)_test.exs"

      File.write!(Path.join(project_path, relative_path), """
      defmodule StructuredArgvTest do
        use ExUnit.Case

        test "structured argv" do
          assert true
        end
      end
      """)

      assert {:ok, result} =
               MixAction.Test.run(
                 %{path: project_path, test_paths: [relative_path]},
                 %{}
               )

      assert result.exit_code == 0
      assert result.passed
      assert result.stdout =~ ~r/1 (passed|test)/
    end

    test "security regression: test_paths rejects option injection before Mix", %{
      project_path: project_path
    } do
      assert {:error, reason} =
               MixAction.Test.run(
                 %{path: project_path, test_paths: ["--exclude", "test"]},
                 %{}
               )

      assert reason =~ "rejected invalid test_paths"
      assert reason =~ "--exclude"
      refute reason =~ "0 tests"
    end

    test "security regression: test_paths rejects a symlink outside the project", %{
      project_path: project_path
    } do
      external =
        Path.join(
          System.tmp_dir!(),
          "arbor_external_mix_test_#{System.unique_integer([:positive])}.exs"
        )

      link = Path.join(project_path, "test/external_test.exs")
      File.write!(external, "raise \"external test executed\"\n")
      File.ln_s!(external, link)
      on_exit(fn -> File.rm(external) end)

      assert {:error, reason} =
               MixAction.Test.run(
                 %{path: project_path, test_paths: ["test/external_test.exs"]},
                 %{}
               )

      assert reason =~ "rejected invalid test_paths"
      assert reason =~ "external_test.exs"
    end

    @tag :requires_pinned_mix
    test "security regression: timeout kills a delayed Mix child before returning", %{
      project_path: project_path
    } do
      launched = Path.join(project_path, "mix-child-launched")
      delayed = Path.join(project_path, "mix-child-delayed")
      test_path = "test/delayed_child_test.exs"

      File.write!(Path.join(project_path, test_path), """
      defmodule DelayedChildTest do
        use ExUnit.Case

        test "contained child" do
          Port.open(
            {:spawn_executable, ~c"/bin/sh"},
            [:binary, args: [~c"-c", ~c"touch #{launched}; sleep 1.5; touch #{delayed}"]]
          )

          Process.sleep(5_000)
        end
      end
      """)

      assert {:ok, result} =
               MixAction.Test.run(
                 %{path: project_path, test_paths: [test_path], timeout: 1_000},
                 %{}
               )

      assert result.exit_code == 137
      assert File.exists?(launched)
      Process.sleep(1_700)
      refute File.exists?(delayed), "Mix child survived timeout return"
    end
  end

  describe "Mix.Format" do
    @tag :requires_pinned_mix
    test "check_only mode passes for formatted code", %{project_path: project_path} do
      assert {:ok, result} =
               MixAction.Format.run(%{path: project_path, check_only: true}, %{})

      assert result.exit_code == 0
      assert result.passed == true
    end

    @tag :requires_pinned_mix
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

    @tag :requires_pinned_mix
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

  defp add_mix_env_assertion(path) do
    File.write!(Path.join([path, "test", "mix_env_test.exs"]), """
    defmodule MixEnvTest do
      use ExUnit.Case

      test "runs in the expected Mix environment" do
        assert Atom.to_string(Mix.env()) == System.fetch_env!("EXPECTED_MIX_ENV")
      end
    end
    """)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

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
    assert_excerpt(feedback["stdout_excerpt"], result.stdout || "", text_limit)
    assert_excerpt(feedback["stderr_excerpt"], result.stderr || "", text_limit)

    assert feedback["stdout_truncated"] == String.length(result.stdout || "") > text_limit
    assert feedback["stderr_truncated"] == String.length(result.stderr || "") > text_limit

    assert feedback["stdout_sha256"] == sha256(result.stdout || "")
    assert feedback["stderr_sha256"] == sha256(result.stderr || "")
    assert feedback["stdout_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    assert feedback["stderr_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp assert_excerpt(excerpt, full, limit) do
    if String.length(full) <= limit do
      assert excerpt == full
    else
      assert String.length(excerpt) == limit
      assert excerpt =~ "...[omitted]..."
      assert String.starts_with?(excerpt, String.slice(full, 0, 16))
      assert String.ends_with?(excerpt, String.slice(full, -16, 16))
    end
  end

  defp sha256(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end
end
