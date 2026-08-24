defmodule Arbor.Actions.Coding.SecurityRegression.ShellTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.SecurityRegression.Core
  alias Arbor.Actions.Coding.SecurityRegression.Validate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :slow

  setup do
    Arbor.Actions.TestLinuxBaselineMaterializer.reset_seams()
    :ok
  end

  test "production default Mix runner remains Mix.run_mix/3 when the seam is unset" do
    previous_runner = Application.get_env(:arbor_actions, :security_regression_mix_runner)

    try do
      Application.delete_env(:arbor_actions, :security_regression_mix_runner)

      default =
        Application.get_env(
          :arbor_actions,
          :security_regression_mix_runner,
          &Arbor.Actions.Mix.run_mix/3
        )

      assert default == (&Arbor.Actions.Mix.run_mix/3)
      assert is_function(default, 3)
    after
      if is_nil(previous_runner) do
        Application.delete_env(:arbor_actions, :security_regression_mix_runner)
      else
        Application.put_env(:arbor_actions, :security_regression_mix_runner, previous_runner)
      end
    end
  end

  test "candidate and base Mix children declare intensive profile on independent trees",
       %{tmp_dir: tmp_dir} do
    fixture = regression_fixture(tmp_dir)
    parent = self()

    with_security_regression_runner(
      hermetic_two_revision_runner(parent),
      fn ->
        params = attested_params(fixture, ["test/security_regression_test.exs"])
        assert {:ok, result} = Validate.run(params, fixture.context)
        assert result.passed
        assert result.reason == "security_regression_validated"

        assert_receive {:mix_invocation, candidate_path, _candidate_args, candidate_opts}, 5_000
        assert_receive {:mix_invocation, base_path, _base_args, base_opts}, 5_000
        refute_received {:mix_invocation, _, _, _}

        assert Keyword.get(candidate_opts, :validation_revision) == :candidate
        assert Keyword.get(base_opts, :validation_revision) == :base
        assert Keyword.get(candidate_opts, :resource_profile) == :intensive
        assert Keyword.get(base_opts, :resource_profile) == :intensive
        assert Keyword.get(candidate_opts, :env) == %{"MIX_ENV" => "test"}
        assert Keyword.get(base_opts, :env) == %{"MIX_ENV" => "test"}

        candidate_resource = Keyword.get(candidate_opts, :validation_resource)
        base_resource = Keyword.get(base_opts, :validation_resource)
        assert is_map(candidate_resource)
        assert is_map(base_resource)
        assert is_binary(candidate_path)
        assert is_binary(base_path)
        assert Path.type(candidate_path) == :absolute
        assert Path.type(base_path) == :absolute
        refute candidate_path == base_path
        refute candidate_path == fixture.lease.worktree_path
        refute base_path == fixture.lease.worktree_path
        assert candidate_resource.candidate_build_path != base_resource.base_build_path
        assert candidate_resource.candidate_deps_path != base_resource.base_deps_path
      end
    )
  end

  test "timeout above the standard Shell ceiling reaches Mix with resource_profile intensive",
       %{tmp_dir: tmp_dir} do
    fixture = regression_fixture(tmp_dir)
    parent = self()
    standard_ceiling = Arbor.Shell.spawn_capable_max_timeout_ms()
    assert standard_ceiling == 600_000
    assert {:ok, intensive_ceiling} = Arbor.Shell.spawn_capable_max_timeout_ms(:intensive)
    operation_timeout = standard_ceiling + 1
    assert operation_timeout <= intensive_ceiling

    with_security_regression_runner(
      hermetic_two_revision_runner(parent),
      fn ->
        params =
          fixture
          |> attested_params(["test/security_regression_test.exs"])
          |> Map.put(:timeout, operation_timeout)

        assert {:ok, result} = Validate.run(params, fixture.context)
        assert result.passed

        assert_receive {:mix_invocation, _candidate_path, _candidate_args, candidate_opts}, 5_000
        assert_receive {:mix_invocation, _base_path, _base_args, base_opts}, 5_000
        assert Keyword.get(candidate_opts, :validation_revision) == :candidate
        assert Keyword.get(base_opts, :validation_revision) == :base
        assert Keyword.get(candidate_opts, :timeout) == operation_timeout
        assert Keyword.get(base_opts, :timeout) == operation_timeout
        assert Keyword.get(candidate_opts, :resource_profile) == :intensive
        assert Keyword.get(base_opts, :resource_profile) == :intensive
      end
    )
  end

  defp hermetic_two_revision_runner(parent) do
    fn path, args, opts ->
      send(parent, {:mix_invocation, path, args, opts})
      revision = Keyword.get(opts, :validation_revision)
      result_path = mix_result_path(args)
      {exit_code, counts} = artifact_for_revision(revision)
      write_artifact(result_path, counts)

      {:ok, %{exit_code: exit_code, stdout: "", stderr: "", timed_out: false}}
    end
  end

  defp mix_result_path(["run", "--no-start", _runner, "--", result_path | _tests])
       when is_binary(result_path) do
    result_path
  end

  defp artifact_for_revision(:candidate) do
    {0,
     %{
       excluded: 0,
       executed: 1,
       invalid: 0,
       max_failures_reached: false,
       passed: 1,
       setup_failures: 0,
       skipped: 0,
       suite_completed: true,
       suite_started: true,
       test_failures: 0,
       total: 1
     }}
  end

  defp artifact_for_revision(:base) do
    {1,
     %{
       excluded: 0,
       executed: 1,
       invalid: 0,
       max_failures_reached: false,
       passed: 0,
       setup_failures: 0,
       skipped: 0,
       suite_completed: true,
       suite_started: true,
       test_failures: 1,
       total: 1
     }}
  end

  defp write_artifact(path, counts) when is_binary(path) and is_map(counts) do
    File.mkdir_p!(Path.dirname(path))
    artifact = {Core.artifact_tag(), Core.artifact_version(), counts}
    File.write!(path, :erlang.term_to_binary(artifact))
  end

  defp regression_fixture(tmp_dir) do
    fixture =
      leased_project(tmp_dir, "defmodule Tiny.Security do\n  def allow_guest?, do: true\nend\n")

    write_candidate_module(
      fixture,
      "defmodule Tiny.Security do\n  def allow_guest?, do: false\nend\n"
    )

    write_candidate_test(fixture, "test/security_regression_test.exs", """
    defmodule Tiny.SecurityRegressionTest do
      use ExUnit.Case
      test "guest remains denied", do: refute(Tiny.Security.allow_guest?())
    end
    """)

    fixture
  end

  defp with_security_regression_runner(runner, fun) do
    previous_runner = Application.get_env(:arbor_actions, :security_regression_mix_runner)
    Application.put_env(:arbor_actions, :security_regression_mix_runner, runner)

    try do
      fun.()
    after
      if is_nil(previous_runner) do
        Application.delete_env(:arbor_actions, :security_regression_mix_runner)
      else
        Application.put_env(:arbor_actions, :security_regression_mix_runner, previous_runner)
      end
    end
  end

  defp attested_params(fixture, test_paths) do
    {:ok, material} =
      Workspace.materialize_security_regression_material(
        fixture.lease.worktree_path,
        fixture.lease.workspace_id,
        fixture.lease.base_commit,
        test_paths
      )

    digest = :crypto.hash(:sha256, "council-approved") |> Base.encode16(case: :lower)

    {:ok, %{review_attestation_id: id}} =
      WorkspaceLeaseRegistry.issue_review_attestation(
        fixture.lease.workspace_id,
        material,
        digest,
        fixture.context
      )

    %{review_attestation_id: id}
  end

  defp leased_project(tmp_dir, base_module, opts \\ []) do
    repo =
      create_base_project(
        Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"),
        base_module,
        opts
      )

    task_id = "task_security_regression_#{System.unique_integer([:positive])}"
    principal_id = "agent_security_regression_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/security-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_base_project(path, base_module, opts) do
    create_git_repo(path)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project
      def project, do: [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
    end
    """)

    helper = Keyword.get(opts, :test_helper, "ExUnit.start()\n")
    File.write!(Path.join(path, "lib/security.ex"), base_module)
    File.write!(Path.join(path, "test/test_helper.exs"), helper)
    git!(path, ["add", "mix.exs", "lib/security.ex", "test/test_helper.exs"])
    git!(path, ["commit", "-m", "base"])
    path
  end

  defp write_candidate_module(fixture, source) do
    File.write!(Path.join(fixture.lease.worktree_path, "lib/security.ex"), source)
    git!(fixture.lease.worktree_path, ["add", "lib/security.ex"])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate module"])
  end

  defp write_candidate_test(fixture, relative_path, source) do
    path = Path.join(fixture.lease.worktree_path, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    git!(fixture.lease.worktree_path, ["add", relative_path])
    git!(fixture.lease.worktree_path, ["commit", "-m", "candidate test"])
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
