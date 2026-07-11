defmodule Arbor.Persistence.EvalFileStoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence

  @moduletag :fast

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "eval_store_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{dir: tmp_dir}
  end

  describe "save_eval_run_file/3 and load_eval_run_file/2" do
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

      assert :ok = Persistence.save_eval_run_file("run_001", run_data, dir: dir)
      assert {:ok, loaded} = Persistence.load_eval_run_file("run_001", dir: dir)

      assert loaded["id"] == "run_001"
      assert loaded["model"] == "qwen3-coder-next"
      assert loaded["provider"] == "lm_studio"
      assert loaded["metrics"]["accuracy"] == 0.75
      assert loaded["sample_count"] == 8
      assert is_binary(loaded["timestamp"])
    end

    test "returns error for non-existent run", %{dir: dir} do
      assert {:error, {:file_error, :enoent}} =
               Persistence.load_eval_run_file("nonexistent", dir: dir)
    end
  end

  describe "list_eval_run_files/1" do
    test "lists runs sorted by timestamp (newest first)", %{dir: dir} do
      for {id, ts} <- [
            {"run_a", "2026-01-01T00:00:00Z"},
            {"run_c", "2026-01-03T00:00:00Z"},
            {"run_b", "2026-01-02T00:00:00Z"}
          ] do
        Persistence.save_eval_run_file(id, %{model: "test", timestamp: ts}, dir: dir)
      end

      {:ok, runs} = Persistence.list_eval_run_files(dir: dir)
      assert length(runs) == 3
      assert Enum.map(runs, & &1["id"]) == ["run_c", "run_b", "run_a"]
    end

    test "filters by model", %{dir: dir} do
      Persistence.save_eval_run_file("r1", %{model: "qwen", provider: "lm"}, dir: dir)
      Persistence.save_eval_run_file("r2", %{model: "llama", provider: "ollama"}, dir: dir)
      Persistence.save_eval_run_file("r3", %{model: "qwen", provider: "lm"}, dir: dir)

      {:ok, runs} = Persistence.list_eval_run_files(dir: dir, model: "qwen")
      assert length(runs) == 2
      assert Enum.all?(runs, &(&1["model"] == "qwen"))
    end

    test "filters by provider", %{dir: dir} do
      Persistence.save_eval_run_file("r1", %{model: "a", provider: "lm_studio"}, dir: dir)
      Persistence.save_eval_run_file("r2", %{model: "b", provider: "ollama"}, dir: dir)

      {:ok, runs} = Persistence.list_eval_run_files(dir: dir, provider: "ollama")
      assert length(runs) == 1
      assert hd(runs)["provider"] == "ollama"
    end

    test "returns empty for non-existent directory" do
      {:ok, runs} =
        Persistence.list_eval_run_files(
          dir: "/tmp/nonexistent_eval_dir_#{:rand.uniform(999_999)}"
        )

      assert runs == []
    end
  end

  describe "latest_eval_run_file/1" do
    test "returns most recent run", %{dir: dir} do
      Persistence.save_eval_run_file(
        "old",
        %{model: "a", timestamp: "2026-01-01T00:00:00Z"},
        dir: dir
      )

      Persistence.save_eval_run_file(
        "new",
        %{model: "a", timestamp: "2026-01-02T00:00:00Z"},
        dir: dir
      )

      {:ok, latest} = Persistence.latest_eval_run_file(dir: dir)
      assert latest["id"] == "new"
    end

    test "returns error when no runs exist", %{dir: dir} do
      assert {:error, :no_runs} = Persistence.latest_eval_run_file(dir: dir)
    end
  end

  describe "compare_eval_run_files/3" do
    test "diffs metrics between two runs", %{dir: dir} do
      Persistence.save_eval_run_file(
        "v1",
        %{
          model: "qwen",
          metrics: %{"accuracy" => 0.6, "mean_score" => 0.7}
        },
        dir: dir
      )

      Persistence.save_eval_run_file(
        "v2",
        %{
          model: "qwen",
          metrics: %{"accuracy" => 0.8, "mean_score" => 0.85}
        },
        dir: dir
      )

      {:ok, comparison} = Persistence.compare_eval_run_files("v1", "v2", dir: dir)

      assert comparison["run_a"]["id"] == "v1"
      assert comparison["run_b"]["id"] == "v2"
      assert_in_delta comparison["metrics_diff"]["accuracy"]["diff"], 0.2, 0.001
      assert_in_delta comparison["metrics_diff"]["mean_score"]["diff"], 0.15, 0.001
    end

    test "returns error if run doesn't exist", %{dir: dir} do
      Persistence.save_eval_run_file("exists", %{model: "a", metrics: %{}}, dir: dir)
      assert {:error, _} = Persistence.compare_eval_run_files("exists", "missing", dir: dir)
    end
  end
end
