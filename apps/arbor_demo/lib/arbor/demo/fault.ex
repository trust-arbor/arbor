defmodule Arbor.Demo.Fault do
  @moduledoc """
  Behaviour for demo fault modules.

  Each fault implementation provides a controllable, BEAM-native fault
  that can be injected for demonstration purposes. Faults are intentionally
  "dumb chaos generators" — they know how to create problems but NOT how
  to fix them. The DebugAgent must discover the fix through investigation.

  ## Design Philosophy

  Faults emit a `correlation_id` on injection that flows into the signal bus.
  This allows the Historian to trace causality, but the DebugAgent must still
  do genuine investigation to connect symptoms to root causes.

  ## Stopping Faults

  The FaultInjector tracks injected faults and can stop them via process
  termination. Individual fault modules no longer implement `clear/1` —
  remediation is discovered by the DebugAgent, not pre-packaged.
  """

  @type fault_ref :: pid() | reference()
  @type correlation_id :: String.t()

  @doc "Unique atom name for this fault type."
  @callback name() :: atom()

  @doc "Human-readable description of what this fault does."
  @callback description() :: String.t()

  @doc """
  Inject the fault.

  Returns `{:ok, ref, correlation_id}` where:
  - `ref` is a pid or reference for the FaultInjector to track
  - `correlation_id` is emitted to signals for Historian tracing

  The fault module must emit a signal on injection:

      Signals.emit(:demo, :fault_injected, %{
        fault: name(),
        correlation_id: correlation_id,
        injected_at: DateTime.utc_now()
      })
  """
  @callback inject(keyword()) :: {:ok, fault_ref(), correlation_id()} | {:error, term()}

  @doc """
  List of monitor skill atoms that can detect this fault.

  This is metadata for testing/validation, NOT a hint for the DebugAgent.
  The agent must discover which skill reports the anomaly through investigation.
  """
  @callback detectable_by() :: [atom()]
end
