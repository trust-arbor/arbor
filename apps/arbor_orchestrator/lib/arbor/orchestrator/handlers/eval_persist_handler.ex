defmodule Arbor.Orchestrator.Handlers.EvalPersistHandler do
  @moduledoc """
  Handler that persists eval run results to Postgres via PersistenceBridge.

  Reads eval results and metrics from context, computes timing aggregates,
  and writes everything to the database (or falls back to JSON files).

  Node attributes:
    - `domain` — eval domain: "coding", "chat", "heartbeat", "embedding" (required)
    - `model` — model identifier (reads from context `eval.model` if omitted)
    - `provider` — provider identifier (reads from context `eval.provider` if omitted)
    - `results_key` — context key for results (auto-detected from upstream eval.run nodes)
    - `metrics_key` — context key for metrics (auto-detected from upstream eval.aggregate)
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}
  alias Arbor.Orchestrator.Eval.PersistenceBridge

  @impl true
  def execute(node, context, _graph, _opts) do
    domain = Map.get(node.attrs, "domain")

    unless domain do
      raise "eval.persist requires 'domain' attribute"
    end

    model =
      Map.get(node.attrs, "model") ||
        Context.get(context, "eval.model") ||
        "unknown"

    provider =
      Map.get(node.attrs, "provider") ||
        Context.get(context, "eval.provider") ||
        "unknown"

    dataset =
      Context.get(context, "eval.dataset.path") ||
        Context.get(context, "eval.dataset_path") ||
        "unknown"

    # Find results — try explicit key, then scan for eval.results.* keys
    results = find_results(node, context)
    metrics = find_metrics(node, context)
    graders = extract_graders(results)

    run_id = PersistenceBridge.generate_run_id(model, domain)

    # Compute timing aggregates from per-result timing data
    timing_metrics = compute_timing_metrics(results)
    all_metrics = Map.merge(metrics, timing_metrics)

    run_attrs = %{
      id: run_id,
      domain: domain,
      model: model,
      provider: provider,
      dataset: dataset,
      graders: graders,
      sample_count: length(results),
      duration_ms: Enum.sum(Enum.map(results, &get_duration/1)),
      metrics: all_metrics,
      config: %{},
      status: "completed",
      metadata: %{}
    }

    case PersistenceBridge.create_run(run_attrs) do
      {:ok, _} ->
        persist_results(run_id, results)

        %Outcome{
          status: :success,
          notes: "Persisted run #{run_id} (#{length(results)} results, domain=#{domain})",
          context_updates: %{
            "eval.persist.run_id" => run_id,
            "eval.persist.status" => "completed"
          }
        }

      {:error, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: "eval.persist error: #{inspect(reason)}"
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "eval.persist error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :side_effecting

  # --- Result discovery ---

  defp find_results(node, context) do
    key = Map.get(node.attrs, "results_key")

    if key do
      Context.get(context, key, [])
    else
      # Scan context for eval.results.* keys
      context
      |> Context.snapshot()
      |> Enum.filter(fn {k, _} -> String.starts_with?(to_string(k), "eval.results.") end)
      |> Enum.flat_map(fn {_, v} -> if is_list(v), do: v, else: [] end)
    end
  end

  defp find_metrics(node, context) do
    key = Map.get(node.attrs, "metrics_key")

    if key do
      Context.get(context, key, %{})
    else
      # Scan for eval.metrics.* keys
      context
      |> Context.snapshot()
      |> Enum.filter(fn {k, _} -> String.starts_with?(to_string(k), "eval.metrics.") end)
      |> Enum.reduce(%{}, fn {_, v}, acc ->
        if is_map(v), do: Map.merge(acc, v), else: acc
      end)
    end
  end

  # --- Timing aggregates ---

  defp compute_timing_metrics([]), do: %{}

  defp compute_timing_metrics(results) do
    durations = Enum.map(results, &get_duration/1) |> Enum.filter(&(&1 > 0))
    ttfts = Enum.map(results, &get_ttft/1) |> Enum.reject(&is_nil/1) |> Enum.filter(&(&1 > 0))
    tokens = Enum.map(results, &get_tokens/1) |> Enum.reject(&is_nil/1)

    base = %{}

    base =
      if durations != [] do
        sorted = Enum.sort(durations)
        n = length(sorted)

        base
        |> Map.put("avg_duration_ms", Float.round(Enum.sum(sorted) / n, 1))
        |> Map.put("p50_duration_ms", percentile(sorted, 50))
        |> Map.put("p95_duration_ms", percentile(sorted, 95))
        |> Map.put("p99_duration_ms", percentile(sorted, 99))
      else
        base
      end

    base =
      if ttfts != [] do
        Map.put(base, "avg_ttft_ms", Float.round(Enum.sum(ttfts) / length(ttfts), 1))
      else
        base
      end

    if tokens != [] and durations != [] do
      total_tokens = Enum.sum(tokens)
      total_secs = Enum.sum(durations) / 1000.0

      if total_secs > 0 do
        Map.put(base, "avg_tokens_per_second", Float.round(total_tokens / total_secs, 1))
      else
        base
      end
    else
      base
    end
  end

  defp percentile(sorted, p) do
    n = length(sorted)
    idx = max(0, min(n - 1, round(n * p / 100.0) - 1))
    Enum.at(sorted, idx)
  end

  # --- Result persistence ---

  defp persist_results(run_id, results) do
    result_attrs =
      Enum.map(results, fn result ->
        %{
          id: generate_result_id(),
          run_id: run_id,
          sample_id: get_in_result(result, ["id"]) || "unknown",
          input: encode_field(get_in_result(result, ["input"])),
          expected: encode_field(get_in_result(result, ["expected"])),
          actual: encode_field(get_in_result(result, ["actual"])),
          passed: get_in_result(result, ["passed"]) == true,
          scores: encode_scores(get_in_result(result, ["scores"])),
          duration_ms: get_duration(result),
          ttft_ms: get_ttft(result),
          tokens_generated: get_tokens(result),
          metadata: get_in_result(result, ["metadata"]) || %{}
        }
      end)

    Enum.each(result_attrs, &PersistenceBridge.save_result/1)
  end

  # --- Helpers ---

  defp extract_graders(results) do
    results
    |> Enum.flat_map(fn result ->
      case get_in_result(result, ["scores"]) do
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
    get_in_result(result, ["duration_ms"]) ||
      get_in_result(result, [:duration_ms]) ||
      0
  end

  defp get_ttft(result) do
    get_in_result(result, ["ttft_ms"]) ||
      get_in_result(result, [:ttft_ms])
  end

  defp get_tokens(result) do
    get_in_result(result, ["tokens_generated"]) ||
      get_in_result(result, [:tokens_generated])
  end

  defp get_in_result(result, keys) when is_map(result) do
    Enum.find_value(keys, fn key -> Map.get(result, key) end)
  end

  defp get_in_result(_, _), do: nil

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

  defp generate_result_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
