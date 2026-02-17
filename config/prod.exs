import Config

config :logger, level: :info

# P0-3: Fail-closed on unknown identities in production.
# Unknown (unregistered) agent IDs are rejected during authorization.
config :arbor_security, strict_identity_mode: true
