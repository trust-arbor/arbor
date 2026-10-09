defmodule Arbor.Orchestrator.Eval.PersistenceBridgeTest do
  @moduledoc """
  Thin delegate tests — logic lives in arbor_persistence.
  """
  use ExUnit.Case, async: false
  @moduletag :isolated_repo

  alias Arbor.Orchestrator.Eval.PersistenceBridge
  alias Arbor.Persistence
  alias Arbor.Persistence.Repo

  @migrations Path.expand("../../../../../arbor_persistence/priv/repo/migrations", __DIR__)

  setup_all do
    assert Process.whereis(Repo) == nil,
           "run PersistenceBridge's real database tests in an isolated checkout"

    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-persistence-bridge-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      {Repo,
       database: Path.join(root, "eval.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 4,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    :ok
  end

  describe "deprecated delegate surface" do
    test "available?/0 matches Persistence.eval_database_available?/0" do
      assert PersistenceBridge.available?() == Persistence.eval_database_available?()
    end

    test "generate_run_id/2 delegates to Persistence" do
      id = PersistenceBridge.generate_run_id("model", "domain")
      assert is_binary(id)
      assert String.contains?(id, "model")
      assert String.contains?(id, "domain")
    end

    test "create_run/1 returns {:ok, _} via facade" do
      attrs = %{
        id: "delegate-#{System.os_time(:millisecond)}",
        model: "test-model",
        domain: "coding",
        provider: "test",
        dataset: "test.jsonl",
        graders: [],
        status: "running",
        config: %{}
      }

      assert {:ok, _} = PersistenceBridge.create_run(attrs)
    end

    test "complete_run/4 and fail_run/2 do not crash" do
      assert PersistenceBridge.complete_run("nonexistent", %{}, 0, 0) in [
               :ok,
               {:error, :not_found}
             ]

      assert PersistenceBridge.fail_run("nonexistent", "test error") in [
               :ok,
               {:error, :not_found}
             ]
    end

    test "list_runs/1 returns a list envelope" do
      case PersistenceBridge.list_runs([]) do
        {:ok, runs} -> assert is_list(runs)
        runs when is_list(runs) -> assert is_list(runs)
      end
    end

    test "save_result/1 does not crash" do
      run_id = "result-run-#{System.unique_integer([:positive])}"

      assert {:ok, _run} =
               PersistenceBridge.create_run(%{
                 id: run_id,
                 model: "test-model",
                 domain: "coding",
                 provider: "test",
                 dataset: "test.jsonl"
               })

      assert {:ok, _result} =
               PersistenceBridge.save_result(%{
                 id: "result-#{System.unique_integer([:positive])}",
                 run_id: run_id,
                 sample_id: "sample-1",
                 passed: true,
                 scores: %{}
               })
    end
  end
end
