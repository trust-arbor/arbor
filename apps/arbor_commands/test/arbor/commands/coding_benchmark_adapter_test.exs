defmodule Arbor.Commands.CodingBenchmarkAdapterTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.{LegacyAdapter, PipelineAdapter}
  alias Arbor.Commands.CodingBenchmarkScenario, as: Scenario
  alias Arbor.Common.SafePath

  @config_keys [
    :coding_benchmark_principal_id,
    :coding_benchmark_legacy_executor_module,
    :coding_benchmark_pipeline_executor_module
  ]

  defmodule CapturingLegacyExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context) do
      TestSupport.capture(:legacy, principal_id, task, context)
    end
  end

  defmodule CapturingPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context) do
      TestSupport.capture(:pipeline, principal_id, task, context)
    end
  end

  defmodule LeasedLegacyExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context) do
      TestSupport.run_production_executor(
        :legacy,
        principal_id,
        task,
        context
      )
    end
  end

  defmodule LeasedPipelineExecutor do
    @moduledoc false
    alias Arbor.Commands.CodingBenchmarkAdapterTest, as: TestSupport

    def run(principal_id, task, context) do
      TestSupport.run_production_executor(
        :pipeline,
        principal_id,
        task,
        context
      )
    end
  end

  setup do
    originals = Map.new(@config_keys, &{&1, Application.fetch_env(:arbor_commands, &1)})

    Application.put_env(:arbor_commands, :coding_benchmark_principal_id, "agent_benchmark")

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

    clear_process_state()

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_commands, key, value)
        {key, :error} -> Application.delete_env(:arbor_commands, key)
      end)

      clear_process_state()
    end)

    :ok
  end

  test "trusted adapters bind the configured principal and exact deterministic executor inputs" do
    request = benchmark_request!("legacy")
    Process.put({:executor_reply, :legacy}, {:error, :captured_legacy})

    assert {:error, :captured_legacy, envelope} = LegacyAdapter.run(request)
    assert Map.keys(envelope) |> Enum.sort() == ~w(counters observations worker_ownership)

    assert {"agent_benchmark", legacy_task, legacy_context} =
             Process.get({:executor_call, :legacy})

    assert_exact_inputs(request, legacy_task, legacy_context)

    pipeline_request = %{request | "executor_path" => "pipeline"}
    Process.put({:executor_reply, :pipeline}, {:error, :captured_pipeline})

    assert {:error, :captured_pipeline, _envelope} = PipelineAdapter.run(pipeline_request)

    assert {"agent_benchmark", pipeline_task, pipeline_context} =
             Process.get({:executor_call, :pipeline})

    assert_exact_inputs(pipeline_request, pipeline_task, pipeline_context)
    refute legacy_context == pipeline_context
    refute legacy_task["branch_name"] == pipeline_task["branch_name"]
  end

  test "security regression: request data cannot inject authority or executable modules" do
    request =
      benchmark_request!("legacy")
      |> Map.merge(%{
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
    assert Process.get({:executor_call, :legacy}) == nil

    clean_request = benchmark_request!("legacy")
    Process.put({:executor_reply, :legacy}, {:error, :captured})
    assert {:error, :captured, _envelope} = LegacyAdapter.run(clean_request)

    assert {"agent_benchmark", task, context} = Process.get({:executor_call, :legacy})

    forbidden = ~w(
      authorization capabilities engine engine_opts executor_module metadata principal_id
      private_key signer signing_key
    )

    refute Enum.any?(forbidden, &Map.has_key?(task, &1))
    refute Enum.any?(forbidden, &Map.has_key?(context, &1))
  end

  test "pending approval retains its exact semantic divergence in the closed envelope" do
    request = benchmark_request!("legacy")
    Process.put({:executor_reply, :legacy}, {:ok, :pending_approval, "approval_123"})

    assert {:error, {:pending_approval, "approval_123"}, envelope} =
             LegacyAdapter.run(request)

    assert envelope == %{
             "counters" => %{"rework_cycles" => 0, "validation_cycles" => 0},
             "observations" => %{
               "approval" => %{
                 "count" => 1,
                 "requested" => true,
                 "required" => true,
                 "resumed" => false,
                 "status" => "pending"
               }
             },
             "worker_ownership" => "unknown"
           }
  end

  test "production adapters verify and score the returned leased worktree" do
    scenario = production_scenario!()
    install_leased_executors()
    Process.put(:production_executor_mode, :leased)

    assert {:ok, report} = run_production_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      executor_atom = executor_atom(executor)
      row = row(report, executor)
      assert row["terminal_status"] == "change_committed"
      assert row["changed_paths"] == ["result.txt"]
      assert row["objective_verifier"] == %{"reason" => nil, "status" => "passed"}
      assert row["artifact_hash_verification"]["status"] == "passed"

      {"agent_benchmark", task, %{"task_id" => task_id}} =
        Process.get({:production_executor_call, executor_atom})

      assert task["repo_path"] != Process.get({:returned_worktree, executor_atom})
      assert String.starts_with?(task_id, "coding-benchmark-#{executor}-")
    end

    assert hd(report["pairs"])["comparison"]["status"] == "equivalent"
  end

  test "production results fail closed for missing and escaped returned worktrees" do
    scenario = production_scenario!()
    install_leased_executors()

    Process.put(:production_executor_mode, :missing_worktree)
    assert {:ok, missing_report} = run_production_scenario(scenario)

    for result <- missing_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "missing_returned_worktree"

      assert result["objective_verifier"] == %{
               "reason" => "missing_returned_worktree",
               "status" => "failed"
             }

      assert result["artifact_hash_verification"]["status"] == "failed"
      assert result["artifact_hash_verification"]["base_tree_verified"] == false
      assert result["artifact_hash_verification"]["changed_paths_verified"] == false
      assert result["artifact_hash_verification"]["result_tree_verified"] == false
    end

    escaped = Path.join(scenario.root, "fixtures/happy")
    Process.put(:production_executor_mode, {:escaped_worktree, escaped})
    assert {:ok, escaped_report} = run_production_scenario(scenario)

    for result <- escaped_report["rows"] do
      assert result["terminal_status"] == "worktree_verification_failed"
      assert result["terminal_reason"] == "unsafe_or_missing_returned_worktree"
      assert result["objective_verifier"]["status"] == "failed"
      assert result["artifact_hash_verification"]["status"] == "failed"
      assert result["artifact_hash_verification"]["base_tree_verified"] == false
    end
  end

  test "pipeline artifact paths outside the returned worktree fail verification" do
    scenario = production_scenario!()
    install_leased_executors()
    Process.put(:production_executor_mode, :escaped_artifact)

    assert {:ok, report} = run_production_scenario(scenario)

    assert row(report, "legacy")["artifact_hash_verification"]["status"] == "passed"

    pipeline = row(report, "pipeline")
    assert pipeline["terminal_status"] == "change_committed"
    assert pipeline["objective_verifier"]["status"] == "passed"
    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == false
    assert pipeline["artifact_hash_verification"]["status"] == "failed"
  end

  @doc false
  def capture(executor, principal_id, task, context) do
    Process.put({:executor_call, executor}, {principal_id, task, context})
    Process.get({:executor_reply, executor}, {:error, :missing_test_reply})
  end

  @doc false
  def run_production_executor(executor, principal_id, task, context) do
    Process.put({:production_executor_call, executor}, {principal_id, task, context})

    case Process.get(:production_executor_mode) do
      :leased -> leased_result(executor, task, false)
      :escaped_artifact -> leased_result(executor, task, true)
      :missing_worktree -> {:ok, coding_result(executor, task, nil, %{})}
      {:escaped_worktree, path} -> {:ok, coding_result(executor, task, path, %{})}
    end
  end

  defp assert_exact_inputs(request, task, context) do
    digest = execution_digest(request)

    expected_task = %{
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
        Path.join([
          request["workdir"],
          ".arbor-coding-benchmark",
          request["executor_path"],
          digest
        ])
    }

    assert task == expected_task

    assert context == %{
             "task_id" => "coding-benchmark-#{request["executor_path"]}-#{digest}"
           }
  end

  defp benchmark_request!(executor_path) do
    root =
      Path.join(
        System.tmp_dir!(),
        "coding-benchmark-adapter-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    {:ok, root} = SafePath.resolve_real(root)
    git!(root, ["init", "--quiet"])
    File.write!(Path.join(root, "README.md"), "benchmark\n")
    git!(root, ["add", "--", "README.md"])
    commit!(root, "base")
    on_exit(fn -> File.rm_rf(root) end)

    input = %{
      "acceptance_criteria" => ["Write the deterministic result marker."],
      "objective" => "Complete the happy benchmark."
    }

    base_commit_oid = git!(root, ["rev-parse", "HEAD"])
    base_tree_oid = git!(root, ["rev-parse", "HEAD^{tree}"])

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
    normalized_fixture = hd(normalized["fixtures"])

    %{
      "acp_agent" => "codex",
      "base_commit_oid" => base_commit_oid,
      "base_tree_oid" => base_tree_oid,
      "executor_path" => executor_path,
      "fixture_id" => "happy",
      "normalized_input" => input,
      "normalized_input_hash" => normalized_fixture["normalized_input_hash"],
      "repetition" => 1,
      "schema" => "arbor.coding_benchmark.adapter_request.v1",
      "seed" => 7,
      "workdir" => root
    }
  end

  defp production_scenario! do
    root =
      Path.join(
        System.tmp_dir!(),
        "coding-benchmark-production-#{System.unique_integer([:positive, :monotonic])}"
      )

    scenario = Scenario.create!(root, ["happy"])
    on_exit(fn -> File.rm_rf(root) end)
    scenario
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

  defp leased_result(executor, task, escaped_artifact?) do
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
    Process.put({:returned_worktree, executor}, worktree)

    artifacts =
      if executor == :pipeline,
        do: pipeline_artifacts(worktree, task["repo_path"], escaped_artifact?),
        else: %{}

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

  defp pipeline_artifacts(worktree, repo_path, escaped?) do
    root = Path.join(worktree, ".benchmark-artifacts")
    File.mkdir_p!(root)

    dot_path = Path.join(root, "coding-pipeline.dot")
    plan_path = Path.join(root, "coding-plan.json")
    manifest_path = Path.join(root, "compile-manifest.json")
    dot = "digraph benchmark {}\n"

    File.write!(dot_path, dot)
    File.write!(plan_path, "{}\n")
    File.write!(manifest_path, "{}\n")

    exclude = git!(worktree, ["rev-parse", "--git-path", "info/exclude"])
    File.write!(exclude, ".benchmark-artifacts/\n", [:append])

    %{
      "coding_pipeline_path" => dot_path,
      "coding_plan_path" => if(escaped?, do: Path.join(repo_path, "README.md"), else: plan_path),
      "compile_manifest_path" => manifest_path,
      "compiler_version" => "benchmark-test-v1",
      "graph_hash" => sha256(dot)
    }
  end

  defp row(report, executor) do
    Enum.find(report["rows"], &(&1["executor_path"] == executor))
  end

  defp executor_atom("legacy"), do: :legacy
  defp executor_atom("pipeline"), do: :pipeline

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

  defp clear_process_state do
    for key <- [
          {:executor_call, :legacy},
          {:executor_call, :pipeline},
          {:executor_reply, :legacy},
          {:executor_reply, :pipeline},
          {:production_executor_call, :legacy},
          {:production_executor_call, :pipeline},
          {:returned_worktree, :legacy},
          {:returned_worktree, :pipeline},
          :production_executor_mode
        ] do
      Process.delete(key)
    end
  end

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

  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode_to_iodata!(key), ":", canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end
end
