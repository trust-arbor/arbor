<!-- markdownlint-disable MD013 -->

# Arbor Security Architecture

**State reviewed:** 2026-07-19

This document describes the security controls represented by the current source and
the Phase 6 decisions. It deliberately separates implemented controls from planned
work and from historical design material. It is an architecture overview, not a
compliance certification, a deployment guide, or a promise that every caller uses
every available gate.

## Executive Summary

Arbor treats an agent operation as a chain of questions:

1. **Who is asking?** The principal has a registered cryptographic identity.
2. **What is it asking to do?** The operation has a registered resource URI and
   requires a capability that covers that URI.
3. **What does the operator's policy allow?** Granular rules can block, ask for
   approval, allow with notification, or allow automatically. System ceilings can
   still make an operation more restrictive.
4. **Where can the operation reach?** File paths are checked against capability
   roots, and outbound data is classified by destination and taint. Some outbound
   operations are blocked or require approval.
5. **Did the thing being approved remain the same?** Authorized runs can bind the
   principal, caller, author, worktree, graph, compiled code, and action/handler
   bindings. Coding approval can bind the exact Git tree that was inspected.
6. **Who cleans up?** Worktrees, ACP sessions, and containment units have owners and
   monitored registries. Cleanup does not depend only on a final graph node.

In plain language, one lock is not trusted to do every job. Identity, permission,
path checks, information-flow checks, approval, code binding, and operating-system
containment cover different failure modes. That is defense in depth, not a claim
that Arbor makes a compromised host or a fully compromised BEAM safe. A caller can
also bypass a control if it uses an explicitly trusted or legacy path; the sections
below identify those boundaries.

## Status Vocabulary

- **Implemented today** means the source contains the control and a supported caller
  path uses it. Configuration and caller selection can still matter.
- **Partial / planned / unsupported** means the mechanism exists only for a bounded
  path, needs further wiring or provisioning, or intentionally refuses execution.
- **Historical target** means useful rationale from an earlier architecture document;
  it is not a statement about the current runtime.

## Implemented Today

### Identity and external authentication

- Arbor identities use Ed25519 signing keys. The public security facade owns identity
  registration, status, signing-key storage, signed-request verification, and
  suspension/revocation operations. Identity status is part of authorization; a
  suspended or revoked identity is denied.
- `Arbor.Contracts.Security.SignedRequest` signs a canonical payload containing the
  request payload, principal ID, timestamp, and random nonce. The verifier checks
  freshness, looks up the registered public key, verifies the Ed25519 signature, and
  rejects a reused nonce.
- Gateway clients can authenticate each HTTP request with
  `Authorization: Signature <base64-envelope>`. The gateway binds the signature to
  the actual method, request path, and body before verification. This is the current
  external-agent authentication path; the gateway still permits its existing JWT or
  API-key paths when a signature is absent or invalid.
- Signing authority migration is underway. Newer long-lived callers can hold a
  reload-stable, owner-bound authority reference, while the compatibility
  `Arbor.Security.make_signer/2` closure remains for callers not yet migrated. The
  compatibility path keeps decrypted key material in the caller process, so it is
  not equivalent to an external signer or hardware boundary.

Authoritative code: [`Arbor.Security`](../../apps/arbor_security/lib/arbor/security.ex),
[`SignedRequest`](../../apps/arbor_contracts/lib/arbor/contracts/security/signed_request.ex),
[`SignedRequestAuth`](../../apps/arbor_gateway/lib/arbor/gateway/signed_request_auth.ex),
[`Identity.Verifier`](../../apps/arbor_security/lib/arbor/security/identity/verifier.ex),
and [`Reload-Stable Signing Authority`](../../.arbor/decisions/2026-07-11-reload-stable-signing-authority.md).

### Capabilities, delegation, and revocation

Capabilities are signed, principal-scoped grants for resource URIs. The security
facade supports:

- grant, lookup, expiration, time bounds, usage/rate constraints, and optional
  session/task scope;
- Ed25519 capability signatures and verification;
- signed delegation records with constrained delegation depth and a verifiable
  delegation chain;
