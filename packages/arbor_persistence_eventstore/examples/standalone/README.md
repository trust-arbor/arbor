# Independent EventStore consumer

This ordinary application depends on the EventStore adapter and its sibling
Core package, with no Arbor Host, Kernel, Security, Signals or SQL adapter.
PostgreSQL is required, with an explicit private owned-cluster manifest:

```sh
python3 packages/arbor_persistence/scripts/qualify_standalone.py \
  --adapter eventstore \
  --postgres-fixture /absolute/private/postgres-fixture.json \
  --work-dir /absolute/fresh/private/eventstore-qualification \
  --mix "$PWD/bin/mix"
```

The qualifier copies production Core and EventStore source, the adapter's exact
public lock subset and this consumer outside Arbor. It verifies the owned
loopback postmaster's PID, data root, start time, executable and connection
identity before creating a unique attempt database. Credentials stay in private
files, operator PostgreSQL defaults are discarded, and attempts are retained.

Base EventStore initialization and the explicit Arbor protocol installer run in
a separate migration stage. Application startup starts no EventStore or schema
installer. The writer and each reader explicitly supervise their own EventStore.
The writer seals the exact acknowledged event, operation and fingerprint. A
fresh BEAM and a production release without Mix reopen the database, verify the
exact receipts and reconciliation, and reject a stale expected stream version.
No reader runs schema installation or repairs the database implicitly.

The optional durability capability remains `{:error, :unsupported}`. Successful
private database recovery does not invent a durability declaration, nor prove
power-loss or distributed failover. Compiled, loaded and started Arbor closure
must be exactly Core plus EventStore, with the bare Host facade, Kernel, Security,
Signals and SQL adapter unavailable. Source and acknowledgment SHA-256 manifests
are rechecked across every stage. Logs, private configuration and failed attempts
remain in the chosen directory.
