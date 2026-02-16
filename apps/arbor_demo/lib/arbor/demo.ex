defmodule Arbor.Demo do
  @moduledoc """
  Facade for the Arbor Demo system.

  Provides controllable BEAM-native fault injection for demonstrating
  Arbor's self-healing capabilities. Faults are "dumb chaos generators" —
  they create problems but don't know how to fix them. The DebugAgent must
  discover the fix through genuine investigation.

  ## Available Faults

  - `:message_queue_flood` — Floods a process message queue (detected by `:processes` skill)
  - `:process_leak` — Leaks processes that never terminate (detected by `:beam` skill)
  - `:supervisor_crash` — Creates a supervisor with a crashing child (detected by `:supervisor` skill)

  ## Usage

      # Configure for demo (fast polling, low thresholds)
      Arbor.Demo.configure_demo_mode()

      # Inject a fault - returns correlation_id for tracing
      {:ok, correlation_id} = Arbor.Demo.inject_fault(:message_queue_flood)

      # Check what's active
      Arbor.Demo.active_faults()

      # Stop a fault by type (terminates process but doesn't "fix" the problem)
      # Note: The DebugAgent should discover which process to kill through investigation
      :ok = Arbor.Demo.stop_fault(:message_queue_flood)

      # Stop all faults
      {:ok, count} = Arbor.Demo.stop_all()

  ## Healing Pipeline

  The healing pipeline is accessed via `Arbor.Monitor.healing_status/0`.
  """

  require Logger


  # ============================================================================
  # Fault Injection
  # ============================================================================

  @doc """
  Inject a fault of the given type.

  Returns `{:ok, correlation_id}` where correlation_id can be used to trace
  the fault through the Historian, or `{:error, reason}`.
  """
  defdelegate inject_fault(type, opts \\ []), to: Arbor.Demo.FaultInjector

  @doc """
  Stop an active fault by type or correlation_id.

  This terminates the fault's process but does NOT "fix" the problem in the
  way the DebugAgent would. The DebugAgent should discover which process
  to kill through BEAM inspection, not by calling this function.

  Returns `:ok` or `{:error, :not_active}`.
  """
  defdelegate stop_fault(type_or_correlation_id), to: Arbor.Demo.FaultInjector

  @doc "Stop all active faults. Returns `{:ok, count_stopped}`."
  defdelegate stop_all(), to: Arbor.Demo.FaultInjector

  @doc "Returns a map of currently active faults keyed by correlation_id."
  defdelegate active_faults(), to: Arbor.Demo.FaultInjector

  @doc "Returns status for a specific fault type (`:inactive` or status map)."
  defdelegate fault_status(type), to: Arbor.Demo.FaultInjector

  @doc "Returns list of all available fault types with descriptions."
  defdelegate available_faults(), to: Arbor.Demo.FaultInjector

  @doc "Get the correlation_id for an active fault by type."
  defdelegate get_correlation_id(type), to: Arbor.Demo.FaultInjector

  # ============================================================================
  # Demo Mode Configuration
  # ============================================================================

  @doc """
  Configure the system for demo mode.

  Sets fast polling (500ms), low thresholds (100 messages), and enables signals.
  Call this before injecting faults for reliable demo detection.
  """
  @demo_monitor_config [
    polling_interval_ms: 500,
    anomaly_config: %{
      scheduler_utilization: %{threshold: 0.90},
      process_count_ratio: %{threshold: 0.50},
      message_queue_len: %{threshold: 100},
      memory_total: %{threshold: 0.85},
      ets_table_count: %{threshold: 500},
      ewma_alpha: 0.3,
      ewma_stddev_threshold: 2.0
    },
    signal_emission_enabled: true
  ]

  @production_monitor_config [
    polling_interval_ms: 5_000,
    anomaly_config: %{
      scheduler_utilization: %{threshold: 0.90},
      process_count_ratio: %{threshold: 0.80},
      message_queue_len: %{threshold: 10_000},
      memory_total: %{threshold: 0.85},
      ets_table_count: %{threshold: 500},
      ewma_alpha: 0.3,
      ewma_stddev_threshold: 3.0
    }
  ]

  @spec configure_demo_mode() :: :ok
  def configure_demo_mode do
    apply_monitor_config(@demo_monitor_config, "Demo mode configured (fast polling, low thresholds)")
  end

  @doc """
  Reset to normal production configuration.
  """
  @spec configure_production_mode() :: :ok
  def configure_production_mode do
    apply_monitor_config(@production_monitor_config, "Production mode configured")
  end

  defp apply_monitor_config(config, label) do
    Enum.each(config, fn {key, value} ->
      Application.put_env(:arbor_monitor, key, value)
    end)

    Logger.info("[Demo] #{label}")
    :ok
  end

  # ============================================================================
  # Healing Pipeline Status (delegates to arbor_monitor)
  # ============================================================================

  @doc """
  Get the current healing pipeline status.

  Delegates to `Arbor.Monitor.healing_status/0`.
  """
  @spec healing_status() :: map()
  defdelegate healing_status(), to: Arbor.Monitor
end
