defmodule Arbor.Commands.CodingBenchmarkAdapterExecutionTest do
  use Arbor.Commands.CodingBenchmarkAdapterCase, async: false

  test "actual production adapters bind principal, timeout, and exact sibling topology" do
    requests = benchmark_requests!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:error, :captured_legacy}
    )

    assert {:error, :captured_legacy, _envelope} = LegacyAdapter.run(requests.legacy)

    assert_receive {:executor_call, :legacy, "agent_benchmark", legacy_task, legacy_context}
    assert_exact_inputs(requests.legacy, legacy_task, legacy_context, requests.pair_root)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_test_reply,
      {:error, :captured_pipeline}
    )

    assert {:error, :captured_pipeline, _envelope} = PipelineAdapter.run(requests.pipeline)

    assert_receive {:executor_call, :pipeline, "agent_benchmark", pipeline_task, pipeline_context}

    assert_exact_inputs(requests.pipeline, pipeline_task, pipeline_context, requests.pair_root)
    refute legacy_context["task_id"] == pipeline_context["task_id"]

    legacy_fields = coding_task_fields(legacy_task)
    pipeline_fields = coding_task_fields(pipeline_task)
    refute legacy_fields["branch_name"] == pipeline_fields["branch_name"]
  end

  test "legacy projects per-validation timeout bounded by harness budget and Shell ceiling" do
    shell_ceiling = Arbor.Shell.spawn_capable_max_timeout_ms()

    # Harness budget above the Shell ceiling → project the reviewed standard ceiling.
    over_ceiling = shell_ceiling + 120_000
    requests_over = benchmark_requests!(over_ceiling)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:error, :captured_legacy}
    )

    assert {:error, :captured_legacy, _envelope} = LegacyAdapter.run(requests_over.legacy)
    assert_receive {:executor_call, :legacy, "agent_benchmark", task_over, context_over}

    assert context_over["timeout"] == over_ceiling
    assert task_over["validation_timeout"] == shell_ceiling
    assert task_over["validation_timeout"] < over_ceiling
    refute Map.has_key?(task_over, "plan")

    # Harness budget below the Shell ceiling → project the full outer budget.
    under_ceiling = max(shell_ceiling - 120_000, 60_000)
    requests_under = benchmark_requests!(under_ceiling)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:error, :captured_legacy}
    )

    assert {:error, :captured_legacy, _envelope} = LegacyAdapter.run(requests_under.legacy)
    assert_receive {:executor_call, :legacy, "agent_benchmark", task_under, context_under}

    assert context_under["timeout"] == under_ceiling
    assert task_under["validation_timeout"] == under_ceiling
    assert task_under["validation_timeout"] <= shell_ceiling
  end

  test "pipeline binds graph wall budget from trusted timeout minus module reserve" do
    outer = min_pipeline_execution_timeout_ms() + 45_000
    requests = benchmark_requests!(outer)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_test_reply,
      {:error, :captured_pipeline}
    )

    assert {:error, :captured_pipeline, _envelope} = PipelineAdapter.run(requests.pipeline)
    assert_receive {:executor_call, :pipeline, "agent_benchmark", task, context}

    reserve = Adapter.pipeline_budget_reserve_ms()
    wall = task["plan"]["budgets"]["wall_clock_ms"]

    assert context["timeout"] == outer
    assert wall == outer - reserve
    assert wall < outer
    assert wall >= Adapter.plan_min_wall_clock_ms()
    assert wall <= 86_400_000
    assert Map.keys(task) |> Enum.sort() == ["kind", "plan"]
  end

  test "pipeline fails closed before executor when trusted timeout cannot cover plan min plus reserve" do
    insufficient = min_pipeline_execution_timeout_ms() - 1
    requests = benchmark_requests!(insufficient)

    assert {:error, {:benchmark_setup_error, :pipeline_budget_timeout_insufficient}} =
             PipelineAdapter.run(requests.pipeline)

    refute_receive {:executor_call, :pipeline, _principal, _task, _context}

    # Legacy still uses the full outer timeout without plan budget derivation.
    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:error, :captured_legacy}
    )

    assert {:error, :captured_legacy, _envelope} = LegacyAdapter.run(requests.legacy)
    assert_receive {:executor_call, :legacy, "agent_benchmark", legacy_task, legacy_context}
    assert legacy_context["timeout"] == insufficient
    assert legacy_task["kind"] == "coding_change"
    refute Map.has_key?(legacy_task, "plan")
  end

  test "security regression: request or worker data cannot select or widen pipeline budgets" do
    outer = min_pipeline_execution_timeout_ms() + 20_000
    requests = benchmark_requests!(outer)

    poisoned =
      Map.merge(requests.pipeline, %{
        "budgets" => %{"wall_clock_ms" => 86_400_000},
        "timeout" => 86_400_000,
        "wall_clock_ms" => 86_400_000
      })

    assert {:error, :invalid_benchmark_request_keys} = PipelineAdapter.run(poisoned)
    refute_receive {:executor_call, :pipeline, _principal, _task, _context}

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_test_reply,
      {:error, :captured_pipeline}
    )

    assert {:error, :captured_pipeline, _envelope} = PipelineAdapter.run(requests.pipeline)
    assert_receive {:executor_call, :pipeline, "agent_benchmark", task, context}

    expected_wall = outer - Adapter.pipeline_budget_reserve_ms()
    assert context["timeout"] == outer
    assert task["plan"]["budgets"]["wall_clock_ms"] == expected_wall
    refute task["plan"]["budgets"]["wall_clock_ms"] == 86_400_000
    refute Map.has_key?(task, "timeout")
    refute Map.has_key?(task["plan"], "timeout")
  end

  test "production preflight returns a typed setup error before executor invocation" do
    requests = benchmark_requests!()
    outside = temp_directory!("coding-benchmark-unadmitted")
    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [outside])

    assert {:error, {:benchmark_setup_error, {:coding_repo_roots, :workspace_not_admitted}}} =
             LegacyAdapter.run(requests.legacy)

    refute_receive {:executor_call, :legacy, _principal, _task, _context}

    workspace = Application.fetch_env!(:arbor_commands, :coding_benchmark_workspace_root)
    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [workspace])
    mismatched_logs = temp_directory!("coding-benchmark-wrong-logs")
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, mismatched_logs)

    assert {:error, {:benchmark_setup_error, :coding_pipeline_logs_root_mismatch}} =
             PipelineAdapter.run(requests.pipeline)

    refute_receive {:executor_call, :pipeline, _principal, _task, _context}
  end

  test "fixture setup has an independent bounded deadline" do
    _requests = benchmark_requests!()

    assert {:ok, runtime} = Runtime.load()
    assert runtime.fixture_setup_timeout_ms == 300_000

    Application.put_env(:arbor_commands, :coding_benchmark_fixture_setup_timeout_ms, 9)

    assert {:error,
            {:benchmark_setup_error, {:coding_benchmark_fixture_setup_timeout_ms, :out_of_bounds}}} =
             Runtime.load()
  end

  test "security regression: concurrent identical task scopes receive exclusive artifact roots" do
    requests = benchmark_requests!()
    assert {:ok, runtime} = Runtime.load()

    results =
      for _ <- 1..2 do
        Task.async(fn -> Adapter.execution_scope(requests.legacy, runtime) end)
      end
      |> Enum.map(&Task.await(&1, 1_000))

    assert Enum.count(results, &match?({:ok, _scope}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, {:benchmark_setup_error, :artifact_task_root_exists}}, &1)
           ) == 1

    assert {:ok, scope} = Enum.find(results, &match?({:ok, _scope}, &1))
    assert File.dir?(scope.artifact_root)
  end

  test "artifact allocation rollback preserves pre-existing roots and removes its control lease" do
    requests = benchmark_requests!()
    assert {:ok, runtime} = Runtime.load()
    assert {:ok, preview} = Adapter.verification_scope(requests.legacy, runtime)
    File.mkdir!(preview.artifact_root)
    sentinel = Path.join(preview.artifact_root, "foreign")
    File.write!(sentinel, "untouched")

    assert {:error, {:benchmark_setup_error, :artifact_task_root_exists}} =
             Adapter.execution_scope(requests.legacy, runtime)

    assert File.read!(sentinel) == "untouched"
    refute File.exists?(Path.join(runtime.artifact_root, ".benchmark-leases"))
  end

  test "security regression: post-allocation control swaps roll back only the owned root" do
    requests = benchmark_requests!()
    assert {:ok, runtime} = Runtime.load()
    assert {:ok, preview} = Adapter.verification_scope(requests.legacy, runtime)
    handler_id = "coding-benchmark-allocation-swap-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :commands, :coding_benchmark, :artifact_root_allocated],
      fn _event, _measurements, %{control_path: control_path}, _config ->
        File.rm!(control_path)
        File.mkdir!(control_path)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error,
            {:benchmark_setup_error,
             {:artifact_allocation_rollback_failed, :artifact_lease_control_rollback_failed}}} =
             Adapter.execution_scope(requests.legacy, runtime)

    refute File.exists?(preview.artifact_root)

    control_path =
      Path.join([
        runtime.artifact_root,
        ".benchmark-leases",
        Path.basename(preview.artifact_root) <> ".json"
      ])

    assert File.dir?(control_path)
  end

  test "security regression: failed non-empty root rollback preserves external ownership evidence" do
    requests = benchmark_requests!()
    assert {:ok, runtime} = Runtime.load()
    assert {:ok, preview} = Adapter.verification_scope(requests.legacy, runtime)
    handler_id = "coding-benchmark-nonempty-rollback-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :commands, :coding_benchmark, :artifact_root_allocated],
      fn _event, _measurements, %{control_path: control_path, root: root}, _config ->
        File.write!(Path.join(root, "allocation-race"), "owned root remains managed\n")
        File.chmod!(control_path, 0o400)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error,
            {:benchmark_setup_error,
             {:artifact_allocation_rollback_failed, :artifact_root_rollback_failed}}} =
             Adapter.execution_scope(requests.legacy, runtime)

    control_path =
      Path.join([
        runtime.artifact_root,
        ".benchmark-leases",
        Path.basename(preview.artifact_root) <> ".json"
      ])

    assert File.dir?(preview.artifact_root)
    assert File.regular?(control_path)

    assert %{"lease" => lease, "state" => "allocating"} =
             control_path |> File.read!() |> Jason.decode!()

    assert is_binary(lease)
  end

  test "request workdirs must have the harness-owned pair topology" do
    requests = benchmark_requests!()
    outside = temp_directory!("coding-benchmark-workdir-escape")
    escaped = Map.put(requests.legacy, "workdir", outside)

    assert {:error, {:benchmark_setup_error, :workdir_outside_workspace}} =
             LegacyAdapter.run(escaped)

    refute_receive {:executor_call, :legacy, _principal, _task, _context}

    nested_artifact_root = Path.join(requests.pair_root, "provenance")
    File.mkdir!(nested_artifact_root)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_artifact_root,
      nested_artifact_root
    )

    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, nested_artifact_root)

    assert {:error, {:benchmark_setup_error, :pair_root_overlaps_artifact_root}} =
             LegacyAdapter.run(requests.legacy)

    refute_receive {:executor_call, :legacy, _principal, _task, _context}
  end

  test "security regression: request data cannot inject authority or executable modules" do
    requests = benchmark_requests!()

    request =
      Map.merge(requests.legacy, %{
        "authorization" => true,
        "capabilities" => ["arbor://**"],
        "engine_opts" => %{"authorization" => false},
        "executor_module" => "Elixir.System",
        "metadata" => %{"principal_id" => "agent_attacker"},
        "principal_id" => "agent_attacker",
        "private_key" => "attacker-key",
        "signer" => "attacker-signer"
      })

    assert {:error, :invalid_benchmark_request_keys} = LegacyAdapter.run(request)
    refute_receive {:executor_call, :legacy, _principal, _task, _context}

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:error, :captured}
    )

    assert {:error, :captured, _envelope} = LegacyAdapter.run(requests.legacy)
    assert_receive {:executor_call, :legacy, "agent_benchmark", task, context}

    forbidden = ~w(
      authorization capabilities engine engine_opts executor_module metadata principal_id
      private_key signer signing_key
    )

    refute Enum.any?(forbidden, &Map.has_key?(task, &1))
    refute Enum.any?(forbidden, &Map.has_key?(context, &1))
  end

  test "pending approval retains its exact semantic divergence in the closed envelope" do
    requests = benchmark_requests!()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:ok, :pending_approval, "approval_123"}
    )

    assert {:error, {:pending_approval, "approval_123"}, envelope} =
             LegacyAdapter.run(requests.legacy)

    assert envelope["observations"]["approval"] == %{
             "count" => 1,
             "requested" => true,
             "required" => true,
             "resumed" => false,
             "status" => "pending"
           }
  end

  test "production adapter cancellation uses pipeline cancel_task and reports legacy unsupported" do
    requests = benchmark_requests!()
    Application.delete_env(:arbor_commands, :coding_benchmark_legacy_executor_module)
    Application.delete_env(:arbor_commands, :coding_benchmark_pipeline_executor_module)

    Application.put_env(
      :arbor_orchestrator,
      :pipeline_status_module,
      CapturingPipelineStatus
    )

    assert {:error, :cancellation_unsupported} = LegacyAdapter.cancel(requests.legacy)
    assert :ok = PipelineAdapter.cancel(requests.pipeline)

    digest = execution_digest(requests.pipeline)
    expected_task_id = "coding-benchmark-pipeline-#{digest}"
    assert_receive {:pipeline_mark_abandoned, ^expected_task_id}
  end

  test "security regression: separate run roots never collide on task/run identity" do
    # Two semantically identical fixture/path/seed/repetition requests that only
    # differ by harness-private execution_namespace (as if two CodingBenchmark.run/2
    # invocations reused a frozen manifest after a BEAM restart).
    base = benchmark_requests!()
    assert {:ok, runtime} = Runtime.load()

    ns_a = String.duplicate("a", 64)
    ns_b = String.duplicate("b", 64)
    refute ns_a == ns_b

    request_a = Map.put(base.pipeline, "execution_namespace", ns_a)
    request_b = Map.put(base.pipeline, "execution_namespace", ns_b)

    # Drop workdir path differences so only the invocation namespace drives identity.
    request_b = Map.put(request_b, "workdir", request_a["workdir"])

    assert request_a["fixture_id"] == request_b["fixture_id"]
    assert request_a["seed"] == request_b["seed"]
    assert request_a["repetition"] == request_b["repetition"]
    assert request_a["normalized_input_hash"] == request_b["normalized_input_hash"]
    assert request_a["base_commit_oid"] == request_b["base_commit_oid"]
    assert request_a["workdir"] == request_b["workdir"]
    refute request_a["execution_namespace"] == request_b["execution_namespace"]

    assert {:ok, scope_a} = Adapter.execution_scope(request_a, runtime)
    assert {:ok, scope_b} = Adapter.execution_scope(request_b, runtime)

    refute scope_a.task_id == scope_b.task_id
    refute scope_a.branch_name == scope_b.branch_name
    refute scope_a.worktree_root == scope_b.worktree_root
    refute scope_a.artifact_root == scope_b.artifact_root
    refute scope_a.artifact_lease == scope_b.artifact_lease

    assert String.starts_with?(scope_a.task_id, "coding-benchmark-pipeline-")
    assert String.starts_with?(scope_b.task_id, "coding-benchmark-pipeline-")

    # Legacy stays distinct from pipeline under the same namespace.
    legacy_a = Map.put(base.legacy, "execution_namespace", ns_a)
    assert {:ok, legacy_scope} = Adapter.execution_scope(legacy_a, runtime)
    refute legacy_scope.task_id == scope_a.task_id
    refute legacy_scope.worktree_root == scope_a.worktree_root
    assert String.starts_with?(legacy_scope.task_id, "coding-benchmark-legacy-")
  end

  test "security regression: verify and cancel derive the same identity as execution" do
    requests = benchmark_requests!()
    assert {:ok, runtime} = Runtime.load()

    # Preview derives identity without exclusive create, so it can be compared
    # with a later single execution of the same request.
    assert {:ok, verify_before} = Adapter.verification_scope(requests.pipeline, runtime)
    assert {:ok, verify_again} = Adapter.verification_scope(requests.pipeline, runtime)
    assert verify_again.task_id == verify_before.task_id
    assert verify_again.branch_name == verify_before.branch_name
    assert verify_again.worktree_root == verify_before.worktree_root
    assert verify_again.artifact_root == verify_before.artifact_root
    assert verify_again.artifact_lease == verify_before.artifact_lease

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_test_reply,
      {:error, :captured_pipeline}
    )

    assert {:error, :captured_pipeline, _envelope} = PipelineAdapter.run(requests.pipeline)
    assert_receive {:executor_call, :pipeline, "agent_benchmark", task, context}

    assert context["task_id"] == verify_before.task_id
    # Raw invocation nonce stays out of the ACP task envelope fields.
    refute Map.has_key?(task, "execution_namespace")
    plan = task["plan"]
    assert is_map(plan)
    refute Map.has_key?(plan, "execution_namespace")
    refute Map.has_key?(plan["workspace_policy"] || %{}, "execution_namespace")
    refute Map.has_key?(plan["worker"] || %{}, "execution_namespace")

    assert {:ok, verify_after} = Adapter.verification_scope(requests.pipeline, runtime)
    assert verify_after.task_id == context["task_id"]
    assert verify_after.branch_name == verify_before.branch_name
    assert verify_after.worktree_root == verify_before.worktree_root
    assert verify_after.artifact_root == verify_before.artifact_root
    assert verify_after.artifact_lease == verify_before.artifact_lease

    Application.delete_env(:arbor_commands, :coding_benchmark_pipeline_executor_module)

    Application.put_env(
      :arbor_orchestrator,
      :pipeline_status_module,
      CapturingPipelineStatus
    )

    assert :ok = PipelineAdapter.cancel(requests.pipeline)
    expected_task_id = context["task_id"]
    assert_receive {:pipeline_mark_abandoned, ^expected_task_id}
  end

  test "security regression: consecutive harness invocations never reuse pipeline lifecycle identity" do
    # Frozen-manifest replay: identical seed/fixture/repetition, two full run/2
    # invocations. The second must not resolve lifecycle state under the first's
    # deterministic task/run id (the r8/r9 production failure class).
    scenario = production_scenario!()
    install_capturing_executors()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_test_reply,
      {:error, :captured_legacy}
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_test_reply,
      {:error, :captured_pipeline}
    )

    assert {:ok, report_1} = run_production_scenario(scenario)
    assert_receive {:executor_call, :pipeline, "agent_benchmark", _task_1, context_1}
    assert_receive {:executor_call, :legacy, "agent_benchmark", _legacy_task_1, legacy_context_1}
    task_id_1 = context_1["task_id"]
    legacy_task_id_1 = legacy_context_1["task_id"]

    assert is_binary(task_id_1) and task_id_1 != ""
    assert String.starts_with?(task_id_1, "coding-benchmark-pipeline-")
    refute task_id_1 == legacy_task_id_1

    # Drain any remaining first-run messages before the second invocation.
    flush_executor_calls()

    assert {:ok, report_2} = run_production_scenario(scenario)
    assert_receive {:executor_call, :pipeline, "agent_benchmark", _task_2, context_2}
    assert_receive {:executor_call, :legacy, "agent_benchmark", _legacy_task_2, legacy_context_2}
    task_id_2 = context_2["task_id"]
    legacy_task_id_2 = legacy_context_2["task_id"]

    refute task_id_1 == task_id_2
    refute legacy_task_id_1 == legacy_task_id_2
    refute task_id_2 == legacy_task_id_2

    # Public report rows must not publish the invocation nonce or answer OIDs.
    for report <- [report_1, report_2], row <- report["rows"] do
      refute Map.has_key?(row, "execution_namespace")
      refute Map.has_key?(row, "task_id")
      refute Map.has_key?(row, "target_tree_oid")
      refute Map.has_key?(row, "target_commit_oid")
    end
  end

  defp flush_executor_calls do
    receive do
      {:executor_call, _path, _principal, _task, _context} -> flush_executor_calls()
    after
      0 -> :ok
    end
  end

  test "production harness observes sibling worktrees and separate provenance roots" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      result = row(report, executor)
      assert result["terminal_status"] == "change_committed"
      assert result["changed_paths"] == ["result.txt"]
      assert result["objective_verifier"] == %{"reason" => nil, "status" => "passed"}
      assert result["artifact_hash_verification"]["status"] == "passed"

      assert_receive {:production_executor_call, ^executor, "agent_benchmark", task, context,
                      returned_worktree, artifact_root}

      fields = coding_task_fields(task)
      pair_root = Path.dirname(fields["repo_path"])

      assert Path.dirname(fields["worktree_base_dir"]) |> Path.dirname() ==
               Path.join(pair_root, "worktrees")

      assert {:ok, expected_worktree} =
               Arbor.Orchestrator.expected_coding_worktree_path(
                 fields["worktree_base_dir"],
                 fields["branch_name"]
               )

      assert returned_worktree == expected_worktree
      refute String.starts_with?(returned_worktree, fields["repo_path"] <> "/")

      if executor == "pipeline" do
        refute String.starts_with?(artifact_root, returned_worktree <> "/")
        assert String.starts_with?(artifact_root, scenario.artifact_root <> "/task-")
        assert Map.keys(task) |> Enum.sort() == ["kind", "plan"]

        wall = task["plan"]["budgets"]["wall_clock_ms"]
        assert wall == context["timeout"] - Adapter.pipeline_budget_reserve_ms()
        assert wall < context["timeout"]
      else
        refute Map.has_key?(task, "plan")
        assert task["kind"] == "coding_change"
      end

      assert context["timeout"] == @successful_fixture_execution_timeout_ms
    end

    assert hd(report["pairs"])["comparison"]["status"] == "equivalent"
  end

  test "security regression: fixtures are reconstructed from the attested tree only" do
    scenario = production_scenario!()
    fixture = Path.join(scenario.root, "fixtures/happy")
    hook = Path.join(fixture, ".git/hooks/post-checkout")
    alternates = Path.join(fixture, ".git/objects/info/alternates")
    alternate_repo = Path.join(scenario.root, "alternate-objects")
    File.mkdir!(alternate_repo)
    git!(alternate_repo, ["init", "--quiet"])

    File.write!(Path.join(fixture, ".git/info/exclude"), "ignored-secret\n")
    File.write!(Path.join(fixture, "ignored-secret"), "must not cross boundary\n")
    File.write!(hook, "#!/bin/sh\nexit 99\n")
    File.chmod!(hook, 0o755)
    File.write!(alternates, Path.join(alternate_repo, ".git/objects") <> "\n")
    git!(fixture, ["config", "benchmark.untrusted", "present"])

    git!(fixture, [
      "-c",
      "user.name=Arbor Benchmark",
      "-c",
      "user.email=benchmark@arbor.local",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "attested descendant"
    ])

    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)
    assert report["summary"]["equivalent_pairs"] == 1

    for executor <- [:legacy, :pipeline] do
      assert_receive {:fixture_repository_observed, ^executor,
                      %{
                        alternates?: false,
                        hook?: false,
                        ignored?: false,
                        shallow?: true,
                        source_config?: false
                      }}
    end
  end

  test "identical benchmark runs reuse released artifact leases" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, first} = run_production_scenario(scenario)
    assert {:ok, second} = run_production_scenario(scenario)
    assert first["summary"]["equivalent_pairs"] == 1
    assert second["summary"]["equivalent_pairs"] == 1
    assert File.ls!(scenario.artifact_root) == []
  end

  test "worker-writable marker tampering cannot alter external lease ownership" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :lease_marker_tamper)

    assert {:ok, first} = run_production_scenario(scenario)
    assert {:ok, second} = run_production_scenario(scenario)
    assert first["summary"]["equivalent_pairs"] == 1
    assert second["summary"]["equivalent_pairs"] == 1
    assert File.ls!(scenario.artifact_root) == []
  end

  test "missing, escaped, and non-deterministic returned worktrees fail closed" do
    scenario = production_scenario!()
    install_leased_executors()

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :missing_worktree)
    assert {:ok, missing_report} = run_production_scenario(scenario)

    for result <- missing_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "missing_returned_worktree"
      assert result["objective_verifier"]["status"] == "failed"
      assert result["artifact_hash_verification"]["status"] == "failed"
    end

    symlink_scenario = production_scenario!()
    install_leased_executors()
    escaped = Path.join(symlink_scenario.root, "fixtures/happy")

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_test_mode,
      {:symlink_worktree, escaped}
    )

    assert {:ok, symlink_report} = run_production_scenario(symlink_scenario)

    for result <- symlink_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "unexpected_returned_worktree"
      assert result["objective_verifier"]["status"] == "failed"
    end

    wrong_path_scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :wrong_worktree)
    assert {:ok, wrong_path_report} = run_production_scenario(wrong_path_scenario)

    for result <- wrong_path_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "unexpected_returned_worktree"
    end

    wrong_branch_scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :wrong_branch)
    assert {:ok, wrong_branch_report} = run_production_scenario(wrong_branch_scenario)

    for result <- wrong_branch_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "unexpected_returned_worktree"
    end
  end
end