- direct revocation, principal-wide revocation, session/task cleanup, and cascade
  revocation of delegated children; and
- persistent capability storage when the configured backend is enabled, with
  in-memory-only operation possible by configuration.

Authorization is not just a string comparison. The URI registry, identity status,
capability store, scope, delegation chain, time constraints, approval constraints,
and relevant taint/egress checks participate in the decision. Production configuration
requires signed capabilities and enables strict identity and policy settings.

Authoritative code: [`Arbor.Security`](../../apps/arbor_security/lib/arbor/security.ex),
[`Capability.Signer`](../../apps/arbor_security/lib/arbor/security/capability/signer.ex),
[`CapabilityStore`](../../apps/arbor_security/lib/arbor/security/capability_store.ex),
and [`config/prod.exs`](../../config/prod.exs).

### Granular trust policy

The current trust model is **granular policy**, not a scalar trust score or a band of
trust tiers. A profile has a baseline and URI-prefix rules. Rules use
segment-boundary-aware longest-prefix matching and resolve one of four modes:

- `block`: deny;
- `ask`: require confirmation;
- `allow`: proceed with notification semantics handled by the caller; or
- `auto`: proceed without an approval prompt.

The effective decision is the most restrictive combination of the profile rule,
system security ceiling, optional model constraint, and taint-derived restriction.
Trust policy can also resolve egress standing per destination tier. A capability may
refine an ask only when its egress constraints cover the resolved tier and destination.

The old scalar tier model, including language such as `untrusted` through
`autonomous` as a progression or a 0-100 authorization score, is retired. Taint levels
such as `trusted`, `derived`, `untrusted`, and `hostile` remain a separate
information-flow classification; they are not trust tiers.

Use [`Arbor.Trust`](../../apps/arbor_trust/lib/arbor/trust.ex),
[`Policy`](../../apps/arbor_trust/lib/arbor/trust/policy.ex), and
[`ProfileResolver`](../../apps/arbor_trust/lib/arbor/trust/profile_resolver.ex) for
the current model. The retirement rationale is recorded in
[`finish-retiring-trust-tiers.md`](../../.arbor/roadmap/5-completed/finish-retiring-trust-tiers.md).

### FileGuard and path containment

`Arbor.Security.FileGuard` is an authorization layer for filesystem capabilities. It
combines capability lookup with safe-root resolution, traversal rejection, symlink or
junction containment, file-pattern and exclusion constraints, and depth limits.

The security facade integrates FileGuard into filesystem authorization in two ways:

- when a caller supplies `file_path`, the concrete path is normalized and checked
  against the matched capability; and
- for a path-bearing `arbor://fs/...` URI without `file_path`, the URI path is
  normalized against the capability root as defense in depth.

Failures in this binding path fail closed. `SafePath` is also used by authorized run
workdir checks and other workspace boundaries. This protects the path decision; it
does not turn a process with unrestricted host privileges into a filesystem sandbox.

Authoritative code: [`FileGuard`](../../apps/arbor_security/lib/arbor/security/file_guard.ex),
[`Arbor.Security`](../../apps/arbor_security/lib/arbor/security.ex), and
[`SafePath`](../../apps/arbor_common/lib/arbor/common/safe_path.ex).

### RunAuthorization and immutable execution identity

Authorized Engine runs can carry a `RunAuthorization` that binds:

- execution principal, caller, author, task, and session IDs;
- canonical workdir and filesystem identity;
- source graph hash and compiled graph hash;
- a JSON-clean execution manifest and digest; and
- exact action, handler, and node-module bindings.

The binding is digest-checked, inherited by child graphs as a restricted subset, and
verified on checkpoint/resume. Authorized graph nodes cannot replace the principal or
adapt the graph. Workdir identity is rechecked so a path replacement is not silently
accepted. Signing authority itself stays in trusted runtime options rather than the
checkpoint projection.

This is an execution identity and code-binding control. It does not prove that the
BEAM process, the operating system, or every un-authorized legacy run is uncompromised.

