# Platform inventory physical-owner scope

The live PlatformInventory report is now
`arbor.packaging.platform_inventory.v2`. This is a reviewed scope successor
to the original nine-application E0A census. Persistence, Capabilities, Trust
and Historian retain their complete source families across explicit package
and product Host roots. Moving a source does not remove it from review.

| Physical root | Actual application owner |
| --- | --- |
| `packages/arbor_persistence/lib/` | `arbor_persistence` |
| `packages/arbor_persistence_sql/lib/` | `arbor_persistence_sql` |
| `packages/arbor_persistence_eventstore/lib/` | `arbor_persistence_eventstore` |
| `apps/arbor_persistence_host/lib/` | `arbor_persistence_host` |
| `packages/arbor_capabilities/lib/` | `arbor_capabilities` |
| `packages/arbor_capabilities_signals/lib/` | `arbor_capabilities_signals` |
| `apps/arbor_security/lib/` | `arbor_security` |
| `packages/arbor_trust/lib/` | `arbor_trust` |
| `apps/arbor_trust_host/lib/` | `arbor_trust_host` |
| `packages/arbor_historian/lib/` | `arbor_historian` |
| `apps/arbor_historian_host/lib/` | `arbor_historian_host` |

Cartographer, LLM, Shell and Sandbox retain their original
`apps/<owner>/lib/` roots. The resulting closed scope has fifteen owners.
Core and encoder share one
explicit physical-root policy. Files outside those roots cannot acquire an
owner by declaring a familiar application name; an old embedded copy selected
by the generic Git reader causes projection to fail closed.

Selection remains stage-zero Git production `.ex` blobs. Configuration,
metadata, tests, `priv`, `.exs` and unrelated packages remain outside this
particular census. Mode, path, size, OID/content and provenance-digest checks
remain enforced. The source-coupling and recovery-input inventories retain
their separate scopes, including required migration files.

The report schema and its scan/entry/review/comparison digest domains advance
to v2 so the new scope cannot be mistaken for the v1 receipt. Historical
classification entries are not moved, rehashed or waived automatically. Old
paths continue to report extra reviews, and new paths remain unreviewed until
separately reviewed. The existing classification file is retained as historical
review input; this adoption does not refresh its baseline.

SafeRecoveryProfile and SafeRecoveryArtifact independently pin historical v1
E0A schema/digests. Those receipts remain unchanged and architecture-blocked;
they do not attest the live v2 source set. Updating required physical build
inputs does not relabel those historical receipts or qualify a new recovery
release.

`PackageScopePipelineTest` traces real staged blobs through selection, pure
projection and encoding for the split families, including the canonical Trust
and Historian packages and both passive Hosts. Adjacent names and unrelated
packages remain outside the closed scope. Historical paths cannot silently
qualify new owners; an embedded Core copy fails closed.

The adopted families retain their `P` band in SourceCoupling. Moving mechanisms
into packages does not promote them into Kernel or exclude adapter and Host
edges from the coupling census. These source-review gates do not attest a
current product release or close the [Trust/Historian M2 gap](TRUST_HISTORIAN_M2_COUPLING_GAP.md).
