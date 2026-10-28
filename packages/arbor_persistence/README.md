# Arbor Persistence Core

Standalone storage mechanisms from the authoritative Arbor monorepo. The public
facade is `Arbor.Persistence.Core`; the Arbor product retains its broader
`Arbor.Persistence` facade in the host application.

The core depends only on Jason, TypedStruct (at compile time) and Telemetry.
Starting `:arbor_persistence` creates no supervisor, stores, database processes,
or migrations. Callers start the required Agent/ETS stores, BufferedStore,
EventLog or checkpoint resources under their own supervision trees.

Optional SQL and EventStore packages depend on this core independently. Product
sessions, conversations, notices, vectors, credentials, schema history and backup
scheduling remain host-owned. Backend protocol epochs and persisted data are not
migrated as a side effect of dependency adoption.

## Contracts and composition

Standalone defaults are `Arbor.Persistence.Contracts.Record`, `Filter`,
`Revision`, `Store` and `AppendOperation`. A host may select its complete original
Record/Revision/Filter/AppendOperation provider set with the single trusted
`:contract_modules` map. Partial or malformed sets are rejected. Record structs
are never broadly coerced, and Store owners pin their contract identities before
allocating storage. Client operations resolve the same owner and binding; changing
application config does not change a live store's generation/CAS interpretation.

`:authorization_provider` must implement `authorize/4`. Missing, malformed,
raising, throwing or exiting providers fail closed. Pending approval is returned
unchanged and never performs a storage effect. `:event_bus` optionally provides
`emit/4` and `subscribe/2` for best-effort observability/invalidation transport.
Supplying a provider does not itself prove cross-node delivery or coherence.

Use the package's own tests and an independent cold consumer/release to verify
its dependency closure. Arbor's broader product release gates are separate.
