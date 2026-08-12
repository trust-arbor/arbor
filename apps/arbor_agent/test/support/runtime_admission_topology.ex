defmodule Arbor.Agent.Test.RuntimeAdmissionTopology do
  @moduledoc """
  Test-only runtime-admission topology helpers for ordinary `Lifecycle.start/2`.

  ## Owned topology (`start_owned!/0`)

  Starts a ready per-test `RuntimeAdmission.Supervisor`, `Task.Supervisor`, and
  `TaskStore` under ExUnit supervision with unique process names. The registry
  stays the fixed production name `Arbor.Agent.RuntimeAdmissionRegistry`
  because `IntentOwner` hardcodes it.

  Does not start or depend on the production global TaskStore. Callers must
  pass the returned `:store` through the test-only `task_store:` seam on
  `Lifecycle.start/2`.

  ## Fixed production topology (`start_fixed_production!/0`)

  Starts the production-named registry, runtime-admission supervisor, task
  supervisor, and TaskStore (force-ready) under the suite app supervisor so
  unchanged public `Lifecycle.start/2` callers (Manager, Bootstrap, Reconciler)
  do not poll a missing store. Idempotent.
  """

  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Agent.RuntimeAdmission.Supervisor, as: RASupervisor

  @registry Arbor.Agent.RuntimeAdmissionRegistry
  @ra_supervisor RASupervisor
  @task_supervisor Arbor.Agent.Orchestration.TaskSupervisor
  @production_store TaskStore
  @app_supervisor Arbor.Agent.AppSupervisor

  @type topology :: %{
          store: atom(),
          ra_sup: pid(),
          task_sup: pid()
        }

  @type fixed_topology :: %{
          store: atom(),
          store_pid: pid(),
          ra_sup: pid(),
          task_sup: pid(),
          registry: atom(),
          registry_pid: pid()
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

  @doc """
  Ensure the fixed production-name runtime-admission topology is ready.

  Starts (idempotently) under `Arbor.Agent.AppSupervisor`:

  - `Arbor.Agent.RuntimeAdmissionRegistry`
  - `Arbor.Agent.RuntimeAdmission.Supervisor`
  - `Arbor.Agent.Orchestration.TaskSupervisor`
  - `Arbor.Agent.Orchestration.TaskStore` (force-ready for ordinary admission)

  Public `Lifecycle.start/2` callers that do not pass the test-only
  `task_store:` seam resolve this fixed store without missing-store timeouts.
  """
  @spec start_fixed_production!() :: fixed_topology()
  def start_fixed_production! do
    TaskControlRecoveryMemory.ensure!()

    registry_pid = ensure_child!({Registry, keys: :unique, name: @registry}, @registry)
    ra_sup = ensure_child!(@ra_supervisor, @ra_supervisor)
    task_sup = ensure_child!({Task.Supervisor, name: @task_supervisor}, @task_supervisor)

    store_pid =
      ensure_child!(
        {@production_store,
         name: @production_store,
         task_supervisor: @task_supervisor,
         runtime_admission_supervisor: @ra_supervisor,
         runtime_admission_force_ready: true,
         fence_force_ready: true,
         recovery_force_ready: true},
        @production_store
      )

    %{
      store: @production_store,
      store_pid: store_pid,
      ra_sup: ra_sup,
      task_sup: task_sup,
      registry: @registry,
      registry_pid: registry_pid
    }
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

  defp ensure_child!(child_spec, name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.start_child(@app_supervisor, child_spec) do
          {:ok, pid} when is_pid(pid) ->
            pid

          {:ok, pid, _info} when is_pid(pid) ->
            pid

          {:error, {:already_started, pid}} when is_pid(pid) ->
            pid

          other ->
            raise "RuntimeAdmissionTopology.start_fixed_production! failed for #{inspect(name)}: #{inspect(other)}"
        end
    end
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
