# Load test support modules (elixirc_paths includes test/support but beam may not be on code path)
Code.require_file("support/sdlc_test_helpers.ex", __DIR__)
Code.require_file("support/mock_ai.ex", __DIR__)

# Add children to the empty app supervisor (start_children: false leaves it empty)
config = Arbor.SDLC.Config.new()

for child <- [
      {Arbor.SDLC.PersistentFileTracker, [name: Arbor.SDLC.FileTracker, config: config]},
      {Task.Supervisor, name: Arbor.SDLC.TaskSupervisor}
    ] do
  Supervisor.start_child(Arbor.SDLC.Supervisor, child)
end

# Ensure Shell infrastructure is available for SessionRunner (PortSession-based execution)
for child <- [
      {Arbor.Shell.ExecutionRegistry, []},
      {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
    ] do
  case Supervisor.start_child(Arbor.Shell.Supervisor, child) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, _} -> :ok
  end
end

ExUnit.start()
