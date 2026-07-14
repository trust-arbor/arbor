defmodule Arbor.Shell.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    executable_policy_opts = [startup_path: System.get_env("PATH", "")]
    startup_epoch = make_ref()

    children =
      if Application.get_env(:arbor_shell, :start_children, true) do
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
        {:ok, pid, %{startup_epoch: startup_epoch}}

      {:error, _reason} = error ->
        clear_startup_epoch(startup_epoch)
        error
    end
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
      # Temporary materialization workers. Authority failure rest_for_one-stops
      # this supervisor (and every later execution owner) before replacement.
      Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec(),
      {Arbor.Shell.ExecutionRegistry, []},
      {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
    ]
  end

  defp clear_startup_epoch(startup_epoch) do
    Arbor.Shell.AppleContainerControlPlaneAuthority.clear_boot_epoch(startup_epoch)
    Arbor.Shell.LinuxDependencyBaselineAuthority.clear_boot_epoch(startup_epoch)
    :ok
  end
end
