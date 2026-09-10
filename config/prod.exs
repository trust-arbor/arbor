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

# The Repo adapter is compile-time Ecto state. Production builds default to
# isolated SQLite and opt into Postgres explicitly with ARBOR_DB=postgres.
prod_repo_adapter =
  case System.get_env("ARBOR_DB", "sqlite") do
    "sqlite" -> Ecto.Adapters.SQLite3
    "postgres" -> Ecto.Adapters.Postgres
    other -> raise "unsupported production ARBOR_DB value: #{inspect(other)}"
  end

# Runtime credentials and paths are configured in runtime.exs so release builds
# never capture the build host's home directory or database credentials.
{prod_oban_engine, prod_oban_notifier} =
  case prod_repo_adapter do
    Ecto.Adapters.Postgres -> {Oban.Engines.Basic, Oban.Notifiers.Postgres}
    _ -> {Oban.Engines.Lite, Oban.Notifiers.PG}
  end

config :arbor_persistence,
  start_repo: true,
  repo_adapter: prod_repo_adapter

config :arbor_scheduler, Oban,
  engine: prod_oban_engine,
  notifier: prod_oban_notifier

config :arbor_memory,
  # The historical backend name supports the selected Repo adapter: SQLite by
  # default, PostgreSQL only with ARBOR_DB=postgres. Critical Memory mutations
  # use the owner's acknowledged APIs; ordinary async writes keep their policy.
  persistence_backend: Arbor.Persistence.QueryableStore.Postgres,
  embedding_dedup_enabled: true,
  maintenance_archive_target: [
    name: :memory_events_durable,
    backend: Arbor.Persistence.EventLog.Ecto,
    opts: [repo: Arbor.Persistence.Repo]
  ],
  # VP-05D2C3I1A — durable mutation admission (QueryableStore Record authority)
  mutation_admission_backend: Arbor.Persistence.QueryableStore.Postgres,
  mutation_admission_backend_opts: [repo: Arbor.Persistence.Repo]

# Keep current-run lifecycle and Engine checkpoints on the same selected Repo.
# Backend observations remain authoritative; these classes never elevate an
# unavailable or weaker store. Credentials and database paths stay runtime-owned.
config :arbor_orchestrator, :run_journal,
  backend: Arbor.Persistence.QueryableStore.Postgres,
  store_name: :arbor_pipeline_run_lifecycle,
  backend_opts: [repo: Arbor.Persistence.Repo],
  start_store: false,
  durability_class: :node_restart

config :arbor_orchestrator, :engine_checkpoints,
  store: Arbor.Persistence.QueryableStore.Postgres,
  store_name: :arbor_orchestrator_checkpoints,
  store_opts: [repo: Arbor.Persistence.Repo],
  start_store: false,
  store_child_opts: [],
  durability_class: :node_restart

import_config "provider_route_profile.exs"
