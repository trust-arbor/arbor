defmodule Arbor.Shell.Application do
  @moduledoc false

  use Application

  alias Arbor.Shell.AppleContainerUnitDrainCoordinator

  # Poll interval while waiting for coordinator/dependency restart during
  # prep_stop. Not a time cap on absence proof — only paces retry of the
  # sealed barrier admission call across rest_for_one turnover.
  @prep_stop_retry_ms 50

  @impl true
  def start(_type, _args) do
    executable_policy_opts = [startup_path: System.get_env("PATH", "")]
    startup_epoch = make_ref()
    # Immutable for the process lifetime: prep_stop must not re-read mutable
    # Application env (config can change after start and skip/force the barrier).
    children_started? = Application.get_env(:arbor_shell, :start_children, true) == true

    children =
      if children_started? do
        production_children(executable_policy_opts, startup_epoch)
      else
        []
      end

    # If executable policy or an authority restarts, terminate every later port
    # owner first. Native supervisors then kill their process groups before the
    # replacement boundary admits new work.
    opts = supervisor_options()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        {:ok, pid,
         %{
           startup_epoch: startup_epoch,
           children_started?: children_started?
         }}

      {:error, _reason} = error ->
        clear_startup_epoch(startup_epoch)
        error
    end
  end

  @doc """
  Planned application shutdown barrier.

  Runs while the supervision tree is still fully alive — before OTP begins
  child teardown. Exhaustive Apple Container unit drain + durable recovery
  converge here via `AppleContainerUnitDrainCoordinator.prepare_durable_shutdown/1`
  (nonblocking GenServer state machine). Coordinator `terminate/2` deliberately
  does not own this barrier so crash-driven rest_for_one turnover cannot
  deadlock on earlier siblings.

  Whether the barrier runs is decided from the immutable
  `children_started?` flag captured at `start/2`, not from live Application env.

  Retries across coordinator/dependency restarts until the barrier positively
  succeeds. Preserves the application state for `stop/1`.
  """
  @impl true
  def prep_stop(state) do
    if children_started?(state) do
      await_durable_shutdown_barrier()
    end

    state
  end

  @impl true
  def stop(%{startup_epoch: startup_epoch}) do
    clear_startup_epoch(startup_epoch)
  end

  # Backward-compatible clause for older application state shape.
  def stop(%{apple_container_boot_epoch: boot_epoch}) do
    clear_startup_epoch(boot_epoch)
  end

  def stop(_state), do: :ok

  @doc false
  @spec supervisor_options() :: keyword()
  def supervisor_options do
    [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]
  end

  @doc false
  @spec production_children(keyword(), reference() | nil) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def production_children(
        executable_policy_opts \\ [startup_path: ""],
        boot_epoch \\ nil
      ) do
    authority_opts = if is_reference(boot_epoch), do: [boot_epoch: boot_epoch], else: []

    [
      {Arbor.Shell.ExecutablePolicy, executable_policy_opts},
      {Arbor.Shell.AppleContainerControlPlaneAuthority, authority_opts},
      {Arbor.Shell.LinuxDependencyBaselineAuthority, authority_opts},
      # Image policy binds operator policy to the pinned baseline receipt.
      # Baseline/control-plane turnover tears this down; its own turnover
      # tears down every later execution owner (materializer/registry/ports).
      {Arbor.Shell.AppleContainerImagePolicyAuthority, authority_opts},
      # Temporary materialization workers. Authority failure rest_for_one-stops
      # this supervisor (and every later execution owner) before replacement.
      Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec(),
      {Arbor.Shell.ExecutionRegistry, []},
      {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one},
      # Durable unit-intent journal outlives unit-supervisor and coordinator
      # failures so recovery/admission can re-read authoritative intent. Missing
      # journal config starts a live disabled owner (Shell still boots).
      Arbor.Shell.AppleContainerUnitJournal,
      # Recovery composite (worker DS + reconciler). Loss turns over later unit
      # owners before a replacement startup sweep. shutdown: :infinity.
      Arbor.Shell.AppleContainerUnitRecoverySupervisor,
      # Unit owners sit after recovery so recovery authority remains available
      # while units restart; unit-supervisor shutdown leaves PortSession
      # available for final cleanup sessions.
      Arbor.Shell.AppleContainerUnitWorker.supervisor_child_spec(),
      # Drain coordinator is last under rest_for_one so reverse stop order
      # terminates it first. Planned exhaustive drain is NOT owned by
      # terminate/2 — Application.prep_stop runs prepare_durable_shutdown/1
      # (nonblocking state machine) while Journal, Recovery, UnitSupervisor,
      # and PortSession are still alive. Crash-driven terminate returns
      # promptly so parent EXIT can complete while an earlier sibling restarts.
      Arbor.Shell.AppleContainerUnitDrainCoordinator
    ]
  end

  # Production fail-closed: missing flag on older state shapes that did start
  # children still runs the barrier. Explicit false skips (intentionally
  # childless apps). Config mutation after start must not change this decision.
  defp children_started?(%{children_started?: false}), do: false
  defp children_started?(%{children_started?: true}), do: true
  # Older state without the flag: fail closed and run the barrier (production
  # historically started children by default).
  defp children_started?(%{startup_epoch: _}), do: true
  defp children_started?(%{apple_container_boot_epoch: _}), do: true
  defp children_started?(_other), do: true

  defp await_durable_shutdown_barrier do
    case Process.whereis(AppleContainerUnitDrainCoordinator) do
      pid when is_pid(pid) ->
        case AppleContainerUnitDrainCoordinator.prepare_durable_shutdown(pid) do
          :ok ->
            :ok

          {:error, _reason} ->
            # Coordinator/dependency mid-restart or transient rejection.
            # Do not begin child teardown until the barrier positively succeeds.
            Process.sleep(@prep_stop_retry_ms)
            await_durable_shutdown_barrier()
        end

      nil ->
        # Topology expected (children_started?) but coordinator not yet
        # registered — wait through rest_for_one replacement rather than
        # treating absence as success.
        Process.sleep(@prep_stop_retry_ms)
        await_durable_shutdown_barrier()
    end
  end

  defp clear_startup_epoch(startup_epoch) do
    Arbor.Shell.AppleContainerControlPlaneAuthority.clear_boot_epoch(startup_epoch)
    Arbor.Shell.LinuxDependencyBaselineAuthority.clear_boot_epoch(startup_epoch)
    Arbor.Shell.AppleContainerImagePolicyAuthority.clear_boot_epoch(startup_epoch)
    :ok
  end
end
