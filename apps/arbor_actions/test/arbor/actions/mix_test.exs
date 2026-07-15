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

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Config
  alias Arbor.Actions.Mix, as: MixAction

  defmodule WrongCallbackMixShell do
    def execute_spawn_capable(_tool, _args), do: {:error, :wrong_arity}
  end

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    previous_shell_module = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      restore_env(:arbor_actions, :mix_shell_module, previous_shell_module)
    end)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {:ok, project_path: fixture.project_path, fixture: fixture}
  end

  describe "Mix.Compile" do
    test "passes for a compiling project", %{project_path: project_path, fixture: fixture} do
      assert {:ok, result} =
               MixAction.Compile.run(
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   warnings_as_errors: true
                 },
                 fixture.context
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

    test "action shell seam fails closed for a configured closure", %{fixture: fixture} do
      error = {:invalid_mix_shell_module, :named_module_required}

      assert_mix_shell_error(fixture, fn -> :not_a_module end, error)
    end

    test "action shell seam fails closed for a missing named module", %{fixture: fixture} do
      module = Arbor.Actions.MissingMixShellModule
      error = {:invalid_mix_shell_module, {:module_not_loaded, module}}

      assert_mix_shell_error(fixture, module, error)
    end

    test "action shell seam fails closed for a module with the wrong callback", %{
      fixture: fixture
    } do
      error =
        {:invalid_mix_shell_module,
         {:callback_not_exported, WrongCallbackMixShell, :execute_spawn_capable, 3}}

      assert_mix_shell_error(fixture, WrongCallbackMixShell, error)
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
    test "passes for a passing project", %{project_path: project_path, fixture: fixture} do
      assert {:ok, result} =
               MixAction.Test.run(
                 %{path: project_path, workspace_id: fixture.lease.workspace_id},
                 fixture.context
               )

      assert result.path == project_path
      assert result.exit_code == 0
      assert result.passed == true
      # ExUnit wording varies by version ("1 passed" vs "1 test, 0 failures").
      assert result.stdout =~ ~r/1 (passed|test)/
      assert_structured_feedback(result)
    end

    test "fails for a project with a failing test", %{
      project_path: project_path,
      fixture: fixture
    } do
      add_failing_test(project_path)
      commit_worktree!(fixture)

      assert {:ok, result} =
               MixAction.Test.run(
                 %{path: project_path, workspace_id: fixture.lease.workspace_id},
                 fixture.context
               )

      assert result.exit_code != 0
      assert result.passed == false
      assert_structured_feedback(result)
    end

    test "respects tag filter via --only", %{project_path: project_path, fixture: fixture} do
      assert {:ok, result} =
               MixAction.Test.run(
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   tags: "nonexistent"
                 },
                 fixture.context
               )

      # No tests matched the tag → mix test reports "no tests to run"
      assert result.stdout =~ "0 tests" or result.stdout =~ "no tests"
    end

    test "exposes Jido action metadata" do
      assert MixAction.Test.name() == "mix_test"
      assert MixAction.Test.category() == "mix"
      assert "test" in MixAction.Test.tags()
    end

    test "run_mix defaults a direct test task to MIX_ENV=test", %{
      project_path: project_path,
      fixture: fixture
    } do
      add_mix_env_assertion(project_path, "test")
      commit_worktree!(fixture)
      original = System.get_env("MIX_ENV")
      System.delete_env("MIX_ENV")

      try do
        MixAction.with_validation_resource(
          fixture.lease.workspace_id,
          fixture.context,
          fn resource ->
            assert {:ok, result} =
                     MixAction.run_mix(project_path, ["test"], validation_resource: resource)

            assert result.exit_code == 0
            {:ok, :ok}
          end
        )
      after
        restore_env("MIX_ENV", original)
      end
    end

    test "run_mix honors an explicit MIX_ENV override", %{
      project_path: project_path,
      fixture: fixture
    } do
      add_mix_env_assertion(project_path, "dev")
      commit_worktree!(fixture)

      MixAction.with_validation_resource(
        fixture.lease.workspace_id,
        fixture.context,
        fn resource ->
          assert {:ok, result} =
                   MixAction.run_mix(project_path, ["test"],
                     validation_resource: resource,
                     env: %{"MIX_ENV" => "dev"}
                   )

          assert result.exit_code == 0
          {:ok, :ok}
        end
      )
    end

    test "security regression: closed wrapper identity and caller path env scrubbing", %{
      project_path: project_path,
      fixture: fixture
    } do
      assert {:ok, wrapper} = MixAction.resolve_mix_wrapper()
      assert Path.basename(wrapper) == "mix"
      assert String.ends_with?(wrapper, "/bin/mix")
      assert File.regular?(wrapper)

      # Application env cannot become wrapper authority.
      previous = Application.get_env(:arbor_actions, :mix_wrapper_path)

      try do
        Application.put_env(:arbor_actions, :mix_wrapper_path, "/tmp/evil-mix")
        assert {:ok, ^wrapper} = MixAction.resolve_mix_wrapper()
      after
        restore_env(:arbor_actions, :mix_wrapper_path, previous)
      end

      # Public helper never returns paths without a live validation resource.
      assert {:error, :validation_resource_required} =
               MixAction.contained_mix_env(
                 env: %{
                   "MIX_ENV" => "test",
                   "MIX_BUILD_PATH" => "/tmp/evil-build",
                   "MIX_DEPS_PATH" => "/tmp/evil-deps",
                   "HOME" => "/tmp/evil-home",
                   "ARBOR_ERLANG_ROOT" => "/tmp/evil-erlang",
                   "PATH" => "/tmp/evil-bin"
                 }
               )

      # Owner-issued resource path scrubbing.
      MixAction.with_validation_resource(
        fixture.lease.workspace_id,
        fixture.context,
        fn resource ->
          assert {:ok, _result} =
                   MixAction.run_mix(project_path, ["compile"],
                     validation_resource: resource,
                     env: %{
                       "MIX_ENV" => "test",
                       "MIX_BUILD_PATH" => "/tmp/evil-build",
                       "HOME" => "/tmp/evil-home",
                       "PATH" => "/tmp/evil-bin"
                     }
                   )

          invocation = Arbor.Actions.TestMixShell.last_invocation()
          assert invocation.wrapper == wrapper
          assert invocation.tool == wrapper
          env_map = Map.new(invocation.env)
          assert env_map["ARBOR_MIX_CONTAINED"] == "1"
          assert env_map["MIX_ENV"] == "test"
          refute env_map["MIX_BUILD_PATH"] == "/tmp/evil-build"
          refute env_map["HOME"] == "/tmp/evil-home"
          refute env_map["PATH"] == "/tmp/evil-bin"
          assert env_map["HOME"] == resource.candidate_home_path
          assert String.contains?(env_map["PATH"], env_map["ARBOR_ERLANG_ROOT"])
          {:ok, :ok}
        end
      )
    end

    test "security regression: structured test path keeps inert shell metacharacters", %{
      project_path: project_path,
      fixture: fixture
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

      commit_worktree!(fixture)

      assert {:ok, result} =
               MixAction.Test.run(
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   test_paths: [relative_path]
                 },
                 fixture.context
               )

      assert result.exit_code == 0
      assert result.passed
      assert result.stdout =~ ~r/1 (passed|test)/
    end

    test "security regression: test_paths rejects option injection before Mix", %{
      project_path: project_path,
      fixture: fixture
    } do
      assert {:error, reason} =
               MixAction.Test.run(
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   test_paths: ["--exclude", "test"]
                 },
                 fixture.context
               )

      assert reason =~ "rejected invalid test_paths"
      assert reason =~ "--exclude"
      refute reason =~ "0 tests"
    end

    test "security regression: test_paths rejects a symlink outside the project", %{
      project_path: project_path,
      fixture: fixture
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
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   test_paths: ["test/external_test.exs"]
                 },
                 fixture.context
               )

      assert reason =~ "rejected invalid test_paths"
      assert reason =~ "external_test.exs"
    end
  end

  describe "Mix.Format" do
    test "check_only mode passes for formatted code", %{
      project_path: project_path,
      fixture: fixture
    } do
      assert {:ok, result} =
               MixAction.Format.run(
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   check_only: true
                 },
                 fixture.context
               )

      assert result.exit_code == 0
      assert result.passed == true
    end

    test "check_only mode fails for unformatted code", %{
      project_path: project_path,
      fixture: fixture
    } do
      # Write deliberately misformatted code.
      lib_path = Path.join([project_path, "lib", "tiny.ex"])
      original = File.read!(lib_path)
      File.write!(lib_path, "defmodule    Tiny do\n  def hi,    do:     :hi\nend\n")

      assert {:ok, result} =
               MixAction.Format.run(
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   check_only: true
                 },
                 fixture.context
               )

      assert result.exit_code != 0
      assert result.passed == false

      File.write!(lib_path, original)
    end

    test "write mode rewrites unformatted code", %{project_path: project_path, fixture: fixture} do
      lib_path = Path.join([project_path, "lib", "tiny.ex"])
      File.write!(lib_path, "defmodule    Tiny do\ndef hi,do: :hi\nend\n")

      assert {:ok, result} =
               MixAction.Format.run(
                 %{path: project_path, workspace_id: fixture.lease.workspace_id},
                 fixture.context
               )

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

  defp leased_project(tmp_dir) do
    repo = Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    File.write!(Path.join(repo, "README"), "hi\n")
    git!(repo, ["add", "README"])
    git!(repo, ["commit", "-m", "init"])
    base = git!(repo, ["rev-parse", "HEAD"])

    task_id = "task_mix_test_#{System.unique_integer([:positive])}"
    principal_id = "agent_mix_test_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo,
               branch: "mix-test-#{System.unique_integer([:positive])}",
               task_id: task_id,
               principal_id: principal_id,
               base_ref: base
             })

    project_path = lease.worktree_path
    create_tiny_mix_project(project_path)
    git!(project_path, ["add", "-A"])
    git!(project_path, ["commit", "-m", "tiny project"])

    context = %{task_id: task_id, principal_id: principal_id, agent_id: principal_id}

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context)
    end)

    %{lease: lease, context: context, project_path: project_path, repo: repo}
  end

  defp commit_worktree!(fixture) do
    git!(fixture.project_path, ["add", "-A"])
    # May be no-op if clean.
    _ =
      System.cmd("git", ["-C", fixture.project_path, "commit", "-m", "update"],
        stderr_to_stdout: true
      )

    :ok
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

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

  defp add_mix_env_assertion(path, expected_env) when is_binary(expected_env) do
    File.write!(Path.join([path, "test", "mix_env_test.exs"]), """
    defmodule MixEnvTest do
      use ExUnit.Case

      test "runs in the expected Mix environment" do
        assert Atom.to_string(Mix.env()) == #{inspect(expected_env)}
      end
    end
    """)
  end

  defp assert_mix_shell_error(fixture, configured, expected) do
    previous = Application.get_env(:arbor_actions, :mix_shell_module)

    try do
      Application.put_env(:arbor_actions, :mix_shell_module, configured)
      assert {:error, ^expected} = Config.mix_shell_module()

      assert {:error, reason} =
               MixAction.run_with_required_workspace(
                 fixture.project_path,
                 ["compile"],
                 %{
                   path: fixture.project_path,
                   workspace_id: fixture.lease.workspace_id
                 },
                 fixture.context,
                 []
               )

      assert reason == expected or reason == inspect(expected)
    after
      restore_env(:arbor_actions, :mix_shell_module, previous)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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
