defmodule Arbor.Security.Application do
  @moduledoc false

  use Application

  # Runtime bridge — arbor_persistence is above Security, no compile-time dep.
  # Named BufferedStore child specs are built only when the KernelRuntime
  # start profile is not :activation_only.
  @buffered_store Arbor.Persistence.BufferedStore
  @compile_env Mix.env()

  @impl true
  def start(_type, _args) do
    # Application owns the claim table for the VM lifetime. Creating it in a
    # freeze caller lets that process's exit drop the table and reopen insert_new.
    # A pre-existing named table owned by anyone else is squatting: fail closed
    # before freeze or supervision so startup cannot continue with a mutable
    # foreign claim table.
    with :ok <- Arbor.Security.Config.ensure_enforcement_toggle_claim_table() do
      start_supervised_children()
    end
  end

  defp start_supervised_children do
    Arbor.Security.Config.maybe_freeze_enforcement_toggles(@compile_env)

    signing_authority_owner_token = make_ref()

    children =
      if Application.get_env(:arbor_security, :start_children, true) do
        children_for_profile(
          Arbor.KernelRuntime.Config.start_profile(),
          signing_authority_owner_token
        )
      else
        []
      end

    # StateOwner and the broker are an ordered fail-closed pair. If the owner
    # loses its in-memory snapshot, the broker must be stopped before the owner
    # is restarted and then rebuilt only after the fresh owner is available.
    opts = [strategy: :rest_for_one, name: Arbor.Security.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp children_for_profile(:activation_only, signing_authority_owner_token) do
    core_security_children(signing_authority_owner_token)
  end

  defp children_for_profile(:full, signing_authority_owner_token) do
    buffered_store_children() ++ core_security_children(signing_authority_owner_token)
  end

  # Unknown profiles keep today's stores because KernelRuntime already fails closed.
  defp children_for_profile(_profile, signing_authority_owner_token) do
    buffered_store_children() ++ core_security_children(signing_authority_owner_token)
  end

  defp buffered_store_children do
    [
      Supervisor.child_spec(
        {@buffered_store,
         name: :arbor_security_capabilities,
         backend: security_backend(),
         write_mode: :sync,
         collection: "capabilities",
         hydration_limit: Arbor.Security.Config.max_global_capabilities()},
        id: :arbor_security_capabilities
      ),
      Supervisor.child_spec(
        {@buffered_store,
         name: :arbor_security_identities,
         backend: security_backend(),
         write_mode: :sync,
         collection: "identities"},
        id: :arbor_security_identities
      ),
      Supervisor.child_spec(
        {@buffered_store,
         name: :arbor_security_signing_keys,
         backend: security_backend(),
         write_mode: :sync,
         collection: "signing_keys"},
        id: :arbor_security_signing_keys
      ),
      Supervisor.child_spec(
        {@buffered_store,
         name: :arbor_security_issuers,
         backend: security_backend(),
         write_mode: :sync,
         collection: "issuers"},
        id: :arbor_security_issuers
      )
    ]
  end

  defp core_security_children(signing_authority_owner_token) do
    [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.IssuerRegistry, []},
      {Arbor.Security.Identity.NonceCache, []},
      # Classifies connected nodes for the signed-request replay gate. Before
      # NonceCache's consumers so the gate reads a live table; absent, every
      # peer counts as a replay peer (fail closed).
      {Arbor.Security.Identity.ReplayPeers, []},
      {Arbor.Security.SystemAuthority, []},
      # Persistent metadata outlives broker-only restarts; keys remain in SigningKeyStore.
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      # After key/identity stores + registry so open can fail-closed on status/key.
      {Arbor.Security.SigningAuthorityBroker, state_owner_token: signing_authority_owner_token},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []},
      {Arbor.Security.UriRegistry, []},
      # Ephemeral one-use delivery receipts (same-node). Last so restart
      # loses outstanding receipts fail-closed without cascading earlier children.
      {Arbor.Security.DeliveryReceiptBroker, []}
    ]
  end

  defp security_backend do
    Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)
  end
end
