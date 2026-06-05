# Tests that touch arbor_security primitives (Identity.Registry,
# IssuerRegistry, BufferedStore) need those children running. The umbrella
# test config sets `:arbor_security, :start_children: false` so each app's
# test_helper opts in to what it needs — mirror that pattern here.
#
# We start the same BufferedStore instances + registries that arbor_security's
# own test_helper does, scoped to the scheduler test suite's needs (Phase 3+
# of the scheduler-privesc redesign — `Arbor.Scheduler.CapsFile` tests need
# Identity.Registry + IssuerRegistry to validate signed `.caps.json` files
# end-to-end).
buffered_store = Arbor.Persistence.BufferedStore
security_backend = Arbor.Security.Store.JSONFile

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
      # Phase 5 needs the full grant/revoke chain (SystemAuthority signs,
      # CapabilityStore persists, RateLimiter is referenced by constraint
      # checks). Mirror what arbor_security's own test_helper starts.
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []}
    ] do
  Supervisor.start_child(Arbor.Security.Supervisor, child)
end

ExUnit.start()
