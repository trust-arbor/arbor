defmodule Arbor.Monitor.MetricsStore do
  @moduledoc """
  ETS-backed metrics storage.

  Owns the ETS table as a dedicated holder process so data survives
  Poller restarts. Stores per-skill metrics and anomalies.

  ETS schema:
  - Metrics: `{skill_name, metrics_map, timestamp}`
  - Anomalies: `{:anomaly, skill_name, severity, details, timestamp}`
  """

  use GenServer

  @metrics_table :arbor_monitor_metrics
  @anomaly_table :arbor_monitor_anomalies
  @stats_table :arbor_monitor_stats

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec put(atom(), map()) :: :ok
  def put(skill_name, metrics) when is_atom(skill_name) and is_map(metrics) do
    GenServer.call(__MODULE__, {:put, skill_name, metrics})
  end

  @spec get(atom()) :: {:ok, map(), integer()} | :not_found
  def get(skill_name) when is_atom(skill_name) do
    case :ets.lookup(metrics_table(), skill_name) do
      [{^skill_name, metrics, timestamp}] -> {:ok, metrics, timestamp}
      [] -> :not_found
    end
  end

  @spec all() :: %{atom() => {map(), integer()}}
  def all do
    :ets.tab2list(metrics_table())
    |> Map.new(fn {skill, metrics, ts} -> {skill, {metrics, ts}} end)
  end

  @spec put_anomaly(atom(), Arbor.Monitor.Skill.severity(), map()) :: :ok
  def put_anomaly(skill_name, severity, details) do
    GenServer.call(__MODULE__, {:put_anomaly, skill_name, severity, details})
  end

  @spec get_anomalies() :: [map()]
  def get_anomalies do
    :ets.tab2list(anomaly_table())
    |> Enum.map(fn {{:anomaly, id}, skill, severity, details, ts} ->
      %{
        id: id,
        skill: skill,
        severity: severity,
        details: details,
        timestamp: ts
      }
    end)
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  @spec clear_anomalies() :: :ok
  def clear_anomalies do
    GenServer.call(__MODULE__, :clear_anomalies)
  end

  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # For testing — get table references
  @doc false
  def metrics_table, do: @metrics_table
  @doc false
  def anomaly_table, do: @anomaly_table
  @doc false
  def stats_table, do: @stats_table

  # Server

  @impl true
  def init(_opts) do
    metrics = :ets.new(@metrics_table, [:named_table, :set, :protected, read_concurrency: true])

    anomalies =
      :ets.new(@anomaly_table, [:named_table, :set, :protected, read_concurrency: true])

    stats = :ets.new(@stats_table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{metrics: metrics, anomalies: anomalies, stats: stats}}
  end

  @impl true
  def handle_call({:put, skill_name, metrics}, _from, state) do
    timestamp = System.monotonic_time(:millisecond)
    true = :ets.insert(@metrics_table, {skill_name, metrics, timestamp})
    {:reply, :ok, state}
  end

  def handle_call({:put_anomaly, skill_name, severity, details}, _from, state) do
    timestamp = System.monotonic_time(:millisecond)
    id = System.unique_integer([:positive])
    true = :ets.insert(@anomaly_table, {{:anomaly, id}, skill_name, severity, details, timestamp})
    {:reply, :ok, state}
  end

  def handle_call({:update_anomaly_stats, skill, metric_key, value}, _from, state) do
    {:reply, Arbor.Monitor.AnomalyDetector.update_owned(skill, metric_key, value), state}
  end

  def handle_call({:reset_anomaly_stats, skill, metric_key}, _from, state) do
    :ets.delete(@stats_table, {skill, metric_key})
    {:reply, :ok, state}
  end

  def handle_call(:reset_all_anomaly_stats, _from, state) do
    :ets.delete_all_objects(@stats_table)
    {:reply, :ok, state}
  end

  def handle_call(:clear_anomalies, _from, state) do
    :ets.delete_all_objects(@anomaly_table)
    {:reply, :ok, state}
  end

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@metrics_table)
    :ets.delete_all_objects(@anomaly_table)
    :ets.delete_all_objects(@stats_table)
    {:reply, :ok, state}
  end
end
