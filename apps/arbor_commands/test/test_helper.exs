# The shared test config leaves Shell's supervisor empty. Coding benchmark
# provenance tests exercise its bounded direct-argv facade.
for child <- [
      {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")},
      {Arbor.Shell.ExecutionRegistry, []},
      {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
    ] do
  case Supervisor.start_child(Arbor.Shell.Supervisor, child) do
    {:ok, _pid} -> :ok
    {:error, {:already_started, _pid}} -> :ok
  end
end

ExUnit.start(exclude: [:llm, :llm_local])
