import Config
root = System.fetch_env!("PAIRED_STATE_ROOT")
repo = Arbor.Persistence.SQL.Repo

sql_target = %{
  name: :historian_durable_event_log,
  backend: Arbor.Persistence.EventLog.Ecto,
  opts: [repo: repo]
}

config :arbor_persistence_sql, repo,
  database: System.fetch_env!("PAIRED_SQL_DATABASE"),
  pool_size: 2,
  busy_timeout: 5_000,
  journal_mode: :wal,
  synchronous: :full,
  stacktrace: false,
  log: false

config :paired_standalone_consumer, historian_sql_target: sql_target

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
  invocation_audit_sink: PairedStandaloneConsumer.InvocationSink,
  session_token_secret: System.fetch_env!("CAPABILITIES_COLD_SESSION_SECRET"),
  authority_audit_consumer_name: Arbor.Historian.AuthorityAuditPuller,
  authority_audit_consumer_application: :arbor_historian,
  approval_receipt_issuer_owner: %{
    application: :arbor_trust,
    path: [Arbor.Trust.Supervisor, Arbor.Trust.ConfirmationTracker],
    registered_name: Arbor.Trust.ConfirmationTracker
  },
  allow_local_human_identity: true,
  oidc: [],
  uri_registry_enforcement: true,
  uri_registration_providers: [PairedStandaloneConsumer.Catalog],
  uri_bootstrap_providers: [PairedStandaloneConsumer.Catalog],
  signing_key_owner_roles: %{
    system_authority: %{
      application: :arbor_capabilities,
      path: [Arbor.Security.SystemAuthority],
      registered_name: Arbor.Security.SystemAuthority,
      purposes: []
    },
    signing_broker: %{
      application: :arbor_capabilities,
      path: [Arbor.Security.SigningAuthorityBroker],
      registered_name: Arbor.Security.SigningAuthorityBroker,
      purposes: []
    },
    channel_broker: %{
      application: :arbor_capabilities,
      path: [Arbor.Security.ChannelAuthorityBroker],
      registered_name: Arbor.Security.ChannelAuthorityBroker,
      purposes: []
    },
    scheduler_owner: %{
      application: :paired_standalone_consumer,
      path: [PairedStandaloneConsumer.Provisioner],
      registered_name: PairedStandaloneConsumer.Provisioner,
      purposes: [:session]
    },
    trust_grant_owner: %{
      application: :arbor_trust,
      path: [Arbor.Trust.Supervisor, Arbor.Trust.CapabilityGrantOwner],
      registered_name: Arbor.Trust.CapabilityGrantOwner,
      purposes: [:trust_capability_grant]
    },
    system_lifecycle_owner: %{
      application: :paired_standalone_consumer,
      path: [PairedStandaloneConsumer.DormantLifecycleOwner],
      registered_name: PairedStandaloneConsumer.DormantLifecycleOwner,
      purposes: []
    }
  }

config :arbor_trust,
  runtime_host: nil,
  runtime: [start_profile: :full],
  start_children: true,
  observation: nil,
  profile_sync_transport: nil,
  pubsub: PairedStandaloneConsumer.PubSub,
  action_profile_provider: nil,
  feature_domain_owners: %{},
  approval_evidence_provider: ComposedTrustProof.ApprovalOwner,
  profile_store: [
    mode: :durable,
    backend: Arbor.Persistence.QueryableStore.Postgres,
    backend_opts: [repo: repo],
    collection: "trust_profiles",
    buffered_name: :arbor_trust_profiles
  ]

config :arbor_historian,
  start_children: true,
  authorizer: PairedStandaloneConsumer.Authorizer,
  authority_source: nil,
  event_provider: nil,
  durable_event_log_target: sql_target
