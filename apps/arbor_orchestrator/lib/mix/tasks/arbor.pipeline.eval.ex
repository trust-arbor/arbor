defmodule Mix.Tasks.Arbor.Pipeline.Eval do
  @shortdoc "Run an eval pipeline from a .dot file with a JSONL dataset"
  @moduledoc """
  Executes an evaluation pipeline defined in a .dot file against a JSONL dataset.

  Canonical eval pipelines use `type="exec" target="action"` nodes that invoke
  the registered `eval_pipeline.*` actions:

    - `eval_pipeline.load_dataset` — loads JSONL samples
    - `eval_pipeline.run_eval` — runs a symbolic subject + graders
    - `eval_pipeline.aggregate` — computes metrics
    - `eval_pipeline.persist` — optional durable run record
    - `eval_pipeline.report` — formats output

  Pipeline outputs land under stable exec node keys such as
  `exec.run_eval.results` and `exec.aggregate.metrics`.

  ## Usage

      mix arbor.pipeline.eval pipeline.dot
      mix arbor.pipeline.eval pipeline.dot --dataset samples.jsonl
      mix arbor.pipeline.eval pipeline.dot --dataset samples.jsonl --output report.md
      mix arbor.pipeline.eval pipeline.dot --workdir ./my_project --limit 100

  ## Options

    - `--dataset <path>` — Override dataset path (relative paths resolve under workdir)
    - `--output <path>` — Override report output path (relative paths resolve under workdir)
    - `--workdir <dir>` — Working directory for relative paths (default: current directory)
    - `--limit <n>` — Limit dataset to first N samples
    - `--shuffle` — Randomize sample order
    - `--seed <n>` — Seed for shuffle reproducibility

  CLI overrides are passed as JSON-clean Engine `initial_values` under the
  `eval.*` namespace (for example `eval.path`, `eval.output_path`). Pipelines
  consume them via `context_keys` leaf projection into action params.
  """

  use Mix.Task

  import Arbor.Orchestrator.Mix.Helpers

  @impl true
  def run(args) do
    {opts, files, _} =
      OptionParser.parse(args,
        strict: [
          dataset: :string,
          output: :string,
          workdir: :string,
          limit: :string,
          shuffle: :boolean,
          seed: :string
        ]
      )

    ensure_orchestrator_started()

    file = List.first(files)

    unless file do
      error(
        "Usage: mix arbor.pipeline.eval <file.dot> [--dataset path] [--output path] [--workdir dir]"
      )

      System.halt(1)
    end

    unless File.exists?(file) do
      error("File not found: #{file}")
      System.halt(1)
    end

    run_opts = build_run_opts(opts)

    info("\nRunning eval pipeline: #{file}")
    info(String.duplicate("-", 40))

    case Arbor.Orchestrator.run_file(file, run_opts) do
      {:ok, result} ->
        info("")
        success("Evaluation pipeline completed successfully!")
        info("  Nodes completed: #{length(result.completed_nodes)}")

        case extract_eval_summary(result) do
          nil -> :ok
          summary -> display_eval_summary(summary)
        end

      {:error, reason} ->
        error("\nEvaluation pipeline failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc false
  def build_run_opts(opts) when is_list(opts) do
    workdir = resolve_workdir(Keyword.get(opts, :workdir))

    run_opts =
      [
        workdir: workdir,
        on_event: &print_event/1
      ]

    initial_values = build_initial_values(opts, workdir)

    if map_size(initial_values) == 0 do
      run_opts
    else
      [{:initial_values, initial_values} | run_opts]
    end
  end

  @doc false
  def build_initial_values(opts, workdir) when is_list(opts) and is_binary(workdir) do
    %{}
    |> maybe_put_path("eval.path", Keyword.get(opts, :dataset), workdir)
    |> maybe_put_path("eval.output_path", Keyword.get(opts, :output), workdir)
    |> maybe_put_limit(Keyword.get(opts, :limit))
    |> maybe_put_shuffle(Keyword.get(opts, :shuffle))
    |> maybe_put_seed(Keyword.get(opts, :seed))
  end

  defp resolve_workdir(nil), do: File.cwd!()
  defp resolve_workdir(""), do: File.cwd!()
  defp resolve_workdir(workdir) when is_binary(workdir), do: Path.expand(workdir)

  defp maybe_put_path(values, _key, nil, _workdir), do: values
  defp maybe_put_path(values, _key, "", _workdir), do: values

  defp maybe_put_path(values, key, path, workdir) when is_binary(path) do
    Map.put(values, key, resolve_under_workdir(path, workdir))
  end

  defp resolve_under_workdir(path, workdir) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, workdir)
    end
  end

  defp maybe_put_limit(values, nil), do: values

  defp maybe_put_limit(values, limit_str) when is_binary(limit_str) do
    case Integer.parse(limit_str) do
      {n, _} when n >= 0 -> Map.put(values, "eval.limit", n)
      _ -> values
    end
  end

  defp maybe_put_shuffle(values, true), do: Map.put(values, "eval.shuffle", true)
  defp maybe_put_shuffle(values, _), do: values

  defp maybe_put_seed(values, nil), do: values

  defp maybe_put_seed(values, seed_str) when is_binary(seed_str) do
    case Integer.parse(seed_str) do
      {n, _} when n >= 0 -> Map.put(values, "eval.seed", n)
      _ -> values
    end
  end

  defp print_event(%{type: :stage_started, node_id: id}) do
    info("  ▶ #{id}")
  end

  defp print_event(%{type: :stage_completed, node_id: id, status: status}) do
    case status do
      :success -> Mix.shell().info([:green, "  ✓ #{id}"])
      :skipped -> Mix.shell().info([:yellow, "  ⊘ #{id} (skipped)"])
      other -> info("  • #{id} (#{other})")
    end
  end

  defp print_event(%{type: :stage_failed, node_id: id, error: error}) do
    Mix.shell().error([:red, "  ✗ #{id}: #{error}"])
  end

  defp print_event(%{type: :stage_retrying, node_id: id, attempt: attempt}) do
    warn("  ↻ #{id} (retry #{attempt})")
  end

  defp print_event(_), do: :ok

  @doc false
  def extract_eval_summary(result) do
    context = context_map(result)

    results =
      Enum.find_value(context, fn
        {"exec." <> rest, value} when is_list(value) ->
          if String.ends_with?(rest, ".results"), do: value, else: nil

        _ ->
          nil
      end)

    metrics =
      Enum.find_value(context, fn
        {"exec." <> rest, value} when is_map(value) ->
          if String.ends_with?(rest, ".metrics"), do: value, else: nil

        _ ->
          nil
      end)

    case results do
      nil ->
        nil

      list ->
        total = length(list)
        passed = Enum.count(list, &result_passed?/1)
        failed = total - passed

        accuracy =
          cond do
            is_map(metrics) and is_number(Map.get(metrics, "accuracy")) ->
              Map.get(metrics, "accuracy")

            is_map(metrics) and is_number(Map.get(metrics, :accuracy)) ->
              Map.get(metrics, :accuracy)

            total > 0 ->
              passed / total

            true ->
              0.0
          end

        %{
          total: total,
          passed: passed,
          failed: failed,
          accuracy: accuracy * 1.0
        }
    end
  end

  defp context_map(%{context: %{} = context}), do: context
  defp context_map(%{"context" => %{} = context}), do: context
  defp context_map(_), do: %{}

  defp result_passed?(%{"passed" => true}), do: true
  defp result_passed?(%{passed: true}), do: true
  defp result_passed?(_), do: false

  defp display_eval_summary(%{total: total, passed: passed, failed: failed, accuracy: accuracy}) do
    info("")
    info("  Evaluation Summary:")
    info("    Total samples: #{total}")
    Mix.shell().info([:green, "    Passed: #{passed}"])

    if failed > 0 do
      Mix.shell().error([:red, "    Failed: #{failed}"])
    end

    accuracy_pct = Float.round(accuracy * 100, 2)
    info("    Accuracy: #{accuracy_pct}%")
  end
end
