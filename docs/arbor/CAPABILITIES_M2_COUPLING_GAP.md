# Capabilities adoption: remaining M2 recovery coupling

Capabilities Core adoption is not product release completion. The canonical OTP
application `arbor_capabilities` now owns the historical `Arbor.Security` authority
modules and supervisor. `arbor_security` is a passive product composition app: its
required Core dependency starts the authority, but Host has no application callback
or authority tree of its own.

The frozen v1 recovery policy selects only `arbor_kernel`,
`arbor_kernel_runtime`, `arbor_security`, and `arbor_trust`. Its profile assigns the
identity/capability reference-monitor responsibility to the historical Security
owner. Current source selection and required physical build inputs include the new
packages; this does not update the old recovery policy or receipts.

The concrete coupling edge is `arbor_security -> arbor_capabilities` in required
runtime application dependencies. Under [Artifact.Derive](../../apps/arbor_commands/lib/arbor/commands/safe_recovery_artifact/derive.ex),
canonical Core is `unexpected_first_party` and produces the
`unexpected_first_party_applications` blocker. Artifact validation recomputes this
classification and exact physical ownership; relabelling Core as selected is
rejected.

[PeerProbe](../../apps/arbor_commands/lib/arbor/commands/safe_recovery_closure/peer_probe.ex)
starts required dependencies, records started applications, and resolves loaded
module ownership with `:application.get_application/1`. The actual Core owner
therefore produces `unexpected_first_party_started` and `unexplained_module` in
the [v1 closure projection](../../apps/arbor_commands/lib/arbor/commands/safe_recovery_closure/core.ex),
leaving closure open. Selecting the passive Host cannot explain a current
Core-owned authority module. Frozen source-count/digest bindings can reject a
current measurement even before runtime projection.

The pure v1 projector can still report a historical four-app snapshot as closed;
it accepts supplied snapshot facts and does not attest a live reference monitor.
Its architecture status remains blocked. Such a receipt is historical closure
evidence, not current monitor or product-release attestation. Preserve all v1
schemas, constants, digest domains, and checked-in receipts.

A versioned successor must explicitly bind current profile, artifact, and closure
policy; assign reference-monitor responsibility to `arbor_capabilities` and only
composition duties to Host; and verify actual application/module ownership and
authority-supervisor provenance. Missing Core, Host-only authority claims, and
wrong-owner projections must fail closed. Review each required dependency and
omitted facility individually rather than widening an application allowlist.
Release exclusion and startup exclusion remain separate claims.

The immediate regressions in [artifact CoreTest](../../apps/arbor_commands/test/arbor/commands/safe_recovery_artifact/core_test.exs)
and [closure CoreTest](../../apps/arbor_commands/test/arbor/commands/safe_recovery_closure/core_test.exs)
lock the existing blocker, actual canonical ownership, and wrong-owner open
projection. They do not qualify a successor release.

This files the per-family coupling gap required by
[M1's adoption acceptance criteria](../../.arbor/roadmap/2-planned/monorepo-packages-source-of-truth-and-rl6-adoption.md#acceptance-criteria).
[M2's remaining exit gates](../../.arbor/roadmap/2-planned/profile-releases-feature-contract-and-boot-smoke.md#acceptance-criteria)
still require passive Feature declarations, profile release assembly, runtime
Mix-reference classification, per-release closure/boot/canary reports and baseline
ratchets, all full-release canaries, explicit failure filing, and separate
release/startup exclusion evidence. Those planning links
refer to the separate private `.arbor` repository; the gap is recorded here so
it remains visible with the product source. See also [Product Profiles](PRODUCT_PROFILES.md).
