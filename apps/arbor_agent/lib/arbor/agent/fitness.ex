defmodule Arbor.Agent.Fitness do
  @moduledoc """
  Fitness function baseline capture and comparison for telemetry gates.

  Captures snapshot metrics from the running system, stores them in ETS,
  and provides comparison/gating functions to determine whether the system
  is within acceptable bounds between phases.

  ## Metrics

  - `goal_completion_rate` — ratio of completed (achieved) goals to total goals
  - `signal_volume` — signals published per minute on the signal bus
  - `llm_latency_p95` — 95th percentile LLM response time in milliseconds

  ## Usage

      # Capture a baseline before a phase change
      {:ok, baseline} = Arbor.Agent.Fitness.capture_baseline("agent_abc123")

      # ... run phase ...

      # Compare current metrics to baseline
      {:ok, deltas} = Arbor.Agent.Fitness.compare("agent_abc123")

      # Gate: only proceed if deltas are within thresholds
      Arbor.Agent.Fitness.meets_gate?("agent_abc123", %{
        goal_completion_rate: {-0.1, :infinity},
        signal_volume: {0, 10_000},
        llm_latency_p95: {0, 5_000}
      })

  ## LLM Latency Recording

  Since no global telemetry system tracks LLM call durations yet, callers
  must record observations explicitly:

      Arbor.Agent.Fitness.record_llm_latency("agent_abc123", 1230)

  These samples are stored in the ETS table and used to compute the p95.
  """

  use GenServer

  alias Arbor.Memory.GoalStore
  alias Arbor.Signals.Bus

  require Logger

  @ets_table :arbor_fitness_baselines
  @latency_table :arbor_fitness_llm_latencies

  # Maximum latency samples retained per agent (sliding window)
  @max_latency_samples 1_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Fitness GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Captures a baseline snapshot of current metrics for the given agent.

  Stores the snapshot in ETS keyed by `{agent_id, :baseline}` and returns
  the metrics map.

  ## Metrics returned

  - `:goal_completion_rate` — float 0.0..1.0
  - `:signal_volume` — signals published per minute (float)
  - `:llm_latency_p95` — 95th percentile LLM latency in ms (float), or `nil` if no samples
  - `:captured_at` — `DateTime.t()` timestamp of the snapshot
  - `:signal_stats` — raw bus stats snapshot (for delta computation)
  """
  @spec capture_baseline(String.t()) :: {:ok, map()}
  def capture_baseline(agent_id) when is_binary(agent_id) do
    metrics = collect_metrics(agent_id)
    baseline = Map.put(metrics, :captured_at, DateTime.utc_now())

    ensure_ets_tables()
    :ets.insert(@ets_table, {{agent_id, :baseline}, baseline})

    Logger.info("Fitness baseline captured for #{agent_id}: #{inspect_summary(baseline)}")
    {:ok, baseline}
  end

  @doc """
  Compares current metrics against the stored baseline for the given agent.

  Returns a map of deltas (current - baseline) for each metric.

  ## Returns

  - `{:ok, deltas}` where deltas is a map with keys:
    - `:goal_completion_rate` — change in completion rate (positive = improvement)
    - `:signal_volume` — change in signals/minute
    - `:llm_latency_p95` — change in p95 latency (negative = improvement)
    - `:baseline` — the original baseline snapshot
    - `:current` — the current metrics snapshot
  - `{:error, :no_baseline}` if no baseline has been captured
  """
  @spec compare(String.t()) :: {:ok, map()} | {:error, :no_baseline}
  def compare(agent_id) when is_binary(agent_id) do
    ensure_ets_tables()

    case :ets.lookup(@ets_table, {agent_id, :baseline}) do
      [{{^agent_id, :baseline}, baseline}] ->
        current = collect_metrics(agent_id)

        deltas = %{
          goal_completion_rate: current.goal_completion_rate - baseline.goal_completion_rate,
          signal_volume: current.signal_volume - baseline.signal_volume,
          llm_latency_p95:
            compute_latency_delta(current.llm_latency_p95, baseline.llm_latency_p95),
          baseline: baseline,
          current: Map.put(current, :captured_at, DateTime.utc_now())
        }

        {:ok, deltas}

      [] ->
        {:error, :no_baseline}
    end
  end

  @doc """
  Checks whether the current deltas from baseline are within the given thresholds.

  ## Threshold format

  A map of metric name to `{min, max}` tuples. The delta for each metric
  must satisfy `min <= delta <= max`. Use `:infinity` or `:neg_infinity`
  for unbounded sides.

  Only metrics present in the thresholds map are checked. Missing metrics
  are treated as passing.

  ## Examples

      # Goal completion must not drop more than 10%, signal volume under 10k/min,
      # LLM latency increase under 5 seconds
      Arbor.Agent.Fitness.meets_gate?("agent_abc", %{
        goal_completion_rate: {-0.1, :infinity},
        signal_volume: {0, 10_000},
        llm_latency_p95: {0, 5_000}
      })

  ## Returns

  - `{:ok, true}` if all thresholds are met
  - `{:ok, false, violations}` with a list of `{metric, delta, {min, max}}` tuples
  - `{:error, :no_baseline}` if no baseline exists
  """
  @spec meets_gate?(String.t(), map()) ::
          {:ok, true} | {:ok, false, list()} | {:error, :no_baseline}
  def meets_gate?(agent_id, thresholds) when is_binary(agent_id) and is_map(thresholds) do
    case compare(agent_id) do
      {:ok, deltas} ->
        check_threshold_violations(agent_id, deltas, thresholds)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Records an LLM response latency observation for the given agent.

  Latency should be in milliseconds. Samples are stored in a bounded
  sliding window (newest #{@max_latency_samples} samples).

  ## Examples

      Arbor.Agent.Fitness.record_llm_latency("agent_abc", 1230)
  """
  @spec record_llm_latency(String.t(), number()) :: :ok
  def record_llm_latency(agent_id, latency_ms)
      when is_binary(agent_id) and is_number(latency_ms) and latency_ms >= 0 do
    ensure_ets_tables()
    timestamp = System.monotonic_time(:millisecond)

    :ets.insert(@latency_table, {{agent_id, timestamp}, latency_ms})

    # Prune old samples if over limit
    maybe_prune_latency_samples(agent_id)

    :ok
  end

  @doc """
  Returns the stored baseline for the given agent, or `nil` if none exists.
  """
  @spec get_baseline(String.t()) :: map() | nil
  def get_baseline(agent_id) when is_binary(agent_id) do
    ensure_ets_tables()

    case :ets.lookup(@ets_table, {agent_id, :baseline}) do
      [{{^agent_id, :baseline}, baseline}] -> baseline
      [] -> nil
    end
  end

  @doc """
  Clears the baseline and latency samples for the given agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) when is_binary(agent_id) do
    ensure_ets_tables()
    :ets.delete(@ets_table, {agent_id, :baseline})
    clear_latency_samples(agent_id)
    :ok
  end

  @doc """
  Returns the current metrics snapshot without storing a baseline.

  Useful for dashboard display or ad-hoc inspection.
  """
  @spec current_metrics(String.t()) :: map()
  def current_metrics(agent_id) when is_binary(agent_id) do
    collect_metrics(agent_id)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_tables()
    {:ok, %{}}
  end

  # ============================================================================
  # Private — Metric Collection
  # ============================================================================

  defp collect_metrics(agent_id) do
    %{
      goal_completion_rate: compute_goal_completion_rate(agent_id),
      signal_volume: compute_signal_volume(),
      llm_latency_p95: compute_llm_latency_p95(agent_id),
      signal_stats: get_bus_stats()
    }
  end

  # Goal completion rate: achieved / total (all statuses)
  # Returns 0.0 if no goals exist.
  defp compute_goal_completion_rate(agent_id) do
    goals = safe_get_all_goals(agent_id)
    total = length(goals)

    if total == 0 do
      0.0
    else
      achieved = Enum.count(goals, &(&1.status == :achieved))
      Float.round(achieved / total, 4)
    end
  end

  defp safe_get_all_goals(agent_id) do
    if :ets.whereis(:arbor_memory_goals) != :undefined do
      GoalStore.get_all_goals(agent_id)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Signal volume: total_published / uptime_minutes
  # Uses bus stats snapshot. If bus is unavailable, returns 0.0.
  defp compute_signal_volume do
    case get_bus_stats() do
      %{total_published: published} when is_integer(published) ->
        uptime_minutes = get_bus_uptime_minutes()

        if uptime_minutes > 0 do
          Float.round(published / uptime_minutes, 2)
        else
          published * 1.0
        end

      _ ->
        0.0
    end
  end

  defp get_bus_stats do
    Bus.stats()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # Approximate bus uptime from system uptime (BEAM VM uptime).
  # This is a reasonable proxy since the bus starts with the application.
  defp get_bus_uptime_minutes do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    max(uptime_ms / 60_000, 1.0)
  end

  # LLM latency p95 from recorded samples.
  # Returns nil if no samples exist for the agent.
  defp compute_llm_latency_p95(agent_id) do
    ensure_ets_tables()
    samples = get_latency_samples(agent_id)

    case samples do
      [] ->
        nil

      latencies ->
        sorted = Enum.sort(latencies)
        p95_index = max(trunc(length(sorted) * 0.95) - 1, 0)
        Float.round(Enum.at(sorted, p95_index) * 1.0, 2)
    end
  end

  defp get_latency_samples(agent_id) do
    # Match all entries for this agent_id: {{agent_id, _timestamp}, latency_ms}
    match_spec = [{{{agent_id, :_}, :"$1"}, [], [:"$1"]}]

    case :ets.info(@latency_table) do
      :undefined -> []
      _ -> :ets.select(@latency_table, match_spec)
    end
  rescue
    _ -> []
  end

  defp maybe_prune_latency_samples(agent_id) do
    samples = get_latency_entries(agent_id)

    if length(samples) > @max_latency_samples do
      # Sort by timestamp (second element of key tuple), keep newest
      sorted = Enum.sort_by(samples, fn {{_id, ts}, _val} -> ts end)
      to_delete = Enum.take(sorted, length(sorted) - @max_latency_samples)

      Enum.each(to_delete, fn {key, _val} ->
        :ets.delete(@latency_table, key)
      end)
    end
  end

  defp get_latency_entries(agent_id) do
    match_spec = [{{{agent_id, :"$1"}, :"$2"}, [], [{{{{agent_id, :"$1"}}, :"$2"}}]}]

    case :ets.info(@latency_table) do
      :undefined -> []
      _ -> :ets.select(@latency_table, match_spec)
    end
  rescue
    _ -> []
  end

  defp clear_latency_samples(agent_id) do
    match_spec = [{{{agent_id, :_}, :_}, [], [true]}]

    case :ets.info(@latency_table) do
      :undefined -> :ok
      _ -> :ets.select_delete(@latency_table, match_spec)
    end

    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Private — Threshold Comparison
  # ============================================================================

  defp check_threshold_violations(agent_id, deltas, thresholds) do
    violations =
      Enum.reduce(thresholds, [], fn {metric, {min, max}}, acc ->
        check_metric_bound(Map.get(deltas, metric), metric, min, max, acc)
      end)
      |> Enum.reverse()

    if violations == [] do
      {:ok, true}
    else
      Logger.warning("Fitness gate failed for #{agent_id}: #{inspect(violations)}")
      {:ok, false, violations}
    end
  end

  defp check_metric_bound(nil, _metric, _min, _max, acc), do: acc

  defp check_metric_bound(delta, metric, min, max, acc) do
    if within_bound?(delta, min, max), do: acc, else: [{metric, delta, {min, max}} | acc]
  end

  defp within_bound?(value, min, max) do
    above_min?(value, min) and below_max?(value, max)
  end

  defp above_min?(_value, :neg_infinity), do: true
  defp above_min?(value, min) when is_number(min), do: value >= min
  defp above_min?(_value, _), do: true

  defp below_max?(_value, :infinity), do: true
  defp below_max?(value, max) when is_number(max), do: value <= max
  defp below_max?(_value, _), do: true

  # ============================================================================
  # Private — Latency Delta
  # ============================================================================

  defp compute_latency_delta(nil, _baseline), do: nil
  defp compute_latency_delta(_current, nil), do: nil

  defp compute_latency_delta(current, baseline) do
    Float.round(current - baseline, 2)
  end

  # ============================================================================
  # Private — ETS Setup
  # ============================================================================

  defp ensure_ets_tables do
    ensure_table(@ets_table)
    ensure_table(@latency_table)
  end

  defp ensure_table(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:named_table, :public, :ordered_set])
    end
  rescue
    ArgumentError -> :ok
  end

  # ============================================================================
  # Private — Logging
  # ============================================================================

  defp inspect_summary(metrics) do
    "goal_rate=#{metrics.goal_completion_rate} " <>
      "signal_vol=#{metrics.signal_volume}/min " <>
      "llm_p95=#{inspect(metrics.llm_latency_p95)}ms"
  end
end
