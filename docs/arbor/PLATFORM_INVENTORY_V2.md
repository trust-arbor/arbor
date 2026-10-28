# Platform inventory scope after Persistence adoption

The live PlatformInventory report is now
`arbor.packaging.platform_inventory.v2`. This is a reviewed scope successor
to the original nine-application E0A census. The Persistence adoption splits
the two former Persistence owners into four actual owners; every former
production source remains in the selected family.

| Physical root | Actual application owner |
| --- | --- |
| `packages/arbor_persistence/lib/` | `arbor_persistence` |
| `packages/arbor_persistence_sql/lib/` | `arbor_persistence_sql` |
| `packages/arbor_persistence_eventstore/lib/` | `arbor_persistence_eventstore` |
| `apps/arbor_persistence_host/lib/` | `arbor_persistence_host` |

The other seven selected owners remain Cartographer, LLM, Security, Shell,
Sandbox, Historian and Trust under their original `apps/<owner>/lib/` roots.
The resulting closed scope has eleven owners. Core and encoder share one
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
projection and encoding for all four Persistence owners. It also verifies
that historical paths cannot silently qualify new owners and that an embedded
core copy fails closed.

All four actual Persistence owners retain the family's `P` band in
SourceCoupling. Moving mechanisms into packages does not promote them into
Kernel or exclude adapter and Host edges from the coupling census.
