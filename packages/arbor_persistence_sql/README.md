# Arbor Persistence SQL

PostgreSQL and SQLite implementations of the generic Store and EventLog
protocols in `arbor_persistence`. This adapter has no Kernel, Security, Signals,
product-schema or native-vector dependency.

The ordinary application starts no Repo and runs no migrations. Supply a Repo
through backend options (`repo: MyRepo`) or configure
`config :arbor_persistence_sql, repo: MyRepo`. The optional
`Arbor.Persistence.SQL.Repo` selects its adapter at compilation through
`:arbor_persistence_sql, :repo_adapter`. The legacy backend name
`Arbor.Persistence.QueryableStore.Postgres` also supports SQLite.

Independent generic migrations live in `priv/repo/migrations` under
`Arbor.Persistence.SQL.Repo.Migrations`. They preserve schema/protocol versions;
they do not replace an application's historical migration directory. Arbor's
host keeps its original full history and Repo identity.

Call `Arbor.Persistence.Core` for the generic facade. Contract providers are
configured atomically on the core application; the SQL adapter captures the
selected exact Record/Revision/Filter types before each operation. Host struct
identities and generation/revision fencing remain separate from standalone
owned defaults.

Database tests are excluded by default. For SQLite, set an explicit private
`PERSISTENCE_SQLITE_PATH`, select `PERSISTENCE_SQL_ADAPTER=sqlite`, and set
`PERSISTENCE_MIGRATE=1` before including database tests. For PostgreSQL, select
`postgres` and explicitly set `PERSISTENCE_POSTGRES_DB` plus the matching private
host/port/user/password variables. Select backend-specific test files as listed
in `test-lanes.json`; including `:database` can override a dialect exclusion.

The protocol's fencing and database-restart guarantees are not a power-loss or
distributed-failover certification. Restoring an obsolete binary must not
re-enable writers fenced by the installed schema epoch.
