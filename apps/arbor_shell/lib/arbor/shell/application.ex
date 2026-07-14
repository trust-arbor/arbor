defmodule Arbor.Shell.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    executable_policy_opts = [startup_path: System.get_env("PATH", "")]

    children =
      if Application.get_env(:arbor_shell, :start_children, true) do
        production_children(executable_policy_opts)
      else
        []
      end

    # If executable policy or control-plane authority restarts, terminate every
    # later port owner first. Native supervisors then kill their process groups
    # before the replacement boundary admits new work.
    opts = [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc false
  @spec production_children(keyword()) :: [
          Supervisor.child_spec() | {module(), term()} | module()
        ]
  def production_children(executable_policy_opts \\ [startup_path: ""]) do
    [
      {Arbor.Shell.ExecutablePolicy, executable_policy_opts},
      # Production owner starts with no authority-bearing caller opts.
      {Arbor.Shell.AppleContainerControlPlaneAuthority, []},
      {Arbor.Shell.ExecutionRegistry, []},
      {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
    ]
  end
end
