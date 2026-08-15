defmodule Arbor.Monitor.Config do
  @moduledoc """
  Owner-scoped application env for Monitor.

  Values live under `config :arbor_kernel, monitor: [...]`. Channel-bridge
  and agent-directory seams default to `nil` (disabled). Umbrella runtime or
  tests inject concrete modules; this library never hardcodes those providers.
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

  @default_anomaly_config %{
    scheduler_utilization: %{threshold: 0.90},
    process_count_ratio: %{threshold: 0.80},
    message_queue_len: %{threshold: 10_000},
    memory_total: %{threshold: 0.85},
    ets_table_count: %{threshold: 500},
    ewma_alpha: 0.3,
    ewma_stddev_threshold: 3.0
  }

  @spec polling_interval() :: pos_integer()
  def polling_interval, do: get(:polling_interval_ms, @default_interval_ms)

  @spec enabled_skills() :: [module()]
  def enabled_skills, do: get(:enabled_skills, @default_skills)

  @spec anomaly_config() :: map()
  def anomaly_config, do: get(:anomaly_config, @default_anomaly_config)

  @spec signal_emission_enabled?() :: boolean()
  def signal_emission_enabled?, do: get(:signal_emission_enabled, false)

  @doc """
  Module implementing `Arbor.Monitor.Contracts.ChannelBridge`, or `nil`.

  Expected callbacks when configured: `deliver_channel_message/5`,
  `create_ops_room/2`.
  """
  @spec channel_bridge_module() :: module() | nil
  def channel_bridge_module, do: get(:channel_bridge_module, nil)

  @doc """
  Module implementing `Arbor.Monitor.Contracts.AgentDirectory`, or `nil`.

  Expected callback when configured: `list_monitor_agents/0`.
  """
  @spec agent_directory_module() :: module() | nil
  def agent_directory_module, do: get(:agent_directory_module, nil)

  @doc "Whether Monitor starts its optional supervised children (default true)."
  @spec start_children?() :: boolean() | nil
  def start_children?, do: get(:start_children, true)

  @doc "Optional signal-emission module, or `nil`."
  @spec signal_module() :: module() | nil
  def signal_module, do: get(:signal_module, nil)

  @doc "Healing child keyword options (default `[]`)."
  @spec healing() :: keyword()
  def healing, do: get(:healing, [])

  @doc "Whether HealingSupervisor schedules ops-room setup (default true)."
  @spec start_ops_room?() :: boolean() | nil
  def start_ops_room?, do: get(:start_ops_room, true)

  @doc "AnomalyQueue deduplication window in milliseconds."
  @spec dedup_window_ms() :: non_neg_integer()
  def dedup_window_ms, do: get(:dedup_window_ms, :timer.minutes(5))

  @doc "AnomalyQueue lease timeout in milliseconds."
  @spec lease_timeout_ms() :: non_neg_integer()
  def lease_timeout_ms, do: get(:lease_timeout_ms, :timer.seconds(60))

  @doc "AnomalyQueue lease-check interval in milliseconds."
  @spec check_interval_ms() :: non_neg_integer()
  def check_interval_ms, do: get(:check_interval_ms, :timer.seconds(15))

  @doc "AnomalyQueue maximum retry attempts."
  @spec max_attempts() :: pos_integer()
  def max_attempts, do: get(:max_attempts, 3)

  @doc "AnomalyQueue suppression window in milliseconds."
  @spec suppression_window_ms() :: non_neg_integer()
  def suppression_window_ms, do: get(:suppression_window_ms, :timer.minutes(30))

  @namespace :monitor

  defp get(key, default) when is_atom(key) do
    case Application.fetch_env(:arbor_kernel, @namespace) do
      :error -> default
      {:ok, config} -> fetch_namespace_key(config, key, default)
    end
  end

  defp fetch_namespace_key(config, key, default) when is_list(config) do
    if Keyword.keyword?(config) do
      Keyword.get(config, key, default)
    else
      raise ArgumentError, malformed_namespace_message()
    end
  end

  defp fetch_namespace_key(%{__struct__: _}, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp fetch_namespace_key(%{} = config, key, default) do
    Map.get(config, key, default)
  end

  defp fetch_namespace_key(_config, _key, _default) do
    raise ArgumentError, malformed_namespace_message()
  end

  defp malformed_namespace_message do
    "Arbor.Monitor.Config malformed :arbor_kernel :monitor namespace"
  end
end
