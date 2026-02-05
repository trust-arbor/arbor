defmodule Arbor.Monitor.AnomalyDetector do
  @moduledoc """
  Streaming anomaly detection using EWMA and Welford's online algorithm.

  Tracks running mean and variance per metric key, detecting anomalies
  when values exceed a configurable number of standard deviations from
  the exponentially weighted moving average.

  State is stored in ETS for persistence across Poller restarts.
  """

  alias Arbor.Monitor.Config

  @stats_table :arbor_monitor_stats
  @min_observations 10

  @doc """
  Initialize the stats ETS table. Called by MetricsStore or Application.
  """
  def init do
    if :ets.whereis(@stats_table) == :undefined do
      :ets.new(@stats_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Update the running statistics for a metric and check for anomaly.

  Returns `:normal` or `{:anomaly, severity, details}`.
  """
  @spec update(atom(), atom(), number()) :: Arbor.Monitor.Skill.anomaly_result()
  def update(skill, metric_key, value) when is_number(value) do
    key = {skill, metric_key}
    config = Config.anomaly_config()
    alpha = Map.get(config, :ewma_alpha, 0.3)
    threshold = Map.get(config, :ewma_stddev_threshold, 3.0)

    case get_stats(key) do
      nil ->
        initialize_stats(key, value)

      stats ->
        new_stats = update_stats(stats, value, alpha)
        put_stats(key, new_stats)
        evaluate_anomaly(skill, metric_key, value, new_stats, threshold)
    end
  end

  def update(_skill, _metric_key, _value), do: :normal

  @doc """
  Reset statistics for a specific skill/metric pair.
  """
  @spec reset(atom(), atom()) :: :ok
  def reset(skill, metric_key) do
    :ets.delete(stats_table(), {skill, metric_key})
    :ok
  end

  @doc """
  Reset all statistics.
  """
  @spec reset_all() :: :ok
  def reset_all do
    if :ets.whereis(@stats_table) != :undefined do
      :ets.delete_all_objects(stats_table())
    end

    :ok
  end

  @doc false
  def stats_table, do: @stats_table

  # Private

  defp initialize_stats(key, value) do
    put_stats(key, %{
      ewma: value * 1.0,
      count: 1,
      mean: value * 1.0,
      m2: 0.0
    })

    :normal
  end

  defp update_stats(stats, value, alpha) do
    new_count = stats.count + 1
    delta = value - stats.mean
    new_mean = stats.mean + delta / new_count
    delta2 = value - new_mean

    %{
      ewma: alpha * value + (1 - alpha) * stats.ewma,
      count: new_count,
      mean: new_mean,
      m2: stats.m2 + delta * delta2
    }
  end

  defp evaluate_anomaly(_skill, _metric_key, _value, %{count: count}, _threshold)
       when count < @min_observations,
       do: :normal

  defp evaluate_anomaly(skill, metric_key, value, stats, threshold) do
    variance = stats.m2 / (stats.count - 1)
    stddev = :math.sqrt(max(variance, 0.0))
    deviation = abs(value - stats.ewma)

    if stddev > 0 and deviation > threshold * stddev do
      severity = if deviation > threshold * 2 * stddev, do: :critical, else: :warning

      {:anomaly, severity,
       %{
         skill: skill,
         metric: metric_key,
         value: value,
         ewma: stats.ewma,
         stddev: stddev,
         deviation_stddevs: deviation / stddev
       }}
    else
      :normal
    end
  end

  defp get_stats(key) do
    case :ets.lookup(stats_table(), key) do
      [{^key, stats}] -> stats
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put_stats(key, stats) do
    :ets.insert(stats_table(), {key, stats})
  end
end
