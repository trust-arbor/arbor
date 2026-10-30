import Config
root = System.fetch_env!("CAPABILITIES_COLD_STATE_ROOT")

role = fn application, name, purposes ->
  %{application: application, path: [name], registered_name: name, purposes: purposes}
end

config :arbor_capabilities,
  runtime_host: nil,
  runtime: [start_profile: :full],
  start_children: true,
  signal_transport: nil,
  distributed_signals: false,
  authority_state_root: Path.join(root, "authority"),
  master_key_path: Path.join(root, "authority/signing-master.key"),
  revocation_ledger_path:
    Path.join(root, "independent-revocations/capability_revocations.v1.json"),
  storage_backend: Arbor.Security.Store.JSONFile,
  audit_journal_mode: :durable,
  system_authority_mode: :persistent,
  strict_identity_mode: true,
  identity_verification: true,
  capability_signing_required: true,
  constraint_enforcement_enabled: true,
  delegation_chain_verification_enabled: true,
  invocation_audit_mode: :required,
  invocation_audit_sink: CapabilitiesStandaloneConsumer.DurableSink,
  session_token_secret: System.fetch_env!("CAPABILITIES_COLD_SESSION_SECRET"),
  approval_receipt_issuer_owner: %{
    application: :capabilities_standalone_consumer,
    path: [CapabilitiesStandaloneConsumer.DormantApprovalIssuer],
    registered_name: CapabilitiesStandaloneConsumer.DormantApprovalIssuer
  },
  # Explicit first-install local-host mode, never an OIDC-production default.
  allow_local_human_identity: true,
  oidc: [],
  uri_registry_enforcement: true,
  uri_registration_providers: [CapabilitiesStandaloneConsumer.Catalog],
  uri_bootstrap_providers: [CapabilitiesStandaloneConsumer.Catalog],
  signing_key_owner_roles: %{
    system_authority: role.(:arbor_capabilities, Arbor.Security.SystemAuthority, []),
    signing_broker: role.(:arbor_capabilities, Arbor.Security.SigningAuthorityBroker, []),
    channel_broker: role.(:arbor_capabilities, Arbor.Security.ChannelAuthorityBroker, []),
    scheduler_owner:
      role.(:capabilities_standalone_consumer, CapabilitiesStandaloneConsumer.Provisioner, [
        :session
      ]),
    trust_grant_owner:
      role.(
        :capabilities_standalone_consumer,
        CapabilitiesStandaloneConsumer.DormantTrustGrantOwner,
        []
      ),
    system_lifecycle_owner:
      role.(
        :capabilities_standalone_consumer,
        CapabilitiesStandaloneConsumer.DormantSystemLifecycleOwner,
        []
      )
  }
