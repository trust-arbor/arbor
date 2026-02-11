defmodule Mix.Tasks.Arbor.Pipeline.Eval do
  @shortdoc "Run an eval pipeline from a .dot file with a JSONL dataset"
  @moduledoc """
  Executes an evaluation pipeline defined in a .dot file against a JSONL dataset.

  An eval pipeline orchestrates dataset loading, execution against a subject system,
  grading results, and aggregating metrics. The pipeline is defined as a directed graph
  where nodes specify operations like:

    - `eval.dataset` — loads JSONL samples
    - `eval.run` — applies graders to results
    - `eval.aggregate` — computes metrics
    - `eval.report` — formats output

  ## Usage

      mix arbor.pipeline.eval pipeline.dot
      mix arbor.pipeline.eval pipeline.dot --dataset samples.jsonl
      mix arbor.pipeline.eval pipeline.dot --dataset samples.jsonl --output report.md
      mix arbor.pipeline.eval pipeline.dot --workdir ./my_project --limit 100

  ## Options

    - `--dataset <path>` — Override dataset path from pipeline (relative to workdir)
    - `--output <path>` — Override output path from pipeline
    - `--workdir <dir>` — Working directory for relative paths (default: current directory)
    - `--limit <n>` — Limit dataset to first N samples
    - `--shuffle` — Randomize sample order
    - `--seed <n>` — Seed for shuffle reproducibility
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

        # Try to extract and display eval summary if available
        case extract_eval_summary(result) do
          nil -> :ok
          summary -> display_eval_summary(summary)
        end

      {:error, reason} ->
        error("\nEvaluation pipeline failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp build_run_opts(opts) do
    run_opts = []

    # Add workdir if provided
    run_opts =
      case Keyword.get(opts, :workdir) do
        nil -> run_opts
        workdir -> [{:workdir, workdir} | run_opts]
      end

    # Add on_event callback for progress display
    run_opts = [{:on_event, &print_event/1} | run_opts]

    # Add context updates for dataset/output overrides
    context_updates =
      []
      |> maybe_add_dataset_override(Keyword.get(opts, :dataset))
      |> maybe_add_output_override(Keyword.get(opts, :output))
      |> maybe_add_limit_override(Keyword.get(opts, :limit))
      |> maybe_add_shuffle_override(Keyword.get(opts, :shuffle))
      |> maybe_add_seed_override(Keyword.get(opts, :seed))

    case context_updates do
      [] -> run_opts
      updates -> [{:context_updates, updates} | run_opts]
    end
  end

  defp maybe_add_dataset_override(updates, nil), do: updates

  defp maybe_add_dataset_override(updates, dataset_path) do
    # Store override for eval.dataset handler to use
    [{:eval_dataset_override, dataset_path} | updates]
  end

  defp maybe_add_output_override(updates, nil), do: updates

  defp maybe_add_output_override(updates, output_path) do
    # Store override for eval.report handler to use
    [{:eval_output_override, output_path} | updates]
  end

  defp maybe_add_limit_override(updates, nil), do: updates

  defp maybe_add_limit_override(updates, limit_str) do
    case Integer.parse(limit_str) do
      {n, _} -> [{:eval_limit, n} | updates]
      :error -> updates
    end
  end

  defp maybe_add_shuffle_override(updates, nil), do: updates
  defp maybe_add_shuffle_override(updates, false), do: updates

  defp maybe_add_shuffle_override(updates, true) do
    [{:eval_shuffle, true} | updates]
  end

  defp maybe_add_seed_override(updates, nil), do: updates

  defp maybe_add_seed_override(updates, seed_str) do
    case Integer.parse(seed_str) do
      {n, _} -> [{:eval_seed, n} | updates]
      :error -> updates
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

  defp extract_eval_summary(result) do
    # Look for eval.run results in context
    context = result.context || %{}

    # Find the first eval.run result set
    eval_results =
      Enum.find_value(context, fn
        {"eval.results." <> _rest, results} when is_list(results) -> results
        _ -> nil
      end)

    case eval_results do
      nil ->
        nil

      results ->
        total = length(results)
        passed = Enum.count(results, & &1["passed"])
        failed = total - passed

        %{
          total: total,
          passed: passed,
          failed: failed,
          accuracy: if(total > 0, do: passed / total, else: 0.0)
        }
    end
  end

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
