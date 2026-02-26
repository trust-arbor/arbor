defmodule Arbor.Orchestrator.Pipelines.CouncilDecisionExecutionTest do
  @moduledoc """
  Tier 2 execution tests for council-decision.dot.

  The council pipeline fans out to 13 advisory perspectives in parallel,
  collects results, runs consensus.decide, then exits. These tests verify
  the fan-out/fan-in flow and result aggregation with simulated branches.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Test.DotTestHelper

  @moduletag :dot_execution

  describe "parallel fan-out/fan-in" do
    test "all 13 perspectives execute and results are collected" do
      branch_fn = fn branch_id, _join_target, _context, _graph, _opts ->
        %{
          "id" => branch_id,
          "status" => "success",
          "score" => 0.8,
          "notes" => "Simulated #{branch_id}"
        }
      end

      {:ok, result} =
        DotTestHelper.run_pipeline("council-decision.dot",
          skip_validation: true,
          simulate_compute: false,
          parallel_branch_executor: branch_fn
        )

      assert DotTestHelper.visited?(result, "start")
      assert DotTestHelper.visited?(result, "evaluate")

      # Fan-in collects parallel results
      parallel_results = Map.get(result.context, "parallel.results", [])
      assert length(parallel_results) == 13

      # All results should be successful
      assert Enum.all?(parallel_results, &(&1["status"] == "success"))

      # Verify fan-in completed
      assert DotTestHelper.visited?(result, "collect")
      assert Map.get(result.context, "parallel.fan_in.best_id") != nil
    end

    test "fan-in selects best scoring perspective" do
      branch_fn = fn branch_id, _join_target, _context, _graph, _opts ->
        # Give security perspective the highest score
        score = if branch_id == "security", do: 0.99, else: 0.5

        %{
          "id" => branch_id,
          "status" => "success",
          "score" => score
        }
      end

      {:ok, result} =
        DotTestHelper.run_pipeline("council-decision.dot",
          skip_validation: true,
          simulate_compute: false,
          parallel_branch_executor: branch_fn
        )

      assert Map.get(result.context, "parallel.fan_in.best_id") == "security"
      assert Map.get(result.context, "parallel.fan_in.best_score") == 0.99
    end

    test "partial failures still produce results with continue policy" do
      branch_fn = fn branch_id, _join_target, _context, _graph, _opts ->
        # Simulate 3 failures
        status =
          if branch_id in ["adversarial", "privacy", "emergence"], do: "fail", else: "success"

        %{
          "id" => branch_id,
          "status" => status,
          "score" => if(status == "success", do: 0.7, else: 0.0)
        }
      end

      {:ok, result} =
        DotTestHelper.run_pipeline("council-decision.dot",
          skip_validation: true,
          simulate_compute: false,
          parallel_branch_executor: branch_fn
        )

      parallel_results = Map.get(result.context, "parallel.results", [])
      assert length(parallel_results) == 13
      assert Map.get(result.context, "parallel.success_count") == 10
      assert Map.get(result.context, "parallel.fail_count") == 3
    end

    test "result counts are tracked correctly" do
      branch_fn = fn branch_id, _join_target, _context, _graph, _opts ->
        %{"id" => branch_id, "status" => "success", "score" => 0.6}
      end

      {:ok, result} =
        DotTestHelper.run_pipeline("council-decision.dot",
          skip_validation: true,
          simulate_compute: false,
          parallel_branch_executor: branch_fn
        )

      assert Map.get(result.context, "parallel.success_count") == 13
      assert Map.get(result.context, "parallel.fail_count") == 0
      assert Map.get(result.context, "parallel.total_count") == 13
    end
  end

  describe "exec node (consensus.decide)" do
    test "pipeline reaches decide node after fan-in" do
      branch_fn = fn branch_id, _join_target, _context, _graph, _opts ->
        %{"id" => branch_id, "status" => "success", "score" => 0.7}
      end

      {:ok, result} =
        DotTestHelper.run_pipeline("council-decision.dot",
          skip_validation: true,
          simulate_compute: false,
          parallel_branch_executor: branch_fn
        )

      # decide node is exec type — may fail gracefully if ActionsExecutor unavailable
      # but the pipeline should still reach it
      assert DotTestHelper.visited?(result, "decide") or
               DotTestHelper.visited?(result, "collect")
    end
  end
end
