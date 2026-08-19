defmodule Arbor.Actions.ShellSpawnAndContainmentSecurityRegressionTest do
  @moduledoc """
  Security regression: exit_code 0 + containment_failure true must not pass
  through any public Arbor.Actions.Mix validation action.

  Proves the gate on the public action surface (Compile, Test, Quality, Format,
  Xref), not only helper classification. On parent 414c1d9df this fails at the
  containment assertion (passed/reason/envelope), not at compile/setup.

  Path is the plan-canonical name for causal parent validation discovery.
  """

  use Arbor.Actions.ActionCase, async: false
  @moduletag :slow
  @moduletag :security_regression

  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Actions.MixPrincipalHelpers
  alias Arbor.Actions.TestMixShell

  @expected_containment_termination %{
    "timed_out" => false,
    "killed" => true,
    "output_limit_exceeded" => false,
    "cancelled" => false,
    "containment_failure" => true
  }

  @expected_capacity_termination %{
    "timed_out" => false,
    "killed" => true,
    "output_limit_exceeded" => false,
    "cancelled" => false
  }

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    previous_shell_module = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      if is_nil(previous_shell_module) do
        Application.delete_env(:arbor_actions, :mix_shell_module)
      else
        Application.put_env(:arbor_actions, :mix_shell_module, previous_shell_module)
      end
    end)

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir)
    {:ok, project_path: fixture.project_path, fixture: fixture}
  end

  test "security regression: exit_code 0 + containment_failure cannot pass any public Mix action",
       %{
         project_path: project_path,
         fixture: fixture
       } do
    actions = [
      {MixAction.Compile,
       %{
         path: project_path,
         workspace_id: fixture.lease.workspace_id,
         warnings_as_errors: true
       }},
      {MixAction.Test, %{path: project_path, workspace_id: fixture.lease.workspace_id}},
      {MixAction.Quality, %{path: project_path, workspace_id: fixture.lease.workspace_id}},
      {MixAction.Format,
       %{path: project_path, workspace_id: fixture.lease.workspace_id, check_only: true}},
      {MixAction.Xref,
       %{path: project_path, workspace_id: fixture.lease.workspace_id, mode: "graph"}}
    ]

    for {action_mod, params} <- actions do
      TestMixShell.clear_last_invocation()
      TestMixShell.clear_canned_spawn_result()

      # Trusted Shell flags: exit 0 plus containment_failure (killed also true,
      # matching real Shell Executor coupling). Must not pass and must not be
      # folded into validation_capacity_exceeded.
      TestMixShell.set_canned_spawn_result(%{
        exit_code: 0,
        stdout: "ok",
        stderr: "",
        timed_out: false,
        killed: true,
        output_limit_exceeded: false,
        cancelled: false,
        output_truncated: false,
        containment_failure: true
      })

      try do
        assert {:ok, result} = run_mix_action(action_mod, params, fixture.context),
               "#{inspect(action_mod)} must return {:ok, result}"

        assert result.exit_code == 0,
               "#{inspect(action_mod)} exit_code"

        assert result.passed == false,
               "#{inspect(action_mod)} must set passed false on containment_failure"

        assert result.reason == "validation_containment_failure",
               "#{inspect(action_mod)} reason"

        assert result.termination == @expected_containment_termination,
               "#{inspect(action_mod)} five-key containment termination envelope"

        assert map_size(result.termination) == 5
        assert {:ok, _json} = Jason.encode(result)

        if Map.has_key?(result, :feedback) do
          refute result.feedback["passed"]
          assert result.feedback["exit_code"] == 0
        end
      after
        TestMixShell.clear_canned_spawn_result()
        TestMixShell.clear_last_invocation()
      end
    end
  end

  test "capacity kill without containment still projects four-key validation_capacity_exceeded",
       %{
         project_path: project_path,
         fixture: fixture
       } do
    TestMixShell.clear_canned_spawn_result()

    TestMixShell.set_canned_spawn_result(%{
      exit_code: 137,
      stdout: "killed",
      stderr: "",
      timed_out: false,
      killed: true,
      output_limit_exceeded: false,
      cancelled: false,
      output_truncated: false
    })

    try do
      assert {:ok, result} =
               MixPrincipalHelpers.run(
                 MixAction.Compile,
                 %{
                   path: project_path,
                   workspace_id: fixture.lease.workspace_id,
                   warnings_as_errors: true
                 },
                 fixture.context
               )

      assert result.passed == false
      assert result.reason == "validation_capacity_exceeded"
      assert result.termination == @expected_capacity_termination
      assert map_size(result.termination) == 4
      refute Map.has_key?(result.termination, "containment_failure")
    after
      TestMixShell.clear_canned_spawn_result()
    end
  end

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

    task_id = "task_mix_contain_#{System.unique_integer([:positive])}"
    principal_id = "agent_mix_contain_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo,
               branch: "mix-contain-#{System.unique_integer([:positive])}",
               worktree_base_dir: Path.join(tmp_dir, "worktrees"),
               task_id: task_id,
               principal_id: principal_id,
               base_ref: base
             })

    project_path = lease.worktree_path
    create_tiny_mix_project(project_path)
    git!(project_path, ["add", "-A"])
    git!(project_path, ["commit", "-m", "tiny project"])

    context = %{task_id: task_id, principal_id: principal_id, agent_id: principal_id}
    {:ok, _} = MixPrincipalHelpers.install_agent(principal_id)

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context)
    end)

    %{lease: lease, context: context, project_path: project_path, repo: repo}
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

    File.write!(Path.join(path, "mix.lock"), "%{}\n")
    path
  end

  defp run_mix_action(module, params, context)
       when module in [MixAction.Compile, MixAction.Test, MixAction.Format] do
    MixPrincipalHelpers.run(module, params, context)
  end

  defp run_mix_action(module, params, context) do
    module.run(params, context)
  end
end
