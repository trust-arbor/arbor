# Independent SQL consumer

This ordinary application depends on the SQL package and its sibling Core
package, with no Arbor Host, Kernel, Security, Signals or EventStore adapter.
The qualifier copies both packages and the exact SQL lock subset into a fresh
directory outside Arbor. Dependencies and builds belong only to that attempt.

Run the SQLite proof from the repository root:

```sh
python3 packages/arbor_persistence/scripts/qualify_standalone.py \
  --adapter sql --work-dir /absolute/fresh/private/sql-qualification \
  --mix "$PWD/bin/mix"
```

For PostgreSQL, explicitly select the database kind and the private owned-cluster
manifest supplied by the qualification coordinator:

```sh
python3 packages/arbor_persistence/scripts/qualify_standalone.py \
  --adapter sql --database postgres \
  --postgres-fixture /absolute/private/postgres-fixture.json \
  --work-dir /absolute/fresh/private/sql-postgres-qualification \
  --mix "$PWD/bin/mix"
```

The PostgreSQL guard verifies the owned loopback postmaster's PID, data root,
start time, executable and connection identity before creating a uniquely named
attempt database. It never selects an existing product or adapter test database.
Credentials stay in private files, and operator PostgreSQL environment variables
are discarded. Failed attempts and databases remain available for inspection.

Installation is a separate explicit stage. Starting the package creates no Repo
or database schema. Each installer, writer and reader supervises its own Repo.
The writer persists a Record, advances CAS, deletes and reinserts into generation
two, advances CAS again, and seals its exact acknowledged Record and EventLog
receipts. A fresh BEAM and a production release without Mix reopen the same
private database and compare exact Record/event identity and fingerprints. Both
reject the old generation-one CAS and a stale expected stream version, leaving
the acknowledged state unchanged.

SHA-256 manifests protect copied source and sealed receipts across every stage.
Compiled, loaded and started Arbor applications must be exactly Core plus SQL;
the bare Host facade and the other adapter must remain unavailable. This proves
private database close/reopen across BEAMs, not power-loss or failover behavior.
