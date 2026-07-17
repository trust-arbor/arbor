defmodule Arbor.Commands.CodingBenchmarkAdapterTest do
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.{Adapter, Git, LegacyAdapter, PipelineAdapter, Runtime}
  alias Arbor.Commands.CodingBenchmarkScenario, as: Scenario
  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.Plan

  @runtime_env [
    {:arbor_commands, :coding_benchmark_principal_id},
    {:arbor_commands, :coding_benchmark_legacy_executor_module},
    {:arbor_commands, :coding_benchmark_pipeline_executor_module},
    {:arbor_commands, :coding_benchmark_workspace_root},
    {:arbor_commands, :coding_benchmark_artifact_root},
    {:arbor_commands, :coding_benchmark_execution_timeout_ms},
    {:arbor_commands, :coding_benchmark_fixture_setup_timeout_ms},
    {:arbor_commands, :coding_benchmark_cancellation_timeout_ms},
    {:arbor_commands, :coding_benchmark_test_observer},
    {:arbor_commands, :coding_benchmark_test_resource_registry},
    {:arbor_commands, :coding_benchmark_test_resource_root},
    {:arbor_commands, :coding_benchmark_test_mode},
    {:arbor_commands, :coding_benchmark_legacy_test_reply},
    {:arbor_commands, :coding_benchmark_pipeline_test_reply},
    {:arbor_orchestrator, :coding_repo_roots},
    {:arbor_orchestrator, :coding_worktree_roots},
    {:arbor_orchestrator, :coding_pipeline_logs_root},
    {:arbor_orchestrator, :pipeline_status_module}
  ]

  defmodule CapturingLegacyExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.capture(:legacy, principal_id, task, context)
  end

  defmodule CapturingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.capture(:pipeline, principal_id, task, context)
  end

  defmodule LeasedLegacyExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.run_production_executor(:legacy, principal_id, task, context)
  end

  defmodule LeasedPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.run_production_executor(:pipeline, principal_id, task, context)
  end

  defmodule HangingExecutor do
    @moduledoc false

    def run(principal_id, task, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_executor_started, self(), principal_id, task, context})
      Process.sleep(:infinity)
    end
  end

  defmodule HangingVerifier do
    @moduledoc false

    def run(_request) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_verifier_started, self()})
      Process.sleep(:infinity)
    end
  end

  defmodule FinalBranchSwapVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      git!(workdir, ["checkout", "--detach", "--quiet"])
      :ok
    end

    def run(_request), do: :ok

    defp git!(workdir, args) do
      case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> raise "git failed (#{status}): #{output}"
      end
    end
  end

  defmodule DirtyWorktreeVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      File.write!(Path.join(workdir, "verifier-dirt.txt"), "uncommitted\n")
      :ok
    end

    def run(_request), do: :ok
  end

  defmodule HiddenUntrackedVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      git!(workdir, ["config", "--local", "status.showUntrackedFiles", "no"])
      File.write!(Path.join(workdir, "hidden-untracked.txt"), "must be detected\n")
      :ok
    end

    def run(_request), do: :ok

    defp git!(workdir, args) do
      case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> raise "git failed (#{status}): #{output}"
      end
    end
  end

  defmodule InfoExcludedUntrackedVerifier do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}),
      do: TestSupport.write_excluded_untracked(workdir, :info_exclude)

    def run(_request), do: :ok
  end

  defmodule CoreExcludedUntrackedVerifier do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}),
      do: TestSupport.write_excluded_untracked(workdir, :core_excludes_file)

    def run(_request), do: :ok
  end

  defmodule ArtifactSwapVerifier do
    @moduledoc false

    def run(%{"executor_path" => "pipeline", "workdir" => workdir}) do
      root =
        Application.fetch_env!(:arbor_commands, :coding_benchmark_artifact_root)
        |> File.ls!()
        |> Enum.map(
          &Path.join(Application.fetch_env!(:arbor_commands, :coding_benchmark_artifact_root), &1)
        )
        |> Enum.find(&File.exists?(Path.join(&1, "coding-plan.json")))

      plan_path = Path.join(root, "coding-plan.json")
      File.rm!(plan_path)
      File.ln_s!(Path.join(workdir, "README.md"), plan_path)
      :ok
    end

    def run(_request), do: :ok
  end

  defmodule ResourcePipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.allocate_resource_and_hang(principal_id, task, context)

    def cancel_task(principal_id, context),
      do: TestSupport.cancel_allocated_resource(principal_id, context)
  end

  defmodule HangingCancelPipelineExecutor do
    @moduledoc false

    def run(principal_id, task, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_pipeline_started, self(), principal_id, task, context})
      Process.sleep(:infinity)
    end

    def cancel_task(principal_id, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:hanging_cancel_started, self(), principal_id, context})
      Process.sleep(:infinity)
    end
  end

  defmodule StatusOnlyPipelineExecutor do
    @moduledoc false

    def run(principal_id, task, context) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:status_only_pipeline_started, self(), principal_id, task, context})
      Process.sleep(:infinity)
    end

    def cancel_task(principal_id, context),
      do: Arbor.Orchestrator.cancel_coding_task(principal_id, context)
  end

  defmodule LateWritingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context),
      do: TestSupport.allocate_late_writer_and_hang(principal_id, task, context)

    def cancel_task(principal_id, context),
      do: Arbor.Orchestrator.cancel_coding_task(principal_id, context)
  end

  defmodule LateRaisingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(_principal_id, _task, context),
      do: TestSupport.allocate_late_writer_and_fail(context, :raise)
  end

  defmodule LateExitingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(_principal_id, _task, context),
      do: TestSupport.allocate_late_writer_and_fail(context, :exit)
  end

  defmodule CapturingPipelineStatus do
    @moduledoc false

    def mark_abandoned(task_id) do
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
      send(observer, {:pipeline_mark_abandoned, task_id})
      :ok
    end
  end

  setup_all do
    for child <- [
          {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")},
          {Arbor.Shell.ExecutionRegistry, []},
          {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
        ] do
      case Supervisor.start_child(Arbor.Shell.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  setup do
    originals = Map.new(@runtime_env, fn key -> {key, fetch_env(key)} end)

    Application.put_env(:arbor_commands, :coding_benchmark_principal_id, "agent_benchmark")
    Application.put_env(:arbor_commands, :coding_benchmark_test_observer, self())
    install_capturing_executors()

    on_exit(fn ->
      Enum.each(originals, fn {key, value} -> restore_env(key, value) end)
    end)

    :ok
  end

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
    refute legacy_task["branch_name"] == pipeline_task["branch_name"]
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

      pair_root = Path.dirname(task["repo_path"])

      assert Path.dirname(task["worktree_base_dir"]) |> Path.dirname() ==
               Path.join(pair_root, "worktrees")

      assert {:ok, expected_worktree} =
               Arbor.Orchestrator.expected_coding_worktree_path(
                 task["worktree_base_dir"],
                 task["branch_name"]
               )

      assert returned_worktree == expected_worktree
      refute String.starts_with?(returned_worktree, task["repo_path"] <> "/")

      if executor == "pipeline" do
        refute String.starts_with?(artifact_root, returned_worktree <> "/")
        assert String.starts_with?(artifact_root, scenario.artifact_root <> "/task-")
      end

      assert context["timeout"] == 5_000
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

  test "provenance symlinks, malformed manifests, and changed DOT bytes fail verification" do
    scenario = production_scenario!()
    install_leased_executors()

    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :symlink_artifact)
    assert {:ok, symlink_report} = run_production_scenario(scenario)

    symlink_pipeline = row(symlink_report, "pipeline")
    assert symlink_pipeline["terminal_status"] == "change_committed"
    assert symlink_pipeline["objective_verifier"]["status"] == "passed"
    assert symlink_pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert symlink_pipeline["artifact_hash_verification"]["status"] == "failed"

    invalid_scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :invalid_manifest)
    assert {:ok, invalid_report} = run_production_scenario(invalid_scenario)
    assert row(invalid_report, "pipeline")["artifact_hash_verification"]["status"] == "failed"

    tampered_scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :tampered_dot)
    assert {:ok, tampered_report} = run_production_scenario(tampered_scenario)

    tampered = row(tampered_report, "pipeline")["artifact_hash_verification"]
    assert tampered["graph_hash_verified"] == false
    assert tampered["status"] == "failed"
  end

  test "known optional artifact evidence does not change provenance authority or parity" do
    cases = [
      {"workspace_release",
       fn artifacts, _root ->
         Map.put(artifacts, "workspace_release", %{
           "workspace_release_status" => "retained",
           "workspace_expires_at" => "2026-07-17T12:00:00Z"
         })
       end},
      {"workspace_release and acp_transcript",
       fn artifacts, root ->
         artifacts
         |> Map.put("workspace_release", %{"workspace_release_status" => "removed"})
         |> Map.put("acp_transcript", valid_transcript_descriptor(root))
       end}
    ]

    for {label, transform} <- cases do
      report = run_production_artifact_case(transform)
      verification = row(report, "pipeline")["artifact_hash_verification"]

      assert verification["graph_hash_verified"] == true, label
      assert verification["status"] == "passed", label
      assert report["summary"]["equivalent_pairs"] == 1, label
      assert hd(report["pairs"])["comparison"]["status"] == "equivalent", label
    end
  end

  test "security regression: optional artifact evidence remains closed and bounded" do
    transcript_mutation = fn mutation ->
      fn artifacts, root ->
        descriptor = root |> valid_transcript_descriptor() |> mutation.()
        Map.put(artifacts, "acp_transcript", descriptor)
      end
    end

    cases = [
      {"unknown top-level artifact",
       fn artifacts, _root -> Map.put(artifacts, "unexpected_evidence", %{}) end},
      {"workspace_release unknown field",
       fn artifacts, _root ->
         Map.put(artifacts, "workspace_release", %{
           "workspace_release_status" => "retained",
           "workspace_id" => "inline-authority"
         })
       end},
      {"workspace_release oversized scalar",
       fn artifacts, _root ->
         Map.put(artifacts, "workspace_release", %{
           "workspace_release_status" => String.duplicate("x", 257)
         })
       end},
      {"workspace_release unknown status",
       fn artifacts, _root ->
         Map.put(artifacts, "workspace_release", %{
           "workspace_release_status" => "pending"
         })
       end},
      {"workspace_release non-ISO workspace_expires_at",
       fn artifacts, _root ->
         Map.put(artifacts, "workspace_release", %{
           "workspace_release_status" => "retained",
           "workspace_expires_at" => "not-a-timestamp"
         })
       end},
      {"inline transcript turns",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "turns", []) end)},
      {"inline transcript stream",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "stream", %{}) end)},
      {"non-canonical transcript path",
       transcript_mutation.(fn descriptor ->
         Map.put(descriptor, "path", Path.join(descriptor["path"], "../transcript.json"))
       end)},
      {"uppercase transcript digest",
       transcript_mutation.(fn descriptor ->
         Map.update!(descriptor, "sha256", &String.upcase/1)
       end)},
      {"oversized transcript",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "byte_size", 512_001) end)},
      {"inconsistent transcript counts",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "turns_seen", 4) end)},
      {"inconsistent transcript truncation",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "turns_truncated", false) end)},
      {"invalid transcript aggregate flag",
       transcript_mutation.(fn descriptor ->
         Map.put(descriptor, "aggregate_truncated", "false")
       end)},
      {"invalid transcript schema",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "schema_version", 2) end)},
      {"blank transcript task id",
       transcript_mutation.(fn descriptor -> Map.put(descriptor, "task_id", " ") end)}
    ]

    for {label, transform} <- cases do
      verification =
        transform
        |> run_production_artifact_case()
        |> row("pipeline")
        |> Map.fetch!("artifact_hash_verification")

      assert verification["graph_hash_verified"] == false, label
      assert verification["status"] == "failed", label
    end
  end

  test "security regression: required provenance cannot be omitted or overridden" do
    cases = [
      {"missing graph hash", fn artifacts, _root -> Map.delete(artifacts, "graph_hash") end},
      {"duplicate graph hash",
       fn artifacts, _root -> Map.put(artifacts, :graph_hash, String.duplicate("0", 64)) end},
      {"mismatched graph hash",
       fn artifacts, _root -> Map.put(artifacts, "graph_hash", String.duplicate("0", 64)) end}
    ]

    for {label, transform} <- cases do
      verification =
        transform
        |> run_production_artifact_case()
        |> row("pipeline")
        |> Map.fetch!("artifact_hash_verification")

      assert verification["graph_hash_verified"] == false, label
      assert verification["status"] == "failed", label
    end
  end

  test "provenance artifact swaps are rejected immediately before reads" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    assert {:ok, report} =
             run_production_scenario(scenario,
               verifiers: %{"scripted_objective" => ArtifactSwapVerifier}
             )

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "change_committed"
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "same-size regular artifact swaps fail descriptor identity verification" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    handler_id = "coding-benchmark-inode-swap-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor, :commands, :coding_benchmark, :artifact_opened],
        fn _event, _measurements, %{path: path}, _config ->
          if Path.basename(path) == "coding-pipeline.dot" do
            backup = path <> ".inode-swap"
            :ok = File.rename(path, backup)
            :ok = File.cp(backup, path)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, report} = run_production_scenario(scenario)

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "change_committed"
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "security regression: same-inode same-size in-place mutation during read is rejected" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)
    handler_id = "coding-benchmark-in-place-mutation-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:arbor, :commands, :coding_benchmark, :artifact_chunk_read],
      fn _event, _measurements, metadata, _config ->
        if metadata.pass == 1 and metadata.offset == 0 and
             Path.basename(metadata.path) == "coding-pipeline.dot" do
          path = metadata.path
          original = File.read!(path)
          replacement = :binary.copy("x", byte_size(original))
          File.write!(path, replacement)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert {:ok, report} = run_production_scenario(scenario)
    pipeline = row(report, "pipeline")
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  test "objective verifier timeout is bounded by the benchmark timeout" do
    scenario = production_scenario!(1_000)

    assert {:ok, report} =
             run_production_scenario(scenario,
               adapters: Scenario.adapters(),
               verifiers: %{"scripted_objective" => HangingVerifier}
             )

    assert_receive {:hanging_verifier_started, verifier_pid}
    refute Process.alive?(verifier_pid)

    for result <- report["rows"] do
      assert result["objective_verifier"] == %{
               "reason" => "verifier_timeout:1000",
               "status" => "failed"
             }
    end
  end

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
    scenario = production_scenario!(1_000)

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
                    %{"timeout" => 1_000}}

    refute Process.alive?(pid)
    refute File.exists?(Path.dirname(task["repo_path"]))

    timed_out = row(report, "legacy")
    assert timed_out["terminal_status"] == "executor_timeout"

    assert timed_out["terminal_reason"] ==
             "execution_timeout:1000;artifact_lease_retained:unconfirmed_worker_cleanup"

    assert timed_out["objective_verifier"]["status"] == "failed"

    assert timed_out["cancellation_observations"]["status"] == "unsupported"
    assert timed_out["cancellation_observations"]["cancelled"] == false
    assert timed_out["cancellation_observations"]["cleanup"]["status"] == "unverified"
    assert timed_out["cancellation_observations"]["cleanup"]["resources_cleaned"] == nil
  end

  test "pipeline timeout cancel hook removes external process and filesystem resources" do
    scenario = production_scenario!(1_000)
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
    scenario = production_scenario!(1_000, 50)

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
                    %{"timeout" => 1_000}}

    assert_receive {:hanging_cancel_started, cancel_pid, "agent_benchmark",
                    %{"task_id" => task_id}}

    assert String.starts_with?(task_id, "coding-benchmark-pipeline-")
    refute Process.alive?(run_pid)
    refute Process.alive?(cancel_pid)
    refute File.exists?(Path.dirname(task["repo_path"]))

    timed_out = row(report, "pipeline")
    assert timed_out["terminal_status"] == "executor_timeout"
    assert timed_out["cancellation_observations"]["status"] == "cancel_hook_timeout"
    assert timed_out["cancellation_observations"]["cancelled"] == false
  end

  test "status-only production cancellation is not reported as worker cancellation" do
    scenario = production_scenario!(1_000, 50)

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

  test "unconfirmed timeout retains artifact lease against late writers and identical reruns" do
    scenario = production_scenario!(250, 50)

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

    assert {:ok, second} = run_production_scenario(scenario)
    refute_receive {:late_writer_started, _worker, ^artifact_root, _task_id}, 100
    second_pipeline = row(second, "pipeline")
    refute second_pipeline["terminal_status"] == "change_committed"
    assert second_pipeline["terminal_reason"] =~ "artifact_task_root_exists"
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

      assert {:ok, second} = run_production_scenario(scenario)

      refute_receive {:late_failing_writer_started, _worker, ^artifact_root, ^task_id, _failure},
                     100

      rerun = row(second, "pipeline")
      assert rerun["terminal_status"] == "executor_failed"
      assert rerun["terminal_reason"] =~ "artifact_task_root_exists"
      assert File.read!(late_path) == "late write after #{failure}\n"
    end
  end

  test "invalid measurement retains leases and blocks identical reruns" do
    scenario = production_scenario!()
    install_leased_executors()
    Application.put_env(:arbor_commands, :coding_benchmark_test_mode, :leased)

    invalid_measure = fn fun ->
      _outcome = fun.()
      :invalid_measurement
    end

    assert {:ok, first} = run_production_scenario(scenario, measure: invalid_measure)

    for executor <- ~w(legacy pipeline) do
      failed = row(first, executor)
      assert failed["terminal_status"] == "measurement_failed"
      assert failed["terminal_reason"] =~ "artifact_lease_retained:unconfirmed_worker_cleanup"
    end

    assert {:ok, second} = run_production_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      rerun = row(second, executor)
      assert rerun["terminal_status"] == "executor_failed"
      assert rerun["terminal_reason"] =~ "artifact_task_root_exists"
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

  @doc false
  def capture(executor, principal_id, task, context) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    send(observer, {:executor_call, executor, principal_id, task, context})
    Application.get_env(:arbor_commands, reply_key(executor), {:error, :missing_test_reply})
  end

  @doc false
  def run_production_executor(executor, principal_id, task, context) do
    mode = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_mode)

    case mode do
      :leased ->
        leased_result(executor, principal_id, task, context, :valid)

      :symlink_artifact ->
        leased_result(executor, principal_id, task, context, :symlink)

      :invalid_manifest ->
        leased_result(executor, principal_id, task, context, :invalid_manifest)

      :tampered_dot ->
        leased_result(executor, principal_id, task, context, :tampered_dot)

      :unrelated_commit ->
        leased_result(executor, principal_id, task, context, :valid, :unrelated)

      :replacement_ancestry ->
        leased_result(executor, principal_id, task, context, :valid, :replacement)

      :lease_marker_tamper ->
        leased_result(executor, principal_id, task, context, :lease_marker_tamper)

      {:artifact_transform, transform} when is_function(transform, 2) ->
        leased_result(executor, principal_id, task, context, {:artifact_transform, transform})

      :missing_worktree ->
        production_result(executor, principal_id, task, context, nil, %{}, nil)

      :wrong_worktree ->
        wrong_worktree_result(executor, principal_id, task, context)

      :wrong_branch ->
        wrong_branch_result(executor, principal_id, task, context)

      {:symlink_worktree, outside} ->
        symlink_worktree_result(executor, principal_id, task, context, outside)
    end
  end

  @doc false
  def allocate_resource_and_hang(principal_id, _task, %{"task_id" => task_id}) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    registry = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_resource_registry)
    resource_root = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_resource_root)
    resource_path = Path.join(resource_root, sha256(task_id))
    File.mkdir!(resource_path)
    File.write!(Path.join(resource_path, "lease"), task_id)
    resource_pid = spawn(fn -> Process.sleep(:infinity) end)

    Agent.update(registry, fn resources ->
      Map.put(resources, task_id, %{
        path: resource_path,
        pid: resource_pid,
        principal_id: principal_id
      })
    end)

    send(observer, {:external_resource_allocated, resource_pid, resource_path, task_id})
    Process.sleep(:infinity)
  end

  @doc false
  def allocate_late_writer_and_hang(_principal_id, _task, %{"task_id" => task_id}) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

    artifact_root =
      Path.join(Arbor.Orchestrator.coding_pipeline_logs_root(), "task-" <> sha256(task_id))

    worker =
      spawn(fn ->
        Process.sleep(500)
        late_path = Path.join(artifact_root, "late-write.txt")
        File.write!(late_path, "late write\n")
        send(observer, {:late_writer_finished, self(), late_path})
      end)

    send(observer, {:late_writer_started, worker, artifact_root, task_id})
    Process.sleep(:infinity)
  end

  @doc false
  def allocate_late_writer_and_fail(%{"task_id" => task_id}, failure) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

    artifact_root =
      Path.join(Arbor.Orchestrator.coding_pipeline_logs_root(), "task-" <> sha256(task_id))

    worker =
      spawn(fn ->
        Process.sleep(100)
        late_path = Path.join(artifact_root, "late-write.txt")
        File.write!(late_path, "late write after #{failure}\n")
        send(observer, {:late_failing_writer_finished, self(), late_path})
      end)

    send(observer, {:late_failing_writer_started, worker, artifact_root, task_id, failure})

    case failure do
      :raise -> raise "adapter failed after delegating worker"
      :exit -> exit(:adapter_failed_after_delegating_worker)
    end
  end

  @doc false
  def write_excluded_untracked(workdir, source) do
    filename = "excluded-untracked-#{source}.txt"
    git_common_dir = workdir |> git!(["rev-parse", "--git-common-dir"]) |> Path.expand(workdir)

    case source do
      :info_exclude ->
        exclude_path = Path.join(git_common_dir, "info/exclude")
        File.mkdir_p!(Path.dirname(exclude_path))
        File.write!(exclude_path, filename <> "\n", [:append])

      :core_excludes_file ->
        exclude_path = Path.join(git_common_dir, "benchmark-excludes")
        File.write!(exclude_path, filename <> "\n")
        git!(workdir, ["config", "--local", "core.excludesFile", exclude_path])
    end

    File.write!(Path.join(workdir, filename), "must remain visible to attestation\n")
    :ok
  end

  @doc false
  def cancel_allocated_resource(principal_id, %{"task_id" => task_id}) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    registry = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_resource_registry)

    resource =
      Agent.get_and_update(registry, fn resources ->
        Map.pop(resources, task_id)
      end)

    case resource do
      %{path: path, pid: pid, principal_id: ^principal_id} ->
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          250 -> raise "external resource process did not terminate"
        end

        File.rm_rf!(path)
        send(observer, {:external_resource_cancelled, pid, path, task_id})

        {:ok,
         %{
           worker_terminated: true,
           worker_ownership: :owned,
           cleanup: %{resources_cleaned: true, workspace_removed: true, workspace_retained: false}
         }}

      nil ->
        {:error, :resource_not_found}

      _resource ->
        {:error, :resource_principal_mismatch}
    end
  end

  defp assert_exact_inputs(request, task, context, pair_root) do
    digest = execution_digest(request)

    assert task == %{
             "acp_agent" => "codex",
             "base_ref" => request["base_commit_oid"],
             "branch_name" =>
               "arbor/coding-benchmark/happy-r1-#{request["executor_path"]}-#{String.slice(digest, 0, 12)}",
             "kind" => "coding_change",
             "open_pr" => false,
             "repo_path" => request["workdir"],
             "submit_review" => true,
             "task" =>
               "Complete the happy benchmark.\n\nAcceptance criteria:\n- Write the deterministic result marker.",
             "worktree_base_dir" =>
               Path.join([pair_root, "worktrees", request["executor_path"], digest])
           }

    assert context == %{
             "task_id" => "coding-benchmark-#{request["executor_path"]}-#{digest}",
             "timeout" => 250
           }
  end

  defp benchmark_requests! do
    workspace = temp_directory!("coding-benchmark-adapter")
    source = Path.join(workspace, "source")
    pair_root = Path.join(workspace, "direct-pair")
    File.mkdir_p!(source)
    File.mkdir_p!(pair_root)
    git!(source, ["init", "--quiet"])
    File.write!(Path.join(source, "README.md"), "benchmark\n")
    git!(source, ["add", "--", "README.md"])
    commit!(source, "base")

    for executor <- ~w(legacy pipeline) do
      git_clone!(source, Path.join(pair_root, executor))
    end

    configure_runtime!(workspace, 250)
    input = benchmark_input()
    base_commit_oid = git!(source, ["rev-parse", "HEAD"])
    base_tree_oid = git!(source, ["rev-parse", "HEAD^{tree}"])
    normalized_input_hash = normalized_input_hash!(input, base_tree_oid)

    request = fn executor ->
      %{
        "acp_agent" => "codex",
        "base_commit_oid" => base_commit_oid,
        "base_tree_oid" => base_tree_oid,
        "executor_path" => executor,
        "fixture_id" => "happy",
        "normalized_input" => input,
        "normalized_input_hash" => normalized_input_hash,
        "repetition" => 1,
        "schema" => "arbor.coding_benchmark.adapter_request.v1",
        "seed" => 7,
        "workdir" => Path.join(pair_root, executor)
      }
    end

    %{legacy: request.("legacy"), pair_root: pair_root, pipeline: request.("pipeline")}
  end

  defp production_scenario!(timeout_ms \\ 5_000, cancellation_timeout_ms \\ 500) do
    root = temp_directory!("coding-benchmark-production")
    scenario = Scenario.create!(root, ["happy"])
    artifact_root = configure_runtime!(root, timeout_ms, cancellation_timeout_ms)
    Map.put(scenario, :artifact_root, artifact_root)
  end

  defp configure_runtime!(root, timeout_ms, cancellation_timeout_ms \\ 500) do
    {:ok, workspace_root} = SafePath.resolve_real(root)
    artifact_root = Path.join(workspace_root, "production-artifacts")
    File.mkdir_p!(artifact_root)
    {:ok, artifact_root} = SafePath.resolve_real(artifact_root)

    Application.put_env(:arbor_commands, :coding_benchmark_workspace_root, workspace_root)
    Application.put_env(:arbor_commands, :coding_benchmark_artifact_root, artifact_root)
    Application.put_env(:arbor_commands, :coding_benchmark_execution_timeout_ms, timeout_ms)

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_cancellation_timeout_ms,
      cancellation_timeout_ms
    )

    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_worktree_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, artifact_root)
    artifact_root
  end

  defp install_capturing_executors do
    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      CapturingLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      CapturingPipelineExecutor
    )
  end

  defp install_leased_executors do
    Application.put_env(
      :arbor_commands,
      :coding_benchmark_legacy_executor_module,
      LeasedLegacyExecutor
    )

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_pipeline_executor_module,
      LeasedPipelineExecutor
    )
  end

  defp run_production_scenario(scenario, opts \\ []) do
    defaults = [
      acp_agent: "codex",
      adapters: %{"legacy" => LegacyAdapter, "pipeline" => PipelineAdapter},
      executor_selector: false,
      fixture_root: scenario.root,
      measure: &Scenario.deterministic_measure/1,
      verifiers: Scenario.verifiers(),
      workspace_root: scenario.root
    ]

    CodingBenchmark.run(scenario.manifest, Keyword.merge(defaults, opts))
  end

  defp leased_result(
         executor,
         principal_id,
         task,
         context,
         artifact_mode,
         commit_mode \\ :descendant
       ) do
    observe_fixture_repository(executor, task["repo_path"])

    {:ok, worktree} =
      Arbor.Orchestrator.expected_coding_worktree_path(
        task["worktree_base_dir"],
        task["branch_name"]
      )

    git!(task["repo_path"], [
      "worktree",
      "add",
      "--quiet",
      "-b",
      task["branch_name"],
      worktree,
      task["base_ref"]
    ])

    File.write!(Path.join(worktree, "result.txt"), "completed:happy\n")
    git!(worktree, ["add", "--", "result.txt"])
    commit!(worktree, "benchmark result")

    if commit_mode in [:unrelated, :replacement] do
      git!(worktree, ["checkout", "--quiet", "--orphan", task["branch_name"] <> "-orphan"])
      git!(worktree, ["rm", "-rf", "--quiet", "."])
      File.write!(Path.join(worktree, "result.txt"), "completed:happy\n")
      git!(worktree, ["add", "--", "result.txt"])
      commit!(worktree, "unrelated benchmark result")
      git!(worktree, ["branch", "-M", task["branch_name"]])
      observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

      if commit_mode == :unrelated do
        commit_line = git!(worktree, ["rev-list", "--parents", "-n", "1", "HEAD"])
        send(observer, {:unrelated_commit_observed, executor, commit_line})
      else
        physical = git!(worktree, ["rev-parse", "HEAD"])

        replacement =
          git!(worktree, [
            "-c",
            "user.name=Arbor Benchmark",
            "-c",
            "user.email=benchmark@arbor.local",
            "commit-tree",
            "#{physical}^{tree}",
            "-p",
            task["base_ref"],
            "-m",
            "forged replacement ancestry"
          ])

        git!(worktree, ["replace", physical, replacement])
        send(observer, {:replacement_ancestry_observed, executor, physical, replacement})
      end
    end

    {artifacts, artifact_root} =
      if executor == :pipeline,
        do: production_artifacts(task, context, artifact_mode),
        else: {%{}, nil}

    if artifact_mode == :lease_marker_tamper and is_binary(artifact_root) do
      File.write!(Path.join(artifact_root, ".benchmark-lease"), "forged worker marker")
    end

    production_result(executor, principal_id, task, context, worktree, artifacts, artifact_root)
  end

  defp observe_fixture_repository(executor, repo_path) do
    config = File.read!(Path.join(repo_path, ".git/config"))

    facts = %{
      alternates?: File.exists?(Path.join(repo_path, ".git/objects/info/alternates")),
      hook?: File.exists?(Path.join(repo_path, ".git/hooks/post-checkout")),
      ignored?: File.exists?(Path.join(repo_path, "ignored-secret")),
      shallow?: File.exists?(Path.join(repo_path, ".git/shallow")),
      source_config?: String.contains?(config, "benchmark")
    }

    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)
    send(observer, {:fixture_repository_observed, executor, facts})
  end

  defp symlink_worktree_result(executor, principal_id, task, context, outside) do
    {:ok, worktree} =
      Arbor.Orchestrator.expected_coding_worktree_path(
        task["worktree_base_dir"],
        task["branch_name"]
      )

    File.ln_s!(outside, worktree)
    production_result(executor, principal_id, task, context, worktree, %{}, nil)
  end

  defp wrong_worktree_result(executor, principal_id, task, context) do
    worktree = Path.join(task["worktree_base_dir"], "unexpected-descendant")

    git!(task["repo_path"], [
      "worktree",
      "add",
      "--quiet",
      "-b",
      task["branch_name"],
      worktree,
      task["base_ref"]
    ])

    production_result(executor, principal_id, task, context, worktree, %{}, nil)
  end

  defp wrong_branch_result(executor, principal_id, task, context) do
    worktree = Path.join(task["worktree_base_dir"], "wrong-branch")

    git!(task["repo_path"], [
      "worktree",
      "add",
      "--quiet",
      "-b",
      "benchmark-wrong-branch",
      worktree,
      task["base_ref"]
    ])

    production_result(executor, principal_id, task, context, worktree, %{}, nil)
  end

  defp production_result(
         executor,
         principal_id,
         task,
         context,
         worktree,
         artifacts,
         artifact_root
       ) do
    observer = Application.fetch_env!(:arbor_commands, :coding_benchmark_test_observer)

    send(
      observer,
      {:production_executor_call, Atom.to_string(executor), principal_id, task, context, worktree,
       artifact_root}
    )

    {:ok, coding_result(executor, task, worktree, artifacts)}
  end

  defp coding_result(executor, task, worktree, artifacts) do
    %{
      "artifacts" => artifacts,
      "branch" => task["branch_name"],
      "commit" => if(worktree, do: git!(worktree, ["rev-parse", "HEAD"]), else: nil),
      "files" => ["result.txt"],
      "metrics" => %{
        "execution_path" => Atom.to_string(executor),
        "total_rework_count" => 0,
        "validation_attempts" => 1
      },
      "repo_path" => task["repo_path"],
      "review" => %{
        "blast_radius" => "low",
        "human_required" => false,
        "recommendation" => "keep",
        "security_veto" => false,
        "tier_decision" => "auto_proceed"
      },
      "status" => "change_committed",
      "validation" => [%{"passed" => true}]
    }
    |> maybe_put_worktree(worktree)
  end

  defp maybe_put_worktree(result, nil), do: result
  defp maybe_put_worktree(result, worktree), do: Map.put(result, "worktree_path", worktree)

  defp production_artifacts(task, context, mode) do
    logs_root = Arbor.Orchestrator.coding_pipeline_logs_root()
    root = Path.join(logs_root, "task-" <> sha256(context["task_id"]))
    File.mkdir_p!(root)

    dot_path = Path.join(root, "coding-pipeline.dot")
    plan_path = Path.join(root, "coding-plan.json")
    manifest_path = Path.join(root, "coding-compile-manifest.json")
    plan = production_plan!(task)
    assert {:ok, compilation} = Arbor.Orchestrator.compile_coding_plan(plan)
    dot = compilation["dot_source"]
    manifest = compilation["manifest"]
    assert manifest["action_names"] != []
    assert manifest["handler_types"] != []
    assert manifest["execution_manifest"]["actions"] != []
    assert manifest["execution_manifest"]["nodes"] != []

    archived_dot = if mode == :tampered_dot, do: dot <> "\n// post-compile tamper\n", else: dot
    File.write!(dot_path, archived_dot)

    case mode do
      :symlink -> File.ln_s!(Path.join(task["repo_path"], "README.md"), plan_path)
      _other -> File.write!(plan_path, Jason.encode!(plan, pretty: true))
    end

    manifest =
      if mode == :invalid_manifest, do: Map.delete(manifest, "plan_version"), else: manifest

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    artifacts = %{
      "coding_pipeline_path" => dot_path,
      "coding_plan_path" => plan_path,
      "compile_manifest_path" => manifest_path,
      "compiler_version" => compilation["compiler_version"],
      "graph_hash" => compilation["graph_hash"]
    }

    artifacts =
      case mode do
        {:artifact_transform, transform} when is_function(transform, 2) ->
          transform.(artifacts, root)

        _other ->
          artifacts
      end

    {artifacts, root}
  end

  defp run_production_artifact_case(transform) do
    scenario = production_scenario!()
    install_leased_executors()

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_test_mode,
      {:artifact_transform, transform}
    )

    assert {:ok, report} = run_production_scenario(scenario)
    report
  end

  defp valid_transcript_descriptor(root) do
    path = Path.join(root, "acp-transcript.json")
    content = Jason.encode!(%{"schema_version" => 1})
    File.write!(path, content)

    %{
      "path" => path,
      "sha256" => sha256(content),
      "byte_size" => byte_size(content),
      "turns_retained" => 2,
      "turns_seen" => 3,
      "turns_omitted" => 1,
      "turns_truncated" => true,
      "aggregate_truncated" => false,
      "schema_version" => 1,
      "task_id" => "coding-benchmark-pipeline-transcript"
    }
  end

  defp production_plan!(task) do
    assert {:ok, plan} =
             Plan.new(%{
               "base_ref" => task["base_ref"],
               "repo_root" => task["repo_path"],
               "task" => task["task"],
               "worker" => %{"provider" => task["acp_agent"]},
               "workspace_policy" => %{
                 "branch_name" => task["branch_name"],
                 "mode" => "isolated",
                 "worktree_base_dir" => task["worktree_base_dir"]
               }
             })

    Plan.to_map(plan)
  end

  defp normalized_input_hash!(input, base_tree_oid) do
    manifest = %{
      "fixtures" => [
        %{
          "base_tree_oid" => base_tree_oid,
          "fixture_id" => "happy",
          "fixture_path" => "fixture",
          "input" => input,
          "verifier_id" => "scripted_objective"
        }
      ],
      "schema" => CodingBenchmark.manifest_schema(),
      "seed" => 7
    }

    assert {:ok, normalized} = CodingBenchmark.validate_manifest(manifest)
    normalized |> Map.fetch!("fixtures") |> hd() |> Map.fetch!("normalized_input_hash")
  end

  defp benchmark_input do
    %{
      "acceptance_criteria" => ["Write the deterministic result marker."],
      "objective" => "Complete the happy benchmark."
    }
  end

  defp row(report, executor) do
    Enum.find(report["rows"], &(&1["executor_path"] == executor))
  end

  defp execution_digest(request) do
    hash_json(%{
      "base_commit_oid" => request["base_commit_oid"],
      "executor_path" => request["executor_path"],
      "fixture_id" => request["fixture_id"],
      "normalized_input_hash" => request["normalized_input_hash"],
      "repetition" => request["repetition"],
      "seed" => request["seed"]
    })
  end

  defp temp_directory!(prefix) do
    path = CodingBenchmarkTempRoot.create!(prefix)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp reply_key(:legacy), do: :coding_benchmark_legacy_test_reply
  defp reply_key(:pipeline), do: :coding_benchmark_pipeline_test_reply

  defp fetch_env({app, key}), do: Application.fetch_env(app, key)

  defp restore_env({app, key}, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env({app, key}, :error), do: Application.delete_env(app, key)

  defp commit!(repo, message) do
    git!(repo, [
      "-c",
      "user.name=Arbor Benchmark",
      "-c",
      "user.email=benchmark@arbor.local",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git_clone!(source, destination) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["clone", "--quiet", "--no-hardlinks", "--", source, destination],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> raise "git clone failed (#{status}): #{output}"
    end
  end

  defp git!(workdir, args) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end

  defp hash_json(value), do: value |> canonical_json() |> IO.iodata_to_binary() |> sha256()

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Jason.encode_to_iodata!(value)

  defp canonical_json(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode_to_iodata!(key), ":", canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end
end
