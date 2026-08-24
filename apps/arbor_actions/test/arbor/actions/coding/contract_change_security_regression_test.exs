defmodule Arbor.Actions.Coding.ContractChangeSecurityRegressionTest do
  @moduledoc """
  Security regression: exit_code 0 plus containment or capacity flags must not
  pass public ContractChange.Validate, and a preflight terminal must not start
  a second Mix child.

  The committed bytes in this file are the proof artifact. On parent
  b6a017a043e59c8dad8f8fbdde2f04072738c4c5, Validate.run/2 fails at the public
  action boundary because Mix.project_shell_validation/1 returned a tuple that
  Core.check_from_projection/4 cannot consume (`is_map(projection)` fails, so
  `{:error, :invalid_shell_projection}` is thrown as
  `{:capacity_handoff_failed, :invalid_shell_projection}`, or an output-shape
  exception is raised). run_validate!/1 therefore never returns a result map.
  That output-shape failure is distinct from ValidationCapacityHandoff
  `label_mismatch`. Passed/reason/handoff-validity/index assertions were not
  reached on that parent; the tuple bug prevented them. Failures are not lease
  setup and not `:operation_deadline_exceeded` (this file uses 120_000 ms).

  On this candidate the same bytes return `{:ok, result}` and the semantic
  assertions pass: containment five-key XOR, capacity schema-v3 two-batch
  indexes 1 then 2, and ordinary nonzero exit staying a domain failure.
  """

  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Actions.Coding.ContractChange.Validate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Actions.TestMixShell
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :slow
  @moduletag :security_regression
  @moduletag timeout: 600_000

  @validate_timeout 120_000
  @capacity_flags [:timed_out, :killed, :output_limit_exceeded, :cancelled]

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
    previous_runner = Application.get_env(:arbor_actions, :contract_change_mix_runner)
    Application.delete_env(:arbor_actions, :contract_change_mix_runner)
    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    on_exit(fn ->
      if is_nil(previous_runner) do
        Application.delete_env(:arbor_actions, :contract_change_mix_runner)
      else
        Application.put_env(:arbor_actions, :contract_change_mix_runner, previous_runner)
      end

      TestMixShell.clear_canned_spawn_result()
      TestMixShell.clear_last_invocation()
    end)

    :ok
  end

  test "security regression: exit_code 0 + containment cannot pass at either stage", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    for stage <- [:preflight, :test] do
      TestMixShell.clear_canned_spawn_result()
      TestMixShell.clear_last_invocation()

      TestMixShell.set_canned_spawn_results(
        canned_results(stage, containment_failure: true, killed: true)
      )

      result = run_validate!(fixture)
      assert result.passed == false, inspect(stage)
      assert result.reason == "validation_containment_failure", inspect(stage)
      refute Map.has_key?(result.preflight, "capacity_handoff"), inspect(stage)
      refute Map.has_key?(result.test, "capacity_handoff"), inspect(stage)
      assert {:ok, _json} = Jason.encode(result)

      case stage do
        :preflight ->
          assert result.preflight["exit_code"] == 0
          assert result.preflight["termination"] == expected_containment_termination()
          assert map_size(result.preflight["termination"]) == 5
          assert result.test["status"] == "skipped"
          assert result.test["reason"] == "validation_containment_failure"
          assert last_mix_args() == Core.preflight_argv()

        :test ->
          assert result.preflight["passed"] == true
          refute Map.has_key?(result.preflight, "termination")
          assert result.test["termination"] == expected_containment_termination()
          assert map_size(result.test["termination"]) == 5
          assert List.starts_with?(last_mix_args(), Core.test_argv_prefix())
      end
    end
  end

  test "security regression: each capacity flag cannot pass at either stage", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    for stage <- [:preflight, :test], flag <- @capacity_flags do
      TestMixShell.clear_canned_spawn_result()
      TestMixShell.clear_last_invocation()
      TestMixShell.set_canned_spawn_results(canned_results(stage, [{flag, true}]))

      result = run_validate!(fixture)
      assert result.passed == false, inspect({stage, flag})
      assert result.reason == "validation_capacity_exceeded", inspect({stage, flag})
      assert {:ok, _json} = Jason.encode(result)

      case stage do
        :preflight ->
          refute Map.has_key?(result.preflight, "termination"), inspect({stage, flag})
          assert_canonical_interrupted(result.preflight["capacity_handoff"], 1, {stage, flag})
          unstarted = result.preflight["capacity_handoff"]["unstarted_batches"]
          assert Enum.map(unstarted, & &1["index"]) == [2]
          assert result.test["status"] == "skipped", inspect({stage, flag})

          assert last_mix_args() == Core.preflight_argv(), inspect({stage, flag})

        :test ->
          assert result.preflight["passed"] == true, inspect({stage, flag})
          refute Map.has_key?(result.preflight, "capacity_handoff"), inspect({stage, flag})
          refute Map.has_key?(result.test, "termination"), inspect({stage, flag})
          assert_canonical_interrupted(result.test["capacity_handoff"], 2, {stage, flag})
          assert result.test["capacity_handoff"]["unstarted_batches"] == []
          assert List.starts_with?(last_mix_args(), Core.test_argv_prefix())
      end
    end
  end

  test "security regression: leading/trailing-space decoy cannot admit a contract surface", %{
    tmp_dir: tmp_dir
  } do
    decoy_source = "defmodule Arbor.Contracts.New do\n  def value, do: :decoy\nend\n"
    leading = " apps/arbor_kernel/lib/arbor/contracts/new.ex"
    trailing = "apps/arbor_kernel/lib/arbor/contracts/new.ex "

    leading_fixture = leased_contract_repo(tmp_dir)
    change_dashboard!(leading_fixture)
    write_relative!(leading_fixture.lease.worktree_path, leading, decoy_source)
    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    assert {:error, {:invalid_repo_path, ^leading}} =
             Validate.run(
               %{workspace_id: leading_fixture.lease.workspace_id, timeout: @validate_timeout},
               leading_fixture.context
             )

    assert is_nil(TestMixShell.last_invocation())

    trailing_fixture = leased_contract_repo(tmp_dir)
    change_dashboard!(trailing_fixture)
    write_relative!(trailing_fixture.lease.worktree_path, trailing, decoy_source)
    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    assert {:error, {:invalid_repo_path, ^trailing}} =
             Validate.run(
               %{workspace_id: trailing_fixture.lease.workspace_id, timeout: @validate_timeout},
               trailing_fixture.context
             )

    assert is_nil(TestMixShell.last_invocation())
  end

  test "security regression: nonexistent-app decoy cannot admit an unrelated diff", %{
    tmp_dir: tmp_dir
  } do
    fixture = leased_contract_repo(tmp_dir)
    change_dashboard!(fixture)

    write_relative!(
      fixture.lease.worktree_path,
      "apps/ghost_app/lib/ghost/contracts/foo.ex",
      "defmodule Ghost.Contracts.Foo do\n  def value, do: :ghost\nend\n"
    )

    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    assert {:ok, result} =
             Validate.run(
               %{workspace_id: fixture.lease.workspace_id, timeout: @validate_timeout},
               fixture.context
             )

    assert result.passed == false
    assert result.reason == "contract_surface_missing"
    assert result.preflight["status"] == "skipped"
    assert result.test["status"] == "skipped"
    assert {:ok, _json} = Jason.encode(result)
    assert is_nil(TestMixShell.last_invocation())
  end

  test "security regression: same-process missing or wrong lineage cannot use owner-PID authority",
       %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)
    workspace_id = fixture.lease.workspace_id

    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    assert {:error, :invalid_task_principal} =
             Validate.run(%{workspace_id: workspace_id, timeout: @validate_timeout}, %{})

    assert is_nil(TestMixShell.last_invocation())

    assert {:error, :workspace_unauthorized} =
             Validate.run(%{workspace_id: workspace_id, timeout: @validate_timeout}, %{
               task_id: fixture.context.task_id,
               agent_id: "agent_other_#{System.unique_integer([:positive])}"
             })

    assert is_nil(TestMixShell.last_invocation())

    assert {:error, :workspace_unauthorized} =
             Validate.run(%{workspace_id: workspace_id, timeout: @validate_timeout}, %{
               task_id: "task_other_#{System.unique_integer([:positive])}",
               agent_id: fixture.context.agent_id
             })

    assert is_nil(TestMixShell.last_invocation())
  end

  # Parent 83a0a1f55cab9ed8f48d41c9a8ad72b4c9bb74ae reports
  # {:ok, %{passed: true}} after A→B→A because Mix recaptures B as its
  # before-binding and the outer freeze/postflight both observe A.
  # Finding af4ee64fa1820d69ff61db6add1586ba3d1c77951c08b1703112747c0e61eff0
  test "security regression: ABA tree-binding bypass cannot validate under the frozen candidate identity",
       %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    rel = "apps/arbor_kernel/lib/arbor/contracts/foo.ex"
    frozen_path = Path.join(fixture.lease.worktree_path, rel)
    frozen_bytes = File.read!(frozen_path)

    alternate = """
    defmodule Arbor.Contracts.Foo do
      def value, do: :aba_alternate
    end
    """

    assert alternate != frozen_bytes

    previous_freeze = Application.get_env(:arbor_actions, :contract_change_after_candidate_freeze)
    previous_runner = Application.get_env(:arbor_actions, :contract_change_mix_runner)

    Application.put_env(:arbor_actions, :contract_change_after_candidate_freeze, fn path,
                                                                                    _freeze ->
      File.write!(Path.join(path, rel), alternate)
      :ok
    end)

    Application.put_env(:arbor_actions, :contract_change_mix_runner, fn path, args, opts ->
      result = MixAction.run_mix(path, args, opts)
      File.write!(frozen_path, frozen_bytes)
      result
    end)

    TestMixShell.clear_canned_spawn_result()
    TestMixShell.clear_last_invocation()

    TestMixShell.set_canned_spawn_results([
      spawn_result(),
      spawn_result()
    ])

    on_exit(fn ->
      restore_env(:contract_change_after_candidate_freeze, previous_freeze)
      restore_env(:contract_change_mix_runner, previous_runner)
      TestMixShell.clear_canned_spawn_result()
      TestMixShell.clear_last_invocation()
    end)

    outcome = run_validate(fixture)

    case outcome do
      {:ok, result} ->
        refute result.passed
        refute result.reason == "contract_change_validated"

        flunk(
          "validator reported success for frozen candidate after ABA swap: #{inspect(result.reason)}"
        )

      {:error, {:preflight_execution_failed, reason}} ->
        refute setup_or_timeout_reason?(reason), inspect(reason)
        assert expected_tree_mismatch_reason?(reason), inspect(reason)

      {:error, reason} ->
        refute setup_or_timeout_reason?(reason), inspect(reason)
        flunk("unexpected fail-closed reason after ABA swap: #{inspect(reason)}")
    end

    assert is_nil(TestMixShell.last_invocation())
  end

  test "ordinary nonzero exit with flags false stays a domain failure", %{tmp_dir: tmp_dir} do
    fixture = leased_contract_repo(tmp_dir)
    change_kernel_contract!(fixture)

    TestMixShell.set_canned_spawn_result(%{
      exit_code: 1,
      stdout: "compile failed",
      stderr: "error",
      timed_out: false,
      killed: false,
      output_limit_exceeded: false,
      cancelled: false
    })

    failed = run_validate!(fixture)

    assert failed.passed == false
    assert failed.reason == "preflight_failed"
    refute Map.has_key?(failed.preflight, "termination")
    refute Map.has_key?(failed.preflight, "capacity_handoff")

    TestMixShell.clear_canned_spawn_result()

    TestMixShell.set_canned_spawn_result(%{
      exit_code: 137,
      stdout: "Killed: out of memory / OOM killer",
      stderr: "error: compile timed out waiting for BEAM",
      timed_out: false,
      killed: false,
      output_limit_exceeded: false,
      cancelled: false
    })

    exit_only = run_validate!(fixture)

    assert exit_only.passed == false
    assert exit_only.reason == "preflight_failed"
    refute Map.has_key?(exit_only.preflight, "capacity_handoff")
    refute Map.has_key?(exit_only.preflight, "termination")
  end

  defp run_validate(fixture) do
    Validate.run(
      %{workspace_id: fixture.lease.workspace_id, timeout: @validate_timeout},
      fixture.context
    )
  end

  defp run_validate!(fixture) do
    case run_validate(fixture) do
      {:ok, result} ->
        result

      other ->
        flunk("ContractChange.Validate failed: #{inspect(other)}")
    end
  end

  defp last_mix_args do
    case TestMixShell.last_invocation() do
      %{args: args} -> args
      other -> flunk("expected mix invocation, got #{inspect(other)}")
    end
  end

  defp canned_results(:preflight, flags) do
    [spawn_result(flags), spawn_result()]
  end

  defp canned_results(:test, flags) do
    [spawn_result(), spawn_result(flags)]
  end

  defp assert_canonical_interrupted(handoff, index, context) do
    assert ValidationCapacityHandoff.valid?(handoff), inspect(context)
    interrupted = handoff["interrupted_batch"]
    assert interrupted["index"] == index, inspect(context)
    assert interrupted["total"] == 2, inspect(context)

    assert interrupted["label"] ==
             "batch-#{index}-of-2-n#{interrupted["count"]}-#{interrupted["inventory_sha256"]}",
           inspect(context)
  end

  defp spawn_result(flags \\ []) do
    %{
      exit_code: 0,
      stdout: "ok",
      stderr: "",
      timed_out: Keyword.get(flags, :timed_out, false),
      killed: Keyword.get(flags, :killed, false),
      output_limit_exceeded: Keyword.get(flags, :output_limit_exceeded, false),
      cancelled: Keyword.get(flags, :cancelled, false),
      containment_failure: Keyword.get(flags, :containment_failure, false)
    }
  end

  defp expected_tree_mismatch_reason?(reason) when is_binary(reason) do
    reason == ":expected_tree_mismatch" or String.contains?(reason, "expected_tree_mismatch")
  end

  defp expected_tree_mismatch_reason?(:expected_tree_mismatch), do: true
  defp expected_tree_mismatch_reason?(_reason), do: false

  defp setup_or_timeout_reason?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&setup_or_timeout_reason?/1)
  end

  defp setup_or_timeout_reason?(reason) when is_binary(reason) do
    reason == ":operation_deadline_exceeded" or
      String.contains?(reason, "operation_deadline_exceeded")
  end

  defp setup_or_timeout_reason?(reason)
       when reason in [
              :operation_deadline_exceeded,
              :workspace_not_found,
              :workspace_unauthorized,
              :invalid_task_principal,
              :worktree_missing,
              :missing_worktree_path
            ],
       do: true

  defp setup_or_timeout_reason?(_reason), do: false

  defp restore_env(key, nil), do: Application.delete_env(:arbor_actions, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_actions, key, value)

  defp expected_containment_termination do
    %{
      "timed_out" => false,
      "killed" => true,
      "output_limit_exceeded" => false,
      "cancelled" => false,
      "containment_failure" => true
    }
  end

  defp leased_contract_repo(tmp_dir) do
    repo =
      create_contract_repo(Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}"))

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

  defp create_contract_repo(path) do
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
