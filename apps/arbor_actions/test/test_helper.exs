# Add children to the empty app supervisors (start_children: false leaves them empty)
# arbor_actions tests need shell, persistence, and signal processes

# Test-only Linux baseline materializer Agent + shared WorkspaceLeaseRegistry
# rewire. Production Application starts the registry with Arbor.Shell; tests
# replace that child with the same module, configured only via start opts.
_ = Arbor.Actions.TestLinuxBaselineMaterializer.start_link()

case Supervisor.terminate_child(
       Arbor.Actions.Supervisor,
       Arbor.Actions.Coding.WorkspaceLeaseRegistry
     ) do
  :ok ->
    _ =
      Supervisor.delete_child(
        Arbor.Actions.Supervisor,
        Arbor.Actions.Coding.WorkspaceLeaseRegistry
      )

    {:ok, _} =
      Supervisor.start_child(
        Arbor.Actions.Supervisor,
        {Arbor.Actions.Coding.WorkspaceLeaseRegistry,
         [
           linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
         ]}
      )

  {:error, :not_found} ->
    {:ok, _} =
      Supervisor.start_child(
        Arbor.Actions.Supervisor,
        {Arbor.Actions.Coding.WorkspaceLeaseRegistry,
         [
           linux_dependency_baseline_materializer: Arbor.Actions.TestLinuxBaselineMaterializer
         ]}
      )

  other ->
    IO.warn("Failed to rewire WorkspaceLeaseRegistry for tests: #{inspect(other)}")
end

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {Arbor.Shell.ExecutablePolicy, startup_path: System.get_env("PATH", "")}
)

Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

Supervisor.start_child(
  Arbor.Shell.Supervisor,
  {DynamicSupervisor, name: Arbor.Shell.PortSessionSupervisor, strategy: :one_for_one}
)

for child <- [
      {Arbor.Persistence.QueryableStore.ETS, name: :jobs},
      {Arbor.Persistence.EventLog.ETS, name: :event_log}
    ] do
  Supervisor.start_child(Arbor.Persistence.Supervisor, child)
end

# Signal system — emit functions need Store + Bus running
for child <- [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.Bus, []}
    ] do
  Supervisor.start_child(Arbor.Signals.Supervisor, child)
end

# Security system — needed for signing integration tests
buffered_store = Arbor.Persistence.BufferedStore

security_backend =
  Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

for {name, collection} <- [
      {:arbor_security_capabilities, "capabilities"},
      {:arbor_security_identities, "identities"},
      {:arbor_security_signing_keys, "signing_keys"}
    ] do
  child =
    Supervisor.child_spec(
      {buffered_store,
       name: name, backend: security_backend, write_mode: :sync, collection: collection},
      id: name
    )

  case Supervisor.start_child(Arbor.Security.Supervisor, child) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> IO.warn("Failed to start #{name}: #{inspect(reason)}")
  end
end

for child <- [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ] do
  case Supervisor.start_child(Arbor.Security.Supervisor, child) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
    {:error, reason} -> IO.warn("Failed to start #{inspect(child)}: #{inspect(reason)}")
  end
end

ExUnit.start(exclude: [:llm, :llm_local])
