defmodule Arbor.Monitor.Skills.Beam do
  @moduledoc """
  BEAM runtime metrics: process count, scheduler utilization,
  reductions, atom count/limit.
  """

  @behaviour Arbor.Monitor.Skill

  alias Arbor.Monitor.Config

  @impl true
  def name, do: :beam

  @impl true
  def collect do
    process_count = :erlang.system_info(:process_count)
    process_limit = :erlang.system_info(:process_limit)
    atom_count = :erlang.system_info(:atom_count)
    atom_limit = :erlang.system_info(:atom_limit)
    port_count = :erlang.system_info(:port_count)
    port_limit = :erlang.system_info(:port_limit)
    scheduler_count = :erlang.system_info(:schedulers_online)

    scheduler_utilization = safe_scheduler_usage()

    {reductions, _} = :erlang.statistics(:reductions)

    metrics = %{
      process_count: process_count,
      process_limit: process_limit,
      process_count_ratio: process_count / max(process_limit, 1),
      atom_count: atom_count,
      atom_limit: atom_limit,
      atom_count_ratio: atom_count / max(atom_limit, 1),
      port_count: port_count,
      port_limit: port_limit,
      scheduler_count: scheduler_count,
      scheduler_utilization: scheduler_utilization,
      reductions: reductions
    }

    {:ok, metrics}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def check(metrics) do
    config = Config.anomaly_config()
    sched_threshold = get_in(config, [:scheduler_utilization, :threshold]) || 0.90
    proc_threshold = get_in(config, [:process_count_ratio, :threshold]) || 0.80

    cond do
      metrics[:scheduler_utilization] > sched_threshold ->
        {:anomaly, :critical,
         %{
           metric: :scheduler_utilization,
           value: metrics[:scheduler_utilization],
           threshold: sched_threshold
         }}

      metrics[:process_count_ratio] > proc_threshold ->
        {:anomaly, :warning,
         %{
           metric: :process_count_ratio,
           value: metrics[:process_count_ratio],
           threshold: proc_threshold
         }}

      true ->
        :normal
    end
  end

  defp safe_scheduler_usage do
    # recon:scheduler_usage/1 blocks for the sample period (ms)
    # Use a short sample window to avoid blocking
    case :recon.scheduler_usage(50) do
      usage when is_list(usage) ->
        total =
          Enum.reduce(usage, 0.0, fn {_id, pct}, acc ->
            acc + pct
          end)

        total / max(length(usage), 1)

      _ ->
        0.0
    end
  rescue
    _ -> 0.0
  end
end
