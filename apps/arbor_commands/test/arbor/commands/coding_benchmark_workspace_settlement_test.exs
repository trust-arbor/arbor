defmodule Arbor.Commands.CodingBenchmarkWorkspaceSettlementTest do
  use Arbor.Commands.CodingBenchmarkAdapterCase, async: false

  alias Arbor.Actions
  alias Arbor.Commands.CodingBenchmark.Adapter

  defmodule WorkspaceActions do
    @moduledoc false

    alias Arbor.Actions

    def acquire(principal_id, fields, task_id) do
      Actions.execute_action(
        Arbor.Actions.Coding.Workspace.Acquire,
        %{
          repo_path: fields["repo_path"],
          branch_name: fields["branch_name"],
          worktree_base_dir: fields["worktree_base_dir"]
        },
        %{agent_id: principal_id, task_id: task_id}
      )
    end

    def retain(principal_id, task_id, workspace_id) do
      Actions.execute_action(
        Arbor.Actions.Coding.Workspace.Release,
        %{mode: "retain", workspace_id: workspace_id},
        %{agent_id: principal_id, task_id: task_id}
      )
    end

    def inspect(principal_id, task_id, workspace_id) do
      Actions.execute_action(
        Arbor.Actions.Coding.Workspace.Inspect,
        %{workspace_id: workspace_id},
        %{agent_id: principal_id, task_id: task_id}
      )
    end
  end

  defmodule RetainingWorkspaceExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: Support
    alias Arbor.Commands.CodingBenchmarkWorkspaceSettlementTest.WorkspaceActions

    def run(principal_id, task, context) do
      fields = Support.coding_task_fields(task)
      task_id = context["task_id"]

      {:ok, lease} = WorkspaceActions.acquire(principal_id, fields, task_id)

      # Mirror production coding actions: retain on normal return so the
      # registry still owns the worktree when the benchmark finalizes.
      {:ok, _} = WorkspaceActions.retain(principal_id, task_id, lease.workspace_id)

      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

      send(observer, {
        :workspace_retained,
        task_id,
        lease.workspace_id,
        lease.repo_path,
        lease.worktree_path
      })

      {:ok,
       %{
         "result_type" => "coding_change",
         "status" => "no_changes",
         "workspace_id" => lease.workspace_id,
         "worktree_path" => lease.worktree_path,
         "branch" => fields["branch_name"],
         "metrics" => %{"workspace_release_status" => "retained"}
       }}
    end

    def cancel_task(_principal_id, _context), do: :ok
  end

  defmodule SettlementFailingExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: Support
    alias Arbor.Commands.CodingBenchmarkWorkspaceSettlementTest.WorkspaceActions

    def run(principal_id, task, context) do
      # Retain under the exact benchmark principal, then replace the worktree so
      # identity validation fails closed during settle. Parent roots must be kept.
      fields = Support.coding_task_fields(task)
      task_id = context["task_id"]

      {:ok, lease} = WorkspaceActions.acquire(principal_id, fields, task_id)

      {:ok, _} = WorkspaceActions.retain(principal_id, task_id, lease.workspace_id)

      File.rm_rf!(lease.worktree_path)
      File.mkdir_p!(lease.worktree_path)
      File.write!(Path.join(lease.worktree_path, "forged.txt"), "forged\n")

      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:mismatch_lease_retained, principal_id, task_id, lease.worktree_path})

      {:ok,
       %{
         "result_type" => "coding_change",
         "status" => "no_changes",
         "worktree_path" => lease.worktree_path,
         "branch" => fields["branch_name"]
       }}
    end

    def cancel_task(_principal_id, _context), do: :ok
  end

  defmodule ImmediateErrorExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: Support
    alias Arbor.Commands.CodingBenchmarkWorkspaceSettlementTest.WorkspaceActions

    def run(principal_id, task, context) do
      fields = Support.coding_task_fields(task)
      task_id = context["task_id"]

      {:ok, lease} = WorkspaceActions.acquire(principal_id, fields, task_id)

      {:ok, _} = WorkspaceActions.retain(principal_id, task_id, lease.workspace_id)

      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:error_path_retained, task_id, lease.workspace_id, lease.worktree_path})

      {:error, :deliberate_executor_failure}
    end

    def cancel_task(_principal_id, _context), do: :ok
  end

  defmodule HangingWorkspaceExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterCase, as: Support
    alias Arbor.Commands.CodingBenchmarkWorkspaceSettlementTest.WorkspaceActions

    def run(principal_id, task, context) do
      fields = Support.coding_task_fields(task)
      task_id = context["task_id"]

      {:ok, lease} = WorkspaceActions.acquire(principal_id, fields, task_id)

      # Keep the lease active while hanging so timeout/cancel settlement must
      # reclaim an owned workspace, not only a retained marker.
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

      send(observer, {
        :hanging_workspace_acquired,
        self(),
        principal_id,
        task_id,
        lease.workspace_id,
        lease.worktree_path
      })

      Process.sleep(:infinity)
    end

    def cancel_task(principal_id, %{"task_id" => task_id}) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_workspace_cancel, principal_id, task_id})
      :ok
    end
  end

  test "production benchmark settles task-owned workspaces before pair-root removal" do
    scenario = production_scenario!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      RetainingWorkspaceExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      RetainingWorkspaceExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    retained =
      for _ <- 1..2 do
        assert_receive {:workspace_retained, task_id, workspace_id, repo_path, worktree_path},
                       5_000

        %{
          task_id: task_id,
          workspace_id: workspace_id,
          repo_path: repo_path,
          worktree_path: worktree_path
        }
      end

    for entry <- retained do
      refute File.exists?(entry.worktree_path),
             "settled worktree must be removed: #{entry.worktree_path}"

      # Marker settled: re-settle is empty success.
      assert {:ok, receipt} = Adapter.settle_task_workspaces(entry.task_id)
      assert receipt["settled_count"] == 0
    end

    # Pair/run roots under the owned workspace root must be gone after confirmed
    # settlement — unconditional File.rm_rf is no longer the cleanup path, but
    # owned-tree removal still deletes the confirmed-empty topology.
    refute Enum.any?(
             Path.wildcard(Path.join(scenario.root, "arbor-coding-benchmark-*")),
             &File.dir?/1
           )

    for executor <- ~w(legacy pipeline) do
      result = row(report, executor)
      refute result["terminal_status"] == "workspace_cleanup_failed"

      refute is_binary(result["terminal_reason"]) and
               String.contains?(
                 result["terminal_reason"] || "",
                 "workspace_settlement_unconfirmed"
               )
    end
  end

  test "executor-error path still attempts task/principal-scoped settlement" do
    scenario = production_scenario!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      ImmediateErrorExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      ImmediateErrorExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    for _ <- 1..2 do
      assert_receive {:error_path_retained, task_id, _workspace_id, worktree_path}, 5_000
      refute File.exists?(worktree_path)
      assert {:ok, %{"settled_count" => 0}} = Adapter.settle_task_workspaces(task_id)
    end

    for executor <- ~w(legacy pipeline) do
      result = row(report, executor)
      # Error path is visible; settlement still completed so cleanup is not failed.
      assert result["terminal_status"] in ~w(
               executor_error executor_failed objective_failed worktree_verification_failed
             )
      refute result["terminal_status"] == "workspace_cleanup_failed"
    end
  end

  test "security regression: unconfirmed settlement retains pair root and surfaces cleanup failure" do
    scenario = production_scenario!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      SettlementFailingExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      SettlementFailingExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    mismatches =
      for _ <- 1..2 do
        assert_receive {:mismatch_lease_retained, "agent_benchmark", task_id, worktree_path},
                       5_000

        %{task_id: task_id, worktree_path: worktree_path}
      end

    # Identity-mismatched retained leases cannot be settled; the pair/run root
    # must remain rather than being raw-deleted under unconfirmed settlement.
    assert Enum.any?(mismatches, &File.exists?(&1.worktree_path))

    for executor <- ~w(legacy pipeline) do
      result = row(report, executor)
      assert result["terminal_status"] == "workspace_cleanup_failed"
      assert result["terminal_reason"] =~ "workspace_settlement_unconfirmed"
    end

    # Remove the retained topology, then settle by exact task so the test does
    # not reproduce the benchmark's original stale-marker leak in global state.
    File.rm_rf!(scenario.root)

    for mismatch <- mismatches do
      assert {:ok, %{"settled_count" => 1}} =
               Adapter.settle_task_workspaces(mismatch.task_id)
    end
  end

  test "timeout path settles hanging executor that acquired a coding workspace" do
    outer = min_pipeline_execution_timeout_ms()
    scenario = production_scenario!(outer)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      HangingWorkspaceExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      RetainingWorkspaceExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    assert_receive {
                     :hanging_workspace_acquired,
                     pid,
                     "agent_benchmark",
                     task_id,
                     workspace_id,
                     worktree_path
                   },
                   outer + 5_000

    refute Process.alive?(pid)
    refute File.exists?(worktree_path)

    # Task-scoped settlement already ran; residual settle is empty success.
    assert {:ok, receipt} = Adapter.settle_task_workspaces(task_id)
    assert receipt["settled_count"] == 0

    assert {:error, :not_found} =
             WorkspaceActions.inspect("agent_benchmark", task_id, workspace_id)

    timed_out = row(report, "legacy")
    assert timed_out["terminal_status"] == "executor_timeout"
    refute timed_out["terminal_status"] == "workspace_cleanup_failed"

    refute is_binary(timed_out["terminal_reason"]) and
             String.contains?(
               timed_out["terminal_reason"] || "",
               "workspace_settlement_unconfirmed"
             )

    refute Enum.any?(
             Path.wildcard(Path.join(scenario.root, "arbor-coding-benchmark-*")),
             &File.dir?/1
           )
  end

  test "Adapter.settle_task_workspaces is scoped through the public Actions facade" do
    assert function_exported?(Actions, :settle_coding_workspaces, 3)
    assert function_exported?(Adapter, :settle_task_workspaces, 1)

    assert {:error, :invalid_benchmark_task_id} = Adapter.settle_task_workspaces("")
    assert {:error, :invalid_benchmark_task_id} = Adapter.settle_task_workspaces(nil)

    # Empty settle is success when no matching leases exist.
    assert {:ok, receipt} =
             Adapter.settle_task_workspaces("coding-benchmark-pipeline-missing-task")

    assert receipt["status"] == "settled"
    assert receipt["settled_count"] == 0
  end

  test "security regression: CodingBenchmark module source never unconditional File.rm_rf of pair/run roots" do
    source =
      File.read!(
        Path.expand(
          "../../../lib/arbor/commands/coding_benchmark.ex",
          __DIR__
        )
      )

    # The old bug was unconditional after File.rm_rf(pair_root)/File.rm_rf(run_root).
    refute source =~ ~r/after\s*\n\s*File\.rm_rf\(pair_root\)/
    refute source =~ ~r/after\s*\n\s*File\.rm_rf\(run_root\)/
    refute source =~ "File.rm_rf(pair_root)"
    refute source =~ "File.rm_rf(run_root)"
    assert source =~ "finalize_workspace_settlement"
    assert source =~ "remove_owned_benchmark_root"
  end
end