Authoritative code: [`RunAuthorization`](../../apps/arbor_orchestrator/lib/arbor/orchestrator/engine/run_authorization.ex),
[`ExecutionManifest`](../../apps/arbor_orchestrator/lib/arbor/orchestrator/coding_plan/execution_manifest.ex),
and [`DOT pipeline guide`](./DOT_PIPELINE_GUIDE.md).

### Taint and egress gates

Arbor tracks taint through action inputs and outputs and uses resolved security
classification rather than guessing from a URI name. For an enforced external
destination, untrusted or hostile taint is a hard block and cannot be overridden by
trust standing or a capability. The gate also considers destination tier:

- `on_host` and `none` are local and allowed;
- `on_premises` is allowed unless its deployment flag is enabled;
- `external_provider` is governed by trust standing and may ask or block; and
- `external_peer` is currently classified and observed, but remains advisory for the
  ACP 1.0 deferral.

The gate is enabled in development and production configuration, while tests keep it
dark unless a test explicitly enables it. Production's default cloud-provider
standing is `allow`, so enabling the gate alone is not equivalent to denying all
external traffic. Operators can provision stricter per-agent egress modes and enable
on-premises gating.

Authoritative code: [`EgressGate`](../../apps/arbor_security/lib/arbor/security/egress_gate.ex),
[`Arbor.Trust.Policy`](../../apps/arbor_trust/lib/arbor/trust/policy.ex),
[`config/prod.exs`](../../config/prod.exs), and the
[`URI addressing and classification decision`](../../.arbor/decisions/2026-06-14-uri-addressing-vs-security-classification.md).

### Durable ownership, approval, and review

The coding workflow uses ownership boundaries below the graph:

- the Engine run process owns pipeline execution by default;
- `arbor_actions` owns monitored worktree leases;
- `arbor_ai` owns managed ACP sessions and keeps their PIDs private; and
- registries monitor owners and make cancellation and cleanup independent of happy-path
  finalizer nodes.

Public task and Engine context carry opaque or JSON-clean handles, not PIDs, functions,
or rich authority structs. Worktree cleanup removes only paths created by the lease;
reused or pre-existing worktrees are not automatically removed. Owner death, task
cancellation, and process loss have explicit cleanup paths, with durable retention
state for the coding workspace lifecycle.

Coding approval is not a generic "the operator saw some diff" flag. The reviewed commit
action binds approval to the inspected HEAD, a bounded worktree fingerprint, and, when
available, the exact committable tree OID. It rechecks those values after approval and
immediately before mutation. A fresh exact-resource signed request is minted for the
nested Git commit authorization. Denial and rework do not mutate Git.

The council review path is similarly bound to the reviewed task/worktree data and
review-cycle ledger rather than being a free-standing approval of arbitrary later
content. This is a workflow-specific control, not a claim that every Arbor action is
council-reviewed.

Authoritative docs and code: [`Coding task dispatch`](./CODING_TASK_DISPATCH.md),
[`coding workflow execution boundaries`](../../.arbor/decisions/2026-07-09-coding-workflow-execution-boundaries.md),
[`ReviewedCommit`](../../apps/arbor_actions/lib/arbor/actions/coding/reviewed_commit.ex),
[`ReviewTree`](../../apps/arbor_actions/lib/arbor/actions/coding/review_tree.ex), and
[`code-review-council.dot`](../../apps/arbor_actions/priv/pipelines/code-review-council.dot).

### Shell containment and ACP boundaries

Arbor has two intentionally different Shell execution modes:

- **Direct execution** is a trusted structured-argv primitive for childless commands.
  It pins executable and cwd identity, applies one deadline and output ceiling, tracks
  ownership, and requires containment exhaustion before timeout, cancellation, launcher
  failure, or owner loss becomes terminal. Agent-facing authorization rejects compound
  commands, wrappers, noncanonical executables, and nonempty ambient environments.
- **Spawn-capable execution** is a separate closed contract for Mix, compilers, and
  test runners that need descendants. It does not use a caller-selected backend or
  self-declared capability. The built-in Apple Container path performs preflight,
  admission, owner binding, closed-environment setup, no-network unit creation, and
  positive settlement before publishing terminal output. If a required guarantee or
  admission asset is missing, it refuses to start candidate work.

