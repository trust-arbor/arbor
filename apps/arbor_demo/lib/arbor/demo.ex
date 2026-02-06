defmodule Arbor.Demo do
  @moduledoc """
  Facade for the Arbor Demo system.

  Provides controllable BEAM-native fault injection for demonstrating
  Arbor's self-healing pipeline: Detect -> Diagnose -> Propose -> Review -> Fix -> Verify.

  ## Available Faults

  - `:message_queue_flood` — Floods a process message queue (detected by `:processes` skill)
  - `:process_leak` — Leaks processes that never terminate (detected by `:beam` skill)
  - `:supervisor_crash` — Creates a supervisor with a crashing child (detected by `:supervisor` skill)

  ## Usage

      # Inject a fault
      {:ok, :message_queue_flood} = Arbor.Demo.inject_fault(:message_queue_flood)

      # Check what's active
      Arbor.Demo.active_faults()

      # Clear a specific fault
      :ok = Arbor.Demo.clear_fault(:message_queue_flood)

      # Clear everything
      {:ok, count} = Arbor.Demo.clear_all()

  ## Demo Scenarios

      # Run a pre-scripted scenario
      {:ok, result} = Arbor.Demo.run_scenario(:successful_heal)

      # Run full rehearsal
      {:ok, results} = Arbor.Demo.rehearsal()

  ## Timing Control

      # Set demo timing mode
      Arbor.Demo.set_timing(:fast)  # :fast | :normal | :slow
  """

  alias Arbor.Signals

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
  # Scenarios
  # ============================================================================

  @doc "Run a pre-scripted demo scenario."
  defdelegate run_scenario(name, opts \\ []), to: Arbor.Demo.Scenarios, as: :run

  @doc "Run full demo rehearsal (all scenarios)."
  defdelegate rehearsal(opts \\ []), to: Arbor.Demo.Scenarios

  @doc "Get scenario definition by name."
  defdelegate scenario(name), to: Arbor.Demo.Scenarios

  @doc "List available scenario names."
  defdelegate available_scenarios(), to: Arbor.Demo.Scenarios

  # ============================================================================
  # Timing
  # ============================================================================

  @doc "Set demo timing mode (:fast, :normal, :slow)."
  defdelegate set_timing(mode), to: Arbor.Demo.Timing, as: :set

  @doc "Get current timing configuration."
  defdelegate timing_config(), to: Arbor.Demo.Timing, as: :config

  @doc "Get current timing mode."
  defdelegate timing_mode(), to: Arbor.Demo.Timing, as: :current_mode

  # ============================================================================
  # Recovery Helpers
  # ============================================================================

  @doc """
  Force detection signal emission.

  Use this when the monitor isn't detecting an injected fault.
  Manually emits a monitor.anomaly_detected signal.
  """
  @spec force_detect() :: :ok
  def force_detect do
    faults = active_faults()

    if map_size(faults) == 0 do
      # No active faults, emit generic anomaly
      emit_anomaly(:unknown, %{source: :manual_trigger})
    else
      # Emit for first active fault
      {fault_type, fault_data} = Enum.at(faults, 0)
      emit_anomaly(fault_type, fault_data)
    end

    :ok
  end

  defp emit_anomaly(fault_type, data) do
    Signals.emit(:monitor, :anomaly_detected, %{
      type: fault_type,
      severity: :high,
      timestamp: System.system_time(:millisecond),
      source: :demo_force_detect,
      data: data
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
