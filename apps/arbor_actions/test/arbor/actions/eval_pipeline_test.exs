defmodule Arbor.Actions.EvalPipelineTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.EvalPipeline

  describe "LoadDataset" do
    test "has correct Jido action name" do
      meta = EvalPipeline.LoadDataset.__action_metadata__()
      assert meta.name == "eval_pipeline_load_dataset"
    end

    test "requires path parameter" do
      meta = EvalPipeline.LoadDataset.__action_metadata__()
      assert Keyword.has_key?(meta.schema, :path)
    end

    test "returns error for non-existent path" do
      result = EvalPipeline.LoadDataset.run(%{path: "/nonexistent/path.jsonl"}, %{})
      assert {:error, _} = result
    end
  end

  describe "RunEval" do
    test "has correct Jido action name" do
      meta = EvalPipeline.RunEval.__action_metadata__()
      assert meta.name == "eval_pipeline_run_eval"
    end

    test "requires dataset parameter" do
      meta = EvalPipeline.RunEval.__action_metadata__()
      assert Keyword.has_key?(meta.schema, :dataset)
    end
  end

  describe "Aggregate" do
    test "has correct Jido action name" do
      meta = EvalPipeline.Aggregate.__action_metadata__()
      assert meta.name == "eval_pipeline_aggregate"
    end

    test "requires results parameter" do
      meta = EvalPipeline.Aggregate.__action_metadata__()
      assert Keyword.has_key?(meta.schema, :results)
    end
  end

  describe "Persist" do
    test "has correct Jido action name" do
      meta = EvalPipeline.Persist.__action_metadata__()
      assert meta.name == "eval_pipeline_persist"
    end

    test "requires domain parameter" do
      meta = EvalPipeline.Persist.__action_metadata__()
      assert Keyword.has_key?(meta.schema, :domain)
    end
  end

  describe "Report" do
    test "has correct Jido action name" do
      meta = EvalPipeline.Report.__action_metadata__()
      assert meta.name == "eval_pipeline_report"
    end

    test "has format parameter" do
      meta = EvalPipeline.Report.__action_metadata__()
      assert Keyword.has_key?(meta.schema, :format)
    end
  end

  describe "bridge/4" do
    test "returns default when module not loaded" do
      result = EvalPipeline.bridge(NonExistentModule, :foo, [], :default_value)
      assert result == :default_value
    end

    test "calls function when module available" do
      result = EvalPipeline.bridge(String, :upcase, ["hello"])
      assert result == "HELLO"
    end
  end
end
