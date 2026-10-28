# SQL adapter adoption

This package adopts the generic SQL mechanisms from current Arbor Main
`64d3adf1cf7094b8bdcf620f3b3e1a2e2b326cf4`. The frozen sibling is a boundary
reference only. See the [family adoption decision](../arbor_persistence/ADOPTION.md),
[family provenance](../arbor_persistence/adoption-source-map.json) and this
package's [source inventory](adoption-source-map.json).

The package owns `Arbor.Persistence.QueryableStore.Postgres` (also used for
SQLite), `Arbor.Persistence.EventLog.Ecto`, protocol repair, the three generic
schemas, `MigrationHelper`, `SQLiteBusyTimeout`, SQL configuration and the repair
Mix task. The busy handler keeps its exact module identity and original bytes.
Its only Arbor dependency is the Core package through an ordinary runtime path
dependency. The package starts no Repo and runs no migrations automatically.

`Arbor.Persistence.SQL.Repo` is an independent optional Repo selected through
`:arbor_persistence_sql`. The product retains `Arbor.Persistence.Repo` under
`:arbor_persistence_host`, its native/domain schemas, its DatabaseCase and all
32 original migrations unchanged. The 11 generic SQL migrations have distinct
`Arbor.Persistence.SQL.Repo.Migrations` module names, preserving their Main
bodies and protocol versions. They do not replace the host's history. Provisioning
and applying either history is an explicit consumer operation.

Operations capture one trusted Record/Revision/Filter provider binding and
inherit an enclosing Core storage-owner scope. Host calls retain the original
Kernel contract structs; standalone calls use Core's owned defaults. SQL rows,
logical IDs, timestamps, generation/revision fences, namespace/key identity and
committed-event fingerprints retain their current Main behavior. Foreign
lookalike structs are rejected rather than broadly converted.

[Qualification metadata](qualification.json) records default and explicit
SQLite/PostgreSQL lanes separately. Reported checks passed: default 67 tests
(119 excluded), SQLite 161 tests and PostgreSQL 175 tests, all zero failures.
The first PostgreSQL run exposed a test assertion that accepted SQLite `IN`
text but rejected equivalent PostgreSQL `= ANY`; the corrected assertion retains
its one-query/bounded-row requirements, and both dialect reruns pass.

Final cold SQLite and PostgreSQL consumer/release lanes passed after the Core
owner-binding repair, with all 18 stages bound to current source and exact
Core+SQL closures. Focused host integration also passed. The full fast-suite and quality gates remain open; final committed-input
qualification and exact revert are recorded in the family task ledger.
Database-restart evidence is not a power-loss or distributed-failover guarantee. An obsolete writer must remain
fenced by an installed schema epoch.

The complete family rollback snapshot was reverted to the exact Main base,
freshly compiled, and passed the original Persistence/EventStore suites plus
50 Security authority canaries. Final committed-adoption binding remains in the
family record.

The post-lint selected database suite and strict compile passed again, followed
by fresh source-bound cold consumer/release checks. The final family record
reports zero introduced scoped lint findings.
