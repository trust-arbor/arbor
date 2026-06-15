import Config

config :logger, level: :info

# Production security — all features enabled, fail-closed.
config :arbor_security,
  strict_identity_mode: true,
  identity_verification: true,
  capability_signing_required: true,
  policy_enforcer_enabled: true,
  approval_guard_enabled: true,
  uri_registry_enforcement: true,
  # Egress gate ON (2026-06-14). See the decision doc + dev.exs.
  egress_gate_enforcing: true

# Egress posture: default-allow for cloud providers so routine agent egress
# flows — the always-on taint conjunct (untrusted/hostile -> external = block) is
# the fail-closed protection. Tighten per-deployment to :ask with per-agent
# egress_modes provisioning for stricter control, and/or gate_on_premises_egress.
config :arbor_trust, default_egress_modes: %{external_provider: :allow}

config :arbor_memory,
  embedding_dedup_enabled: true
