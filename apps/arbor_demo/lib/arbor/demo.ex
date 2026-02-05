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
  """

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
end
