# Standalone qualification entry

`qualify_standalone.py` defaults to the previously qualified Core workflow:
fresh external source/dependencies/build, strict compile, public in-memory
canary, production release, and the same canary with Mix code and application
metadata absent. The Core consumer and its three immutable public lock records
are unchanged by the adapter extension.

The CLI now accepts `--adapter core|sql|eventstore`. SQL defaults to private
SQLite; `--database postgres` requires `--postgres-fixture`. EventStore requires
that private PostgreSQL manifest and accepts no SQLite mode. Adapter consumers
live in their own packages' `examples/standalone` directories.

Adapter attempts copy Core and the selected adapter into sibling package roots
outside Arbor. Each consumer uses exactly the selected package's checked-in lock
subset. Installation, writer, fresh reader, release build and no-Mix release
reader are distinct stages. Readers compare sealed acknowledged receipts and
exercise stale version/CAS refusal without performing schema setup.

The PostgreSQL manifest must identify an owned, private, user-owned loopback
cluster and its live PID, data root, postmaster start epoch and executable. The
script verifies those facts before effects and checks connection identity before
creating its unique `arbor_cold_*` database. It does not use the manifest's
existing adapter test databases, inherit operator PostgreSQL defaults, stop the
cluster, or remove databases. Credentials are copied into private files and are
never printed; PostgreSQL failure logs stay private instead of being echoed.

Every attempt requires a new directory. Source SHA-256 manifests, immutable
receipts, separate stdout/stderr, command statuses and failure records remain
available after success or failure. Existing Core qualification evidence is not
modified or relabeled by later adapter runs.
