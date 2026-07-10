defmodule Arbor.Actions.Coding.SecurityRegressionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.SecurityRegression.Validate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry

  @moduletag :slow

  test "valid candidate-pass/base-fail proof is deterministic, bounded, and cleaned", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      leased_project(tmp_dir, """
      defmodule Tiny.Security do
        def allow_guest?, do: true
      end
      """)

    write_candidate_module(fixture, """
    defmodule Tiny.Security do
      def allow_guest?, do: false
    end
    """)

    test_path = "test/security_regression_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.SecurityRegressionTest do
      use ExUnit.Case

      test "guest remains denied" do
        refute Tiny.Security.allow_guest?()
      end
    end
    """)

    params = %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]}

    assert {:ok, first} = Validate.run(params, fixture.context)
    assert {:ok, second} = Validate.run(params, fixture.context)

    assert first == second
    assert first.passed
    assert first.reason == "security_regression_validated"
    assert first.base_commit == fixture.lease.base_commit
    assert first.test_paths == [test_path]
    assert first.candidate.executed == 1
    assert first.candidate.test_failures == 0
    assert first.base.executed == 1
    assert first.base.test_failures == 1
    assert first.candidate_fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert [%{path: ^test_path, sha256: source_hash}] = first.source_hashes
    assert source_hash =~ ~r/\A[0-9a-f]{64}\z/
    assert Jason.decode!(first.feedback_json)["passed"]
    assert byte_size(first.feedback_json) < 12_000
    refute first.feedback_json =~ tmp_dir
    refute first.feedback_json =~ "arbor-security-regression-"

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(
               fixture.lease.workspace_id,
               fixture.context
             )
  end

  test "rejects when the staged test also passes at base", %{tmp_dir: tmp_dir} do
    fixture =
      leased_project(tmp_dir, """
      defmodule Tiny.Security do
        def allow_guest?, do: false
      end
      """)

    test_path = "test/base_pass_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.BasePassTest do
      use ExUnit.Case

      test "guest is denied" do
        refute Tiny.Security.allow_guest?()
      end
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    refute result.passed
    assert result.reason == "base_tests_passed"
    assert result.base.exit_code == 0
    assert result.base.test_failures == 0
  end

  test "candidate test failure never runs the base leg", %{tmp_dir: tmp_dir} do
    fixture =
      leased_project(tmp_dir, """
      defmodule Tiny.Security do
        def allow_guest?, do: true
      end
      """)

    test_path = "test/candidate_failure_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.CandidateFailureTest do
      use ExUnit.Case

      test "guest is denied" do
        refute Tiny.Security.allow_guest?()
      end
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    refute result.passed
    assert result.reason == "candidate_tests_failed"
    assert result.candidate.test_failures == 1
    assert result.base.status == "not_run"
  end

  test "security regression compile failures are inconclusive", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/compile_failure_test.exs"
    write_candidate_test(fixture, test_path, "defmodule Broken do\n  this is not valid\n")

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    refute result.passed
    assert result.reason == "candidate_suite_incomplete"
    assert result.candidate.executed == 0
    assert result.base.status == "not_run"
  end

  test "security regression setup failures at base are not real test failures", %{
    tmp_dir: tmp_dir
  } do
    fixture =
      leased_project(tmp_dir, """
      defmodule Tiny.Security do
        def phase, do: :base
      end
      """)

    write_candidate_module(fixture, """
    defmodule Tiny.Security do
      def phase, do: :candidate
    end
    """)

    test_path = "test/setup_failure_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.SetupFailureTest do
      use ExUnit.Case

      setup_all do
        if Tiny.Security.phase() == :base, do: raise("base setup failed")
        :ok
      end

      test "candidate reaches the test body" do
        assert Tiny.Security.phase() == :candidate
      end
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    refute result.passed
    assert result.reason == "base_setup_failed"
    assert result.base.setup_failures > 0
    assert result.base.test_failures == 0
  end

  test "zero executed tests fail closed", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())
    test_path = "test/zero_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.ZeroTest do
      use ExUnit.Case
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    refute result.passed
    assert result.reason == "candidate_zero_tests"
    assert result.candidate.executed == 0
  end

  test "rejects traversal and symlink test sources", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:error, :invalid_test_paths} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 test_paths: ["../escape_test.exs"]
               },
               fixture.context
             )

    target_path = "test/real_source.exs"
    write_candidate_test(fixture, target_path, "defmodule RealSource do\nend\n")
    link_path = Path.join(fixture.lease.worktree_path, "test/symlink_test.exs")
    File.ln_s!("real_source.exs", link_path)

    assert {:error, :test_path_symlink} =
             Validate.run(
               %{
                 workspace_id: fixture.lease.workspace_id,
                 test_paths: ["test/symlink_test.exs"]
               },
               fixture.context
             )
  end

  test "security regression base cannot pass from stale candidate BEAMs", %{tmp_dir: tmp_dir} do
    fixture = leased_project(tmp_dir, valid_module())

    candidate_only = Path.join(fixture.lease.worktree_path, "lib/candidate_only.ex")

    File.write!(candidate_only, """
    defmodule Tiny.CandidateOnly do
      def fixed?, do: true
    end
    """)

    test_path = "test/isolated_beam_test.exs"

    write_candidate_test(fixture, test_path, """
    defmodule Tiny.IsolatedBeamTest do
      use ExUnit.Case

      test "candidate-only fix exists" do
        assert Tiny.CandidateOnly.fixed?()
      end
    end
    """)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, test_paths: [test_path]},
               fixture.context
             )

    assert result.passed
    assert result.reason == "security_regression_validated"
    assert result.candidate.test_failures == 0
    assert result.base.test_failures == 1
  end

  test "normal validation-resource release removes detached worktree and build roots", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_project(tmp_dir, valid_module())

    assert {:ok, resource} =
             WorkspaceLeaseRegistry.acquire_validation_resource(
               fixture.lease.workspace_id,
               fixture.context
             )

    File.mkdir_p!(resource.candidate_build_path)
    File.write!(Path.join(resource.candidate_build_path, "beam"), "stale")

    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.create_validation_snapshot(
               resource.resource_id,
               fixture.context
             )

    assert File.dir?(snapshot.root_path)
    assert File.dir?(snapshot.base_worktree_path)

    assert {:ok, %{status: "removed"}} =
             WorkspaceLeaseRegistry.release_validation_resource(
               resource.resource_id,
               fixture.context
             )

    refute File.exists?(snapshot.root_path)
    refute File.exists?(snapshot.base_worktree_path)
  end

  test "lease owner death cleans active detached snapshot and build resources", %{
    tmp_dir: tmp_dir
  } do
    repo = create_base_project(Path.join(tmp_dir, "owner_death_repo"), valid_module())
    repo_root = git!(repo, ["rev-parse", "--show-toplevel"])
    server = :"security_regression_registry_#{System.unique_integer([:positive])}"
    start_supervised!({WorkspaceLeaseRegistry, name: server})
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo_root,
              branch: "test/security-regression-owner-death",
              worktree_base_dir: Path.join(tmp_dir, "owner-worktrees")
            },
            server: server
          )

        {:ok, resource} =
          WorkspaceLeaseRegistry.acquire_validation_resource(
            lease.workspace_id,
            server: server
          )

        File.mkdir_p!(resource.base_build_path)
        File.write!(Path.join(resource.base_build_path, "stale"), "beam")

        {:ok, snapshot} =
          WorkspaceLeaseRegistry.create_validation_snapshot(
            resource.resource_id,
            server: server
          )

        send(parent, {:active_resource, lease, snapshot})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:active_resource, lease, snapshot}, 5_000
    assert File.dir?(lease.worktree_path)
    assert File.dir?(snapshot.base_worktree_path)
    assert File.dir?(snapshot.root_path)

    Process.exit(owner, :kill)

    assert_eventually(fn ->
      not File.exists?(snapshot.root_path) and not File.exists?(snapshot.base_worktree_path) and
        not File.exists?(lease.worktree_path)
    end)
  end

  test "exposes process-spawn action metadata without registry integration" do
    assert Validate.name() == "coding_security_regression_validate"
    assert Validate.category() == "coding"
    assert Validate.effect_class() == :process_spawn
  end

  defp leased_project(tmp_dir, base_module) do
    repo = create_base_project(Path.join(tmp_dir, "repo"), base_module)
    task_id = "task_security_regression_#{System.unique_integer([:positive])}"
    principal_id = "agent_security_regression_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/security-regression-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
          task_id: task_id,
          principal_id: principal_id
        })
    end)

    %{repo: repo, lease: lease, context: context}
  end

  defp create_base_project(path, base_module) do
    create_git_repo(path)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "test"))

    File.write!(Path.join(path, "mix.exs"), """
    defmodule Tiny.MixProject do
      use Mix.Project

      def project do
        [app: :tiny, version: "0.1.0", elixir: "~> 1.14"]
      end
    end
    """)

    File.write!(Path.join(path, "lib/security.ex"), base_module)
    File.write!(Path.join(path, "test/test_helper.exs"), "ExUnit.start()\n")
    git!(path, ["add", "mix.exs", "lib/security.ex", "test/test_helper.exs"])
    git!(path, ["commit", "-m", "base mix project"])
    path
  end

  defp write_candidate_module(fixture, source) do
    File.write!(Path.join(fixture.lease.worktree_path, "lib/security.ex"), source)
  end

  defp write_candidate_test(fixture, relative_path, source) do
    path = Path.join(fixture.lease.worktree_path, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp valid_module do
    """
    defmodule Tiny.Security do
      def valid?, do: true
    end
    """
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
