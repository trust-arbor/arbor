defmodule Arbor.Commands.CodingBenchmarkExactTargetTreeTest do
  use ExUnit.Case, async: false

  @moduletag :slow
  @moduletag :integration

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmark.Catalog
  alias Arbor.Commands.CodingBenchmark.ExactTargetTreeVerifier
  alias Arbor.Commands.CodingBenchmarkTempRoot
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Coding.Benchmark, as: BenchmarkTask

  @runtime_env [
    {:arbor_commands, :coding_benchmark_workspace_root},
    {:arbor_commands, :coding_benchmark_artifact_root},
    {:arbor_commands, :coding_benchmark_execution_timeout_ms},
    {:arbor_commands, :coding_benchmark_fixture_setup_timeout_ms},
    {:arbor_commands, :coding_benchmark_cancellation_timeout_ms},
    {:arbor_commands, :coding_benchmark_verifiers},
    {:arbor_orchestrator, :coding_repo_roots},
    {:arbor_orchestrator, :coding_worktree_roots},
    {:arbor_orchestrator, :coding_pipeline_logs_root}
  ]

  setup do
    originals = Map.new(@runtime_env, fn key -> {key, fetch_env(key)} end)

    on_exit(fn ->
      Enum.each(originals, fn {key, value} -> restore_env(key, value) end)
    end)

    root = CodingBenchmarkTempRoot.create!("coding-benchmark-exact-target")
    on_exit(fn -> File.rm_rf(root) end)
    configure_benchmark_runtime!(root)
    %{root: root}
  end

  test "correct final HEAD tree passes and wrong final tree fails", %{root: root} do
    scenario = exact_target_scenario!(root, mode: :match)

    assert {:ok, report} = run_exact(scenario)
    assert report["summary"]["row_count"] == 2

    for executor <- ~w(legacy pipeline) do
      row = row(report, "sample-task", executor)
      assert row["terminal_status"] == "change_committed"
      assert row["objective_verifier"] == %{"reason" => nil, "status" => "passed"}
      refute_target_oid_leaked(row, scenario.target_tree_oid)
      refute_target_oid_leaked(report, scenario.target_tree_oid)
    end

    wrong = exact_target_scenario!(root, mode: :mismatch, fixture_id: "wrong-task")

    assert {:ok, failed_report} = run_exact(wrong)

    for executor <- ~w(legacy pipeline) do
      row = row(failed_report, "wrong-task", executor)
      assert row["objective_verifier"]["status"] == "failed"
      assert row["objective_verifier"]["reason"] == "target_tree_mismatch"
      refute_target_oid_leaked(row, wrong.target_tree_oid)
      refute_target_oid_leaked(failed_report, wrong.target_tree_oid)
    end
  end

  test "target tree binding is exact to fixture_id and never enters adapter requests", %{
    root: root
  } do
    scenario = exact_target_scenario!(root, mode: :match)
    observed = :ets.new(:exact_target_requests, [:public, :bag])

    adapters = %{
      "legacy" => request_observing_adapter(observed, "legacy", scenario.target_body),
      "pipeline" => request_observing_adapter(observed, "pipeline", scenario.target_body)
    }

    assert {:ok, report} =
             CodingBenchmark.run(scenario.manifest,
               adapters: adapters,
               exact_target_trees: scenario.exact_target_trees,
               fixture_root: scenario.root,
               measure: fn fun -> {11, fun.()} end,
               verifiers: %{},
               workspace_root: scenario.root
             )

    assert report["summary"]["row_count"] == 2

    requests = :ets.tab2list(observed)
    assert length(requests) == 2

    for {_tag, request} <- requests do
      refute Map.has_key?(request, "target_tree_oid")
      refute Map.has_key?(request, "target_commit_oid")
      refute_target_oid_leaked(request, scenario.target_tree_oid)
      assert request["fixture_id"] == "sample-task"
      assert request["schema"] == "arbor.coding_benchmark.adapter_request.v1"
    end

    # Binding for a different fixture_id does not satisfy this fixture.
    assert {:error, %{"field" => "exact_target_trees", "reason" => "fixture_set_mismatch"}} =
             CodingBenchmark.run(scenario.manifest,
               adapters: adapters,
               exact_target_trees: %{"other-task" => scenario.target_tree_oid},
               fixture_root: scenario.root,
               measure: fn fun -> {11, fun.()} end,
               verifiers: %{},
               workspace_root: scenario.root
             )
  end

  test "prepared publication installs built-in and rejects config override", %{root: root} do
    scenario = exact_target_scenario!(root, mode: :match)
    write_prepared_sidecars!(scenario)

    fake_pass = fn _request -> :ok end

    Application.put_env(:arbor_commands, :coding_benchmark_verifiers, %{
      "exact_target_tree" => fake_pass
    })

    assert {:error,
            %{
              "field" => "verifiers.exact_target_tree",
              "reason" => "builtin_selector_reserved"
            }} =
             BenchmarkTask.execute(
               [
                 "--manifest",
                 "manifest.json",
                 "--output",
                 "override-report.json"
               ],
               adapters: scenario.adapters,
               measure: fn fun -> {7, fun.()} end,
               root: scenario.root,
               workspace_root: scenario.root
             )

    Application.delete_env(:arbor_commands, :coding_benchmark_verifiers)

    assert {:error,
            %{
              "field" => "verifiers.exact_target_tree",
              "reason" => "builtin_selector_reserved"
            }} =
             BenchmarkTask.execute(
               [
                 "--manifest",
                 "manifest.json",
                 "--output",
                 "runtime-override-report.json"
               ],
               adapters: scenario.adapters,
               measure: fn fun -> {7, fun.()} end,
               root: scenario.root,
               verifiers: %{"exact_target_tree" => fake_pass},
               workspace_root: scenario.root
             )

    assert {:ok, %{report: passed}} =
             BenchmarkTask.execute(
               [
                 "--manifest",
                 "manifest.json",
                 "--output",
                 "prepared-pass-report.json"
               ],
               adapters: scenario.adapters,
               measure: fn fun -> {7, fun.()} end,
               root: scenario.root,
               workspace_root: scenario.root
             )

    for executor <- ~w(legacy pipeline) do
      row = row(passed, "sample-task", executor)
      assert row["objective_verifier"] == %{"reason" => nil, "status" => "passed"}
      refute_target_oid_leaked(row, scenario.target_tree_oid)
    end

    refute_target_oid_leaked(passed, scenario.target_tree_oid)
  end

  test "missing prepared targets and conflicting ownership fail closed", %{root: root} do
    scenario = exact_target_scenario!(root, mode: :match)

    assert {:error,
            %{
              "field" => "exact_target_trees",
              "reason" => "missing_for_exact_target_tree"
            }} =
             CodingBenchmark.run(scenario.manifest,
               adapters: scenario.adapters,
               fixture_root: scenario.root,
               measure: fn fun -> {5, fun.()} end,
               verifiers: %{},
               workspace_root: scenario.root
             )

    assert {:error,
            %{
              "field" => "verifiers.exact_target_tree",
              "reason" => "builtin_selector_reserved"
            }} =
             CodingBenchmark.run(scenario.manifest,
               adapters: scenario.adapters,
               exact_target_trees: scenario.exact_target_trees,
               fixture_root: scenario.root,
               measure: fn fun -> {5, fun.()} end,
               verifiers: %{"exact_target_tree" => fn _ -> :ok end},
               workspace_root: scenario.root
             )

    assert ExactTargetTreeVerifier.selector() == "exact_target_tree"
  end

  test "legacy incomplete and tampered publications remain closed", %{root: root} do
    scenario = exact_target_scenario!(root, mode: :match)
    sidecars = write_prepared_sidecars!(scenario)
    File.rm!(sidecars.publication_path)

    assert {:error,
            %{
              "field" => "publication",
              "reason" => "incomplete_or_unsafe_publication"
            }} =
             BenchmarkTask.execute(["--manifest", "manifest.json", "--dry-run"],
               root: scenario.root,
               workspace_root: scenario.root
             )

    write_canonical_json!(sidecars.publication_path, sidecars.publication)

    mismatched =
      Map.put(sidecars.publication, "manifest_digest", String.duplicate("0", 64))

    write_canonical_json!(sidecars.publication_path, mismatched)

    assert {:error,
            %{
              "error" => "invalid_coding_benchmark_publication",
              "field" => "publication.manifest_digest",
              "reason" => "digest_or_binding_mismatch"
            }} =
             BenchmarkTask.execute(["--manifest", "manifest.json", "--dry-run"],
               root: scenario.root,
               workspace_root: scenario.root
             )

    write_canonical_json!(sidecars.publication_path, sidecars.publication)

    tampered =
      Map.put(sidecars.target_evidence, "source_repository_label", "tampered-arbor-test")

    write_canonical_json!(sidecars.target_evidence_path, tampered)

    assert {:error,
            %{
              "error" => "invalid_coding_benchmark_publication",
              "field" => "publication.target_evidence_digest",
              "reason" => "digest_or_binding_mismatch"
            }} =
             BenchmarkTask.execute(["--manifest", "manifest.json", "--dry-run"],
               root: scenario.root,
               workspace_root: scenario.root
             )
  end

  defp exact_target_scenario!(root, opts) do
    mode = Keyword.fetch!(opts, :mode)
    fixture_id = Keyword.get(opts, :fixture_id, "sample-task")

    scenario_root =
      Path.join(root, "scenario-#{fixture_id}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(scenario_root)

    fixtures_root = Path.join(scenario_root, "fixtures")
    fixture_path = Path.join(fixtures_root, fixture_id)
    File.mkdir_p!(fixture_path)

    git!(fixture_path, ["init", "--quiet", "--initial-branch=benchmark"])
    File.write!(Path.join(fixture_path, "README.md"), "base\n")
    git!(fixture_path, ["add", "--", "README.md"])

    git!(fixture_path, [
      "-c",
      "user.name=Arbor Benchmark",
      "-c",
      "user.email=benchmark@arbor.local",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    base_tree = git!(fixture_path, ["rev-parse", "HEAD^{tree}"])
    base_commit = git!(fixture_path, ["rev-parse", "HEAD^{commit}"])

    target_body =
      case mode do
        :match -> "target-correct\n"
        :mismatch -> "target-correct\n"
      end

    File.write!(Path.join(fixture_path, "result.txt"), target_body)
    git!(fixture_path, ["add", "--", "result.txt"])

    git!(fixture_path, [
      "-c",
      "user.name=Arbor Benchmark",
      "-c",
      "user.email=benchmark@arbor.local",
      "commit",
      "--quiet",
      "-m",
      "target"
    ])

    target_tree = git!(fixture_path, ["rev-parse", "HEAD^{tree}"])
    target_commit = git!(fixture_path, ["rev-parse", "HEAD^{commit}"])

    # Reset fixture workdir to the base tree for worker clones.
    git!(fixture_path, ["reset", "--hard", base_commit])
    assert git!(fixture_path, ["rev-parse", "HEAD^{tree}"]) == base_tree

    worker_body =
      case mode do
        :match -> target_body
        :mismatch -> "wrong-final-tree\n"
      end

    adapters = %{
      "legacy" => tree_adapter("legacy", worker_body),
      "pipeline" => tree_adapter("pipeline", worker_body)
    }

    manifest = %{
      "schema" => CodingBenchmark.manifest_schema(),
      "seed" => 11,
      "fixtures" => [
        %{
          "fixture_id" => fixture_id,
          "fixture_path" => Path.join("fixtures", fixture_id),
          "base_tree_oid" => base_tree,
          "input" => %{
            "objective" => "Reproduce the reviewed target tree for #{fixture_id}.",
            "acceptance_criteria" => ["Final HEAD tree matches the prepared target."]
          },
          "verifier_id" => "exact_target_tree"
        }
      ]
    }

    File.write!(
      Path.join(scenario_root, "manifest.json"),
      Jason.encode!(manifest, pretty: true)
    )

    %{
      adapters: adapters,
      base_commit_oid: base_commit,
      base_tree_oid: base_tree,
      exact_target_trees: %{fixture_id => target_tree},
      fixture_id: fixture_id,
      manifest: manifest,
      root: scenario_root,
      target_body: target_body,
      target_commit_oid: target_commit,
      target_tree_oid: target_tree
    }
  end

  defp tree_adapter(executor, body) do
    fn request ->
      cond do
        request["executor_path"] != executor ->
          {:error, :executor_path_mismatch}

        true ->
          workdir = request["workdir"]
          File.write!(Path.join(workdir, "result.txt"), body)
          git!(workdir, ["add", "--", "result.txt"])

          git!(workdir, [
            "-c",
            "user.name=Arbor Benchmark",
            "-c",
            "user.email=benchmark@arbor.local",
            "commit",
            "--quiet",
            "-m",
            "worker result"
          ])

          tree_oid = git!(workdir, ["rev-parse", "HEAD^{tree}"])

          artifacts =
            if executor == "pipeline", do: pipeline_artifacts(workdir, request), else: %{}

          {:ok,
           %{
             counters: %{validation_cycles: 1, rework_cycles: 0},
             observations: %{
               approval: %{
                 count: 0,
                 requested: false,
                 required: false,
                 resumed: false,
                 status: :not_required
               },
               cancellation: %{
                 cancelled: false,
                 cleanup_completed: true,
                 requested: false,
                 status: :not_requested,
                 worker_terminated: false
               },
               cleanup: %{
                 completed: true,
                 resources_cleaned: true,
                 status: :retained,
                 workspace_removed: false,
                 workspace_retained: true
               },
               tree_oid: tree_oid
             },
             result: %{
               result_type: :coding_change,
               payload: %{
                 artifacts: artifacts,
                 files: ["result.txt"],
                 reason: nil,
                 report: %{
                   review: %{
                     blast_radius: :low,
                     human_required: false,
                     recommendation: :keep,
                     security_veto: false,
                     tier_decision: :auto_proceed
                   },
                   status: :change_committed,
                   validation: [%{passed: true}]
                 }
               }
             },
             worker_ownership: :none
           }}
      end
    end
  end

  defp request_observing_adapter(table, executor, body) do
    inner = tree_adapter(executor, body)

    fn request ->
      :ets.insert(table, {executor, request})
      inner.(request)
    end
  end

  defp pipeline_artifacts(workdir, request) do
    artifact_root = Path.join(workdir, ".git/arbor-benchmark-artifacts")
    File.mkdir_p!(artifact_root)

    dot_path = Path.join(artifact_root, "coding-pipeline.dot")
    plan_path = Path.join(artifact_root, "coding-plan.json")
    manifest_path = Path.join(artifact_root, "compile-manifest.json")
    dot = "digraph benchmark { input_hash=\"#{request["normalized_input_hash"]}\" }\n"

    File.write!(dot_path, dot)
    File.write!(plan_path, "{}\n")
    File.write!(manifest_path, "{}\n")

    %{
      coding_pipeline_path: dot_path,
      coding_plan_path: plan_path,
      compile_manifest_path: manifest_path,
      graph_hash: :crypto.hash(:sha256, dot) |> Base.encode16(case: :lower)
    }
  end

  defp write_prepared_sidecars!(scenario) do
    {:ok, normalized_manifest} = CodingBenchmark.validate_manifest(scenario.manifest)
    catalog_digest = String.duplicate("c", 64)

    fixtures =
      Map.new(normalized_manifest["fixtures"], fn fixture ->
        {fixture["fixture_id"],
         %{
           "base_commit_oid" => scenario.base_commit_oid,
           "base_tree_oid" => fixture["base_tree_oid"],
           "normalized_input_hash" => fixture["normalized_input_hash"],
           "target_commit_oid" => scenario.target_commit_oid,
           "target_tree_oid" => scenario.target_tree_oid
         }}
      end)

    target_evidence = %{
      "catalog_digest" => catalog_digest,
      "fixtures" => fixtures,
      "manifest_digest" => Catalog.canonical_digest(scenario.manifest),
      "schema" => "arbor.coding_benchmark.target_evidence.v1",
      "source_repository_label" => "arbor-test"
    }

    publication = %{
      "catalog_digest" => catalog_digest,
      "manifest_digest" => Catalog.canonical_digest(scenario.manifest),
      "schema" => "arbor.coding_benchmark.publication.v1",
      "target_evidence_digest" => Catalog.canonical_digest(target_evidence)
    }

    target_evidence_path = Path.join(scenario.root, "target-evidence.json")
    publication_path = Path.join(scenario.root, "publication.json")
    write_canonical_json!(target_evidence_path, target_evidence)
    write_canonical_json!(publication_path, publication)

    %{
      publication: publication,
      publication_path: publication_path,
      target_evidence: target_evidence,
      target_evidence_path: target_evidence_path
    }
  end

  defp write_canonical_json!(path, value) do
    File.write!(path, Catalog.canonical_encode(value) <> "\n")
  end

  defp run_exact(scenario) do
    CodingBenchmark.run(scenario.manifest,
      adapters: scenario.adapters,
      exact_target_trees: scenario.exact_target_trees,
      fixture_root: scenario.root,
      measure: fn fun -> {13, fun.()} end,
      verifiers: %{},
      workspace_root: scenario.root
    )
  end

  defp row(report, fixture_id, executor) do
    Enum.find(report["rows"], fn result ->
      result["fixture_id"] == fixture_id and result["executor_path"] == executor
    end)
  end

  defp refute_target_oid_leaked(value, target_tree_oid) do
    encoded = Jason.encode!(value)
    refute String.contains?(encoded, target_tree_oid)
  end

  defp configure_benchmark_runtime!(root) do
    {:ok, workspace_root} = SafePath.resolve_real(root)
    artifact_root = Path.join(workspace_root, "production-artifacts")
    File.mkdir_p!(artifact_root)
    {:ok, artifact_root} = SafePath.resolve_real(artifact_root)

    Application.put_env(:arbor_commands, :coding_benchmark_workspace_root, workspace_root)
    Application.put_env(:arbor_commands, :coding_benchmark_artifact_root, artifact_root)
    Application.put_env(:arbor_commands, :coding_benchmark_execution_timeout_ms, 5_000)
    Application.put_env(:arbor_commands, :coding_benchmark_cancellation_timeout_ms, 500)
    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_worktree_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, artifact_root)
  end

  defp fetch_env({app, key}), do: Application.fetch_env(app, key)
  defp restore_env({app, key}, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env({app, key}, :error), do: Application.delete_env(app, key)

  defp git!(workdir, args) do
    # Fixed executable and argument vector; no shell interpolation occurs.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeSystemCmd
    case System.cmd("git", ["-C", workdir | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git failed (#{status}): #{output}"
    end
  end
end
