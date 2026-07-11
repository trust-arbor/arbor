# Add children to the empty app supervisor (start_children: false leaves it empty)
# Start BufferedStore instances first (used by CapabilityStore, Registry, and SigningKeyStore)
buffered_store = Arbor.Persistence.BufferedStore

security_backend =
  Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

for {name, collection} <- [
      {:arbor_security_capabilities, "capabilities"},
      {:arbor_security_identities, "identities"},
      {:arbor_security_signing_keys, "signing_keys"},
      {:arbor_security_issuers, "issuers"}
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
      {Arbor.Security.IssuerRegistry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      # After identity registry + signing-key store (started above).
      {Arbor.Security.SigningAuthorityBroker, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ] do
  Supervisor.start_child(Arbor.Security.Supervisor, child)
end

ExUnit.start(exclude: [:llm, :llm_local])
