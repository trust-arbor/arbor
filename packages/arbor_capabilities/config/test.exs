import Config

# App-local tests own private authority state; they never load product config.
config :arbor_capabilities,
  runtime_host: nil,
  runtime: [start_profile: :full],
  start_children: false,
  storage_backend: nil,
  audit_journal_mode: :ephemeral,
  distributed_signals: false,
  capability_signing_required: false,
  identity_verification: false,
  strict_identity_mode: false,
  reflex_checking_enabled: false,
  policy_enforcer_enabled: false,
  approval_guard_enabled: false,
  uri_registry_enforcement: false,
  egress_gate_enforcing: false,
  system_authority_mode: :ephemeral,
  session_token_secret: "arbor-test-session-token-secret-32-bytes-minimum",
  oidc_registration_mode: :allow,
  master_key_path:
    Path.join([
      System.tmp_dir!(),
      "arbor-capabilities-test-#{System.pid()}",
      "master.key"
    ]),
  # The broker requires a closed issuer descriptor at startup. This dormant
  # test-only name grants no claim until an exact supervised owner exists.
  approval_receipt_issuer_owner: %{
    application: :arbor_capabilities,
    path: [Arbor.Security.TestSupport.UnoccupiedApprovalReceiptIssuerOwner],
    registered_name: Arbor.Security.TestSupport.UnoccupiedApprovalReceiptIssuerOwner
  },
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
    # Registry startup admits a complete closed role vocabulary. These test-only
    # names are unoccupied, so owner matching denies until a focused test owns one.
    scheduler_owner: %{
      application: :arbor_capabilities,
      path: [Arbor.Security.TestSupport.UnoccupiedSchedulerOwner],
      registered_name: Arbor.Security.TestSupport.UnoccupiedSchedulerOwner,
      purposes: [:scheduler]
    },
    trust_grant_owner: %{
      application: :arbor_capabilities,
      path: [Arbor.Security.TestSupport.UnoccupiedTrustGrantOwner],
      registered_name: Arbor.Security.TestSupport.UnoccupiedTrustGrantOwner,
      purposes: [:trust_capability_grant]
    },
    system_lifecycle_owner: %{
      application: :arbor_capabilities,
      path: [Arbor.Security.TestSupport.UnoccupiedSystemLifecycleOwner],
      registered_name: Arbor.Security.TestSupport.UnoccupiedSystemLifecycleOwner,
      purposes: [:system_lifecycle]
    }
  }
