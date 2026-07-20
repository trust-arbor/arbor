defmodule Arbor.Commands.CodingBenchmarkAdapterLifecycleTest do
  use Arbor.Commands.CodingBenchmarkAdapterCase, async: false

  test "final symbolic branch and commit attestation rejects verifier branch swaps" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} =
             run_production_scenario(scenario,
               verifiers: %{"scripted_objective" => FinalBranchSwapVerifier}
             )

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "worktree_verification_failed"
    assert pipeline["terminal_reason"] == "final_branch_or_commit_attestation_failed"
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "final Git attestation rejects dirty worktrees and unrelated commits" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, dirty_report} =
             run_production_scenario(scenario,
               verifiers: %{"scripted_objective" => DirtyWorktreeVerifier}
             )

    assert row(dirty_report, "pipeline")["terminal_reason"] ==
             "final_branch_or_commit_attestation_failed"

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :unrelated_commit)
    assert {:ok, unrelated_report} = run_production_scenario(scenario)

    for executor <- [:legacy, :pipeline] do
      assert_receive {:unrelated_commit_observed, ^executor, commit_line}
      assert [_commit] = String.split(commit_line)
    end

    for executor <- ~w(legacy pipeline) do
      result = row(unrelated_report, executor)
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "final_branch_or_commit_attestation_failed"
    end
  end

  test "security regression: executor config cannot hide untracked files from final attestation" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} =
             run_production_scenario(scenario,
               verifiers: %{"scripted_objective" => HiddenUntrackedVerifier}
             )

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "worktree_verification_failed"
    assert pipeline["terminal_reason"] == "final_branch_or_commit_attestation_failed"
  end

  test "security regression: repository and configured excludes cannot hide untracked paths" do
    for verifier <- [InfoExcludedUntrackedVerifier, CoreExcludedUntrackedVerifier] do
      scenario = production_scenario!()
      install_leased_executors()
      Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

      assert {:ok, report} =
               run_production_scenario(scenario,
                 verifiers: %{"scripted_objective" => verifier}
               )

      pipeline = row(report, "pipeline")

      assert pipeline["terminal_status"] == "worktree_verification_failed",
             "exclude verifier #{inspect(verifier)} was not detected"

      assert pipeline["terminal_reason"] == "final_branch_or_commit_attestation_failed"
      assert pipeline["artifact_hash_verification"]["changed_paths_verified"] == false
    end
  end

  test "security regression: replacement refs cannot forge physical commit ancestry" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :replacement_ancestry)

    assert {:ok, report} = run_production_scenario(scenario)

    for executor <- [:legacy, :pipeline] do
      assert_receive {:replacement_ancestry_observed, ^executor, physical, replacement}
      refute physical == replacement
    end

    for executor <- ~w(legacy pipeline) do
      result = row(report, executor)
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "final_branch_or_commit_attestation_failed"
    end
  end

  test "descendant-spawning Git commands fail closed through the public shell facade" do
    assert {:error, reason} =
             Git.run(File.cwd!(), ["daemon", "--reuseaddr", "--base-path=.", "."], 50)

    assert reason =~ "git_failed:" or reason =~ "git_timeout:50"
  end

  test "hanging executor is killed and cannot block pair-root cleanup" do
    outer = min_pipeline_execution_timeout_ms()
    scenario = production_scenario!(outer)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      HangingExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      LeasedPipelineExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    assert_receive {:hanging_executor_started, pid, "agent_benchmark", task,
                    %{"timeout" => ^outer}}

    refute Process.alive?(pid)
    fields = coding_task_fields(task)
    refute File.exists?(Path.dirname(fields["repo_path"]))

    timed_out = row(report, "legacy")
    assert timed_out["terminal_status"] == "executor_timeout"

    assert timed_out["terminal_reason"] ==
             "execution_timeout:#{outer};artifact_lease_retained:unconfirmed_worker_cleanup"

    assert timed_out["objective_verifier"]["status"] == "failed"

    assert timed_out["cancellation_observations"]["status"] == "unsupported"
    assert timed_out["cancellation_observations"]["cancelled"] == false
    assert timed_out["cancellation_observations"]["cleanup"]["status"] == "unverified"
    assert timed_out["cancellation_observations"]["cleanup"]["resources_cleaned"] == nil
  end

  test "pipeline timeout cancel hook removes external process and filesystem resources" do
    outer = min_pipeline_execution_timeout_ms()
    scenario = production_scenario!(outer)
    resource_root = Path.join(scenario.root, "external-executor-resources")
    File.mkdir!(resource_root)
    {:ok, registry} = Agent.start_link(fn -> %{} end)

    Application.put_env(:arbor_commands, :coding_benchmark_test_resource_registry, registry)
    Application.put_env(:arbor_commands, :coding_benchmark_test_resource_root, resource_root)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      LeasedLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      ResourcePipelineExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    assert_receive {:external_resource_allocated, resource_pid, resource_path, task_id}
    assert_receive {:external_resource_cancelled, ^resource_pid, ^resource_path, ^task_id}
    refute Process.alive?(resource_pid)
    refute File.exists?(resource_path)

    timed_out = row(report, "pipeline")
    assert timed_out["terminal_status"] == "executor_timeout"
    assert timed_out["cancellation_observations"]["status"] == "cancel_confirmed"
    assert timed_out["cancellation_observations"]["cancelled"] == true
    assert timed_out["cancellation_observations"]["cleanup"]["status"] == "released"
    assert timed_out["cancellation_observations"]["cleanup"]["resources_cleaned"] == true
    assert timed_out["cancellation_observations"]["worker_ownership"] == "owned"
  end

  test "hanging pipeline cancel hook is bounded before pair-root cleanup" do
    outer = min_pipeline_execution_timeout_ms()
    scenario = production_scenario!(outer, 50)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      LeasedLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      HangingCancelPipelineExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    assert_receive {:hanging_pipeline_started, run_pid, "agent_benchmark", task,
                    %{"timeout" => ^outer}}

    assert_receive {:hanging_cancel_started, cancel_pid, "agent_benchmark",
                    %{"task_id" => task_id}}

    assert String.starts_with?(task_id, "coding-benchmark-pipeline-")
    refute Process.alive?(run_pid)
    refute Process.alive?(cancel_pid)
    fields = coding_task_fields(task)
    refute File.exists?(Path.dirname(fields["repo_path"]))

    timed_out = row(report, "pipeline")
    assert timed_out["terminal_status"] == "executor_timeout"
    assert timed_out["cancellation_observations"]["status"] == "cancel_hook_timeout"
    assert timed_out["cancellation_observations"]["cancelled"] == false
  end

  test "status-only production cancellation is not reported as worker cancellation" do
    outer = min_pipeline_execution_timeout_ms()
    scenario = production_scenario!(outer, 50)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      LeasedLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      StatusOnlyPipelineExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    Application.put_env(:arbor_orchestrator, :pipeline_status_module, CapturingPipelineStatus)

    assert {:ok, report} = run_production_scenario(scenario)
    assert_receive {:status_only_pipeline_started, run_pid, "agent_benchmark", _task, context}
    assert_receive {:pipeline_mark_abandoned, task_id}, 1_000
    assert task_id == context["task_id"]
    refute Process.alive?(run_pid)

    timed_out = row(report, "pipeline")
    assert timed_out["terminal_status"] == "executor_timeout"
    assert timed_out["cancellation_observations"]["status"] == "cancel_requested"
    assert timed_out["cancellation_observations"]["cancelled"] == false
    assert timed_out["cancellation_observations"]["cleanup"]["status"] == "unverified"
  end

  test "unconfirmed timeout retains artifact lease against late writers while fresh invocations stay isolated" do
    outer = min_pipeline_execution_timeout_ms()
    scenario = production_scenario!(outer, 50)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      LeasedLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      LateWritingPipelineExecutor
    )

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    Application.put_env(:arbor_orchestrator, :pipeline_status_module, CapturingPipelineStatus)

    assert {:ok, first} = run_production_scenario(scenario)
    assert_receive {:late_writer_started, worker, artifact_root, task_id}
    assert_receive {:pipeline_mark_abandoned, ^task_id}, 1_000
    assert_receive {:late_writer_finished, ^worker, late_path}, 2_000
    assert late_path == Path.join(artifact_root, "late-write.txt")
    assert File.read!(late_path) == "late write\n"

    timed_out = row(first, "pipeline")
    assert timed_out["terminal_status"] == "executor_timeout"
    assert timed_out["cancellation_observations"]["cleanup"]["status"] == "unverified"
    assert timed_out["terminal_reason"] =~ "artifact_lease_retained:unconfirmed_worker_cleanup"

    # Fresh run/2 gets its own execution_namespace/task/artifact identity. The
    # first run's retained lease and late-write evidence must remain untouched.
    assert {:ok, second} = run_production_scenario(scenario)
    assert_receive {:late_writer_started, second_worker, second_artifact_root, second_task_id}
    assert_receive {:pipeline_mark_abandoned, ^second_task_id}, 1_000
    assert_receive {:late_writer_finished, ^second_worker, second_late_path}, 2_000

    refute second_worker == worker
    refute second_artifact_root == artifact_root
    refute second_task_id == task_id
    refute second_late_path == late_path
    assert second_late_path == Path.join(second_artifact_root, "late-write.txt")
    assert File.read!(second_late_path) == "late write\n"

    second_pipeline = row(second, "pipeline")
    assert second_pipeline["terminal_status"] == "executor_timeout"
    assert second_pipeline["cancellation_observations"]["cleanup"]["status"] == "unverified"
    assert second_pipeline["terminal_reason"] =~ "artifact_lease_retained:unconfirmed_worker_cleanup"
    refute second_pipeline["terminal_reason"] =~ "artifact_task_root_exists"

    assert File.dir?(artifact_root)
    assert File.read!(late_path) == "late write\n"
  end

  test "security regression: delegated late workers retain leases after adapter raise and exit" do
    for executor <- [LateRaisingPipelineExecutor, LateExitingPipelineExecutor] do
      scenario = production_scenario!()

      Application.put_env(
        :arbor_commands,
        :coding_benchmark_legacy_executor_module,
        LeasedLegacyExecutor
      )

      Application.put_env(:arbor_commands, :coding_benchmark_pipeline_executor_module, executor)
      Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

      assert {:ok, first} = run_production_scenario(scenario)
      assert_receive {:late_failing_writer_started, worker, artifact_root, task_id, failure}
      assert_receive {:late_failing_writer_finished, ^worker, late_path}, 2_000
      assert late_path == Path.join(artifact_root, "late-write.txt")
      assert File.read!(late_path) == "late write after #{failure}\n"

      failed = row(first, "pipeline")
      assert failed["terminal_status"] in ["executor_raised", "executor_threw"]
      assert failed["terminal_reason"] =~ "artifact_lease_retained:unconfirmed_worker_cleanup"

      # Second invocation must not reuse the first task/artifact namespace. It
      # fails independently under its own retained lease while the original
      # late-write evidence stays intact.
      assert {:ok, second} = run_production_scenario(scenario)

      assert_receive {:late_failing_writer_started, second_worker, second_artifact_root,
                      second_task_id, second_failure}

      assert_receive {:late_failing_writer_finished, ^second_worker, second_late_path}, 2_000

      refute second_worker == worker
      refute second_artifact_root == artifact_root
      refute second_task_id == task_id
      assert second_failure == failure
      refute second_late_path == late_path
      assert second_late_path == Path.join(second_artifact_root, "late-write.txt")
      assert File.read!(second_late_path) == "late write after #{failure}\n"

      rerun = row(second, "pipeline")
      assert rerun["terminal_status"] in ["executor_raised", "executor_threw"]
      assert rerun["terminal_reason"] =~ "artifact_lease_retained:unconfirmed_worker_cleanup"
      refute rerun["terminal_reason"] =~ "artifact_task_root_exists"

      assert File.dir?(artifact_root)
      assert File.read!(late_path) == "late write after #{failure}\n"
    end
  end

  test "invalid measurement retains leases while fresh invocations stay isolated" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    invalid_measure = fn fun ->
      _outcome = fun.()
      :invalid_measurement
    end

    assert {:ok, first} = run_production_scenario(scenario, measure: invalid_measure)

    first_evidence =
      for executor <- ~w(legacy pipeline) do
        assert_receive {:production_executor_call, ^executor, _principal, _task, context, worktree,
                        reported_artifact_root}

        task_id = context["task_id"]
        assert is_binary(task_id) and task_id != ""

        artifact_root =
          Path.join(
            scenario.artifact_root,
            "task-" <> (:crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower))
          )

        if is_binary(reported_artifact_root) do
          assert reported_artifact_root == artifact_root
        end

        assert File.dir?(artifact_root)
        assert is_binary(worktree) and worktree != ""

        failed = row(first, executor)
        assert failed["terminal_status"] == "measurement_failed"
        assert failed["terminal_reason"] =~ "artifact_lease_retained:unconfirmed_worker_cleanup"

        %{
          artifact_root: artifact_root,
          task_id: task_id,
          worktree: worktree
        }
      end

    first_task_ids = MapSet.new(Enum.map(first_evidence, & &1.task_id))
    first_artifact_roots = MapSet.new(Enum.map(first_evidence, & &1.artifact_root))
    first_worktrees = MapSet.new(Enum.map(first_evidence, & &1.worktree))
    assert MapSet.size(first_task_ids) == 2
    assert MapSet.size(first_artifact_roots) == 2
    assert MapSet.size(first_worktrees) == 2

    # Fresh run/2 is not blocked by retained first-run identity. It uses a new
    # namespace and must not overwrite or delete the first run's evidence roots.
    assert {:ok, second} = run_production_scenario(scenario)

    second_evidence =
      for executor <- ~w(legacy pipeline) do
        assert_receive {:production_executor_call, ^executor, _principal, _task, context, worktree,
                        reported_artifact_root}

        task_id = context["task_id"]
        assert is_binary(task_id) and task_id != ""

        artifact_root =
          Path.join(
            scenario.artifact_root,
            "task-" <> (:crypto.hash(:sha256, task_id) |> Base.encode16(case: :lower))
          )

        if is_binary(reported_artifact_root) do
          assert reported_artifact_root == artifact_root
        end

        assert is_binary(worktree) and worktree != ""

        rerun = row(second, executor)
        refute rerun["terminal_reason"] =~ "artifact_task_root_exists"
        refute rerun["terminal_reason"] =~ "artifact_lease_retained"
        assert rerun["terminal_status"] == "change_committed"

        %{
          artifact_root: artifact_root,
          task_id: task_id,
          worktree: worktree
        }
      end

    second_task_ids = MapSet.new(Enum.map(second_evidence, & &1.task_id))
    second_artifact_roots = MapSet.new(Enum.map(second_evidence, & &1.artifact_root))
    second_worktrees = MapSet.new(Enum.map(second_evidence, & &1.worktree))

    assert MapSet.disjoint?(first_task_ids, second_task_ids)
    assert MapSet.disjoint?(first_artifact_roots, second_artifact_roots)
    assert MapSet.disjoint?(first_worktrees, second_worktrees)

    for evidence <- first_evidence do
      assert File.dir?(evidence.artifact_root)
    end

    for evidence <- second_evidence do
      refute File.exists?(evidence.artifact_root)
    end
  end

  test "external lease-control tampering is surfaced and retained" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    handler_id = "coding-benchmark-control-tamper-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :commands, :coding_benchmark, :artifact_chunk_read],
      fn _event, _measurements, metadata, _config ->
        if metadata.pass == 1 and metadata.offset == 0 and
             Path.basename(metadata.path) == "coding-pipeline.dot" do
          lease_directory = Path.join(scenario.artifact_root, ".benchmark-leases")
          [control_file] = File.ls!(lease_directory)
          File.write!(Path.join(lease_directory, control_file), "{}")
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert {:ok, report} = run_production_scenario(scenario)
    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "artifact_cleanup_failed"
    assert pipeline["terminal_reason"] =~ "artifact_lease_cleanup_failed:lease_state:corrupt"
    assert File.exists?(scenario.artifact_root)
  end
end
