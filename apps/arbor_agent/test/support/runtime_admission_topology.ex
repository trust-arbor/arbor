defmodule Arbor.Agent.Test.RuntimeAdmissionTopology do
  @moduledoc """
  Test-only owned runtime-admission topology for ordinary `Lifecycle.start/2`.

  Starts a ready per-test `RuntimeAdmission.Supervisor`, `Task.Supervisor`, and
  `TaskStore` under ExUnit supervision with unique process names. The registry
  stays the fixed production name `Arbor.Agent.RuntimeAdmissionRegistry`
  because `IntentOwner` hardcodes it.

  Does not start or depend on the production global TaskStore. Callers must
  pass the returned `:store` through the test-only `task_store:` seam on
  `Lifecycle.start/2`.
  """

  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor

  @registry Arbor.Agent.RuntimeAdmissionRegistry

  @type topology :: %{
          store: atom(),
          ra_sup: pid(),
          task_sup: pid()
        }

  @doc """
  Reset recovery memory, ensure the fixed registry exists, and start a ready
  test-owned TaskStore topology. Returns `%{store:, ra_sup:, task_sup:}`.
  """
  @spec start_owned!() :: topology()
  def start_owned! do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()
    ensure_runtime_admission_registry!()

    ra_sup = ExUnit.Callbacks.start_supervised!({RASupervisor, name: unique_name(:ra_sup)})
    task_sup = ExUnit.Callbacks.start_supervised!({Task.Supervisor, name: unique_name(:task_sup)})
    store = unique_name(:store)

    ExUnit.Callbacks.start_supervised!(
      {TaskStore,
       name: store,
       task_supervisor: task_sup,
       runtime_admission_supervisor: ra_sup,
       runtime_admission_force_ready: true,
       fence_force_ready: true,
       recovery_force_ready: true}
    )

    %{store: store, ra_sup: ra_sup, task_sup: task_sup}
  end

  # Fixed production Registry name — IntentOwner hardcodes this atom.
  # Handle already_started by whereis; never invent a unique registry name.
  defp ensure_runtime_admission_registry! do
    case Process.whereis(@registry) do
      nil ->
        ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: @registry})

      _pid ->
        :ok
    end
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
