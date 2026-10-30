# Capabilities adoption

Source: `apps/arbor_security` at `3fbe6596fa2da06480fbdd75c3b516815d79a9d3`.
The current product implementation is relocated into `packages/arbor_capabilities`;
no frozen sibling library is copied into the adopted package.

The full authority implementation and OTP callback move together. The product
retains only consumer adapters and explicit configuration. Canonical application
and configuration ownership becomes `:arbor_capabilities`. All historical
`Arbor.Security.*` modules and their supervisor/child/ETS/persistent identities,
cryptographic algorithms, signed domains, durable records and wire tags remain
unchanged. Exact application provenance checks bind to the actual new OTP owner.

Authenticated-call operations delegate directly to the public Custody API with
the same signatures. Public `Arbor.Common.SafePath` and `SensitiveData` identities
are owned by Support; OAuth identities are owned by the existing OAuth leaf.
Consumer-owned SkillImporter and Signals behaviours are implemented by host
adapters, while their existing public Security function bodies stay in Core.

`Arbor.Security.Contracts.RuntimeHost` is the only new product runtime port.
It takes a trusted static configured module, runs startup preparation before any
authority claim/freeze, and supplies the existing closed startup/boot profile and
provider gate operations. No runtime implementation or authority tree is copied
from KernelRuntime. Nil standalone omits only the host HTTP gate and defaults to
closed `:full`; configured-provider failures cannot choose standalone.

Product module defaults and checkout-relative development storage defaults move
to explicit host configuration. Durable Core authority roots must be absolute.
Required role provenance stays caller-configured and exact. ReplayPeers binds its
local owner to Capabilities and conservatively treats remote Capabilities **or**
legacy Security applications as replay authorities; only absence of both is foreign.

`ADOPTION_SOURCE_MAP.json` records each original production source hash and
its package or host disposition. New port and manifest files are additions;
existing source rows classify only the permitted ownership and integration edits.
Existing owning tests and new regressions are tracked by the integration/QA lease.
The package uses only versioned public dependencies, a normal private Mix build,
and an archive allowlist without product configuration, tests or compiled artifacts.

## Release qualification boundary

Package adoption does not close the product release plan. The frozen v1
safe-recovery profile, artifact and closure schemas still name Security as the
reference monitor. They must classify the new physical Core as unexpected and
leave the current product closure blocked. The regression tests preserve that
refusal, including the case where the passive Host is selected while Core owns
the actual authority modules. Historical receipts are unchanged.

See [the current coupling gap](../../docs/arbor/CAPABILITIES_M2_COUPLING_GAP.md)
for the required versioned successor and remaining M2 release gates. A synthetic
or historical closed v1 projection is not evidence about the current monitor.

The owning suite runs directly from this package with its public dependencies
and an independent build before the product umbrella is compiled. Host-only
Signals and Kernel Runtime cases retain their literal integration assertions in
`apps/arbor_security/test`; `TEST_SPLITS.json` records their disposition. The
standalone qualifier separately builds five real package archives and exercises
fresh-VM durable recovery, revocation, actual new/legacy/foreign peer behavior,
and an assembled ERTS release with copied source and Mix inputs hidden.
