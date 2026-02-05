defmodule Arbor.Demo.Fault do
  @moduledoc """
  Behaviour for demo fault modules.

  Each fault implementation provides a controllable, BEAM-native fault
  that can be injected and cleared on demand for demonstration purposes.
  """

  @type fault_ref :: reference() | pid() | nil

  @doc "Unique atom name for this fault type."
  @callback name() :: atom()

  @doc "Human-readable description of what this fault does."
  @callback description() :: String.t()

  @doc "Inject the fault. Returns a reference for later cleanup."
  @callback inject(keyword()) :: {:ok, fault_ref()} | {:error, term()}

  @doc "Clear the fault using the reference from inject/1."
  @callback clear(fault_ref()) :: :ok

  @doc "List of monitor skill atoms that can detect this fault."
  @callback detectable_by() :: [atom()]
end
