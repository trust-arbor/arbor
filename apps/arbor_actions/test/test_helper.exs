# Add children to the empty app supervisors (start_children: false leaves them empty)
# arbor_actions tests need shell, persistence, and signal processes
Supervisor.start_child(Arbor.Shell.Supervisor, {Arbor.Shell.ExecutionRegistry, []})

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

ExUnit.start()
