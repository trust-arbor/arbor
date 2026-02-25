defmodule Arbor.Actions.EvalPipeline do
  @moduledoc """
  Pipeline-level evaluation operations as Jido actions.

  These actions wrap the orchestrator's eval pipeline stages (dataset loading,
  evaluation execution, aggregation, persistence, reporting) so they can be
  invoked via `exec target="action"` in DOT pipelines instead of domain-specific
  handler types.

  Uses runtime bridges (`Code.ensure_loaded?` + `apply/3`) since
  `arbor_orchestrator` is a Standalone app.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `LoadDataset` | Load a JSONL dataset file |
  | `RunEval` | Execute evaluation on dataset samples |
  | `Aggregate` | Compute metrics over eval results |
  | `Persist` | Persist eval run to database |
  | `Report` | Generate formatted eval report |
  """

  @doc false
  def bridge(module, function, args, default \\ nil) do
    if Code.ensure_loaded?(module) do
      apply(module, function, args)
    else
      default
    end
  rescue
    e -> {:error, "Bridge call failed: #{Exception.message(e)}"}
  catch
    :exit, reason -> {:error, "Bridge process error: #{inspect(reason)}"}
  end

  # ============================================================================
  # LoadDataset
  # ============================================================================

  defmodule LoadDataset do
    @moduledoc """
    Load a JSONL dataset into the pipeline.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to JSONL dataset file |
    | `shuffle` | boolean | no | Randomize sample order |
    | `limit` | integer | no | Max samples to load |
    | `seed` | integer | no | Random seed for reproducibility |
    | `workdir` | string | no | Working directory for relative paths |
    """

    use Jido.Action,
      name: "eval_pipeline_load_dataset",
      description: "Load a JSONL dataset file for evaluation",
      category: "eval",
      tags: ["eval", "dataset", "load", "pipeline"],
      schema: [
        path: [type: :string, required: true, doc: "Path to JSONL dataset file"],
        shuffle: [type: :boolean, default: false, doc: "Randomize sample order"],
        limit: [type: :non_neg_integer, doc: "Max samples to load"],
        seed: [type: :non_neg_integer, doc: "Random seed for reproducibility"],
        workdir: [type: :string, doc: "Working directory for relative paths"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.EvalPipeline

    def taint_roles, do: %{path: :control, shuffle: :data, limit: :data, seed: :data}

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{path: params.path})

      workdir = params[:workdir] || "."

      resolved =
        if Path.type(params.path) == :absolute,
          do: params.path,
          else: Path.join(workdir, params.path)

      load_opts =
        []
        |> maybe_add(:shuffle, params[:shuffle])
        |> maybe_add(:seed, params[:seed])
        |> maybe_add(:limit, params[:limit])

      case EvalPipeline.bridge(Arbor.Orchestrator.Eval, :load_dataset, [resolved, load_opts]) do
        {:ok, samples} ->
          Actions.emit_completed(__MODULE__, %{count: length(samples)})
          {:ok, %{dataset: samples, count: length(samples), path: resolved}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to load dataset: #{inspect(reason)}"}

        nil ->
          {:error, "Eval module not available"}
      end
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, _key, false), do: opts
    defp maybe_add(opts, key, value), do: [{key, value} | opts]
  end

  # ============================================================================
  # RunEval
  # ============================================================================

  defmodule RunEval do
    @moduledoc """
    Execute evaluation on dataset samples.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `dataset` | list | yes | List of sample maps from LoadDataset |
    | `graders` | string | yes | Comma-separated grader names |
    | `subject` | string | no | Subject module name (default: passthrough) |
    | `model` | string | no | Model name for the subject |
    | `provider` | string | no | Provider name for the subject |
    """

    use Jido.Action,
      name: "eval_pipeline_run_eval",
      description: "Run evaluation graders on dataset samples",
      category: "eval",
      tags: ["eval", "run", "graders", "pipeline"],
      schema: [
        dataset: [type: {:list, :map}, required: true, doc: "List of sample maps"],
        graders: [type: :string, required: true, doc: "Comma-separated grader names"],
        subject: [type: :string, doc: "Subject module name"],
        model: [type: :string, doc: "Model name for subject"],
        provider: [type: :string, doc: "Provider name for subject"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.EvalPipeline

    def taint_roles do
      %{dataset: :data, graders: :control, subject: :control, model: :data, provider: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{sample_count: length(params.dataset)})

      grader_names =
        params.graders
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      subject = resolve_subject(params[:subject])

      subject_opts =
        []
        |> maybe_add(:model, params[:model])
        |> maybe_add(:provider, params[:provider])

      case EvalPipeline.bridge(Arbor.Orchestrator.Eval, :run_eval, [
             params.dataset,
             subject,
             grader_names,
             subject_opts
           ]) do
        results when is_list(results) ->
          passed = Enum.count(results, & &1["passed"])

          Actions.emit_completed(__MODULE__, %{count: length(results), passed: passed})
          {:ok, %{results: results, count: length(results), passed: passed}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Eval run failed: #{inspect(reason)}"}

        nil ->
          {:error, "Eval module not available"}
      end
    end

    @passthrough Arbor.Orchestrator.Eval.Subjects.Passthrough

    defp resolve_subject(nil), do: resolve_module(@passthrough)
    defp resolve_subject(""), do: resolve_module(@passthrough)

    defp resolve_subject(name) do
      module = Module.concat([name])
      Code.ensure_loaded(module)
      module
    rescue
      _ -> resolve_module(@passthrough)
    end

    defp resolve_module(mod) do
      if Code.ensure_loaded?(mod), do: mod, else: nil
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: [{key, value} | opts]
  end

  # ============================================================================
  # Aggregate
  # ============================================================================

  defmodule Aggregate do
    @moduledoc """
    Compute metrics over evaluation results.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `results` | list | yes | Eval results from RunEval |
    | `metrics` | string | no | Comma-separated metric names (default: "accuracy,mean_score") |
    | `threshold` | float | no | Minimum primary metric value to pass |
    """

    use Jido.Action,
      name: "eval_pipeline_aggregate",
      description: "Compute metrics over evaluation results",
      category: "eval",
      tags: ["eval", "aggregate", "metrics", "pipeline"],
      schema: [
        results: [type: {:list, :map}, required: true, doc: "Eval results from RunEval"],
        metrics: [type: :string, default: "accuracy,mean_score", doc: "Comma-separated metrics"],
        threshold: [type: :float, doc: "Minimum primary metric value to pass"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.EvalPipeline

    def taint_roles, do: %{results: :data, metrics: :control, threshold: :data}

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{result_count: length(params.results)})

      metric_names =
        (params[:metrics] || "accuracy,mean_score")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      metrics =
        Map.new(metric_names, fn name ->
          value =
            EvalPipeline.bridge(
              Arbor.Orchestrator.Eval.Metrics,
              :compute,
              [name, params.results, []],
              0.0
            )

          {name, value}
        end)

      primary_metric = List.first(metric_names)
      primary_value = Map.get(metrics, primary_metric, 0.0)

      passed =
        case params[:threshold] do
          nil -> true
          threshold -> primary_value >= threshold
        end

      Actions.emit_completed(__MODULE__, %{metrics: metrics, passed: passed})
      {:ok, %{metrics: metrics, passed: passed, primary_metric: primary_metric}}
    end
  end

  # ============================================================================
  # Persist
  # ============================================================================

  defmodule Persist do
    @moduledoc """
    Persist evaluation run results to the database.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `results` | list | yes | Eval results to persist |
    | `metrics` | map | no | Computed metrics |
    | `domain` | string | yes | Eval domain (coding, chat, heartbeat) |
    | `model` | string | no | Model name |
    | `provider` | string | no | Provider name |
    | `metadata` | map | no | Additional metadata |
    """

    use Jido.Action,
      name: "eval_pipeline_persist",
      description: "Persist eval run results to the database",
      category: "eval",
      tags: ["eval", "persist", "database", "pipeline"],
      schema: [
        results: [type: {:list, :map}, required: true, doc: "Eval results to persist"],
        metrics: [type: :map, default: %{}, doc: "Computed metrics"],
        domain: [type: :string, required: true, doc: "Eval domain"],
        model: [type: :string, default: "unknown", doc: "Model name"],
        provider: [type: :string, default: "unknown", doc: "Provider name"],
        metadata: [type: :map, default: %{}, doc: "Additional metadata"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.EvalPipeline

    def taint_roles do
      %{results: :data, metrics: :data, domain: :control, model: :data, provider: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{domain: params.domain})

      results = params.results
      metrics = params[:metrics] || %{}
      timing = compute_timing_metrics(results)
      all_metrics = Map.merge(metrics, timing)
      graders = extract_graders(results)

      run_id =
        EvalPipeline.bridge(Arbor.Orchestrator.Eval.PersistenceBridge, :generate_run_id, [
          params[:model] || "unknown",
          params.domain
        ])

      run_id = run_id || "run-#{System.system_time(:millisecond)}"

      run_attrs = %{
        id: run_id,
        domain: params.domain,
        model: params[:model] || "unknown",
        provider: params[:provider] || "unknown",
        dataset: "unknown",
        graders: graders,
        sample_count: length(results),
        duration_ms: Enum.sum(Enum.map(results, &get_duration/1)),
        metrics: all_metrics,
        config: %{},
        status: "completed",
        metadata: params[:metadata] || %{}
      }

      case EvalPipeline.bridge(Arbor.Orchestrator.Eval.PersistenceBridge, :create_run, [run_attrs]) do
        {:ok, _} ->
          persist_results(run_id, results)
          Actions.emit_completed(__MODULE__, %{run_id: run_id})
          {:ok, %{run_id: run_id, status: "persisted"}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Persist failed: #{inspect(reason)}"}

        nil ->
          {:error, "PersistenceBridge not available"}
      end
    end

    defp persist_results(run_id, results) do
      Enum.each(results, fn result ->
        result_attrs = %{
          id: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower),
          run_id: run_id,
          sample_id: get_field(result, "id", "unknown"),
          input: encode_field(get_field(result, "input")),
          expected: encode_field(get_field(result, "expected")),
          actual: encode_field(get_field(result, "actual")),
          passed: get_field(result, "passed") == true,
          scores: encode_scores(get_field(result, "scores")),
          duration_ms: get_duration(result),
          ttft_ms: get_field(result, "ttft_ms"),
          tokens_generated: get_field(result, "tokens_generated"),
          metadata: get_field(result, "metadata", %{})
        }

        EvalPipeline.bridge(Arbor.Orchestrator.Eval.PersistenceBridge, :save_result, [
          result_attrs
        ])
      end)
    end

    defp compute_timing_metrics([]), do: %{}

    defp compute_timing_metrics(results) do
      durations = Enum.map(results, &get_duration/1) |> Enum.filter(&(&1 > 0))

      if durations != [] do
        sorted = Enum.sort(durations)
        n = length(sorted)

        %{
          "avg_duration_ms" => Float.round(Enum.sum(sorted) / n, 1),
          "p50_duration_ms" => percentile(sorted, 50),
          "p95_duration_ms" => percentile(sorted, 95)
        }
      else
        %{}
      end
    end

    defp percentile(sorted, p) do
      n = length(sorted)
      idx = max(0, min(n - 1, round(n * p / 100.0) - 1))
      Enum.at(sorted, idx)
    end

    defp extract_graders(results) do
      results
      |> Enum.flat_map(fn result ->
        case get_field(result, "scores") do
          scores when is_list(scores) ->
            Enum.map(scores, fn
              %{grader: g} -> g
              %{"grader" => g} -> g
              _ -> nil
            end)

          _ ->
            []
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    defp get_duration(result) do
      get_field(result, "duration_ms") || get_field(result, :duration_ms) || 0
    end

    defp get_field(result, key, default \\ nil)

    defp get_field(result, key, default) when is_map(result) do
      Map.get(result, key) || Map.get(result, to_string(key), default)
    end

    defp get_field(_, _, default), do: default

    defp encode_field(value) when is_binary(value), do: value
    defp encode_field(value) when is_map(value), do: Jason.encode!(value)
    defp encode_field(value) when is_list(value), do: Jason.encode!(value)
    defp encode_field(nil), do: nil
    defp encode_field(value), do: inspect(value)

    defp encode_scores(scores) when is_list(scores) do
      scores
      |> Enum.with_index()
      |> Map.new(fn {score, idx} ->
        key =
          case score do
            %{grader: g} -> g
            %{"grader" => g} -> g
            _ -> "grader_#{idx}"
          end

        {key, score}
      end)
    end

    defp encode_scores(scores) when is_map(scores), do: scores
    defp encode_scores(_), do: %{}
  end

  # ============================================================================
  # Report
  # ============================================================================

  defmodule Report do
    @moduledoc """
    Generate a formatted evaluation report.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `results` | list | yes | Eval results |
    | `metrics` | map | no | Computed metrics |
    | `format` | string | no | Report format: "terminal", "json", "markdown" (default: "terminal") |
    | `output_path` | string | no | File path to write report (stores in result if omitted) |
    """

    use Jido.Action,
      name: "eval_pipeline_report",
      description: "Generate a formatted evaluation report",
      category: "eval",
      tags: ["eval", "report", "format", "pipeline"],
      schema: [
        results: [type: {:list, :map}, required: true, doc: "Eval results"],
        metrics: [type: :map, default: %{}, doc: "Computed metrics"],
        format: [type: :string, default: "terminal", doc: "Report format"],
        output_path: [type: :string, doc: "File path for report output"]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{results: :data, metrics: :data, format: :control, output_path: :control}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{format: params[:format] || "terminal"})

      results = params.results
      metrics = params[:metrics] || %{}
      format = params[:format] || "terminal"

      report = format_report(results, metrics, format)

      case params[:output_path] do
        nil ->
          Actions.emit_completed(__MODULE__, %{format: format})
          {:ok, %{report: report, format: format}}

        output_path ->
          File.mkdir_p!(Path.dirname(output_path))
          File.write!(output_path, report)
          Actions.emit_completed(__MODULE__, %{format: format, path: output_path})
          {:ok, %{report: report, format: format, path: output_path}}
      end
    end

    defp format_report(results, metrics, "json") do
      Jason.encode!(%{"results" => results, "metrics" => metrics}, pretty: true)
    end

    defp format_report(results, metrics, "markdown") do
      total = length(results)
      passed = Enum.count(results, & &1["passed"])
      failed = total - passed

      metrics_section =
        Enum.map_join(metrics, "\n", fn {k, v} ->
          "| #{k} | #{format_value(v)} |"
        end)

      failures =
        results
        |> Enum.reject(& &1["passed"])
        |> Enum.take(5)
        |> Enum.map_join("\n", fn r ->
          "- **#{r["id"]}**: expected=`#{truncate(r["expected"], 60)}` actual=`#{truncate(to_string(r["actual"]), 60)}`"
        end)

      """
      # Evaluation Report

      **Samples:** #{total} total, #{passed} passed, #{failed} failed

      ## Metrics

      | Metric | Value |
      |--------|-------|
      #{metrics_section}

      ## Top Failures

      #{if failures == "", do: "_None_", else: failures}
      """
    end

    defp format_report(results, metrics, _terminal) do
      total = length(results)
      passed = Enum.count(results, & &1["passed"])

      metrics_lines =
        Enum.map_join(metrics, "\n", fn {k, v} ->
          "  #{k}: #{format_value(v)}"
        end)

      failures =
        results
        |> Enum.reject(& &1["passed"])
        |> Enum.take(3)
        |> Enum.map_join("\n", fn r ->
          "  - #{r["id"]}: expected=#{truncate(r["expected"], 40)} actual=#{truncate(to_string(r["actual"]), 40)}"
        end)

      """
      === Evaluation Report ===
      Samples: #{total} | Passed: #{passed} | Failed: #{total - passed}

      Metrics:
      #{metrics_lines}
      #{if failures != "", do: "\nTop Failures:\n#{failures}", else: ""}
      """
    end

    defp format_value(v) when is_float(v), do: Float.round(v, 4)
    defp format_value(v), do: v

    defp truncate(nil, _), do: ""
    defp truncate(str, max) when byte_size(str) <= max, do: str
    defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."
  end
end
