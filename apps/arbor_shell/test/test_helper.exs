# Add children to the empty app supervisor (start_children: false leaves it empty)
# Order must match Arbor.Shell.Application.production_children/1 (rest_for_one).
Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
)

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {Arbor.Shell.AppleContainerControlPlaneAuthority, []}
)

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {Arbor.Shell.LinuxDependencyBaselineAuthority, []}
)

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  Arbor.Shell.LinuxDependencyBaselineMaterializer.supervisor_child_spec()
)

Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
)

defmodule Arbor.Shell.TestAgentAuthorizer do
  @moduledoc false

  def authorize_command(agent_id, command, opts) do
    with %{command_name: command_name} <- Keyword.get(opts, :prepared_command) do
      resource = "arbor://shell/exec/#{command_name}"

      Arbor.Security.authorize(agent_id, resource, :execute,
        command: command,
        path: Keyword.get(opts, :cwd),
        verify_identity: false
      )
    else
      _other -> {:error, :invalid_prepared_command}
    end
  end
end

Application.put_env(:arbor_shell, :agent_authorizer, Arbor.Shell.TestAgentAuthorizer)

ExUnit.start(exclude: [:llm, :llm_local])
