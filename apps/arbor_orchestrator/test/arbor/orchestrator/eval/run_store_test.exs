defmodule Arbor.Orchestrator.Eval.RunStoreTest do
  @moduledoc """
  Thin delegate tests — logic lives in arbor_persistence.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.RunStore

  @moduletag :fast

  setup do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(System.tmp_dir!(), "run-store-" <> token)
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{tmp_dir: root}
  end

  test "save_run/load_run delegate to Persistence", %{tmp_dir: tmp_dir} do
    assert :ok = RunStore.save_run("run_001", %{model: "m", metrics: %{"a" => 1}}, dir: tmp_dir)
    assert {:ok, loaded} = RunStore.load_run("run_001", dir: tmp_dir)
    assert loaded["id"] == "run_001"
    assert loaded["model"] == "m"
  end

  test "list_runs/latest_run/compare_runs delegate", %{tmp_dir: tmp_dir} do
    assert :ok =
             RunStore.save_run(
               "v1",
               %{model: "m", metrics: %{"accuracy" => 0.5}, timestamp: "2026-01-01T00:00:00Z"},
               dir: tmp_dir
             )

    assert :ok =
             RunStore.save_run(
               "v2",
               %{model: "m", metrics: %{"accuracy" => 0.8}, timestamp: "2026-01-02T00:00:00Z"},
               dir: tmp_dir
             )

    assert {:ok, runs} = RunStore.list_runs(dir: tmp_dir)
    assert length(runs) == 2

    assert {:ok, latest} = RunStore.latest_run(dir: tmp_dir)
    assert latest["id"] == "v2"

    assert {:ok, comparison} = RunStore.compare_runs("v1", "v2", dir: tmp_dir)
    assert_in_delta comparison["metrics_diff"]["accuracy"]["diff"], 0.3, 0.001
  end
end
