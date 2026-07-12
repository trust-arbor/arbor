defmodule Arbor.Commands.CodingBenchmarkTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Commands.CodingBenchmark
  alias Arbor.Commands.CodingBenchmarkScenario, as: Scenario
  alias Arbor.Common.SafePath
  alias Mix.Tasks.Arbor.Coding.Benchmark, as: BenchmarkTask

  @row_keys ~w(
    approval_observations artifact_hash_verification base_tree_oid
    cancellation_observations changed_paths counters executor_path fixture_id
    normalized_input_hash objective_verifier repetition review_outcome terminal_reason
    terminal_status wall_clock_ms
  )

  @runtime_env [
    {:arbor_commands, :coding_benchmark_workspace_root},
    {:arbor_commands, :coding_benchmark_artifact_root},
    {:arbor_commands, :coding_benchmark_execution_timeout_ms},
    {:arbor_orchestrator, :coding_repo_roots},
    {:arbor_orchestrator, :coding_worktree_roots},
    {:arbor_orchestrator, :coding_pipeline_logs_root}
  ]

  setup do
    original = Application.fetch_env(:arbor_agent, :coding_executor_mode)
    runtime_originals = Map.new(@runtime_env, fn key -> {key, fetch_env(key)} end)
    Application.put_env(:arbor_agent, :coding_executor_mode, :benchmark_test_sentinel)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:arbor_agent, :coding_executor_mode, value)
        :error -> Application.delete_env(:arbor_agent, :coding_executor_mode)
      end

      Enum.each(runtime_originals, fn {key, value} -> restore_env(key, value) end)
    end)

    :ok
  end

  test "happy pair executes byte-identical fixtures with semantic parity" do
    scenario = scenario!(~w(happy))

    assert {:ok, report} = run_scenario(scenario)
    assert report["summary"] == summary(1, 2, 1, 0, 0)

    assert %{
             "comparison" => %{
               "differences" => [],
               "equivalent" => true,
               "reason" => nil,
               "status" => "equivalent"
             }
           } = hd(report["pairs"])

    legacy = row(report, "happy", "legacy")
    pipeline = row(report, "happy", "pipeline")

    for result <- [legacy, pipeline] do
      assert result["terminal_status"] == "change_committed"
      assert result["objective_verifier"] == %{"reason" => nil, "status" => "passed"}
      assert result["changed_paths"] == ["result.txt"]
      assert result["wall_clock_ms"] == 17
      assert result["artifact_hash_verification"]["status"] == "passed"
      assert result["artifact_hash_verification"]["base_tree_verified"] == true
      assert result["artifact_hash_verification"]["result_tree_verified"] == true
      assert result["artifact_hash_verification"]["changed_paths_verified"] == true
    end

    assert legacy["artifact_hash_verification"]["graph_hash_verified"] == nil

    assert legacy["artifact_hash_verification"]["artifact_presence"] == %{
             "digest" => false,
             "dot" => false,
             "manifest" => false,
             "plan" => false
           }

    assert pipeline["artifact_hash_verification"]["graph_hash_verified"] == true
    assert Enum.all?(pipeline["artifact_hash_verification"]["artifact_presence"], &elem(&1, 1))
    assert Application.get_env(:arbor_agent, :coding_executor_mode) == :benchmark_test_sentinel
  end

  test "validation recovery retains validation and rework counters" do
    scenario = scenario!(~w(validation-recovery))
    assert {:ok, report} = run_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      assert row(report, "validation-recovery", executor)["counters"] == %{
               "rework_cycles" => 1,
               "validation_cycles" => 2
             }
    end

    assert hd(report["pairs"])["comparison"]["status"] == "equivalent"
  end

  test "review recovery retains final review outcome and rework count" do
    scenario = scenario!(~w(review-recovery))
    assert {:ok, report} = run_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      result = row(report, "review-recovery", executor)
      assert result["counters"]["rework_cycles"] == 1
      assert result["review_outcome"]["recommendation"] == "keep"
      assert result["review_outcome"]["human_required"] == false
      assert result["review_outcome"]["security_veto"] == false
    end
  end

  test "approval observations record one required approval and resume" do
    scenario = scenario!(~w(approval-resume))
    assert {:ok, report} = run_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      assert row(report, "approval-resume", executor)["approval_observations"] == %{
               "count" => 1,
               "requested" => true,
               "required" => true,
               "resumed" => true,
               "status" => "approved"
             }
    end
  end

  test "review rejection and executor failure both retain report rows" do
    scenario = scenario!(~w(review-rejection executor-failure))
    assert {:ok, report} = run_scenario(scenario)
    assert report["summary"]["row_count"] == 4

    for executor <- ~w(legacy pipeline) do
      rejected = row(report, "review-rejection", executor)
      assert rejected["terminal_status"] == "review_rejected"
      assert rejected["terminal_reason"] == "scripted_review_rejection"
      assert rejected["review_outcome"]["recommendation"] == "reject"
    end

    succeeded = row(report, "executor-failure", "legacy")
    failed = row(report, "executor-failure", "pipeline")

    assert succeeded["terminal_status"] == "change_committed"
    assert failed["terminal_status"] == "executor_failed"
    assert failed["terminal_reason"] == "scripted_pipeline_failure"
    assert failed["changed_paths"] == []
    assert failed["objective_verifier"] == %{"reason" => "executor_failed", "status" => "not_run"}
    assert failed["artifact_hash_verification"]["status"] == "not_run"

    failed_pair = Enum.find(report["pairs"], &(&1["fixture_id"] == "executor-failure"))
    assert failed_pair["comparison"]["status"] == "unavailable"
    assert Application.get_env(:arbor_agent, :coding_executor_mode) == :benchmark_test_sentinel
  end

  test "cancellation distinguishes owned cleanup from reused worker preservation" do
    scenario = scenario!(~w(cancel-owned cancel-reused))
    assert {:ok, report} = run_scenario(scenario)

    for executor <- ~w(legacy pipeline) do
      owned = row(report, "cancel-owned", executor)["cancellation_observations"]
      reused = row(report, "cancel-reused", executor)["cancellation_observations"]

      assert owned["worker_ownership"] == "owned"
      assert owned["worker_terminated"] == true
      assert owned["cleanup"]["workspace_removed"] == true
      assert owned["cleanup"]["workspace_retained"] == false

      assert reused["worker_ownership"] == "reused"
      assert reused["worker_terminated"] == false
      assert reused["cleanup"]["workspace_removed"] == false
      assert reused["cleanup"]["workspace_retained"] == true

      assert row(report, "cancel-owned", executor)["objective_verifier"]["status"] == "not_run"
      assert row(report, "cancel-reused", executor)["terminal_status"] == "cancelled"
    end
  end

  test "seeded pair ordering is deterministic and randomizable" do
    scenario = scenario!(~w(happy))

    orders =
      for seed <- 0..20 do
        assert {:ok, report} =
                 CodingBenchmark.run(scenario.manifest,
                   dry_run: true,
                   fixture_root: scenario.root,
                   seed: seed,
                   workspace_root: scenario.root
                 )

        hd(report["pairs"])["execution_order"]
      end

    assert Enum.sort(Enum.uniq(orders)) == [~w(legacy pipeline), ~w(pipeline legacy)]

    assert {:ok, first} = dry_run(scenario, 11)
    assert {:ok, second} = dry_run(scenario, 11)
    assert first == second
  end

  test "report and every row have closed JSON-clean schemas" do
    scenario = scenario!(~w(happy executor-failure))
    assert {:ok, report} = run_scenario(scenario)

    assert Map.keys(report) |> Enum.sort() ==
             ~w(manifest_hash pairs repetitions rows schema seed summary)

    assert report["schema"] == CodingBenchmark.report_schema()
    assert report["manifest_hash"] =~ ~r/\A[0-9a-f]{64}\z/

    for result <- report["rows"] do
      assert Map.keys(result) |> Enum.sort() == Enum.sort(@row_keys)
      assert result["normalized_input_hash"] =~ ~r/\A[0-9a-f]{64}\z/

      assert Map.keys(result["artifact_hash_verification"]) |> Enum.sort() ==
               ~w(
                 artifact_presence base_tree_verified changed_paths_verified graph_hash_verified
                 normalized_input_hash_verified result_tree_verified status
               )
    end

    assert {:ok, encoded} = Jason.encode(report)
    assert {:ok, ^report} = Jason.decode(encoded)
  end

  test "manifest schema rejects unknown executable selectors and unsafe fixture paths" do
    scenario = scenario!(~w(happy))

    with_callback =
      Map.update!(scenario.manifest, "fixtures", fn [fixture] ->
        [Map.put(fixture, "adapter_module", "Elixir.System")]
      end)

    assert {:error,
            %{"error" => "invalid_coding_benchmark_manifest", "reason" => "unknown_field"}} =
             CodingBenchmark.validate_manifest(with_callback)

    unsafe = put_in(scenario.manifest, ["fixtures", Access.at(0), "fixture_path"], "../happy")

    assert {:error, %{"field" => field, "reason" => "unsafe_path"}} =
             CodingBenchmark.validate_manifest(unsafe)

    assert field =~ "fixture_path"

    assert {:error, %{"field" => "repetitions", "reason" => "out_of_bounds"}} =
             CodingBenchmark.run(scenario.manifest, dry_run: true, repetitions: 0)
  end

  test "trusted benchmark workspace config rejects runtime workspace escapes" do
    scenario = scenario!(~w(happy))
    outside = Path.dirname(scenario.root)

    assert {:error,
            %{
              "error" => "invalid_coding_benchmark_runtime",
              "field" => "workspace_root",
              "reason" => "workspace_outside_root"
            }} =
             CodingBenchmark.run(scenario.manifest,
               dry_run: true,
               fixture_root: scenario.root,
               workspace_root: outside
             )
  end

  test "Mix task writes JSON at its boundary with all supported execution options" do
    scenario = scenario!(~w(happy))

    assert {:ok, %{output_path: output_path, report: report}} =
             BenchmarkTask.execute(
               [
                 "--manifest",
                 "manifest.json",
                 "--acp-agent",
                 "grok",
                 "--repetitions",
                 "2",
                 "--seed",
                 "19",
                 "--output",
                 "report.json"
               ],
               adapters: Scenario.adapters(),
               measure: &Scenario.deterministic_measure/1,
               root: scenario.root,
               verifiers: Scenario.verifiers(),
               workspace_root: scenario.root
             )

    assert {:ok, real_root} = SafePath.resolve_real(scenario.root)
    assert output_path == Path.join(real_root, "report.json")
    assert report["repetitions"] == 2
    assert report["seed"] == 19
    assert report["summary"]["row_count"] == 4
    assert {:ok, ^report} = output_path |> File.read!() |> Jason.decode()
  end

  test "Mix task dry-run is deterministic and refuses unsafe paths and bounds" do
    scenario = scenario!(~w(happy))
    outside = Path.join(Path.dirname(scenario.root), "outside-benchmark.json")
    File.write!(outside, "do not overwrite")
    on_exit(fn -> File.rm(outside) end)

    assert {:ok, %{report: dry_report}} =
             BenchmarkTask.execute(
               ["--manifest", "manifest.json", "--dry-run", "--output", "dry.json"],
               root: scenario.root,
               workspace_root: scenario.root
             )

    assert Enum.all?(dry_report["rows"], &(&1["terminal_status"] == "dry_run"))
    assert Enum.all?(dry_report["rows"], &(&1["wall_clock_ms"] == 0))

    assert {:error, %{"field" => "manifest", "reason" => "unsafe_path"}} =
             BenchmarkTask.execute(["--manifest", "../manifest.json", "--dry-run"],
               root: scenario.root
             )

    assert {:error, %{"field" => "output", "reason" => "unsafe_path"}} =
             BenchmarkTask.execute(
               [
                 "--manifest",
                 "manifest.json",
                 "--dry-run",
                 "--output",
                 "../outside-benchmark.json"
               ],
               root: scenario.root
             )

    for invalid <- ["0", "101"] do
      assert {:error, %{"field" => "repetitions", "reason" => "out_of_bounds"}} =
               BenchmarkTask.execute(
                 ["--manifest", "manifest.json", "--dry-run", "--repetitions", invalid],
                 root: scenario.root
               )
    end

    assert {:error, %{"field" => "seed", "reason" => "out_of_bounds"}} =
             BenchmarkTask.execute(
               ["--manifest", "manifest.json", "--dry-run", "--seed", "-1"],
               root: scenario.root
             )

    assert File.read!(outside) == "do not overwrite"
  end

  test "Mix task rejects symlink outputs, manifest overwrite, and fixture output" do
    scenario = scenario!(~w(happy))
    outside = Path.join(Path.dirname(scenario.root), "outside-symlink-target.json")
    File.write!(outside, "untouched")
    on_exit(fn -> File.rm(outside) end)

    symlink = Path.join(scenario.root, "linked-report.json")
    File.ln_s!(outside, symlink)

    assert {:error, %{"field" => "output", "reason" => "non_regular_file"}} =
             BenchmarkTask.execute(
               ["--manifest", "manifest.json", "--dry-run", "--output", "linked-report.json"],
               root: scenario.root
             )

    assert {:error, %{"field" => "output", "reason" => "would_overwrite_manifest"}} =
             BenchmarkTask.execute(
               ["--manifest", "manifest.json", "--dry-run", "--output", "manifest.json"],
               root: scenario.root
             )

    assert {:error, %{"field" => "output", "reason" => "inside_fixture"}} =
             BenchmarkTask.execute(
               [
                 "--manifest",
                 "manifest.json",
                 "--dry-run",
                 "--output",
                 "fixtures/happy/report.json"
               ],
               root: scenario.root
             )

    assert File.read!(outside) == "untouched"
  end

  defp scenario!(fixture_ids) do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-coding-benchmark-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    scenario = Scenario.create!(root, fixture_ids)
    configure_benchmark_runtime!(root)
    on_exit(fn -> File.rm_rf(root) end)
    scenario
  end

  defp configure_benchmark_runtime!(root) do
    {:ok, workspace_root} = SafePath.resolve_real(root)
    artifact_root = Path.join(workspace_root, "production-artifacts")
    File.mkdir_p!(artifact_root)
    {:ok, artifact_root} = SafePath.resolve_real(artifact_root)

    Application.put_env(:arbor_commands, :coding_benchmark_workspace_root, workspace_root)
    Application.put_env(:arbor_commands, :coding_benchmark_artifact_root, artifact_root)
    Application.put_env(:arbor_commands, :coding_benchmark_execution_timeout_ms, 5_000)
    Application.put_env(:arbor_orchestrator, :coding_repo_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_worktree_roots, [workspace_root])
    Application.put_env(:arbor_orchestrator, :coding_pipeline_logs_root, artifact_root)
  end

  defp fetch_env({app, key}), do: Application.fetch_env(app, key)

  defp restore_env({app, key}, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env({app, key}, :error), do: Application.delete_env(app, key)

  defp run_scenario(scenario, opts \\ []) do
    defaults = [
      adapters: Scenario.adapters(),
      fixture_root: scenario.root,
      measure: &Scenario.deterministic_measure/1,
      verifiers: Scenario.verifiers(),
      workspace_root: scenario.root
    ]

    CodingBenchmark.run(scenario.manifest, Keyword.merge(defaults, opts))
  end

  defp dry_run(scenario, seed) do
    CodingBenchmark.run(scenario.manifest,
      dry_run: true,
      fixture_root: scenario.root,
      seed: seed,
      workspace_root: scenario.root
    )
  end

  defp row(report, fixture_id, executor) do
    Enum.find(report["rows"], fn result ->
      result["fixture_id"] == fixture_id and result["executor_path"] == executor
    end)
  end

  defp summary(pair_count, row_count, equivalent, different, unavailable) do
    %{
      "different_pairs" => different,
      "equivalent_pairs" => equivalent,
      "pair_count" => pair_count,
      "row_count" => row_count,
      "unavailable_pairs" => unavailable
    }
  end
end
