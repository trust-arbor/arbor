defmodule Arbor.Actions.EvalPipeline do
  @moduledoc """
  Pipeline-level evaluation operations as Jido actions.

  These actions compose public lower-level facades (`Arbor.Eval`, `Arbor.LLM`,
  `Arbor.AI`, `Arbor.Persistence`) so they can be invoked via
  `exec target="action"` in DOT pipelines.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `LoadDataset` | Load a JSONL dataset file |
  | `RunEval` | Execute evaluation on dataset samples |
  | `Aggregate` | Compute metrics over eval results |
  | `Persist` | Persist eval run to database |
  | `Report` | Generate formatted eval report |
  """

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
    alias Arbor.Actions.File, as: FileActions
    alias Arbor.Actions.EvalPipeline

    def taint_roles, do: %{path: :control, shuffle: :data, limit: :data, seed: :data}

    def effect_class, do: :read

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, %{path: params.path})

      workdir = params[:workdir] || "."
      resolved = EvalPipeline.resolve_path(params.path, workdir)

      load_opts =
        []
        |> maybe_add(:shuffle, params[:shuffle])
        |> maybe_add(:seed, params[:seed])
        |> maybe_add(:limit, params[:limit])

      with {:ok, authorized_path} <- FileActions.authorize_file_op(context, resolved, :read),
           {:ok, samples} <- Arbor.Eval.load_dataset(authorized_path, load_opts) do
        Actions.emit_completed(__MODULE__, %{count: length(samples)})
        {:ok, %{dataset: samples, count: length(samples), path: authorized_path}}
      else
        {:error, {:unauthorized, _} = reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to load dataset: #{inspect(reason)}"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to load dataset: #{inspect(reason)}"}
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

    Subject and grader names are resolved only through closed public catalogs
    (`Arbor.Eval`, `Arbor.LLM`, `Arbor.AI`). Caller strings are never interned
    as atoms or resolved as module names.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `dataset` | list | yes | List of sample maps from LoadDataset |
    | `graders` | string | yes | Comma-separated grader names |
    | `subject` | string | no | Symbolic subject name (default: passthrough) |
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
        subject: [type: :string, doc: "Symbolic subject name"],
        model: [type: :string, doc: "Model name for subject"],
        provider: [type: :string, doc: "Provider name for subject"]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{dataset: :data, graders: :control, subject: :control, model: :data, provider: :data}
    end

    # Provider-backed and AI subjects may egress; default gated tier is acceptable.
    def effect_class, do: :network_egress

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{sample_count: length(params.dataset)})

      with {:ok, subject_module} <- resolve_subject(params[:subject]),
           {:ok, grader_modules} <- resolve_graders(params.graders) do
        subject_opts =
          []
          |> maybe_add(:model, params[:model])
          |> maybe_add(:provider, params[:provider])

        results =
          Arbor.Eval.run_eval_modules(
            params.dataset,
            subject_module,
            grader_modules,
            subject_opts
          )

        passed = Enum.count(results, & &1["passed"])

        Actions.emit_completed(__MODULE__, %{count: length(results), passed: passed})
        {:ok, %{results: results, count: length(results), passed: passed}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Eval run failed: #{inspect(reason)}"}
      end
    end

    # Omitted/blank subject defaults to deterministic passthrough.
    defp resolve_subject(nil), do: resolve_subject("passthrough")
    defp resolve_subject(""), do: resolve_subject("passthrough")

    defp resolve_subject(name) when is_binary(name) do
      cond do
        module = Arbor.Eval.subject(name) ->
          {:ok, module}

        module = Arbor.LLM.eval_subject(name) ->
          {:ok, module}

        module = Arbor.AI.eval_subject(name) ->
          {:ok, module}

        true ->
          {:error, {:unknown_subject, name}}
      end
    end

    defp resolve_subject(other), do: {:error, {:unknown_subject, other}}

    defp resolve_graders(graders) when is_binary(graders) do
      names =
        graders
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      if names == [] do
        {:error, :empty_grader_list}
      else
        resolve_grader_names(names, [])
      end
    end

    defp resolve_graders(_), do: {:error, :empty_grader_list}

    defp resolve_grader_names([], modules), do: {:ok, Enum.reverse(modules)}

    defp resolve_grader_names([name | rest], modules) do
      cond do
        module = Arbor.Eval.grader(name) ->
          resolve_grader_names(rest, [module | modules])

        module = Arbor.AI.eval_grader(name) ->
          resolve_grader_names(rest, [module | modules])

        true ->
          {:error, {:unknown_grader, name}}
      end
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

    def taint_roles, do: %{results: :data, metrics: :control, threshold: :data}

    def effect_class, do: :read

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{result_count: length(params.results)})

      metric_names =
        (params[:metrics] || "accuracy,mean_score")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      metrics =
        Map.new(metric_names, fn name ->
          {name, Arbor.Eval.compute_metric(name, params.results, [])}
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

    def taint_roles do
      %{results: :data, metrics: :data, domain: :control, model: :data, provider: :data}
    end

    def effect_class, do: :local_write

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, %{domain: params.domain})

      results = params.results
      metrics = params[:metrics] || %{}
      timing = compute_timing_metrics(results)
      all_metrics = Map.merge(metrics, timing)
      graders = extract_graders(results)

      run_id =
        Arbor.Persistence.generate_eval_run_id(
          params[:model] || "unknown",
          params.domain
        )

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

      case Arbor.Persistence.create_eval_run(run_attrs) do
        {:ok, _} ->
          persist_results(run_id, results)
          Actions.emit_completed(__MODULE__, %{run_id: run_id})
          {:ok, %{run_id: run_id, status: "persisted"}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Persist failed: #{inspect(reason)}"}
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

        Arbor.Persistence.save_eval_result(result_attrs)
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
    | `workdir` | string | no | Working directory for relative output paths |
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
        output_path: [type: :string, doc: "File path for report output"],
        workdir: [type: :string, doc: "Working directory for relative output paths"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.File, as: FileActions
    alias Arbor.Actions.EvalPipeline

    def taint_roles do
      %{results: :data, metrics: :data, format: :control, output_path: :control}
    end

    def effect_class, do: :local_write

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, %{format: params[:format] || "terminal"})

      results = params.results
      metrics = params[:metrics] || %{}
      format = params[:format] || "terminal"
      report = Arbor.Eval.format_report(results, metrics, format)

      case params[:output_path] do
        nil ->
          Actions.emit_completed(__MODULE__, %{format: format})
          {:ok, %{report: report, format: format}}

        output_path ->
          write_report(context, output_path, params[:workdir], report, format)
      end
    end

    defp write_report(context, output_path, workdir, report, format) do
      workdir = workdir || "."
      resolved = EvalPipeline.resolve_path(output_path, workdir)

      with {:ok, authorized_path} <- FileActions.authorize_file_op(context, resolved, :write),
           :ok <- ensure_parent_dir(authorized_path),
           :ok <- File.write(authorized_path, report) do
        Actions.emit_completed(__MODULE__, %{format: format, path: authorized_path})
        {:ok, %{report: report, format: format, path: authorized_path}}
      else
        {:error, {:unauthorized, _} = reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to write report: #{inspect(reason)}"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to write report: #{inspect(reason)}"}
      end
    end

    defp ensure_parent_dir(path) do
      case File.mkdir_p(Path.dirname(path)) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def resolve_path(path, workdir) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workdir || ".", path)
    end
  end
end
