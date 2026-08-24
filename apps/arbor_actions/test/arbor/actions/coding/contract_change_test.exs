defmodule Arbor.Actions.Coding.ContractChangeTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions
  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Actions.Coding.ContractChange.Validate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.TestMixShell

  @moduletag :slow
  @contained_mix_timeout 120_000

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    previous_shell = Application.get_env(:arbor_actions, :mix_shell_module)
    Application.put_env(:arbor_actions, :mix_shell_module, Arbor.Actions.TestMixShell)

    on_exit(fn ->
      if is_nil(previous_shell) do
        Application.delete_env(:arbor_actions, :mix_shell_module)
      else
        Application.put_env(:arbor_actions, :mix_shell_module, previous_shell)
      end
    end)

    :ok
  end

  setup do
    parent = self()

    previous_runner = Application.get_env(:arbor_actions, :contract_change_mix_runner)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn path, args, opts ->
      send(parent, {:contract_mix, path, args, Keyword.take(opts, [:env, :resource_profile])})
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    on_exit(fn ->
      if is_nil(previous_runner) do
        Application.delete_env(:arbor_actions, :contract_change_mix_runner)
      else
        Application.put_env(:arbor_actions, :contract_change_mix_runner, previous_runner)
      end

      Application.delete_env(:arbor_actions, :contract_change_after_candidate_freeze)
    end)

    :ok
  end

  test "discovery, name resolution, and canonical URI" do
    assert Validate in Actions.list_actions().coding
    assert Validate.name() == "coding_contract_change_validate"
    assert {:ok, Validate} = Actions.name_to_module("coding_contract_change_validate")
    assert {:ok, Validate} = Actions.name_to_module("coding.contract_change.validate")

    assert Actions.canonical_uri_for(Validate, %{}) ==
             "arbor://action/coding/contract_change/validate"
  end

  test "closed action input rejects extra parameters" do
    assert {:error, :unsupported_parameter} =
             Validate.run(%{workspace_id: "ws", path: "/tmp"}, %{})

    assert {:error, :unsupported_parameter} =
             Validate.run(%{workspace_id: "ws", test_paths: ["apps/foo/test"]}, %{})
  end

  test "valid contract candidate passes with owner-owned Mix argv", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)

    File.write!(
      Path.join(fixture.lease.worktree_path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"),
      """
      defmodule Arbor.Contracts.Foo do
        def value, do: 2
      end
      """
    )

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, timeout: 5_000},
               fixture.context
             )

    assert result.passed == true
    assert result.reason == "contract_change_validated"
    assert is_binary(result.validated_tree_oid)
    assert is_binary(result.validated_head)
    assert "apps/arbor_kernel/lib/arbor/contracts/foo.ex" in result.changed_files
    assert "apps/arbor_kernel/test/arbor/contracts/admission_test.exs" in result.test_paths
    refute Enum.any?(result.test_paths, &String.contains?(&1, "*"))

    assert_receive {:contract_mix, _path, preflight_args, preflight_opts}
    assert preflight_args == Core.preflight_argv()
    assert preflight_opts[:env] == %{"MIX_ENV" => "test"}
    assert preflight_opts[:resource_profile] == :intensive

    assert_receive {:contract_mix, _path, test_args, test_opts}
    assert List.starts_with?(test_args, Core.test_argv_prefix())
    refute Enum.any?(test_args, &String.contains?(&1, "*"))
    refute Enum.any?(test_args, &String.contains?(&1, "apps/arbor_dashboard"))
    assert test_opts[:env] == %{"MIX_ENV" => "test"}
  end

  test "unauthorized callers and extra params fail closed", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    workspace_id = fixture.lease.workspace_id
    parent = self()

    foreign =
      spawn(fn ->
        result = Validate.run(%{workspace_id: workspace_id}, %{})
        send(parent, {:foreign_result, result})
      end)

    ref = Process.monitor(foreign)
    assert_receive {:foreign_result, {:error, reason}}, 5_000

    assert reason in [
             :invalid_task_principal,
             :workspace_unauthorized,
             :unauthorized,
             :not_authorized,
             :workspace_not_found
           ]

    assert_receive {:DOWN, ^ref, :process, ^foreign, _}, 1_000
    refute_received {:contract_mix, _, _, _}
  end

  test "no-contract and false-prefix diffs fail closed without Mix", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)

    File.write!(
      Path.join(fixture.lease.worktree_path, "apps/arbor_dashboard/lib/arbor/dashboard.ex"),
      """
      defmodule Arbor.Dashboard do
        def value, do: :changed
      end
      """
    )

    assert {:ok, result} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    assert result.passed == false
    assert result.reason == "contract_surface_missing"
    assert result.preflight["status"] == "skipped"
    assert result.test["status"] == "skipped"
    refute_received {:contract_mix, _, _, _}
  end

  test "same-process missing or wrong lineage fails closed without Mix", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    workspace_id = fixture.lease.workspace_id

    assert {:error, :invalid_task_principal} = Validate.run(%{workspace_id: workspace_id}, %{})

    assert {:error, :workspace_unauthorized} =
             Validate.run(%{workspace_id: workspace_id}, %{
               task_id: fixture.context.task_id,
               agent_id: "agent_other_#{System.unique_integer([:positive])}"
             })

    assert {:error, :workspace_unauthorized} =
             Validate.run(%{workspace_id: workspace_id}, %{
               task_id: "task_other_#{System.unique_integer([:positive])}",
               agent_id: fixture.context.agent_id
             })

    refute_received {:contract_mix, _, _, _}
  end

  test "nonexistent-app decoy plus consumer file fails closed without Mix", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    change_dashboard!(fixture)

    write_relative!(
      fixture.lease.worktree_path,
      "apps/ghost_app/lib/ghost/contracts/foo.ex",
      "defmodule Ghost.Contracts.Foo do\n  def value, do: :ghost\nend\n"
    )

    assert {:ok, result} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    assert result.passed == false
    assert result.reason == "contract_surface_missing"
    assert result.preflight["status"] == "skipped"
    assert result.test["status"] == "skipped"
    refute_received {:contract_mix, _, _, _}
  end

  test "leading-space decoy fails closed without Mix", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    change_dashboard!(fixture)
    leading = " apps/arbor_kernel/lib/arbor/contracts/new.ex"

    write_relative!(
      fixture.lease.worktree_path,
      leading,
      "defmodule Arbor.Contracts.New do\n  def value, do: :decoy\nend\n"
    )

    assert {:error, {:invalid_repo_path, ^leading}} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    refute_received {:contract_mix, _, _, _}
  end

  test "trailing-space decoy fails closed without Mix", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    change_dashboard!(fixture)
    trailing = "apps/arbor_kernel/lib/arbor/contracts/new.ex "

    write_relative!(
      fixture.lease.worktree_path,
      trailing,
      "defmodule Arbor.Contracts.New do\n  def value, do: :decoy\nend\n"
    )

    assert {:error, {:invalid_repo_path, ^trailing}} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    refute_received {:contract_mix, _, _, _}
  end

  test "post-freeze mutation fails closed", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)

    Application.put_env(:arbor_actions, :contract_change_after_candidate_freeze, fn path,
                                                                                    _freeze ->
      File.write!(Path.join(path, "mutated.txt"), "drift\n")
      :ok
    end)

    File.write!(
      Path.join(fixture.lease.worktree_path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"),
      """
      defmodule Arbor.Contracts.Foo do
        def value, do: 3
      end
      """
    )

    assert {:error, :validation_tree_mutated} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)
  end

  test "missing kernel suite fails closed", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir, suite?: false)

    File.write!(
      Path.join(fixture.lease.worktree_path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"),
      """
      defmodule Arbor.Contracts.Foo do
        def value, do: 4
      end
      """
    )

    assert {:error, :contract_suite_missing} =
             Validate.run(%{workspace_id: fixture.lease.workspace_id}, fixture.context)

    refute_received {:contract_mix, _, _, _}
  end

  test "contained MixAction path passes a valid contract candidate", %{tmp_dir: tmp_dir} do
    Application.delete_env(:arbor_actions, :contract_change_mix_runner)
    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    on_exit(fn ->
      TestMixShell.clear_canned_spawn_result()
      TestMixShell.clear_last_invocation()
    end)

    TestMixShell.set_canned_spawn_results([
      %{exit_code: 0, stdout: "preflight ok", stderr: ""},
      %{exit_code: 0, stdout: "tests ok", stderr: ""}
    ])

    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, timeout: @contained_mix_timeout},
               fixture.context
             )

    assert result.passed == true
    assert result.reason == "contract_change_validated"
    assert is_map(TestMixShell.last_invocation())
    assert List.starts_with?(TestMixShell.last_invocation().args, Core.test_argv_prefix())
  end

  test "contained MixAction path fail-closes a failing preflight", %{tmp_dir: tmp_dir} do
    Application.delete_env(:arbor_actions, :contract_change_mix_runner)
    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    on_exit(fn ->
      TestMixShell.clear_canned_spawn_result()
      TestMixShell.clear_last_invocation()
    end)

    TestMixShell.set_canned_spawn_results([
      %{exit_code: 1, stdout: "compile failed", stderr: "error"}
    ])

    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, timeout: @contained_mix_timeout},
               fixture.context
             )

    assert result.passed == false
    assert result.reason == "preflight_failed"
    assert result.preflight["status"] == "completed"
    assert result.test["status"] == "skipped"
    assert is_map(TestMixShell.last_invocation())
    assert TestMixShell.last_invocation().args == Core.preflight_argv()
  end

  defp leased_contract_repo(tmp_dir, opts \\ []) do
    suite? = Keyword.get(opts, :suite?, true)

    repo =
      create_contract_repo(
        Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"),
        suite?
      )

    task_id = "task_contract_#{System.unique_integer([:positive])}"
    principal_id = "agent_contract_#{System.unique_integer([:positive])}"
    context = %{task_id: task_id, agent_id: principal_id}

    {:ok, lease} =
      Workspace.Acquire.run(
        %{
          repo_path: repo,
          branch_name: "test/contract-#{System.unique_integer([:positive])}",
          worktree_base_dir: Path.join(tmp_dir, "worktrees")
        },
        context
      )

    on_exit(fn -> _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, context) end)
    %{repo: repo, lease: lease, context: context}
  end

  defp create_contract_repo(path, suite?) do
    create_git_repo(path)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule ContractFixture.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0", deps: []]
    end
    """)

    File.mkdir_p!(Path.join(path, "config"))
    File.write!(Path.join(path, "config/config.exs"), "import Config\n")
    File.write!(Path.join(path, "mix.lock"), "%{}\n")

    File.mkdir_p!(Path.join(path, "apps/arbor_kernel/lib/arbor/contracts"))
    File.mkdir_p!(Path.join(path, "apps/arbor_kernel/test/arbor/contracts"))
    File.mkdir_p!(Path.join(path, "apps/arbor_dashboard/lib/arbor"))

    File.write!(Path.join(path, "apps/arbor_kernel/mix.exs"), """
    defmodule Arbor.Kernel.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_kernel, version: "0.1.0", elixir: "~> 1.14", deps: []]
    end
    """)

    File.write!(Path.join(path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"), """
    defmodule Arbor.Contracts.Foo do
      def value, do: 1
    end
    """)

    File.write!(Path.join(path, "apps/arbor_dashboard/lib/arbor/dashboard.ex"), """
    defmodule Arbor.Dashboard do
      def value, do: :ok
    end
    """)

    if suite? do
      File.write!(
        Path.join(path, "apps/arbor_kernel/test/arbor/contracts/admission_test.exs"),
        """
        defmodule Arbor.Contracts.AdmissionTest do
          use ExUnit.Case
          test "admits", do: assert true
        end
        """
      )

      File.write!(
        Path.join(path, "apps/arbor_kernel/test/arbor/contracts/dependency_hierarchy_test.exs"),
        """
        defmodule Arbor.Contracts.DependencyHierarchyTest do
          use ExUnit.Case
          test "hierarchy", do: assert true
        end
        """
      )
    end

    File.mkdir_p!(Path.join(path, "bin"))
    File.write!(Path.join(path, "bin/mix"), "#!/usr/bin/env bash\nexec mix \"$@\"\n")
    File.chmod!(Path.join(path, "bin/mix"), 0o755)

    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "contract base"])
    path
  end

  defp change_kernel_contract!(fixture) do
    File.write!(
      Path.join(fixture.lease.worktree_path, "apps/arbor_kernel/lib/arbor/contracts/foo.ex"),
      """
      defmodule Arbor.Contracts.Foo do
        def value, do: :contained
      end
      """
    )
  end

  defp change_dashboard!(fixture) do
    write_relative!(
      fixture.lease.worktree_path,
      "apps/arbor_dashboard/lib/arbor/dashboard.ex",
      """
      defmodule Arbor.Dashboard do
        def value, do: :changed
      end
      """
    )
  end

  defp write_relative!(worktree, rel, contents)
       when is_binary(worktree) and is_binary(rel) and is_binary(contents) do
    abs = Path.join(worktree, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, contents)
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