The direct launcher is not a substitute for descendant containment. A process group can
be escaped by `setsid`, so spawn-capable cleanup requires an OS-owned unit or an
equivalent proof of whole-unit exhaustion.

Authoritative code: [`Arbor.Shell`](../../apps/arbor_shell/lib/arbor/shell.ex),
[`Executor`](../../apps/arbor_shell/lib/arbor/shell/executor.ex), and
[`spawn-capable shell containment decision`](../../.arbor/decisions/2026-07-13-spawn-capable-shell-containment.md).

### Grok ACP private runtime and no-shell profile

The managed Grok ACP path creates a private Arbor runtime tree and a private `grok`
home with restrictive modes. It stages authentication only into that private home,
binds a verified Arbor agent profile, and disables ambient MCP/configuration sources,
hooks, telemetry, memory, subagents, and web fetch through a closed environment.

The `arbor-no-shell` profile exposes native file tools and disallows terminal commands,
task/subagent controls, and task-output/kill controls. The launch command is checked
against the expected strict Grok command, including `--deny Bash(*)`, and the worktree
authority is verified before and during launch. This is a strong profile-specific
boundary, not a universal guarantee for every ACP provider or every manually launched
CLI.

Authoritative code: [`RuntimeHome`](../../apps/arbor_ai/lib/arbor/ai/acp_session/runtime_home.ex),
[`GrokSandbox`](../../apps/arbor_ai/lib/arbor/ai/acp_session/grok_sandbox.ex), and
[`ACP trust enforcement status`](../../.arbor/decisions/2026-07-06-acp-trust-enforcement-status.md).

### Distributed security signal caveat

Signals are normally fire-and-forget observability and must not be treated as the
execution lifecycle or authorization source of truth. There is a deliberate,
load-bearing exception in `arbor_security`: cluster-scoped security signals currently
carry distributed nonce, capability, and identity state synchronization. That transport
must be treated as security-critical until it is replaced by an explicit synchronization
mechanism. Security-topic subscriptions are capability-restricted; an open signal topic
is not evidence of security authorization.

Authoritative code: [`CapabilityStore`](../../apps/arbor_security/lib/arbor/security/capability_store.ex),
[`Identity.Registry`](../../apps/arbor_security/lib/arbor/security/identity/registry.ex),
and [`Arbor.Signals`](../../apps/arbor_signals/lib/arbor/signals.ex).

## Partial, Planned, or Unsupported Controls

The following boundaries are important because their names can otherwise sound more
complete than their current implementation.

### Signing and identity boundaries

- The reload-stable signing-authority broker is the intended owner of long-lived signing
  authority, but migration is staged. Legacy signer closures remain in some callers.
- The old four-layer external signer and hardware-backed key architecture is not
  implemented as a general Arbor deployment mode. There is no claim here that private
  keys are outside the BEAM, that a separate UID is mandatory, or that Secure Enclave,
  TPM, HSM, or cloud KMS integration is complete.
- Signed-request authentication is available, but Gateway intentionally passes through
  to other auth schemes when the signature is absent or invalid. Deployment policy must
  decide which schemes are acceptable on each endpoint.

### ACP authorization granularity

The ACP permission callback can route a tool request through trust policy and capability
authorization when the session is launched in the callback-enabled mode. It is not safe
to infer that from every ACP session: `permission_mode: bypass` intentionally skips the
callback and is prohibited for the reviewed coding-agent path. Current callback
authorization is still generally tool-level; mapping arguments such as a Bash command
or an Edit path to a fully argument-scoped resource URI remains incomplete. Worktree
isolation, tool allowlists, and the Grok no-shell profile therefore remain necessary
defense in depth.

### Egress and URI work

- `external_peer` ACP egress is classified and emits telemetry but remains advisory in
  the ACP 1.0 policy; it is not a universal hard block.
- Full consolidation of all historical URI shapes and destination-specific coverage for
  every comms/ACP path remain tracked work. Classification and runtime destination
  resolution are the current enforcement direction.
