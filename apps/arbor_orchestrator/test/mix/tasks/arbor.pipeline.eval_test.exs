defmodule Mix.Tasks.Arbor.Pipeline.EvalTest do
  @moduledoc """
  Deterministic command-level coverage for mix arbor.pipeline.eval wiring:

  - CLI overrides become JSON-clean Engine `initial_values` (not context_updates)
  - dataset/report paths resolve under the selected workdir
  - a small JSONL pipeline runs through Engine with passthrough + exact_match
    (no external LLM)
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Mix.Tasks.Arbor.Pipeline.Eval, as: EvalTask

  # Real eval actions without Security capability grants. Production
  # ActionsExecutor authorizes every call; this keeps the Engine path
  # deterministic and free of external LLM / identity infrastructure.
  defmodule LocalEvalExecutor do
    @moduledoc false

    @actions %{
      "eval_pipeline.load_dataset" => Arbor.Actions.EvalPipeline.LoadDataset,
      "eval_pipeline.run_eval" => Arbor.Actions.EvalPipeline.RunEval,
      "eval_pipeline.aggregate" => Arbor.Actions.EvalPipeline.Aggregate,
      "eval_pipeline.report" => Arbor.Actions.EvalPipeline.Report
    }

    def execute(name, args, workdir, _opts) do
      case Map.fetch(@actions, name) do
        {:ok, module} ->
          params =
            args
            |> atomize_keys(module)
            |> Map.put_new(:workdir, workdir)

          case module.run(params, %{}) do
            {:ok, result} when is_map(result) ->
              {:ok, Jason.encode!(result)}

            {:ok, result} ->
              {:ok, to_string(result)}

            {:error, reason} ->
              {:error, if(is_binary(reason), do: reason, else: inspect(reason))}
          end

        :error ->
          {:error, "Unknown local eval action: #{name}"}
      end
    end

    defp atomize_keys(args, module) do
      known =
        module
        |> then(fn mod ->
          meta = mod.__action_metadata__()
          Keyword.keys(meta.schema || [])
        end)
        |> MapSet.new()

      Enum.reduce(args, %{}, fn {k, v}, acc ->
        atom =
          cond do
            is_atom(k) ->
              k

            is_binary(k) ->
              Enum.find(known, fn a -> Atom.to_string(a) == k end)
          end

        if atom, do: Map.put(acc, atom, v), else: acc
      end)
    end
  end

  describe "build_run_opts / initial_values" do
    test "uses initial_values rather than obsolete context_updates" do
      tmp = unique_tmp("eval_cli_opts")
      on_exit(fn -> File.rm_rf(tmp) end)

      opts =
        EvalTask.build_run_opts(
          dataset: "samples.jsonl",
          output: "out/report.md",
          workdir: tmp,
          limit: "2",
          shuffle: true,
          seed: "7"
        )

      assert Keyword.get(opts, :workdir) == Path.expand(tmp)
      refute Keyword.has_key?(opts, :context_updates)

      values = Keyword.fetch!(opts, :initial_values)
      assert values["eval.path"] == Path.expand("samples.jsonl", tmp)
      assert values["eval.output_path"] == Path.expand("out/report.md", tmp)
      assert values["eval.limit"] == 2
      assert values["eval.shuffle"] == true
      assert values["eval.seed"] == 7

      # JSON-clean scalars/maps only (Engine checkpoint boundary).
      assert {:ok, _} = Jason.encode(values)
    end

    test "omits initial_values when no overrides are provided" do
      opts = EvalTask.build_run_opts([])
      refute Keyword.has_key?(opts, :initial_values)
      assert is_binary(Keyword.get(opts, :workdir))
    end

    test "absolute dataset paths stay absolute" do
      abs =
        Path.join(System.tmp_dir!(), "abs_dataset_#{System.unique_integer([:positive])}.jsonl")

      opts = EvalTask.build_run_opts(dataset: abs, workdir: "/tmp/workdir_ignored")
      assert Keyword.fetch!(opts, :initial_values)["eval.path"] == Path.expand(abs)
    end
  end

  describe "extract_eval_summary" do
    test "reads stable exec action output keys" do
      result = %{
        context: %{
          "exec.run_eval.results" => [
            %{"id" => "s1", "passed" => true},
            %{"id" => "s2", "passed" => false}
          ],
          "exec.aggregate.metrics" => %{"accuracy" => 0.5}
        }
      }

      summary = EvalTask.extract_eval_summary(result)
      assert summary.total == 2
      assert summary.passed == 1
      assert summary.failed == 1
      assert summary.accuracy == 0.5
    end

    test "ignores obsolete eval handler keys" do
      result = %{
        context: %{
          "eval.results.run" => [%{"passed" => true}]
        }
      }

      assert EvalTask.extract_eval_summary(result) == nil
    end
  end

  describe "Engine passthrough + exact_match" do
    test "executes a small JSONL dataset and writes a report" do
      tmp = unique_tmp("eval_engine_passthrough")
      on_exit(fn -> File.rm_rf(tmp) end)

      File.write!(Path.join(tmp, "samples.jsonl"), """
      {"id":"s1","input":"hello","expected":"hello"}
      {"id":"s2","input":"world","expected":"earth"}
      """)

      report_path = Path.join(tmp, "report.md")
      dot_path = Path.join(tmp, "passthrough_eval.dot")

      File.write!(dot_path, """
      digraph PassthroughEval {
        start [shape=Mdiamond]
        load_dataset [
          type="exec",
          target="action",
          action="eval_pipeline.load_dataset",
          param.path="samples.jsonl",
          context_keys="eval.path,eval.limit"
        ]
        run_eval [
          type="exec",
          target="action",
          action="eval_pipeline.run_eval",
          param.subject="passthrough",
          param.graders="exact_match",
          context_keys="exec.load_dataset.dataset"
        ]
        aggregate [
          type="exec",
          target="action",
          action="eval_pipeline.aggregate",
          param.metrics="accuracy,mean_score",
          context_keys="exec.run_eval.results"
        ]
        report [
          type="exec",
          target="action",
          action="eval_pipeline.report",
          param.format="markdown",
          param.output_path="report.md",
          context_keys="exec.run_eval.results,exec.aggregate.metrics,eval.output_path"
        ]
        done [shape=Msquare]
        start -> load_dataset -> run_eval -> aggregate -> report -> done
      }
      """)

      run_opts =
        EvalTask.build_run_opts(
          dataset: "samples.jsonl",
          output: "report.md",
          workdir: tmp,
          limit: "2"
        )
        |> Keyword.delete(:on_event)
        |> Keyword.put(:actions_executor, LocalEvalExecutor)

      assert {:ok, result} = Arbor.Orchestrator.run_file(dot_path, run_opts)

      assert result.context["outcome"] != "fail",
             "pipeline failed: #{inspect(result.final_outcome)}"

      assert "load_dataset" in result.completed_nodes
      assert "run_eval" in result.completed_nodes
      assert "aggregate" in result.completed_nodes
      assert "report" in result.completed_nodes

      results = result.context["exec.run_eval.results"]
      assert is_list(results)
      assert length(results) == 2
      assert Enum.count(results, & &1["passed"]) == 1

      metrics = result.context["exec.aggregate.metrics"]
      assert is_map(metrics)
      assert metrics["accuracy"] == 0.5

      assert File.exists?(report_path)
      report = File.read!(report_path)
      assert is_binary(report) and byte_size(report) > 0

      summary = EvalTask.extract_eval_summary(result)
      assert summary.total == 2
      assert summary.passed == 1
      assert summary.failed == 1
      assert_in_delta summary.accuracy, 0.5, 0.0001

      # Context snapshot must remain JSON-serializable.
      assert {:ok, _} = Jason.encode(result.context)
    end
  end

  defp unique_tmp(prefix) do
    root =
      Path.join(
        Path.expand(System.tmp_dir!()),
        "#{prefix}_#{System.unique_integer([:positive])}_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end
end
