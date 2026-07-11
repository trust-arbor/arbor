defmodule Arbor.Actions.EvalPipelineTest do
  use ExUnit.Case, async: true
  @moduletag :fast

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

    test "security regression: unknown subject does not intern a module atom" do
      # Caller-controlled subject must not mint atoms via Module.concat/1.
      subject = "Arbor.EvalPipeline.UnknownSubject#{System.unique_integer([:positive])}"
      module_name = "Elixir." <> subject

      assert {:error, {:unknown_atom, ^module_name}} =
               Arbor.Common.SafeAtom.to_existing(module_name)

      assert {:ok, %{results: [], count: 0, passed: 0}} =
               EvalPipeline.RunEval.run(
                 %{dataset: [], graders: "exact_match", subject: subject},
                 %{}
               )

      assert {:error, {:unknown_atom, ^module_name}} =
               Arbor.Common.SafeAtom.to_existing(module_name)
    end

    test "unloaded existing subject module falls back to passthrough" do
      # Compile-time module alias creates the atom without a module body, so
      # SafeAtom succeeds but Code.ensure_loaded? fails and RunEval must fall
      # back to the passthrough subject rather than returning nil/error.
      unloaded = Arbor.EvalPipeline.UnloadedExistingSubjectAtom
      refute Code.ensure_loaded?(unloaded)

      sample = %{"id" => "s1", "input" => "hello", "expected" => "hello"}

      assert {:ok, %{results: [result], count: 1, passed: 1}} =
               EvalPipeline.RunEval.run(
                 %{
                   dataset: [sample],
                   graders: "exact_match",
                   subject: inspect(unloaded)
                 },
                 %{}
               )

      # Passthrough returns input unchanged; exact_match therefore passes.
      assert result["passed"] == true
      assert result["actual"] == "hello"
      assert result["expected"] == "hello"
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
    @results [
      %{"id" => "pass", "expected" => "same", "actual" => "same", "passed" => true},
      %{
        "id" => "fail",
        "expected" => "expected",
        "actual" => "actual",
        "passed" => false
      }
    ]
    @metrics %{"accuracy" => 0.5}

    test "has correct Jido action name" do
      meta = EvalPipeline.Report.__action_metadata__()
      assert meta.name == "eval_pipeline_report"
    end

    test "has format parameter" do
      meta = EvalPipeline.Report.__action_metadata__()
      assert Keyword.has_key?(meta.schema, :format)
    end

    test "preserves terminal report output while delegating formatting" do
      assert {:ok, %{report: report, format: "terminal"}} =
               EvalPipeline.Report.run(
                 %{results: @results, metrics: @metrics, format: "terminal"},
                 %{}
               )

      assert report == """
             === Evaluation Report ===
             Samples: 2 | Passed: 1 | Failed: 1

             Metrics:
               accuracy: 0.5

             Top Failures:
               - fail: expected=expected actual=actual
             """
    end

    test "preserves Markdown and JSON report output" do
      for format <- ["markdown", "json"] do
        assert {:ok, %{report: report, format: ^format}} =
                 EvalPipeline.Report.run(
                   %{results: @results, metrics: @metrics, format: format},
                   %{}
                 )

        assert report == Arbor.Eval.Report.format(@results, @metrics, format)
      end
    end

    test "keeps file writes at the action boundary" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "eval_report_#{System.unique_integer([:positive])}")

      output_path = Path.join(tmp_dir, "nested/report.md")
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      assert {:ok, %{report: report, format: "markdown", path: ^output_path}} =
               EvalPipeline.Report.run(
                 %{
                   results: @results,
                   metrics: @metrics,
                   format: "markdown",
                   output_path: output_path
                 },
                 %{}
               )

      assert File.read!(output_path) == report
      assert report == Arbor.Eval.Report.format(@results, @metrics, "markdown")
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
