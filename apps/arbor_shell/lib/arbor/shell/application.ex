defmodule Arbor.Shell.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    executable_policy_opts = [startup_path: System.get_env("PATH", "")]

    children =
      if Application.get_env(:arbor_shell, :start_children, true) do
        [
          {Arbor.Shell.ExecutablePolicy, executable_policy_opts},
          {Arbor.Shell.ExecutionRegistry, []},
          {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
        ]
      else
        []
      end

    # If executable policy or execution tracking restarts, terminate every later
    # port owner first. Native supervisors then kill their process groups before
    # the replacement boundary admits new work.
    opts = [strategy: :rest_for_one, name: Arbor.Shell.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
