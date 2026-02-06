defmodule Arbor.Demo do
  @moduledoc """
  Facade for the Arbor Demo system.

  Provides controllable BEAM-native fault injection for demonstrating
  Arbor's self-healing capabilities. The actual healing pipeline is handled
  by `arbor_monitor` — this module just provides fault injection controls.

  ## Available Faults

  - `:message_queue_flood` — Floods a process message queue (detected by `:processes` skill)
  - `:process_leak` — Leaks processes that never terminate (detected by `:beam` skill)
  - `:supervisor_crash` — Creates a supervisor with a crashing child (detected by `:supervisor` skill)

  ## Usage

      # Configure for demo (fast polling, low thresholds)
      Arbor.Demo.configure_demo_mode()

      # Inject a fault
      {:ok, :message_queue_flood} = Arbor.Demo.inject_fault(:message_queue_flood)

      # Check what's active
      Arbor.Demo.active_faults()

      # Clear a specific fault
      :ok = Arbor.Demo.clear_fault(:message_queue_flood)

      # Clear everything
      {:ok, count} = Arbor.Demo.clear_all()

  ## Healing Pipeline

  The healing pipeline is handled by `arbor_monitor`:

  - `Arbor.Monitor.AnomalyQueue` — Queues detected anomalies
  - `Arbor.Monitor.CascadeDetector` — Detects cascade failures
  - `Arbor.Monitor.Verification` — Tracks fix verification (soak period)
  - `Arbor.Monitor.RejectionTracker` — Three-strike escalation
  """

  require Logger

  alias Arbor.Monitor.{AnomalyQueue, CascadeDetector, RejectionTracker, Verification}

  # ============================================================================
  # Fault Injection
  # ============================================================================

  @doc "Inject a fault of the given type. Returns `{:ok, type}` or `{:error, reason}`."
  defdelegate inject_fault(type, opts \\ []), to: Arbor.Demo.FaultInjector

  @doc "Clear a specific active fault. Returns `:ok` or `{:error, :not_active}`."
  defdelegate clear_fault(type), to: Arbor.Demo.FaultInjector

  @doc "Clear all active faults. Returns `{:ok, count_cleared}`."
  defdelegate clear_all(), to: Arbor.Demo.FaultInjector

  @doc "Returns a map of currently active faults with their metadata."
  defdelegate active_faults(), to: Arbor.Demo.FaultInjector

  @doc "Returns status for a specific fault type (`:inactive` or status map)."
  defdelegate fault_status(type), to: Arbor.Demo.FaultInjector

  @doc "Returns list of all available fault types with descriptions."
  defdelegate available_faults(), to: Arbor.Demo.FaultInjector

  # ============================================================================
  # Demo Mode Configuration
  # ============================================================================

  @doc """
  Configure the system for demo mode.

  Sets fast polling (500ms), low thresholds (100 messages), and enables signals.
  Call this before injecting faults for reliable demo detection.
  """
  @spec configure_demo_mode() :: :ok
  def configure_demo_mode do
    # Fast polling for demo
    Application.put_env(:arbor_monitor, :polling_interval_ms, 500)

    # Low thresholds for quick detection
    Application.put_env(:arbor_monitor, :anomaly_config, %{
      scheduler_utilization: %{threshold: 0.90},
      process_count_ratio: %{threshold: 0.50},
      message_queue_len: %{threshold: 100},
      memory_total: %{threshold: 0.85},
      ets_table_count: %{threshold: 500},
      ewma_alpha: 0.3,
      ewma_stddev_threshold: 2.0
    })

    # Enable signal emission
    Application.put_env(:arbor_monitor, :signal_emission_enabled, true)

    Logger.info("[Demo] Demo mode configured (fast polling, low thresholds)")
    :ok
  end

  @doc """
  Reset to normal production configuration.
  """
  @spec configure_production_mode() :: :ok
  def configure_production_mode do
    Application.put_env(:arbor_monitor, :polling_interval_ms, 5_000)

    Application.put_env(:arbor_monitor, :anomaly_config, %{
      scheduler_utilization: %{threshold: 0.90},
      process_count_ratio: %{threshold: 0.80},
      message_queue_len: %{threshold: 10_000},
      memory_total: %{threshold: 0.85},
      ets_table_count: %{threshold: 500},
      ewma_alpha: 0.3,
      ewma_stddev_threshold: 3.0
    })

    Logger.info("[Demo] Production mode configured")
    :ok
  end

  # ============================================================================
  # Healing Pipeline Status (delegates to arbor_monitor)
  # ============================================================================

  @doc """
  Get the current healing pipeline status.

  Returns a map with queue, cascade, verification, and rejection stats.
  """
  @spec healing_status() :: map()
  def healing_status do
    %{
      queue: safe_call(fn -> AnomalyQueue.stats() end, %{}),
      cascade: safe_call(fn -> CascadeDetector.status() end, %{}),
      verification: safe_call(fn -> Verification.stats() end, %{}),
      rejections: safe_call(fn -> RejectionTracker.stats() end, %{})
    }
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
