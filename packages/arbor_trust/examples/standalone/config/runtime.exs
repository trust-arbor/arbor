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
  invocation_audit_sink: TrustStandaloneConsumer.DurableSink,
  session_token_secret: System.fetch_env!("CAPABILITIES_COLD_SESSION_SECRET"),
  approval_receipt_issuer_owner: %{
    application: :arbor_trust,
    path: [Arbor.Trust.Supervisor, Arbor.Trust.ConfirmationTracker],
    registered_name: Arbor.Trust.ConfirmationTracker
  },
  # Explicit first-install local-host mode, never an OIDC-production default.
  allow_local_human_identity: true,
  oidc: [],
  uri_registry_enforcement: true,
  uri_registration_providers: [TrustStandaloneConsumer.Catalog],
  uri_bootstrap_providers: [TrustStandaloneConsumer.Catalog],
  signing_key_owner_roles: %{
    system_authority: role.(:arbor_capabilities, Arbor.Security.SystemAuthority, []),
    signing_broker: role.(:arbor_capabilities, Arbor.Security.SigningAuthorityBroker, []),
    channel_broker: role.(:arbor_capabilities, Arbor.Security.ChannelAuthorityBroker, []),
    scheduler_owner:
      role.(:trust_standalone_consumer, TrustStandaloneConsumer.Provisioner, [
        :session
      ]),
    trust_grant_owner: %{
      application: :arbor_trust,
      path: [Arbor.Trust.Supervisor, Arbor.Trust.CapabilityGrantOwner],
      registered_name: Arbor.Trust.CapabilityGrantOwner,
      purposes: [:trust_capability_grant]
    },
    system_lifecycle_owner:
      role.(
        :trust_standalone_consumer,
        TrustStandaloneConsumer.DormantSystemLifecycleOwner,
        []
      )
  }

config :arbor_trust,
  runtime_host: nil,
  runtime: [start_profile: :full],
  start_children: true,
  profile_store: [mode: :memory],
  profile_sync_transport: nil,
  observation: nil,
  pubsub: TrustStandaloneConsumer.PubSub,
  approval_evidence_provider: ComposedTrustProof.ApprovalOwner,
  policy_enforcer_enabled: true,
  approval_guard_enabled: true