- Egress enforcement depends on the caller supplying the resolved tier, taint, and trust
  standing to the security gate. The kernel does not derive an agent's trust profile by
  itself on every entry path.

### Spawn-capable platform work

- The spawn-capable API is deliberately unavailable when the production containment
  backend or its admission evidence is missing. A configured callback, arbitrary module,
  or legacy `spawn_backend` setting cannot reactivate it.
- The only implemented spawn-capable backend is Apple Container on macOS 26 with the reviewed
  signed 1.1.x CLI/API-server/plugin layout, pinned kernel, immutable local images, and
  a verified Linux/arm64 guest toolchain. Provisioning those assets is an operator
  prerequisite; code presence alone does not prove a host can execute this path.
- Linux dependency-baseline authority and Linux/arm64 guest materialization exist for
  the Apple Container validation design, but a general native Linux spawn-capable
  containment backend is not documented as supported here.
- Windows has path-containment handling for filesystem links/reparse-point behavior,
  but no supported Windows spawn-capable containment backend is claimed. The Windows
  shell-containment compatibility item remains open.

## Current Platform Support and Limitations

| Platform | Current position |
| --- | --- |
| macOS | Core Elixir security and direct childless Shell paths are the primary development surface. Spawn-capable validation is bounded to macOS 26 with Apple Container 1.1.x admission evidence and required locally provisioned assets. Missing assets fail closed. |
| Linux | Core identity, capability, trust, taint, egress, and path-policy code is not described as macOS-only. Linux/arm64 dependency-baseline and guest-image evidence support the Apple Container design, but no general native Linux spawn-capable backend is supported by this document. |
| Windows | FileGuard/SafePath code accounts for Windows junction and reparse-point containment behavior. Native spawn-capable containment and equivalent whole-unit cleanup are not a supported Arbor platform mode. |

Platform support means that the relevant code path can run or fail closed; it does not
mean the same OS-level isolation primitive exists everywhere. Operators must verify
the actual runtime, signed assets, configuration, and authorization mode for the
deployment.

## Historical Target Architecture

The previous version of this document described a four-layer target:

1. a dedicated `arbor` service account;
2. an authenticated CLI-to-daemon RPC boundary;
3. a separate signer process holding the private key; and
4. hardware-backed signing through Secure Enclave, TPM, HSM, or cloud KMS.

That model remains useful historical rationale: a UID boundary protects against an
operator-shell compromise, an RPC boundary separates a CLI from daemon authority, a
signer process reduces the BEAM's access to raw keys, and hardware can protect keys
even from a compromised daemon or root-level insider. It is **not** the current Arbor
deployment architecture. The current implementation instead uses in-process security
facades, staged signing-authority migration, capability/trust policy, run binding, and
bounded Shell/ACP containment.

Likewise, early Arbor documents described progressive scalar trust tiers and scores.
Those terms are historical rationale only. As of the 2026-06-29 trust-policy retirement,
current design work must use profile baselines, URI-prefix rules, system ceilings,
capabilities, approval modes, and taint classification.

Do not use this historical section to infer that daemon RPC, external signer processes,
hardware keys, service-account installation, or scalar trust graduation are available
features.

## Related Authority

- [`docs/arbor-security-design.md`](../arbor-security-design.md) - action authorization
  risks and remaining hardening context.
- [`Agent security gates`](../../.claude/skills/agent-security-gates.md) - gate-by-gate
  operational checklist.
- [`CONTRACT_RULES.md`](./CONTRACT_RULES.md) - facade and dependency-boundary rules.
- [`Coding task dispatch`](./CODING_TASK_DISPATCH.md) - reviewed coding workflow contract.
- [`2026-07-13 spawn-capable containment decision`](../../.arbor/decisions/2026-07-13-spawn-capable-shell-containment.md)
  - platform admission and containment boundary.
- [`2026-07-06 ACP trust enforcement status`](../../.arbor/decisions/2026-07-06-acp-trust-enforcement-status.md)
  - callback-enabled ACP limitations.
