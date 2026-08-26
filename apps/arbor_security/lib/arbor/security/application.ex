defmodule Arbor.Security.Application do
  @moduledoc false

  use Application

  alias Arbor.Security.ProviderGate

  @compile_env Mix.env()
  @provider_gate Arbor.Security.ProviderGate
  @supervisor Arbor.Security.Supervisor

  @impl true
  def start(_type, _args) do
    # Application owns the claim table for the VM lifetime. Creating it in a
    # freeze caller lets that process's exit drop the table and reopen insert_new.
    # A pre-existing named table owned by anyone else is squatting: fail closed
    # before freeze or supervision so startup cannot continue with a mutable
    # foreign claim table.
    with :ok <- Arbor.Security.Config.ensure_enforcement_toggle_claim_table(),
         :ok <- Arbor.Security.Config.ensure_authority_root_claim_table() do
      start_supervised_children()
    end
  end

  defp start_supervised_children do
    Arbor.Security.Config.maybe_freeze_enforcement_toggles(@compile_env)

    signing_authority_owner_token = make_ref()

    with {:ok, snapshot} <- Arbor.Security.Config.startup_store_snapshot(:application),
         {:ok, profile} <- admit_profile(snapshot.start_profile) do
      children = children_from_snapshot(snapshot, signing_authority_owner_token)
      start_security_supervisor(profile, children)
    end
  end

  defp admit_profile(profile) when profile in [:full, :activation_only], do: {:ok, profile}
  defp admit_profile(other), do: {:error, {:invalid_start_profile, other}}

  defp start_security_supervisor(_profile, []) do
    Supervisor.start_link([], strategy: :rest_for_one, name: @supervisor)
  end

  defp start_security_supervisor(:full, children) do
    Arbor.KernelRuntime.start_provider_gate_supervisor(
      [ProviderGate.child_spec([]) | children],
      @supervisor,
      @provider_gate
    )
  end

  defp start_security_supervisor(_profile, children) do
    Supervisor.start_link(children, strategy: :rest_for_one, name: @supervisor)
  end

  defp children_from_snapshot(%{start_children: false}, _signing_authority_owner_token), do: []
  defp children_from_snapshot(%{start_children: nil}, _signing_authority_owner_token), do: []

  defp children_from_snapshot(snapshot, signing_authority_owner_token) do
    children_for_profile(snapshot, signing_authority_owner_token)
  end

  defp children_for_profile(
         %{start_profile: :activation_only} = snapshot,
         signing_authority_owner_token
       ) do
    core_security_children(snapshot, signing_authority_owner_token)
  end

  defp children_for_profile(snapshot, signing_authority_owner_token) do
    security_store_children(snapshot) ++
      core_security_children(snapshot, signing_authority_owner_token)
  end

  defp security_store_children(snapshot) do
    [
      authority_store_child(
        snapshot,
        :arbor_security_capabilities,
        "capabilities",
        hydration_limit: snapshot.capabilities_hydration_limit
      ),
      authority_store_child(snapshot, :arbor_security_identities, "identities"),
      authority_store_child(snapshot, :arbor_security_signing_keys, "signing_keys"),
      authority_store_child(snapshot, :arbor_security_issuers, "issuers")
    ]
  end

  defp authority_store_child(snapshot, name, namespace, extra \\ []) do
    store_opts =
      Arbor.Security.Config.authority_store_start_opts(name, namespace, snapshot, extra)

    Supervisor.child_spec({Arbor.Security.AuthorityStore, store_opts}, id: name)
  end

  defp core_security_children(snapshot, signing_authority_owner_token) do
    [
      {Arbor.Security.Identity.Registry, []},
      {Arbor.Security.IssuerRegistry, []},
      {Arbor.Security.Identity.NonceCache, []},
      # Classifies connected nodes for the signed-request replay gate. Before
      # NonceCache's consumers so the gate reads a live table; absent, every
      # peer counts as a replay peer (fail closed).
      {Arbor.Security.Identity.ReplayPeers, []},
      {Arbor.Security.SystemAuthority, []},
      # The StateOwner/Broker pair is ordered for rest_for_one recovery. The
      # owner precedes the broker so owner loss restarts both and no broker can
      # retain stale owner authority; broker-only loss restarts only the broker
      # and preserves owner-held metadata. Their shared opaque startup token
      # binds the pair. The key/identity stores and registries above must
      # already be live before either child starts.
      {Arbor.Security.SigningAuthorityStateOwner, broker_token: signing_authority_owner_token},
      {Arbor.Security.SigningAuthorityBroker, state_owner_token: signing_authority_owner_token},
      {Arbor.Security.Constraint.RateLimiter, []},
      {Arbor.Security.CapabilityStore, []},
      {Arbor.Security.Reflex.Registry, []},
      {Arbor.Security.UriRegistry, []},
      {Arbor.Security.AuditJournalOwner,
       Arbor.Security.Config.audit_journal_start_opts(snapshot)},
      # Ephemeral one-use delivery receipts (same-node). Last so restart
      # loses outstanding receipts fail-closed without cascading earlier children.
      {Arbor.Security.DeliveryReceiptBroker, []}
    ]
  end
end
