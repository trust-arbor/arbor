defmodule Arbor.Orchestrator.Pipelines.EvalDotMigrationTest do
  @moduledoc """
  Regression: tracked eval DOT specs must not retain retired domain handler
  types (`eval.dataset`, `eval.run`, …) or unimplemented `eval_v3.*` sketches.
  Business stages use `type="exec" target="action" action="eval_pipeline.*"`.

  Also exercises the parsed coding-eval graph through ExecHandler so namespaced
  pipeline outputs reach RunEval under flat schema parameter names.
  """
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Handlers.ExecHandler

  @specs_dir Path.expand("../../../../specs/pipelines", __DIR__)

  # Retired dedicated eval handler types (pre-action extraction).
  @retired_eval_types ~w(
    eval.dataset
    eval.run
    eval.aggregate
    eval.report
    eval.persist
  )

  # Sketch-only node types never backed by a handler or mix task.
  @unimplemented_eval_v3_types ~w(
    eval_v3.setup
    eval_v3.seed_bug
    eval_v3.heartbeat
    eval_v3.metrics
    eval_v3.cleanup
  )

  @coding_graders ~w(compile_check functional_test code_quality)

  defmodule CaptureExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:captured_execute, name, args, workdir, opts})
      {:ok, Jason.encode!(%{"results" => [], "count" => 0, "passed" => 0})}
    end
  end

  test "tracked pipeline specs do not retain retired eval.* handler types" do
    offenders = find_type_offenders(@retired_eval_types)

    assert offenders == [],
           "retired eval.* node types still present:\n" <> format_offenders(offenders)
  end

  test "tracked pipeline specs do not retain unimplemented eval_v3.* sketches" do
    offenders = find_type_offenders(@unimplemented_eval_v3_types)

    assert offenders == [],
           "unimplemented eval_v3.* node types still present:\n" <> format_offenders(offenders)
  end

  test "abandoned eval-v3-trial.dot is not shipped in tracked specs" do
    path = Path.join(@specs_dir, "eval-v3-trial.dot")
    refute File.exists?(path), "eval-v3-trial.dot was abandoned; do not reintroduce it"
  end

  test "coding-eval.dot is the canonical eval_pipeline action graph" do
    path = Path.join(@specs_dir, "coding-eval.dot")
    assert File.exists?(path)
    source = File.read!(path)

    assert source =~ ~s(type="exec")
    assert source =~ ~s(target="action")
    assert source =~ ~s(action="eval_pipeline.load_dataset")
    assert source =~ ~s(action="eval_pipeline.run_eval")
    assert source =~ ~s(action="eval_pipeline.aggregate")
    assert source =~ ~s(action="eval_pipeline.report")
    assert source =~ ~s(param.subject="llm")
    refute source =~ "Arbor.Orchestrator.Eval"

    for grader <- @coding_graders do
      assert source =~ grader,
             "coding-eval.dot must retain grader #{inspect(grader)}"
    end
  end

  test "coding-eval.dot parsed path feeds RunEval dataset under flat schema params" do
    path = Path.join(@specs_dir, "coding-eval.dot")
    assert {:ok, graph} = Parser.parse_file(path)

    run_eval = Map.fetch!(graph.nodes, "run_eval")
    assert run_eval.attrs["type"] == "exec"
    assert run_eval.attrs["target"] == "action"
    assert run_eval.attrs["action"] == "eval_pipeline.run_eval"
    assert run_eval.attrs["context_keys"] == "exec.load_dataset.dataset"
    assert run_eval.attrs["param.subject"] == "llm"

    load_dataset = Map.fetch!(graph.nodes, "load_dataset")

    assert load_dataset.attrs["context_keys"] ==
             "eval.path,eval.limit,eval.shuffle,eval.seed"

    graders =
      run_eval.attrs["param.graders"]
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    assert graders == @coding_graders

    aggregate = Map.fetch!(graph.nodes, "aggregate")
    assert aggregate.attrs["action"] == "eval_pipeline.aggregate"
    assert aggregate.attrs["context_keys"] == "exec.run_eval.results"

    report = Map.fetch!(graph.nodes, "report")
    assert report.attrs["action"] == "eval_pipeline.report"
    assert report.attrs["context_keys"] =~ "exec.run_eval.results"
    assert report.attrs["context_keys"] =~ "exec.aggregate.metrics"

    dataset = [%{"id" => "coding-1", "input" => "defmodule Demo, do: :ok"}]

    context = %Context{
      values: %{"exec.load_dataset.dataset" => dataset}
    }

    outcome =
      ExecHandler.execute(
        run_eval,
        context,
        graph,
        agent_id: "agent_eval_migration",
        actions_executor: CaptureExecutor
      )

    assert outcome.status == :success

    assert_received {:captured_execute, "eval_pipeline.run_eval", args, _workdir, _opts}
    assert Map.fetch!(args, "dataset") == dataset
    refute Map.has_key?(args, "exec.load_dataset.dataset")
    assert Map.fetch!(args, "graders") == "compile_check,functional_test,code_quality"
    assert Map.fetch!(args, "subject") == "llm"

    # Schema allowlist: flat string keys must be the ones ActionsExecutor can atomize.
    for required <- ~w(dataset graders subject) do
      assert is_binary(required)
      assert Map.has_key?(args, required)
      refute String.contains?(required, ".")
    end
  end

  test "coding-eval aggregate/report receive flat results and metrics params" do
    path = Path.join(@specs_dir, "coding-eval.dot")
    assert {:ok, graph} = Parser.parse_file(path)

    results = [%{"id" => "coding-1", "passed" => true}]
    metrics = %{"accuracy" => 1.0}

    aggregate = Map.fetch!(graph.nodes, "aggregate")

    agg_outcome =
      ExecHandler.execute(
        aggregate,
        %Context{values: %{"exec.run_eval.results" => results}},
        graph,
        agent_id: "agent_eval_migration",
        actions_executor: CaptureExecutor
      )

    assert agg_outcome.status == :success
    assert_received {:captured_execute, "eval_pipeline.aggregate", agg_args, _, _}
    assert Map.fetch!(agg_args, "results") == results
    refute Map.has_key?(agg_args, "exec.run_eval.results")

    report = Map.fetch!(graph.nodes, "report")

    report_outcome =
      ExecHandler.execute(
        report,
        %Context{
          values: %{
            "exec.run_eval.results" => results,
            "exec.aggregate.metrics" => metrics
          }
        },
        graph,
        agent_id: "agent_eval_migration",
        actions_executor: CaptureExecutor
      )

    assert report_outcome.status == :success
    assert_received {:captured_execute, "eval_pipeline.report", report_args, _, _}
    assert Map.fetch!(report_args, "results") == results
    assert Map.fetch!(report_args, "metrics") == metrics
    refute Map.has_key?(report_args, "exec.run_eval.results")
    refute Map.has_key?(report_args, "exec.aggregate.metrics")
  end

  defp find_type_offenders(types) do
    for path <- pipeline_dot_files(),
        source = File.read!(path),
        type <- types,
        source =~ type_attr_pattern(type) do
      {Path.relative_to(path, @specs_dir), type}
    end
  end

  defp pipeline_dot_files do
    Path.wildcard(Path.join(@specs_dir, "**/*.dot"))
  end

  defp type_attr_pattern(type) do
    # Match type="eval.run" / type='eval.run' attribute forms in DOT sources.
    ~r/type\s*=\s*["']#{Regex.escape(type)}["']/
  end

  defp format_offenders(offenders) do
    Enum.map_join(offenders, "\n", fn {file, type} -> "  #{file}: type=#{type}" end)
  end
end
