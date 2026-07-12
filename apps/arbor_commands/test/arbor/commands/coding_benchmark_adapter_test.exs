defmodule Arbor.Commands.CodingBenchmarkAdapterTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.{LegacyAdapter, PipelineAdapter}
  alias Arbor.Commands.CodingBenchmarkScenario, as: Scenario
  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Orchestrator.Config, as: OrchestratorConfig

  @runtime_env [
    {:arbor_commands, :coding_benchmark_principal_id},
    {:arbor_commands, :coding_benchmark_legacy_executor_module},
    {:arbor_commands, :coding_benchmark_pipeline_executor_module},
    {:arbor_commands, :coding_benchmark_workspace_root},
    {:arbor_commands, :coding_benchmark_artifact_root},
    {:arbor_commands, :coding_benchmark_execution_timeout_ms},
    {:arbor_commands, :coding_benchmark_test_observer},
    {:arbor_commands, :coding_benchmark_test_mode},
    {:arbor_commands, :coding_benchmark_legacy_test_reply},
    {:arbor_commands, :coding_benchmark_pipeline_test_reply},
    {:arbor_orchestrator, :coding_repo_roots},
    {:arbor_orchestrator, :coding_worktree_roots},
    {:arbor_orchestrator, :coding_pipeline_logs_root}
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

      assert String.starts_with?(returned_worktree, task["worktree_base_dir"] <> "/")
      refute String.starts_with?(returned_worktree, task["repo_path"] <> "/")

      if executor == "pipeline" do
        refute String.starts_with?(artifact_root, returned_worktree <> "/")
        assert String.starts_with?(artifact_root, scenario.artifact_root <> "/task-")
      end

      assert context["timeout"] == 5_000
    end

    assert hd(report["pairs"])["comparison"]["status"] == "equivalent"
  end

  test "missing and symlink-escaped returned worktrees fail closed" do
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

    escaped = Path.join(scenario.root, "fixtures/happy")

    Application.put_env(
      :arbor_commands,
      :coding_benchmark_test_mode,
      {:symlink_worktree, escaped}
    )

    assert {:ok, symlink_report} = run_production_scenario(scenario)

    for result <- symlink_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "unsafe_or_missing_returned_worktree"
      assert result["objective_verifier"]["status"] == "failed"
    end
  end

  test "provenance symlink escapes and malformed manifests fail identity verification" do
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
  end

  test "hanging executor is killed and cannot block pair-root cleanup" do
    scenario = production_scenario!(50)

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

    assert_receive {:hanging_executor_started, pid, "agent_benchmark", task, %{"timeout" => 50}}

    refute Process.alive?(pid)
    refute File.exists?(Path.dirname(task["repo_path"]))

    timed_out = row(report, "legacy")
    assert timed_out["terminal_status"] == "executor_timeout"
    assert timed_out["terminal_reason"] == "execution_timeout:50"
    assert timed_out["objective_verifier"]["status"] == "failed"
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

      :missing_worktree ->
        production_result(executor, principal_id, task, context, nil, %{}, nil)

      {:symlink_worktree, outside} ->
        symlink_worktree_result(executor, principal_id, task, context, outside)
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

  defp production_scenario!(timeout_ms \\ 5_000) do
    root = temp_directory!("coding-benchmark-production")
    scenario = Scenario.create!(root, ["happy"])
    artifact_root = configure_runtime!(root, timeout_ms)
    Map.put(scenario, :artifact_root, artifact_root)
  end

  defp configure_runtime!(root, timeout_ms) do
    {:ok, workspace_root} = SafePath.resolve_real(root)
    artifact_root = Path.join(workspace_root, "production-artifacts")
    File.mkdir_p!(artifact_root)
    {:ok, artifact_root} = SafePath.resolve_real(artifact_root)

    Application.put_env(:arbor_commands, :coding_benchmark_workspace_root, workspace_root)
    Application.put_env(:arbor_commands, :coding_benchmark_artifact_root, artifact_root)
    Application.put_env(:arbor_commands, :coding_benchmark_execution_timeout_ms, timeout_ms)
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

  defp run_production_scenario(scenario) do
    CodingBenchmark.run(scenario.manifest,
      acp_agent: "codex",
      adapters: %{"legacy" => LegacyAdapter, "pipeline" => PipelineAdapter},
      executor_selector: false,
      fixture_root: scenario.root,
      measure: &Scenario.deterministic_measure/1,
      verifiers: Scenario.verifiers(),
      workspace_root: scenario.root
    )
  end

  defp leased_result(executor, principal_id, task, context, artifact_mode) do
    worktree = Path.join(task["worktree_base_dir"], "leased-worktree")

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

    {artifacts, artifact_root} =
      if executor == :pipeline,
        do: production_artifacts(task, context, artifact_mode),
        else: {%{}, nil}

    production_result(executor, principal_id, task, context, worktree, artifacts, artifact_root)
  end

  defp symlink_worktree_result(executor, principal_id, task, context, outside) do
    worktree = Path.join(task["worktree_base_dir"], "leased-worktree")
    File.ln_s!(outside, worktree)
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
    logs_root = OrchestratorConfig.coding_pipeline_logs_root()
    root = Path.join(logs_root, "task-" <> sha256(context["task_id"]))
    File.mkdir_p!(root)

    dot_path = Path.join(root, "coding-pipeline.dot")
    plan_path = Path.join(root, "coding-plan.json")
    manifest_path = Path.join(root, "coding-compile-manifest.json")
    dot = "digraph benchmark {}\n"
    graph_hash = sha256(dot)
    plan = production_plan!(task)
    manifest = production_manifest(plan, graph_hash)

    File.write!(dot_path, dot)

    case mode do
      :symlink -> File.ln_s!(Path.join(task["repo_path"], "README.md"), plan_path)
      _other -> File.write!(plan_path, Jason.encode!(plan, pretty: true))
    end

    manifest =
      if mode == :invalid_manifest, do: Map.delete(manifest, "plan_version"), else: manifest

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    {%{
       "coding_pipeline_path" => dot_path,
       "coding_plan_path" => plan_path,
       "compile_manifest_path" => manifest_path,
       "compiler_version" => "coding-plan-1",
       "graph_hash" => graph_hash
     }, root}
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

  defp production_manifest(plan, graph_hash) do
    execution_manifest = %{
      "actions" => [],
      "capability_uris" => [],
      "compiled_graph_hash" => sha256("compiled:" <> graph_hash),
      "egress" => [],
      "graph_hash" => graph_hash,
      "handlers" => [],
      "nodes" => [],
      "version" => 2
    }

    %{
      "action_catalog_digest" => sha256("action-catalog"),
      "action_names" => [],
      "compiler_version" => "coding-plan-1",
      "execution_manifest" => execution_manifest,
      "execution_manifest_digest" => hash_json(execution_manifest),
      "graph_hash" => graph_hash,
      "handler_types" => [],
      "overlays" => plan["overlays"],
      "plan_fingerprint" => hash_json(plan),
      "plan_version" => plan["version"],
      "review_profile" => plan["review_profile"],
      "task_class" => plan["task_class"],
      "template_version" => "coding-change-v1",
      "validation_profile" => plan["validation_profile"]
    }
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
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    {:ok, path} = SafePath.resolve_real(path)
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
