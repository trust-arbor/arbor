# Add children to the empty app supervisor (start_children: false leaves it empty)
Code.require_file("support/oidc_test_helper.ex", __DIR__)

# Security state synchronization is load-bearing and fails closed when Signals
# is unavailable. Test config leaves dependency supervision trees empty, so
# start the Signals children before the security stores below.
Application.ensure_all_started(:arbor_signals)

for child <- [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.Bus, []},
      {Arbor.Signals.Relay, []}
    ] do
  case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
    {:ok, _pid} ->
      :ok

    {:error, {:already_started, _pid}} ->
      :ok

    {:error, :already_present} ->
      {module, _opts} = child
      :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
      {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)

    {:error, reason} ->
      IO.warn("Failed to start #{inspect(elem(child, 0))}: #{inspect(reason)}")
  end
end

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

signing_authority_owner_token = make_ref()

for child <- [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.IssuerRegistry, []},
      {Arbor.Security.Identity.NonceCache, []},
      {Arbor.Security.SystemAuthority, []},
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      # After identity registry + signing-key store (started above).
      {Arbor.Security.SigningAuthorityBroker, state_owner_token: signing_authority_owner_token},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []}
    ] do
  Supervisor.start_child(Arbor.Security.Supervisor, child)
end

ExUnit.start(exclude: [:llm, :llm_local])
