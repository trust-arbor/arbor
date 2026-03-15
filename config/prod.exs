import Config

config :logger, level: :info

# Production security — all features enabled, fail-closed.
config :arbor_security,
  strict_identity_mode: true,
  identity_verification: true,
  capability_signing_required: true,
  policy_enforcer_enabled: true,
  approval_guard_enabled: true,
  uri_registry_enforcement: true

config :arbor_memory,
  embedding_dedup_enabled: true
