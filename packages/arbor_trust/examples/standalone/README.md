# Trust cold consumer

Qualification requires source/API review, strict compilation and per-attempt
normal and source-hidden ERTS receipts. Source presence alone is not a pass
receipt; the composing runner records the outcome of each required gate.

## Inputs and ownership

The consumer's seven first-party dependencies are unpacked public archives:
Kernel, Custody, Support, OAuth, Capabilities, Persistence and Trust. Every
`ARBOR_*_PATH` is mandatory and has no checkout/cache fallback. All use public
version requirements. Trust remains active `:arbor_trust`, version 0.1.0, with
unchanged `Arbor.Trust.*` identities and canonical child paths. Product Hosts,
KernelRuntime, Signals, SQL packages/providers, Historian and optional OIDC are
absent from compiled/loaded metadata and code paths.

The fixture owns an explicit private `TrustStandaloneConsumer.PubSub` under its
application supervisor. It does not discover/start `Arbor.Core.PubSub`. Trust's
profile store is explicitly `[mode: :memory]`; this leaf makes no Trust durable
or distributed-invalidation claim. A composed proof separately supplies actual
SQL durability and a real same-PID Historian authority-audit puller.

The fixture adopts the current production Core example's actual first-install
local-human genesis, actor enrollment and stored signing-authority acquisition
operations. It retains strict identity, signed capabilities, delegation,
constraints, persistent Core authority storage, durable mutation journal and
required invocation auditing. It does not enable OIDC or claim OIDC production
qualification. No test bootstrap, identity fixture, alternate security facade,
owner PID bypass, renamed production identity or forged human record is used.
`CORE_HELPER_PROVENANCE.json` binds copied fixture helper bodies to their actual
Main-derived source. Opaque authorities remain on the admitted provisioner's
stack and are never returned or serialized.

Required environment:

- Seven archive roots: `ARBOR_KERNEL_PATH`, `ARBOR_CUSTODY_PATH`,
  `ARBOR_SUPPORT_PATH`, `ARBOR_OAUTH_PATH`, `ARBOR_CAPABILITIES_PATH`,
  `ARBOR_PERSISTENCE_PATH`, `ARBOR_TRUST_PATH`.
- `PAIRED_STATE_ROOT` and `CAPABILITIES_COLD_STATE_ROOT`: precreated canonical
  absolute private 0700 directories for this one VM/scenario.
- `CAPABILITIES_COLD_SESSION_SECRET`: fresh synthetic secret of at least32bytes.
- `PAIRED_COOKIE_SHA256`: digest of the single synthetic initial cookie; the
  harness owns loopback EPMD and cookie provisioning. No HOME override is used.
- `TRUST_COLD_SCENARIO`: one of the four closed scenarios below.

Normal entry: `TrustStandaloneConsumer.verify!()`.
Source-hidden ERTS entry: `TrustStandaloneConsumer.verify!(require_no_mix: true)`.
Both return bounded JSON-compatible public IDs/checks/module paths. Private keys,
actor authorities, session tokens, approval receipts and custody bytes are not
returned. Both execution modes are required and must have separate retained receipts.

## Fresh-VM scenario matrix

| Scenario | Started canonical apps | Actual proof |
|---|---:|---|
| full |7| Real full canonical Trust tree, owner provenance, profile writes/ceilings, operator-provisioned grant owner, target-signed JIT/replay refusal, private custody, live human answer and one-use canonical Tracker receipt, private PubSub lifecycle delivery, explicit block/actor sync |
| activation_only |7| Actual canonical PolicyHost alone; public lifecycle returns that same owner; provider/consumer subtree absent; conservative unknown-principal ceiling |
| runtime_unavailable |6, excluding Trust| Missing configured runtime refuses actual startup before PolicyHost; no standalone fallback |
| profile_sync_unavailable |6, excluding Trust| Missing configured transport refuses actual Store startup/cache ownership; canonical tree rolls back |

Compiled and loaded first-party closure is exactly seven for every scenario.
Use distinct private state roots for each normal and ERTS invocation. The
protected production PolicyHost claim intentionally survives app restart; the
proof never invokes a test-only claim release or hot profile rebinding.

## Actual freeze behavior and acceptance limit

Current Main's freeze API acknowledges the frozen flag/reason/time and emits
real PubSub events. CapabilitySync deliberately treats those messages as
non-authoritative observations. Current effective-mode resolution does not read
the frozen flag. The proof preserves and reports this behavior: state/event is
real, effective mode and capabilities remain unchanged after observation, and
no automatic freeze-denial/revocation claim is made.

The proof then installs an explicit `:block` rule and uses the caller-owned
operator authority with the public PolicyEnforcer sync API. It requires actual
revocation and denial while the enrolled identity and encrypted key remain
available. A follow-up freeze enforcement feature is outside this adoption.

## Composed integration API

Copy `lib/composed_trust_proof.ex` byte-for-byte to the composed consumer and
record both source and destination hashes. It exports:

- `ComposedTrustProof.approval_owner_child_spec/0`: include this actual
  consumer-owned pending-request authority under the composed supervisor.
- `ComposedTrustProof.verify!/1`: synchronous call in the existing provisioner
  PID with `%{operator_id, operator_authority, agent_id, agent_authority, pubsub,
  phase: :write | :recover | :refused | :rollback}`. The actor-enrolled persistent
  trust agent must be separate from the Core proof's revoked child.

Configure `:arbor_trust, :approval_evidence_provider` to
`ComposedTrustProof.ApprovalOwner`; keep the canonical grant/approval role
descriptors from Root configuration unchanged. The fixture's winning answer
transition calls actual `Security.authorize_approval_answer/3` with a current
human session before publishing the closed owner-read record. It cannot accept
caller-supplied verified-human metadata. Canonical ConfirmationTracker claims
its own receipt custody; the proof's provisioner is explicitly denied that claim.
Catalog prefixes must include memory, trust and approval as well as the Core
proof's security/standalone scopes.

Write phase stores only public profile/rule/capability/owner/request identities
in `PAIRED_STATE_ROOT/trust-public-evidence.json`. Recovery phases require that
file and actual persisted Trust profile/rules; they do not reseed missing rows.
They require the same persistent grant-owner identity and continued absence of
the revoked JIT cap with live principal/key. Actual node-restart SQL, journal
append/readback/ACK/retirement, fresh-VM recovery and compatible-state rollback
are accepted only through the composed consumer's real durable configuration.

Acceptance requires language formatting/compilation, standalone owning suites,
normal consumer and source-hidden ERTS runs for all four scenarios, actual
composed SQL authority/audit phases and rollback, artifact provenance/cookie
review, and complete-slice Grok review. These consumer gates provide no M2
product release or architecture clearance.
