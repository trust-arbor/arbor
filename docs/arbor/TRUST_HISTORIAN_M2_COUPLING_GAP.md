# Trust and Historian adoption: remaining M2 recovery coupling

This paired adoption changes physical owners and product composition. Active
`arbor_trust` and `arbor_historian` now live under `packages/`, with their
historical public modules, supervisors, durable formats and authority roles.
`arbor_trust_host` and `arbor_historian_host` are passive product adapters:
required canonical dependencies own the real trees; neither Host substitutes
its own authority supervisor or puller process.

The concrete required product edges are `arbor_trust_host -> arbor_trust` and
`arbor_historian_host -> arbor_historian`. Both Hosts require Kernel Runtime
and the Security Host before their canonical application. HistorianHost also
requires PersistenceHost. Trust's direct Capabilities dependency is build
available with `runtime: false`; real product authority is supplied through
Security Host composition. Historian has no direct concrete Capabilities,
Signals or SQL dependency. Product configuration supplies inline authority and
authorization adapters, a durable SQL target and Signals observation/sync
ports. This does not make those facilities part of a standalone leaf's default
runtime.

Capabilities still binds the same canonical owners: Trust's
`ConfirmationTracker` issues approval receipts and `CapabilityGrantOwner`
continues scoped signing; Historian's `AuthorityAuditPuller` calls reconcile,
batch and ACK inline from its real canonical child PID. The application atoms,
root paths and registered names in those owner descriptors remain unchanged.
AuthoritySource callbacks must not use a Task, RPC or GenServer proxy. The
Signals durable sink now names the passive HistorianHost adapter, while the
public Historian sink and historical SecurityEventLog module identities remain.

The frozen v1 recovery policy still selects only `arbor_kernel`,
`arbor_kernel_runtime`, `arbor_security` and `arbor_trust`. Its profile and
[Shell trusted-build plan](../../apps/arbor_shell/lib/arbor/shell/trusted_build/plan.ex)
retain the old Trust project under `apps/arbor_trust`. This adoption does not
rewrite the selected application set, release commands, source-count/digest
bindings, schemas or checked-in receipts. The new passive Hosts and canonical
Historian lie outside the old selected set; actual required-dependency and
started-application measurements therefore need explicit successor policy.
The earlier [Capabilities ownership blockers](CAPABILITIES_M2_COUPLING_GAP.md)
remain. Current physical Trust input ownership also differs from the frozen
old-app projection. No renamed owner or synthetic four-app snapshot can attest
the current product authority tree.

[SourcePolicy](../../apps/arbor_commands/lib/arbor/commands/safe_recovery_artifact/source_policy.ex)
requires both package manifests and both Host manifests and reviews their full
source trees. [PlatformInventory's physical-owner policy](PLATFORM_INVENTORY_V2.md)
also keeps both families selected. Positive package/Host cases, missing-manifest
refusals, retired/adjacent-root negatives and the unchanged unrelated-root
control protect review coverage. Council blast-radius rules retain authority
review at the new exact roots. These are source-level gates, not current
product boot evidence or a refreshed logical-coupling baseline.

Before merging this slice, qualification must bind exact candidate bytes and
public source-only Hex archives, strict fresh unpacked builds and consumers,
module/application ownership, complete owning/Host/security suites and Grok
review. Independent Trust evidence must use real Capabilities and caller-owned
PubSub without Kernel Runtime, concrete Signals or product SQL; explicit memory
mode cannot claim durability. Independent Historian must exclude Capabilities,
Signals and SQL. Source-hidden ERTS releases must repeat actual public
operations with Mix unavailable. A separate composed gate must use real
production authority, the canonical Trust/Historian trees, real durable SQL,
exact puller PID and append/readback/ACK ordering; whole-BEAM recovery,
outage/conflict refusal and compatible private-state rollback remain required.
No leaf fixture can replace that composed evidence.

M2 still needs its five product release definitions, per-profile closure,
boot/canary reports, baseline ratchets and separate release/startup exclusion
proofs. Root currently has no explicit product release list; this slice adds
none. Historical blocked/open receipts stay historical. Package cold-boot
success alone provides no current full-product boot credit, architecture
clearance or M2 completion. No SigningAuthority, taint or OIDC feature work is
part of this adoption.
