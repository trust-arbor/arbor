defmodule Arbor.Monitor.Config do
  @moduledoc """
  Configuration for Arbor.Monitor.

  All settings read from Application env with sensible defaults.
  """

  @default_interval_ms 5_000

  @default_skills [
    Arbor.Monitor.Skills.Beam,
    Arbor.Monitor.Skills.Memory,
    Arbor.Monitor.Skills.Ets,
    Arbor.Monitor.Skills.Processes,
    Arbor.Monitor.Skills.Supervisor,
    Arbor.Monitor.Skills.System
  ]

  @spec polling_interval() :: pos_integer()
  def polling_interval do
    Application.get_env(:arbor_monitor, :polling_interval_ms, @default_interval_ms)
  end

  @spec enabled_skills() :: [module()]
  def enabled_skills do
    Application.get_env(:arbor_monitor, :enabled_skills, @default_skills)
  end

  @spec anomaly_config() :: map()
  def anomaly_config do
    Application.get_env(:arbor_monitor, :anomaly_config, %{
      scheduler_utilization: %{threshold: 0.90},
      process_count_ratio: %{threshold: 0.80},
      message_queue_len: %{threshold: 10_000},
      memory_total: %{threshold: 0.85},
      ets_table_count: %{threshold: 500},
      ewma_alpha: 0.3,
      ewma_stddev_threshold: 3.0
    })
  end

  @spec signal_emission_enabled?() :: boolean()
  def signal_emission_enabled? do
    Application.get_env(:arbor_monitor, :signal_emission_enabled, false)
  end
end
