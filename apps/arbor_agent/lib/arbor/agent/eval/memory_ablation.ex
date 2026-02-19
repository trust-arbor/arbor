defmodule Arbor.Agent.Eval.MemoryAblation do
  @moduledoc """
  Orchestrates memory subsystem ablation studies.

  Runs controlled trials across memory tiers, persists raw LLM responses
  with metadata, and produces comparative metrics. Each trial creates a
  fresh agent with standardized seed state, runs N heartbeats with
  tier-specific prompt section filtering, and captures everything.

  ## Usage

      # Run all tiers with defaults
      MemoryAblation.run()

      # Specific tiers, more runs
      MemoryAblation.run(tiers: [0, 1, 5], runs: 3, heartbeats: 15)

  ## Persistence

  Results are stored via EvalRun/EvalResult:
    - One EvalRun per tier per run (domain: "memory_ablation")
    - One EvalResult per heartbeat within that run
    - Raw LLM responses, prompts, and timing in metadata
  """

  alias Arbor.Agent.Eval.{TrialConfig, TrialRunner}

  require Logger

  @doc """
  Run the full ablation study.

  ## Options

    * `:tiers` - List of tier numbers to test (default: [0, 1, 2, 3, 4, 5])
    * `:runs` - Number of runs per tier (default: 1)
    * `:heartbeats` - Heartbeats per run (default: 10)
    * `:model` - LLM model (default: google/gemini-3-flash-preview)
    * `:provider` - LLM provider (default: :openrouter)

  Returns `{:ok, summary}` where summary contains per-tier metrics.
  """
  def run(opts \\ []) do
    tiers = Keyword.get(opts, :tiers, TrialConfig.tier_numbers())
    runs_per_tier = Keyword.get(opts, :runs, 1)
    heartbeats = Keyword.get(opts, :heartbeats, 10)
    model = Keyword.get(opts, :model, "google/gemini-3-flash-preview")
    provider = Keyword.get(opts, :provider, :openrouter)
    tag = Keyword.get(opts, :tag)

    Logger.info(
      "[MemoryAblation] Starting study: tiers=#{inspect(tiers)}, " <>
        "runs=#{runs_per_tier}, heartbeats=#{heartbeats}, model=#{model}" <>
        if(tag, do: ", tag=#{tag}", else: "")
    )

    study_start = System.monotonic_time(:millisecond)

    results =
      for tier_num <- tiers, run_num <- 1..runs_per_tier do
        tier_config = TrialConfig.for_tier(tier_num)

        trial_opts = [
          heartbeats: heartbeats,
          model: model,
          provider: provider,
          trial_num: run_num
        ]

        Logger.info(
          "[MemoryAblation] Running tier #{tier_num} (#{tier_config.name}), run #{run_num}/#{runs_per_tier}"
        )

        case TrialRunner.run(tier_config, trial_opts) do
          {:ok, trial_result} ->
            # Persist to eval infrastructure
            persist_trial(trial_result, model, provider, run_num, tag)
            trial_result

          {:error, reason} ->
            Logger.error(
              "[MemoryAblation] Tier #{tier_num} run #{run_num} failed: #{inspect(reason)}"
            )

            %{tier: tier_num, tier_name: tier_config.name, error: reason}
        end
      end

    study_duration = System.monotonic_time(:millisecond) - study_start

    summary = build_summary(results, study_duration)
    Logger.info("[MemoryAblation] Study complete in #{study_duration}ms")

    {:ok, summary}
  end

  # -- Persistence --

  defp persist_trial(trial, model, provider, run_num, tag) do
    run_id = "ma_tier#{trial.tier}_run#{run_num}_#{:erlang.unique_integer([:positive])}"

    run_attrs = %{
      id: run_id,
      domain: "memory_ablation",
      model: model,
      provider: to_string(provider),
      dataset: "tier_#{trial.tier}_#{trial.tier_name}",
      graders: ["memory_ablation_metrics"],
      sample_count: trial.heartbeat_count,
      duration_ms: trial.metrics.total_llm_duration_ms |> round(),
      metrics: serialize_metrics(trial.metrics),
      config: %{
        "tier" => trial.tier,
        "tier_name" => to_string(trial.tier_name),
        "heartbeat_count" => trial.heartbeat_count,
        "model" => model,
        "provider" => to_string(provider)
      },
      metadata: build_run_metadata(tag),
      status: "completed"
    }

    case persist_run(run_attrs) do
      {:ok, _} ->
        persist_heartbeat_results(run_id, trial.results)
        Logger.debug("[MemoryAblation] Persisted run #{run_id}")

      {:error, reason} ->
        Logger.warning("[MemoryAblation] Failed to persist run: #{inspect(reason)}")
    end
  end

  defp persist_heartbeat_results(run_id, results) do
    result_attrs =
      Enum.map(results, fn r ->
        %{
          id: "#{run_id}_hb#{r.heartbeat}",
          run_id: run_id,
          sample_id: "heartbeat_#{r.heartbeat}",
          input: Map.get(r, :prompt, ""),
          actual: Map.get(r, :raw_text, ""),
          passed: !Map.has_key?(r, :error),
          scores: heartbeat_scores(r),
          duration_ms: get_in(r, [:llm_meta, :timing_ms]) || 0,
          tokens_generated: get_in(r, [:llm_meta, :usage, :completion_tokens]) || 0,
          metadata: heartbeat_metadata(r)
        }
      end)

    persist_results_batch(result_attrs)
  end

  defp heartbeat_scores(result) do
    parsed = result.parsed

    %{
      "action_count" => length(parsed.actions),
      "new_goals" => length(parsed.new_goals),
      "goal_updates" => length(parsed.goal_updates),
      "memory_notes" => length(parsed.memory_notes),
      "concerns" => length(parsed.concerns),
      "curiosity" => length(parsed.curiosity),
      "identity_insights" => length(parsed.identity_insights),
      "decompositions" => length(parsed.decompositions),
      "proposal_decisions" => length(parsed.proposal_decisions),
      "thinking_length" => String.length(parsed.thinking || "")
    }
  end

  defp heartbeat_metadata(result) do
    meta = %{
      "system_prompt" => Map.get(result, :system_prompt, ""),
      "prompt_sections" => serialize_sections(Map.get(result, :prompt_sections)),
      "raw_response" => Map.get(result, :raw_text, ""),
      "timestamp" => to_string(Map.get(result, :timestamp, DateTime.utc_now()))
    }

    case result[:llm_meta] do
      nil ->
        meta

      llm ->
        Map.merge(meta, %{
          "model" => llm[:model],
          "provider" => to_string(llm[:provider]),
          "usage" => llm[:usage] || %{},
          "timing_ms" => llm[:timing_ms] || 0
        })
    end
  end

  defp serialize_sections(:all), do: "all"
  defp serialize_sections(sections) when is_list(sections), do: Enum.map(sections, &to_string/1)
  defp serialize_sections(other), do: inspect(other)

  defp serialize_metrics(metrics) do
    metrics
    |> from_struct_if_needed()
    |> Enum.into(%{}, fn {k, v} ->
      {to_string(k), serialize_value(v)}
    end)
  end

  defp serialize_value(v) when is_map(v) do
    Enum.into(v, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp serialize_value(v) when is_float(v), do: Float.round(v, 4)
  defp serialize_value(v), do: v

  # -- Summary --

  defp build_summary(results, duration_ms) do
    successful = Enum.reject(results, &Map.has_key?(&1, :error))

    by_tier =
      successful
      |> Enum.group_by(& &1.tier)
      |> Enum.into(%{}, fn {tier, trials} ->
        {tier, summarize_tier(trials)}
      end)

    %{
      tiers: by_tier,
      total_trials: length(results),
      successful_trials: length(successful),
      failed_trials: length(results) - length(successful),
      total_duration_ms: duration_ms
    }
  end

  defp summarize_tier(trials) do
    all_metrics = Enum.map(trials, & &1.metrics)
    tier_name = hd(trials).tier_name

    %{
      name: tier_name,
      trial_count: length(trials),
      avg_metrics: average_metrics(all_metrics),
      individual_metrics: all_metrics
    }
  end

  defp average_metrics(metrics_list) when length(metrics_list) == 1, do: hd(metrics_list)

  defp average_metrics(metrics_list) do
    n = length(metrics_list)

    numeric_keys =
      metrics_list
      |> hd()
      |> Enum.filter(fn {_k, v} -> is_number(v) end)
      |> Enum.map(fn {k, _v} -> k end)

    Enum.into(numeric_keys, %{}, fn key ->
      values = Enum.map(metrics_list, &Map.get(&1, key, 0))
      {key, Enum.sum(values) / n}
    end)
  end

  defp build_run_metadata(nil), do: %{}
  defp build_run_metadata(tag), do: %{"tag" => tag}

  # -- Persistence bridge --

  defp persist_run(attrs) do
    if Code.ensure_loaded?(Arbor.Persistence) and
         function_exported?(Arbor.Persistence, :insert_eval_run, 1) do
      apply(Arbor.Persistence, :insert_eval_run, [attrs])
    else
      {:error, :persistence_unavailable}
    end
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  defp persist_results_batch(results) do
    if Code.ensure_loaded?(Arbor.Persistence) and
         function_exported?(Arbor.Persistence, :insert_eval_results_batch, 1) do
      apply(Arbor.Persistence, :insert_eval_results_batch, [results])
    else
      {:error, :persistence_unavailable}
    end
  rescue
    _ -> {:error, :persistence_error}
  catch
    :exit, _ -> {:error, :persistence_unavailable}
  end

  defp from_struct_if_needed(%{__struct__: _} = s), do: Map.from_struct(s)
  defp from_struct_if_needed(m) when is_map(m), do: m
end
