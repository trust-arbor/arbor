defmodule Arbor.Orchestrator.Eval.RunStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.RunStore

  @moduletag :fast

  setup do
    # Use a unique tmp dir per test
    tmp_dir = Path.join(System.tmp_dir!(), "eval_store_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{dir: tmp_dir}
  end

  describe "save_run/3 and load_run/2" do
    test "round-trips run data", %{dir: dir} do
      run_data = %{
        model: "qwen3-coder-next",
        provider: "lm_studio",
        dataset: "elixir_coding.jsonl",
        graders: ["compile_check", "functional_test"],
        metrics: %{"accuracy" => 0.75, "mean_score" => 0.82},
        sample_count: 8,
        duration_ms: 45_000,
        results: [%{"id" => "test1", "passed" => true}]
      }

      assert :ok = RunStore.save_run("run_001", run_data, dir: dir)
      assert {:ok, loaded} = RunStore.load_run("run_001", dir: dir)

      assert loaded["id"] == "run_001"
      assert loaded["model"] == "qwen3-coder-next"
      assert loaded["provider"] == "lm_studio"
      assert loaded["metrics"]["accuracy"] == 0.75
      assert loaded["sample_count"] == 8
      assert is_binary(loaded["timestamp"])
    end

    test "returns error for non-existent run", %{dir: dir} do
      assert {:error, {:file_error, :enoent}} = RunStore.load_run("nonexistent", dir: dir)
    end
  end

  describe "list_runs/1" do
    test "lists runs sorted by timestamp (newest first)", %{dir: dir} do
      for {id, ts} <- [
            {"run_a", "2026-01-01T00:00:00Z"},
            {"run_c", "2026-01-03T00:00:00Z"},
            {"run_b", "2026-01-02T00:00:00Z"}
          ] do
        RunStore.save_run(id, %{model: "test", timestamp: ts}, dir: dir)
      end

      {:ok, runs} = RunStore.list_runs(dir: dir)
      assert length(runs) == 3
      assert Enum.map(runs, & &1["id"]) == ["run_c", "run_b", "run_a"]
    end

    test "filters by model", %{dir: dir} do
      RunStore.save_run("r1", %{model: "qwen", provider: "lm"}, dir: dir)
      RunStore.save_run("r2", %{model: "llama", provider: "ollama"}, dir: dir)
      RunStore.save_run("r3", %{model: "qwen", provider: "lm"}, dir: dir)

      {:ok, runs} = RunStore.list_runs(dir: dir, model: "qwen")
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1["model"] == "qwen"))
    end

    test "filters by provider", %{dir: dir} do
      RunStore.save_run("r1", %{model: "a", provider: "lm_studio"}, dir: dir)
      RunStore.save_run("r2", %{model: "b", provider: "ollama"}, dir: dir)

      {:ok, runs} = RunStore.list_runs(dir: dir, provider: "ollama")
      assert length(runs) == 1
      assert hd(runs)["provider"] == "ollama"
    end

    test "returns empty for non-existent directory" do
      {:ok, runs} = RunStore.list_runs(dir: "/tmp/nonexistent_eval_dir_#{:rand.uniform(999_999)}")
      assert runs == []
    end
  end

  describe "latest_run/1" do
    test "returns most recent run", %{dir: dir} do
      RunStore.save_run("old", %{model: "a", timestamp: "2026-01-01T00:00:00Z"}, dir: dir)
      RunStore.save_run("new", %{model: "a", timestamp: "2026-01-02T00:00:00Z"}, dir: dir)

      {:ok, latest} = RunStore.latest_run(dir: dir)
      assert latest["id"] == "new"
    end

    test "returns error when no runs exist", %{dir: dir} do
      assert {:error, :no_runs} = RunStore.latest_run(dir: dir)
    end
  end

  describe "compare_runs/3" do
    test "diffs metrics between two runs", %{dir: dir} do
      RunStore.save_run(
        "v1",
        %{
          model: "qwen",
          metrics: %{"accuracy" => 0.6, "mean_score" => 0.7}
        },
        dir: dir
      )

      RunStore.save_run(
        "v2",
        %{
          model: "qwen",
          metrics: %{"accuracy" => 0.8, "mean_score" => 0.85}
        },
        dir: dir
      )

      {:ok, comparison} = RunStore.compare_runs("v1", "v2", dir: dir)

      assert comparison["run_a"]["id"] == "v1"
      assert comparison["run_b"]["id"] == "v2"
      assert_in_delta comparison["metrics_diff"]["accuracy"]["diff"], 0.2, 0.001
      assert_in_delta comparison["metrics_diff"]["mean_score"]["diff"], 0.15, 0.001
    end

    test "returns error if run doesn't exist", %{dir: dir} do
      RunStore.save_run("exists", %{model: "a", metrics: %{}}, dir: dir)
      assert {:error, _} = RunStore.compare_runs("exists", "missing", dir: dir)
    end
  end
end
