defmodule Arbor.Actions.EvalPipelineTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Actions
  alias Arbor.Actions.EvalPipeline
  alias Arbor.Actions.Egress

  defmodule DenySecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: {:error, :policy_denied}
  end

  defmodule AllowSecurity do
    @moduledoc false
    def authorize(_agent, _uri, _action, _opts), do: {:ok, :authorized}
  end

  setup do
    previous = Application.get_env(:arbor_actions, :security_module)
    on_exit(fn -> restore_security_module(previous) end)
    :ok
  end

  defp restore_security_module(nil), do: Application.delete_env(:arbor_actions, :security_module)

  defp restore_security_module(module),
    do: Application.put_env(:arbor_actions, :security_module, module)

  @pipeline_modules [
    EvalPipeline.LoadDataset,
    EvalPipeline.RunEval,
    EvalPipeline.Aggregate,
    EvalPipeline.Persist,
    EvalPipeline.Report
  ]

  describe "registry membership and naming" do
    test "registers exactly the five eval_pipeline modules" do
      assert Actions.list_actions()[:eval_pipeline] == @pipeline_modules

      for module <- @pipeline_modules do
        assert module in Actions.all_actions()
      end
    end

    test "exposes DOT names, underscore aliases, and canonical singular URIs" do
      expectations = [
        {EvalPipeline.LoadDataset, "eval_pipeline.load_dataset", "eval_pipeline_load_dataset",
         "arbor://action/eval_pipeline/load_dataset"},
        {EvalPipeline.RunEval, "eval_pipeline.run_eval", "eval_pipeline_run_eval",
         "arbor://action/eval_pipeline/run_eval"},
        {EvalPipeline.Aggregate, "eval_pipeline.aggregate", "eval_pipeline_aggregate",
         "arbor://action/eval_pipeline/aggregate"},
        {EvalPipeline.Persist, "eval_pipeline.persist", "eval_pipeline_persist",
         "arbor://action/eval_pipeline/persist"},
        {EvalPipeline.Report, "eval_pipeline.report", "eval_pipeline_report",
         "arbor://action/eval_pipeline/report"}
      ]

      for {module, dot_name, underscore, uri} <- expectations do
        assert Actions.action_module_to_name(module) == dot_name
        assert module.__action_metadata__().name == underscore
        assert Actions.canonical_uri_for(module, %{}) == uri
        assert Actions.tool_name_to_canonical_uri(dot_name) == {:ok, uri}
        assert Actions.tool_name_to_canonical_uri(underscore) == {:ok, uri}
      end
    end

    test "projects capability profiles and effect classes" do
      assert Egress.effect_class_for(EvalPipeline.LoadDataset) == :read
      assert Egress.effect_class_for(EvalPipeline.Aggregate) == :read
      assert Egress.effect_class_for(EvalPipeline.RunEval) == :network_egress
      assert Egress.effect_class_for(EvalPipeline.Persist) == :local_write
      assert Egress.effect_class_for(EvalPipeline.Report) == :local_write

      profiles =
        Actions.action_namespace_capability_profiles()
        |> Map.new(&{&1.uri_prefix, &1})

      assert profiles["arbor://action/eval_pipeline/load_dataset"].effect_class == :read
      assert profiles["arbor://action/eval_pipeline/aggregate"].effect_class == :read
      assert profiles["arbor://action/eval_pipeline/run_eval"].effect_class == :network_egress
      assert profiles["arbor://action/eval_pipeline/persist"].effect_class == :local_write
      assert profiles["arbor://action/eval_pipeline/report"].effect_class == :local_write
    end
  end

  describe "LoadDataset vertical path" do
    test "loads JSONL through Arbor.Eval after path resolution" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "eval_pipeline_load_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      File.write!(Path.join(tmp_dir, "samples.jsonl"), """
      {"id":"s1","input":"hello","expected":"hello"}
      {"input":"world","expected":"earth"}
      """)

      assert {:ok, %{dataset: samples, count: 2, path: path}} =
               EvalPipeline.LoadDataset.run(
                 %{path: "samples.jsonl", workdir: tmp_dir},
                 %{}
               )

      assert path == Path.join(tmp_dir, "samples.jsonl")
      assert Enum.map(samples, & &1["id"]) == ["s1", "sample_1"]
    end

    test "returns error for non-existent path" do
      result = EvalPipeline.LoadDataset.run(%{path: "/nonexistent/path.jsonl"}, %{})
      assert {:error, _} = result
    end

    test "security regression: denied read happens before File.read" do
      Application.put_env(:arbor_actions, :security_module, DenySecurity)

      tmp_dir =
        Path.join(System.tmp_dir!(), "eval_pipeline_deny_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      path = Path.join(tmp_dir, "secret.jsonl")
      File.write!(path, ~s({"id":"s1","input":"x","expected":"x"}\n))

      # Prove the file is readable when authorized so a later deny is not :enoent.
      Application.put_env(:arbor_actions, :security_module, AllowSecurity)

      assert {:ok, %{count: 1}} =
               EvalPipeline.LoadDataset.run(%{path: path}, %{agent_id: "agent_eval"})

      Application.put_env(:arbor_actions, :security_module, DenySecurity)

      assert {:error, message} =
               EvalPipeline.LoadDataset.run(%{path: path}, %{agent_id: "agent_eval"})

      assert message =~ "unauthorized"
      assert message =~ "policy_denied"
    end
  end

  describe "RunEval symbolic catalogs" do
    test "passthrough + exact_match vertical path" do
      sample = %{"id" => "s1", "input" => "hello", "expected" => "hello"}

      assert {:ok, %{results: [result], count: 1, passed: 1}} =
               EvalPipeline.RunEval.run(
                 %{dataset: [sample], graders: "exact_match"},
                 %{}
               )

      assert result["passed"] == true
      assert result["actual"] == "hello"
    end

    test "blank subject defaults to passthrough" do
      sample = %{"id" => "s1", "input" => "abc", "expected" => "abc"}

      assert {:ok, %{passed: 1}} =
               EvalPipeline.RunEval.run(
                 %{dataset: [sample], graders: "exact_match", subject: ""},
                 %{}
               )
    end

    test "explicit unknown subject fails clearly without internment" do
      subject = "Arbor.EvalPipeline.UnknownSubject#{System.unique_integer([:positive])}"
      module_name = "Elixir." <> subject

      assert_raise ArgumentError, fn -> String.to_existing_atom(subject) end

      assert {:error, message} =
               EvalPipeline.RunEval.run(
                 %{dataset: [], graders: "exact_match", subject: subject},
                 %{}
               )

      assert message =~ "unknown_subject"
      assert message =~ subject

      assert_raise ArgumentError, fn -> String.to_existing_atom(subject) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(module_name) end
    end

    test "security regression: unknown subject does not intern a module atom" do
      subject = "Arbor.EvalPipeline.UnknownSubject#{System.unique_integer([:positive])}"
      module_name = "Elixir." <> subject

      assert {:error, {:unknown_atom, ^module_name}} =
               Arbor.Common.SafeAtom.to_existing(module_name)

      assert {:error, message} =
               EvalPipeline.RunEval.run(
                 %{dataset: [], graders: "exact_match", subject: subject},
                 %{}
               )

      assert message =~ "unknown_subject"

      assert {:error, {:unknown_atom, ^module_name}} =
               Arbor.Common.SafeAtom.to_existing(module_name)
    end

    test "unknown grader fails clearly and never vacuously passes" do
      sample = %{"id" => "s1", "input" => "hello", "expected" => "hello"}

      assert {:error, message} =
               EvalPipeline.RunEval.run(
                 %{dataset: [sample], graders: "not_a_real_grader"},
                 %{}
               )

      assert message =~ "unknown_grader"
    end

    test "empty grader list fails closed" do
      assert {:error, message} =
               EvalPipeline.RunEval.run(%{dataset: [], graders: "  ,  "}, %{})

      assert message =~ "empty_grader_list"
    end

    test "resolves LLM and AI catalog names without module-path strings" do
      assert Arbor.LLM.eval_subject("llm") != nil
      assert "llm" in Arbor.LLM.eval_subject_names()
      assert Arbor.AI.eval_subject("embedding_retrieval") != nil
      assert "embedding_retrieval" in Arbor.AI.eval_subject_names()
      assert Arbor.AI.eval_grader("embedding_similarity") != nil
      assert "embedding_similarity" in Arbor.AI.eval_grader_names()

      # Action adapter accepts only closed symbolic names from public catalogs.
      assert {:error, message} =
               EvalPipeline.RunEval.run(
                 %{
                   dataset: [],
                   graders: "exact_match",
                   subject: "Elixir.Arbor.LLM.Eval.Subject"
                 },
                 %{}
               )

      assert message =~ "unknown_subject"
    end
  end

  describe "Aggregate" do
    test "computes metrics through Arbor.Eval" do
      results = [
        %{"id" => "a", "passed" => true, "scores" => [%{score: 1.0, passed: true}]},
        %{"id" => "b", "passed" => false, "scores" => [%{score: 0.0, passed: false}]}
      ]

      assert {:ok, %{metrics: metrics, passed: true, primary_metric: "accuracy"}} =
               EvalPipeline.Aggregate.run(%{results: results}, %{})

      assert metrics["accuracy"] == 0.5
      assert metrics["mean_score"] == 0.5
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

    test "preserves terminal report output while delegating formatting" do
      assert {:ok, %{report: report, format: "terminal"}} =
               EvalPipeline.Report.run(
                 %{results: @results, metrics: @metrics, format: "terminal"},
                 %{}
               )

      assert report == Arbor.Eval.format_report(@results, @metrics, "terminal")
    end

    test "preserves Markdown and JSON report output" do
      for format <- ["markdown", "json"] do
        assert {:ok, %{report: report, format: ^format}} =
                 EvalPipeline.Report.run(
                   %{results: @results, metrics: @metrics, format: format},
                   %{}
                 )

        assert report == Arbor.Eval.format_report(@results, @metrics, format)
      end
    end

    test "writes report with non-bang file ops after authorization" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "eval_report_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(tmp_dir) end)
      output_path = Path.join(tmp_dir, "nested/report.md")

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
    end

    test "security regression: denied write does not create directories or files" do
      Application.put_env(:arbor_actions, :security_module, DenySecurity)

      tmp_dir =
        Path.join(System.tmp_dir!(), "eval_report_deny_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(tmp_dir) end)
      nested = Path.join(tmp_dir, "nested")
      output_path = Path.join(nested, "report.md")

      refute File.exists?(tmp_dir)

      assert {:error, message} =
               EvalPipeline.Report.run(
                 %{
                   results: @results,
                   metrics: @metrics,
                   format: "markdown",
                   output_path: output_path
                 },
                 %{agent_id: "agent_eval"}
               )

      assert message =~ "unauthorized"
      refute File.exists?(tmp_dir)
      refute File.exists?(nested)
      refute File.exists?(output_path)
    end
  end

  describe "no orchestrator bridge" do
    test "EvalPipeline module does not export bridge/3 or bridge/4" do
      refute function_exported?(EvalPipeline, :bridge, 3)
      refute function_exported?(EvalPipeline, :bridge, 4)
    end
  end
end
