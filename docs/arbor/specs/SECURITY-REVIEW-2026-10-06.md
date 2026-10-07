# SECURITY-REVIEW-2026-10-06 — Kernel Runtime and Security Hardening

**Status:** active, canonical conformance source

**Canonical since:** 2026-10-07

This specification names the security invariants established from the independent
2026-10-06 reviews of `arbor_kernel_runtime` and `arbor_security`. The external
review artifacts remain evidence; this tracked document is the stable authority
for statement IDs used by `./bin/mix arbor.spec.coverage`.

`KSEC-NNN` maps to `arbor_kernel_runtime-20261006/FINDING-NNN` and
`SSEC-NNN` maps to `arbor_security-20261006/FINDING-NNN`. A statement captures
the durable invariant, rather than a particular implementation, so fixes may
change without renaming their regression tests.

The key words MUST and MUST NOT are to be interpreted as described in RFC 2119.

## Kernel runtime review invariants

- **KSEC-001** (MUST NOT): Live evaluation graders MUST NOT compile, execute, or unload modules from model or dataset text; an unavailable isolated evaluator MUST fail closed.
- **KSEC-002** (MUST): Distributed security-state synchronization MUST preserve authenticated payload meaning across nodes, and decryption, provenance, or decoding failures MUST be treated as errors rather than empty security state.
- **KSEC-003** (MUST): Distribution credentials MUST stay out of process arguments and terminal output, MUST be stored with private permissions, and a loopback deployment MUST bind distribution to loopback.
- **KSEC-004** (MUST): Executable capability providers and hot-load paths MUST require an authenticated principal and the normal authorization boundary; discovery without principal authority MUST remain non-executable.
- **KSEC-005** (MUST): Diagnostics MUST verify a target is a supervisor before supervisor-specific calls and MUST NOT crash or indefinitely block an arbitrary GenServer.
- **KSEC-006** (MUST): Skill trust and provenance MUST derive from the source boundary; project-local input MUST remain untrusted, MUST NOT shadow bundled skills, and scanner/importer paths MUST reject unsafe names, links, and unbounded input.
- **KSEC-007** (MUST): Core runtime registries MUST keep mutation under owner custody, gate reset/restore facilities to tests, validate registered implementations, and expose the exact dispatched module identity for audit.
- **KSEC-008** (MUST): Signal storage and ingress MUST prevent duplicate identifiers from diverging index and record state or defeating privacy deletion and absence proofs.
- **KSEC-009** (MUST): Subscriber filters and synchronous handlers MUST run behind exception, exit, and time bounds so subscriber code cannot crash or stall the Signals bus.
- **KSEC-010** (MUST): The distributed-node trust boundary MUST be explicit, and Relay/Bus ingress MUST bind origin to supervised connection authority rather than caller-supplied node or signal fields.
- **KSEC-011** (MUST): Monitor findings forwarded with system authority MUST originate from authenticated supervised producers, and attacker-influenced diagnostic detail MUST be bounded and isolated as untrusted content.
- **KSEC-012** (MUST): Filesystem containment MUST resolve real path components and bind authorization to the regular file actually opened, rejecting link substitution, ancestor/root replacement, and check/open races; any descriptor-opening helper MUST be runtime-bound and non-replaceable from an authorized workspace.
- **KSEC-013** (MUST): SSRF admission MUST classify every resolved address, including mapped and special ranges, and the egress connection MUST stay bound to an admitted address under bounded redirect and response policy.
- **KSEC-014** (MUST): Runtime log redaction MUST cover chardata, format arguments, metadata, and current credential/key formats before any Logger handler emits them.
- **KSEC-015** (MUST): Every Hands task MUST apply one closed name grammar and containment check before filesystem or process effects; cleanup MUST NOT escape its managed root through traversal or links.
- **KSEC-016** (MUST): Signal ingress MUST assign fresh server-owned identifiers, timestamps, emitter identity, and origin; caller or peer attribution MUST NOT become trusted attribution.
- **KSEC-017** (MUST): Operator tooling MUST create secret files and directories with restrictive permissions before writing, forward only allowlisted environment keys, and redact configuration output.
- **KSEC-018** (MUST): Channel membership, signing, decryption, invitation, and rotation operations MUST be bound to authenticated caller authority and pinned channel authority; raw private keys MUST NOT be exported.
- **KSEC-019** (MUST): Security-relevant monitor, telemetry, and skill state MUST be owner-protected; restart diagnostics MUST read the correct bounded state, and healing MUST start only approved workers.
- **KSEC-020** (MUST): Reviewed import, cache, shell-argument, sanitizer, session-path, PII, OAuth, durable-signal, and pagination helpers MUST validate bounded input and fail closed on malformed or unavailable security state.

