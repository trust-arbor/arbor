defmodule Arbor.Orchestrator.Eval.PersistenceBridgeTest do
  @moduledoc """
  Thin delegate tests — logic lives in arbor_persistence.
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Eval.PersistenceBridge
  alias Arbor.Persistence

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
      result =
        PersistenceBridge.save_result(%{
          id: "result-test",
          run_id: "run-test",
          sample_id: "sample-1",
          passed: true,
          scores: %{}
        })

      assert result == :ok or match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end
end
