defmodule Arbor.Orchestrator.Handlers.DriftDetectHandler do
  @moduledoc """
  Handler for drift.detect nodes that compare current LLM output
  against a saved baseline to detect model drift, prompt degradation,
  or API behavior changes.

  This is the AI equivalent of snapshot testing — catch silent behavioral
  regressions before they affect downstream consumers.

  Node attributes:
    - `baseline_path` - path to baseline file (JSON with baseline data)
    - `current_key` - context key with current output to compare (default: last_response)
    - `dimensions` - comma-separated metrics to compute: "length,keywords,structure" (default: all)
    - `threshold` - minimum similarity score to pass, 0.0-1.0 (default: 0.7)
    - `action` - what to do on drift: "warn" (default), "fail", "log"
    - `update_baseline` - "true" to update baseline with current output (default: false)
    - `result_key` - context key to store drift report (default: drift_report)

  Dimensions (each produces a 0.0-1.0 similarity score):
    - length: 1.0 - abs(len_a - len_b) / max(len_a, len_b, 1)
    - keywords: Jaccard similarity of word sets (words >= 3 chars, lowercased)
    - structure: Compare line counts, paragraph counts, code block counts
    - format: Check if output follows same structural pattern (has headers, lists, code blocks)

  Baseline file format (JSON):
    {
      "text": "the baseline output text",
      "timestamp": "ISO8601",
      "metadata": {"source_node": "...", "model": "..."},
      "stats": {"length": N, "word_count": N, "line_count": N}
    }

  Context updates written:
    - last_stage: node ID
    - {result_key}: JSON drift report
    - drift.{node_id}.score: overall similarity score (0.0-1.0)
    - drift.{node_id}.passed: true/false
    - drift.{node_id}.dimensions: JSON map of per-dimension scores
    - drift.{node_id}.action_taken: "pass", "warn", or "fail"
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  import Arbor.Orchestrator.Handlers.Helpers, only: [parse_csv: 1]

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @all_dimensions ["length", "keywords", "structure", "format"]

  @impl true
  def execute(node, context, _graph, opts) do
    baseline_path = Map.get(node.attrs, "baseline_path")
    current_key = Map.get(node.attrs, "current_key", "last_response")
    dimensions_str = Map.get(node.attrs, "dimensions", Enum.join(@all_dimensions, ","))
    threshold = parse_float(Map.get(node.attrs, "threshold", "0.7"), 0.7)
    action = Map.get(node.attrs, "action", "warn")
    update_baseline = Map.get(node.attrs, "update_baseline", "false") == "true"
    result_key = Map.get(node.attrs, "result_key", "drift_report")

    logs_root = Keyword.get(opts, :logs_root)

    case logs_root do
      nil -> :ok
      root -> File.mkdir_p!(Path.join(root, node.id))
    end

    cond do
      is_nil(baseline_path) or baseline_path == "" ->
        %Outcome{status: :fail, failure_reason: "drift.detect requires baseline_path attribute"}

      not File.exists?(baseline_path) ->
        # No baseline yet — create it from current output
        current_text = get_text(context, current_key)
        create_baseline(baseline_path, current_text)

        %Outcome{
          status: :success,
          context_updates: %{
            "last_stage" => node.id,
            result_key => "Baseline created (first run)",
            "drift.#{node.id}.score" => 1.0,
            "drift.#{node.id}.passed" => true,
            "drift.#{node.id}.dimensions" => Jason.encode!(%{}),
            "drift.#{node.id}.action_taken" => "pass"
          },
          notes: "Created baseline at #{baseline_path} (first run, no comparison)"
        }

      true ->
        compare_with_baseline(
          baseline_path,
          context,
          current_key,
          dimensions_str,
          threshold,
          action,
          update_baseline,
          result_key,
          node.id,
          logs_root
        )
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "DriftDetect handler error: #{Exception.message(e)}"
      }
  end

  defp compare_with_baseline(
         baseline_path,
         context,
         current_key,
         dimensions_str,
         threshold,
         action,
         update_baseline,
         result_key,
         node_id,
         logs_root
       ) do
    baseline = load_baseline(baseline_path)
    current_text = get_text(context, current_key)

    dimensions =
      parse_csv(dimensions_str) |> Enum.filter(&(&1 in @all_dimensions))

    dimensions = if dimensions == [], do: @all_dimensions, else: dimensions

    dim_scores = compute_dimensions(baseline["text"], current_text, dimensions)

    overall =
      if map_size(dim_scores) > 0 do
        dim_scores |> Map.values() |> Enum.sum() |> Kernel./(map_size(dim_scores))
      else
        1.0
      end

    passed = overall >= threshold

    report = %{
      "overall_score" => Float.round(overall, 4),
      "threshold" => threshold,
      "passed" => passed,
      "dimensions" => Enum.into(dim_scores, %{}, fn {k, v} -> {k, Float.round(v, 4)} end),
      "baseline_timestamp" => baseline["timestamp"],
      "comparison_timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    report_json = Jason.encode!(report, pretty: true)

    case logs_root do
      nil -> :ok
      root -> File.write!(Path.join([root, node_id, "drift_report.json"]), report_json)
    end

    if update_baseline do
      create_baseline(baseline_path, current_text)
    end

    action_taken =
      cond do
        passed -> "pass"
        action == "fail" -> "fail"
        true -> "warn"
      end

    context_updates = %{
      "last_stage" => node_id,
      result_key => report_json,
      "drift.#{node_id}.score" => Float.round(overall, 4),
      "drift.#{node_id}.passed" => passed,
      "drift.#{node_id}.dimensions" => Jason.encode!(dim_scores),
      "drift.#{node_id}.action_taken" => action_taken
    }

    notes =
      "Drift score: #{Float.round(overall, 4)} (threshold: #{threshold}) — #{action_taken}"

    if action_taken == "fail" do
      %Outcome{
        status: :fail,
        failure_reason:
          "Drift detected: score #{Float.round(overall, 4)} below threshold #{threshold}",
        context_updates: context_updates
      }
    else
      %Outcome{status: :success, context_updates: context_updates, notes: notes}
    end
  end

  defp get_text(context, key) do
    val = Context.get(context, key)
    if is_binary(val), do: val, else: to_string(val || "")
  end

  defp create_baseline(path, text) do
    File.mkdir_p!(Path.dirname(path))

    baseline = %{
      "text" => text,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "metadata" => %{},
      "stats" => %{
        "length" => String.length(text),
        "word_count" => text |> String.split(~r/\s+/) |> Enum.reject(&(&1 == "")) |> length(),
        "line_count" => text |> String.split("\n") |> length()
      }
    }

    File.write!(path, Jason.encode!(baseline, pretty: true))
  end

  defp load_baseline(path) do
    path |> File.read!() |> Jason.decode!()
  end

  defp compute_dimensions(baseline_text, current_text, dimensions) do
    Enum.into(dimensions, %{}, fn dim ->
      score = compute_dimension(dim, baseline_text, current_text)
      {dim, score}
    end)
  end

  defp compute_dimension("length", baseline, current) do
    a = String.length(baseline)
    b = String.length(current)
    max_len = max(a, b)
    if max_len == 0, do: 1.0, else: 1.0 - abs(a - b) / max_len
  end

  defp compute_dimension("keywords", baseline, current) do
    words_a = tokenize(baseline)
    words_b = tokenize(current)

    if MapSet.size(words_a) == 0 and MapSet.size(words_b) == 0 do
      1.0
    else
      intersection = MapSet.intersection(words_a, words_b) |> MapSet.size()
      union = MapSet.union(words_a, words_b) |> MapSet.size()
      if union == 0, do: 1.0, else: intersection / union
    end
  end

  defp compute_dimension("structure", baseline, current) do
    a_lines = baseline |> String.split("\n") |> length()
    b_lines = current |> String.split("\n") |> length()
    a_paras = baseline |> String.split(~r/\n\n+/) |> length()
    b_paras = current |> String.split(~r/\n\n+/) |> length()
    a_code = Regex.scan(~r/```/, baseline) |> length() |> div(2)
    b_code = Regex.scan(~r/```/, current) |> length() |> div(2)

    line_sim = ratio_similarity(a_lines, b_lines)
    para_sim = ratio_similarity(a_paras, b_paras)
    code_sim = ratio_similarity(a_code, b_code)

    (line_sim + para_sim + code_sim) / 3.0
  end

  defp compute_dimension("format", baseline, current) do
    features = [
      {~r/^#+\s/m, "headers"},
      {~r/^[-*]\s/m, "lists"},
      {~r/```/, "code_blocks"}
    ]

    matches =
      Enum.count(features, fn {pattern, _name} ->
        has_a = Regex.match?(pattern, baseline)
        has_b = Regex.match?(pattern, current)
        has_a == has_b
      end)

    matches / length(features)
  end

  defp compute_dimension(_unknown, _baseline, _current), do: 1.0

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[\s,.;:!?()\[\]{}<>"]+/)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> MapSet.new()
  end

  defp ratio_similarity(a, b) do
    max_val = max(a, b)
    if max_val == 0, do: 1.0, else: 1.0 - abs(a - b) / max_val
  end

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_float(_val, default), do: default

  @impl true
  def idempotency, do: :idempotent_with_key
end