## Security review invariants

- **SSEC-001** (MUST): A capability issuer MUST be enrolled, current, and confined to its issuance envelope, and persisted authority records MUST be authenticated before they can create authority.
- **SSEC-002** (MUST NOT): Arbitrary in-VM callers MUST NOT obtain another principal's private signing key or a transferable key-bearing authority; signing MUST remain inside an owner-bound facade or broker.
- **SSEC-003** (MUST): Session-token secrets MUST be deployment-supplied and non-default, and issued tokens MUST be scoped, revocable, session-bound, and shorter-lived when they carry approval authority.
- **SSEC-004** (MUST): Authority-creating or authority-reducing mutations, including grant, delegation, role, signing, identity, issuer, URI, reflex, and registry changes, MUST require an authenticated actor bound to the exact request and audit attribution.
- **SSEC-005** (MUST): The configured delegation verifier MUST exist and be loaded, and an invalid or unverifiable delegation chain MUST fail authorization closed.
- **SSEC-006** (MUST): Approval authority MUST use an authenticated one-use receipt bound to the principal, resource, action arguments, and authoritative context; caller-supplied context MUST NOT override what was approved.
- **SSEC-007** (MUST): Identity standing MUST be checked for every authorization, including requests whose identity proof was previously verified; suspended or revoked identities MUST fail closed.
- **SSEC-008** (MUST): OIDC discovery and token verification MUST enforce bounded same-origin transport, strict typed and freshness claims with nonce binding, and a supervised owner-protected key cache that refreshes safely.
- **SSEC-009** (MUST): Production OIDC registration MUST apply an explicit admission policy, reject public-key ownership collisions, and require proof of possession before granting human identity or operator authority.
- **SSEC-010** (MUST NOT): A revoked capability MUST NOT regain authority when stale pre-revocation record bytes are restored or replayed.
- **SSEC-011** (MUST): Audit and authority stores MUST authenticate writers, isolate corrupt or foreign records, recover committed state after torn writes, and enforce bounded per-principal capacity while authority creation fails closed.
- **SSEC-012** (MUST): Unknown, malformed, tainted, or policy-uncovered egress tiers MUST fail closed, and external-peer egress MUST pass the configured policy boundary.
- **SSEC-013** (MUST NOT): Signing-authority handles MUST NOT act as transferable general signing oracles; signatures and activation issuance MUST be domain/resource bound, clock bounded, and replay protected.
- **SSEC-014** (MUST): Reading key material MUST never create or rotate a missing master key, serialized key state MUST be integrity authenticated, and distinct cryptographic purposes MUST use derived keys.
- **SSEC-015** (MUST): Reflex and filesystem gates MUST normalize command/path syntax, use segment-aware capability matching with correct wildcard and depth semantics, and keep an authorized read bound to the selected capability and opened descriptor.
- **SSEC-016** (MUST): Security events, nonces, login queues, escalation, usage limits, delegated capabilities, deserialization, cross-node store mutation, and sealed envelopes MUST enforce bounded authenticated state and fail closed on malformed, replayed, or unavailable authority.
