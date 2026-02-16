defmodule Arbor.Monitor do
  @moduledoc """
  BEAM runtime intelligence facade.

  Provides process monitoring, memory tracking, scheduler utilization,
  and anomaly detection using recon and streaming statistics.

  ## Usage

      # Get overall health status
      Arbor.Monitor.status()

      # Run all skills and get combined metrics
      Arbor.Monitor.collect()

      # Run a specific skill
      Arbor.Monitor.collect(:beam)

      # Read stored metrics (no collection, just ETS read)
      Arbor.Monitor.metrics()

      # List current anomalies
      Arbor.Monitor.anomalies()

      # List available skills
      Arbor.Monitor.skills()
  """

  alias Arbor.Monitor.{Config, MetricsStore}

  @doc """
  Returns current health summary.
  """
  @spec status() :: map()
  def status do
    anomalies = anomalies()

    severity =
      cond do
        Enum.any?(anomalies, &(&1.severity == :emergency)) -> :emergency
        Enum.any?(anomalies, &(&1.severity == :critical)) -> :critical
        Enum.any?(anomalies, &(&1.severity == :warning)) -> :warning
        true -> :healthy
      end

    %{
      status: severity,
      anomaly_count: length(anomalies),
      skills: skills(),
      metrics_available: MetricsStore.all() |> Map.keys()
    }
  end

  @doc """
  Run all enabled skills and return combined metrics map.
  """
  @spec collect() :: %{atom() => {:ok, map()} | {:error, term()}}
  def collect do
    Config.enabled_skills()
    |> Map.new(fn skill_mod ->
      result =
        try do
          skill_mod.collect()
        rescue
          error -> {:error, Exception.message(error)}
        end

      {skill_mod.name(), result}
    end)
  end

  @doc """
  Run a specific skill by name and return its metrics.
  """
  @spec collect(atom()) :: {:ok, map()} | {:error, term()}
  def collect(skill_name) when is_atom(skill_name) do
    case find_skill(skill_name) do
      nil -> {:error, :unknown_skill}
      skill_mod -> skill_mod.collect()
    end
  end

  @doc """
  Read current metrics from ETS (no collection, just read).
  """
  @spec metrics() :: map()
  def metrics do
    MetricsStore.all()
    |> Map.new(fn {skill, {metrics, _ts}} -> {skill, metrics} end)
  end

  @doc """
  Read a specific skill's metrics from ETS.
  """
  @spec metrics(atom()) :: {:ok, map()} | :not_found
  def metrics(skill_name) when is_atom(skill_name) do
    case MetricsStore.get(skill_name) do
      {:ok, metrics, _ts} -> {:ok, metrics}
      :not_found -> :not_found
    end
  end

  @doc """
  List current anomalies.
  """
  @spec anomalies() :: [map()]
  def anomalies do
    MetricsStore.get_anomalies()
  end

  @doc """
  List available skill names.
  """
  @spec skills() :: [atom()]
  def skills do
    Config.enabled_skills()
    |> Enum.map(& &1.name())
  end

  @doc """
  Get healing pipeline status.

  Returns a map with queue, cascade, verification, and rejection stats.
  Each component returns its stats or an empty map if unavailable.
  """
  @spec healing_status() :: map()
  def healing_status do
    alias Arbor.Monitor.{AnomalyQueue, CascadeDetector, RejectionTracker, Verification}

    %{
      queue: safe_call(fn -> AnomalyQueue.stats() end),
      cascade: safe_call(fn -> CascadeDetector.status() end),
      verification: safe_call(fn -> Verification.stats() end),
      rejections: safe_call(fn -> RejectionTracker.stats() end)
    }
  end

  defp find_skill(name) do
    Enum.find(Config.enabled_skills(), fn mod -> mod.name() == name end)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end
end
