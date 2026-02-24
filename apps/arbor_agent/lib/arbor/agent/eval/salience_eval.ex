defmodule Arbor.Agent.Eval.SalienceEval do
  @moduledoc """
  A/B comparison eval for salience-modulated compaction.

  Replays a salience-labeled transcript through ContextCompactor twice:
  - **Group A** (baseline): current behavior — `detail_level` only
  - **Group B** (salience): `effective_detail` with `compute_salience/2`

  Measures differential retention of high- vs low-salience messages.

  ## Usage

      {:ok, results} = SalienceEval.run(effective_window: 2000)
  """

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.{CompactionEval, SalienceTranscript}

  require Logger

  @default_checkpoints [0.50, 0.75, 1.0]

  @doc """
  Run the salience eval.

  ## Options

    * `:effective_window` - Window size for compaction (default: 2000)
    * `:checkpoints` - Fractional positions to measure at (default: [0.50, 0.75, 1.0])
    * `:persist` - Persist results to database (default: true)
    * `:tag` - Experiment tag
  """
  def run(opts \\ []) do
    window = Keyword.get(opts, :effective_window, 2000)
    checkpoints = Keyword.get(opts, :checkpoints, @default_checkpoints)
    persist = Keyword.get(opts, :persist, true)
    tag = Keyword.get(opts, :tag)

    # 1. Generate transcript
    transcript = SalienceTranscript.generate()
    messages = CompactionEval.reconstruct_messages(transcript)

    # 2. Extract ground truth partitioned by salience label
    {high_facts, low_facts} = extract_salience_ground_truth(transcript)

    # 3. Replay Group A (baseline — no salience)
    Logger.info("[SalienceEval] Running Group A (baseline, window=#{window})")
    {_comp_a, snapshots_a} = replay_baseline(messages, window, checkpoints)

    # 4. Replay Group B (with salience)
    Logger.info("[SalienceEval] Running Group B (salience, window=#{window})")
    {_comp_b, snapshots_b} = replay_with_salience(messages, window, checkpoints)

    # 5. Measure retention at each checkpoint
    measurements =
      Enum.map(checkpoints, fn pct ->
        comp_a = find_snapshot(snapshots_a, pct)
        comp_b = find_snapshot(snapshots_b, pct)

        high_ret_a = measure_fact_retention(comp_a, high_facts)
        high_ret_b = measure_fact_retention(comp_b, high_facts)
        low_ret_a = measure_fact_retention(comp_a, low_facts)
        low_ret_b = measure_fact_retention(comp_b, low_facts)

        %{
          checkpoint: pct,
          high_retention_a: Float.round(high_ret_a, 3),
          high_retention_b: Float.round(high_ret_b, 3),
          low_retention_a: Float.round(low_ret_a, 3),
          low_retention_b: Float.round(low_ret_b, 3),
          high_salience_lift: Float.round(high_ret_b - high_ret_a, 3),
          low_salience_delta: Float.round(low_ret_b - low_ret_a, 3),
          stats_a: comp_a && ContextCompactor.stats(comp_a),
          stats_b: comp_b && ContextCompactor.stats(comp_b)
        }
      end)

    # 6. Build summary
    summary = build_summary(measurements, high_facts, low_facts, window)

    # 7. Optionally persist
    if persist do
      maybe_persist(measurements, summary, window, tag)
    end

    {:ok,
     %{
       measurements: measurements,
       summary: summary,
       high_facts_count: length(high_facts),
       low_facts_count: length(low_facts),
       effective_window: window,
       message_count: length(messages)
     }}
  end

  # ── Ground Truth Extraction ──────────────────────────────────

  @doc false
  def extract_salience_ground_truth(transcript) do
    tool_calls = transcript["tool_calls"] || []

    high_calls = Enum.filter(tool_calls, &(&1["salience_label"] == "high"))
    low_calls = Enum.filter(tool_calls, &(&1["salience_label"] == "low"))

    high_facts = extract_facts_from_calls(high_calls)
    low_facts = extract_facts_from_calls(low_calls)

    {high_facts, low_facts}
  end

  defp extract_facts_from_calls(calls) do
    Enum.flat_map(calls, fn tc ->
      result = tc["result"] || ""
      name = tc["name"] || ""

      facts = []

      # Extract file paths from results
      facts =
        case Jason.decode(result) do
          {:ok, %{"path" => path}} when is_binary(path) ->
            [{:path, path} | facts]

          _ ->
            facts
        end

      # Extract person names
      person_facts =
        Regex.scan(~r/"name"\s*:\s*"([^"]+)"/, result)
        |> Enum.map(fn [_, n] -> {:person, n} end)

      # Extract error patterns
      error_facts =
        if String.contains?(result, "ERROR") do
          # Extract the specific error signature
          case Regex.run(~r/(ERROR[^"]{10,60})/, result) do
            [_, err] -> [{:error, String.slice(err, 0, 50)}]
            _ -> [{:error, "ERROR"}]
          end
        else
          []
        end

      # Extract decision language
      decision_facts =
        cond do
          String.contains?(result, "decided") -> [{:decision, "decided"}]
          String.contains?(result, "Confirmed") -> [{:decision, "confirmed"}]
          true -> []
        end

      # Extract emotional markers
      emotional_facts =
        Regex.scan(~r/"emotional_markers"\s*:\s*\[([^\]]+)\]/, result)
        |> Enum.flat_map(fn [_, markers_str] ->
          Regex.scan(~r/"([^"]+)"/, markers_str)
          |> Enum.map(fn [_, m] -> {:emotion, m} end)
        end)

      # Extract tool name as context
      tool_fact = if name != "", do: [{:tool, name}], else: []

      facts ++ person_facts ++ error_facts ++ decision_facts ++ emotional_facts ++ tool_fact
    end)
    |> Enum.uniq()
  end

  # ── Replay ──────────────────────────────────────────────────

  defp replay_baseline(messages, window, checkpoints) do
    # Standard replay — salience_scores will be populated by append
    # but we suppress them by zeroing them before compact
    total = length(messages)
    checkpoint_indices = Enum.map(checkpoints, &trunc(&1 * total))

    compactor = ContextCompactor.new(effective_window: window, enable_llm_compaction: false)

    {final, snapshots} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({compactor, []}, fn {msg, idx}, {comp, snaps} ->
        comp = ContextCompactor.append(comp, msg)
        # Zero out salience_scores for baseline — forces detail_level-only path
        comp = %{comp | salience_scores: %{}}
        comp = ContextCompactor.maybe_compact(comp)

        new_snaps =
          if (idx + 1) in checkpoint_indices do
            pct = Enum.find(checkpoints, fn p -> trunc(p * total) == idx + 1 end)
            snaps ++ [{pct, comp}]
          else
            snaps
          end

        {comp, new_snaps}
      end)

    {final, snapshots}
  end

  defp replay_with_salience(messages, window, checkpoints) do
    # Standard replay — salience_scores populated naturally by append
    total = length(messages)
    checkpoint_indices = Enum.map(checkpoints, &trunc(&1 * total))

    compactor = ContextCompactor.new(effective_window: window, enable_llm_compaction: false)

    {final, snapshots} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({compactor, []}, fn {msg, idx}, {comp, snaps} ->
        comp =
          comp
          |> ContextCompactor.append(msg)
          |> ContextCompactor.maybe_compact()

        new_snaps =
          if (idx + 1) in checkpoint_indices do
            pct = Enum.find(checkpoints, fn p -> trunc(p * total) == idx + 1 end)
            snaps ++ [{pct, comp}]
          else
            snaps
          end

        {comp, new_snaps}
      end)

    {final, snapshots}
  end

  defp find_snapshot(snapshots, pct) do
    case Enum.find(snapshots, fn {p, _} -> p == pct end) do
      {_, comp} -> comp
      nil -> nil
    end
  end

  # ── Retention Measurement ────────────────────────────────────

  defp measure_fact_retention(nil, _facts), do: 0.0

  defp measure_fact_retention(_compactor, []), do: 1.0

  defp measure_fact_retention(compactor, facts) do
    llm_text =
      compactor
      |> ContextCompactor.llm_messages()
      |> Enum.map_join("\n", fn msg ->
        content = Map.get(msg, :content) || Map.get(msg, "content", "")
        name = Map.get(msg, :name) || Map.get(msg, "name", "")

        text =
          cond do
            is_binary(content) -> content
            is_list(content) -> inspect(content)
            true -> ""
          end

        "#{name} #{text}"
      end)

    retained =
      Enum.count(facts, fn
        {:path, path} -> String.contains?(llm_text, path)
        {:person, name} -> String.contains?(llm_text, name)
        {:error, err} -> String.contains?(llm_text, err)
        {:decision, word} -> String.contains?(llm_text, word)
        {:emotion, marker} -> String.contains?(String.downcase(llm_text), marker)
        {:tool, _name} -> true
      end)

    retained / length(facts)
  end

  # ── Summary ──────────────────────────────────────────────────

  defp build_summary(measurements, high_facts, low_facts, window) do
    IO.puts("\n=== Salience Eval Summary ===")
    IO.puts("Window: #{window} tokens")

    IO.puts(
      "Ground truth: #{length(high_facts)} high-salience facts, #{length(low_facts)} low-salience facts"
    )

    IO.puts("")

    header =
      String.pad_trailing("Checkpoint", 12) <>
        String.pad_trailing("High-A", 9) <>
        String.pad_trailing("High-B", 9) <>
        String.pad_trailing("Lift", 9) <>
        String.pad_trailing("Low-A", 9) <>
        String.pad_trailing("Low-B", 9) <>
        String.pad_trailing("Delta", 9)

    IO.puts(header)
    IO.puts(String.duplicate("-", 66))

    for m <- measurements do
      IO.puts(
        String.pad_trailing("#{trunc(m.checkpoint * 100)}%", 12) <>
          String.pad_trailing("#{trunc(m.high_retention_a * 100)}%", 9) <>
          String.pad_trailing("#{trunc(m.high_retention_b * 100)}%", 9) <>
          String.pad_trailing(format_lift(m.high_salience_lift), 9) <>
          String.pad_trailing("#{trunc(m.low_retention_a * 100)}%", 9) <>
          String.pad_trailing("#{trunc(m.low_retention_b * 100)}%", 9) <>
          String.pad_trailing(format_lift(m.low_salience_delta), 9)
      )
    end

    IO.puts("")

    # Pass/fail
    final = List.last(measurements)
    lift = final && final.high_salience_lift

    passed = lift != nil and lift >= 0.0

    if passed do
      IO.puts("PASS: high_salience_lift = #{format_lift(lift)} (>= 0)")
    else
      IO.puts("FAIL: high_salience_lift = #{format_lift(lift)} (< 0)")
    end

    IO.puts("")

    %{
      passed: passed,
      final_high_salience_lift: lift,
      window: window,
      high_facts: length(high_facts),
      low_facts: length(low_facts)
    }
  end

  defp format_lift(nil), do: "N/A"

  defp format_lift(v) when v > 0, do: "+#{trunc(v * 100)}%"
  defp format_lift(v) when v < 0, do: "#{trunc(v * 100)}%"
  defp format_lift(_), do: "0%"

  # ── Persistence ──────────────────────────────────────────────

  defp maybe_persist(measurements, summary, window, tag) do
    persistence = Module.concat([:Arbor, :Common, :Eval, :PersistenceBridge])

    if Code.ensure_loaded?(persistence) and function_exported?(persistence, :persist_eval, 1) do
      eval_run = %{
        eval_type: "salience",
        tag: tag,
        metadata: %{
          effective_window: window,
          passed: summary.passed,
          final_lift: summary.final_high_salience_lift
        },
        results:
          Enum.map(measurements, fn m ->
            %{
              label: "checkpoint_#{trunc(m.checkpoint * 100)}",
              score: m.high_salience_lift,
              metadata: Map.drop(m, [:stats_a, :stats_b])
            }
          end)
      }

      apply(persistence, :persist_eval, [eval_run])
    else
      :ok
    end
  rescue
    _ -> :ok
  end
end
