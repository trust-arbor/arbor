# Durable capability mutation audit

Status: implemented for the local CapabilityStore owner, 2026-09-24. This extends
the existing Security authority journal and Historian EventLog. It does not
replace either store or claim coverage of every Security authority owner.

## Commit and recovery boundary

CapabilityStore prepares a version-2 intent before a new or changed capability
can be written or published live. The intent identifies the exact store key,
Record ID, generation, revision, and digest of the complete serialized capability.
Its operation ID is stable over those mutation facts; observation time and
optional correlation fields do not create a second mutation identity. The first
prepared canonical payload remains immutable.

The serialized owner performs exact create/CAS/CAD and then reads the authoritative
entry through that same owner. An exact resulting record or tombstone establishes
the effect even if the backend acknowledgement was lost. A later journal error
cannot turn that known effect into a claimed rollback. Definite CAS conflicts
retain the acknowledged facade's existing conflict classification.

On startup, the journal opens before CapabilityStore. Recovery observes prepared
intents; it never replays a grant. Exact resulting state advances the intent to
`effect_applied`. Unchanged before-state remains prepared and retryable. A different
incarnation remains unresolved: current absence or a later replacement cannot
prove that an earlier transient grant never happened.

Before each delivery pass, the registered Historian consumer requests the same
bounded observation through CapabilityStore's serialized mailbox. A journal-only
restart therefore converges while the capability owner stays alive. This request
is consumer-gated and observes existing pending intents only; it cannot grant or
replay authority, and the journal never calls back into CapabilityStore.

Reductions can proceed while the journal is missing, poisoned, full, or unable to
represent a legacy key. They still require an exact acknowledged/reobserved store
effect before live eviction. `Security.capability_mutation_audit_status/0` reports
the last owner's `effect` and `audit` (`recorded` or `degraded`) separately. This is
process-local diagnostic state, not durable evidence. Legacy successful revoke
results remain successful after a known effect; multi-revoke partial failure
reports applied and failed counts. No durable audit record is fabricated during
an outage.

## Delivery and correlation

Historian's supervised AuthorityAuditPuller fetches applied intents through the
Security facade. The configured target must report code-owned `:node_restart`
durability. Each operation has one stable EventLog stream and event ID. The puller
rereads committed content and recomputes its complete fingerprint before an exact
intent-digest acknowledgement. Lost append acknowledgements are reconciled by
readback. Extra rows, conflicting content, unavailable storage, and volatile
targets leave journal evidence pending. Only the configured registered consumer
PID can fetch delivery bodies or acknowledge them; caller-provided ACKs cannot
erase pending evidence. The trusted BEAM and its process registration remain part
of this boundary.

`Security.current_invocation_id/0` is captured at the mutation caller before the
CapabilityStore mailbox. The closed `inv_` identifier is carried as correlation
and cleared after the serialized message. Capability metadata cannot select it.
No invocation outside an admitted source-owned context is inferred. Delivery
preserves the original prepare timestamp and marks the effect as applied; that
timestamp is not represented as the exact wall-clock effect time.

## Finite operational capacity

Application and TestBootstrap select a persisted, versioned operational profile:
4096 frames / 16 MiB, with 1024 frames / 4 MiB reserved for reductions and finishing
admitted lifecycles. New increases must fit the 3072-frame / 12-MiB soft budget,
including their remaining applied/delivered records. This bounds an initial
undelivered burst to roughly 1024 three-record lifecycles; it is not measured
throughput. A bounded 48-frame profile remains available to explicit local test
owners. Durable profile promotion uses the existing proven compaction/publication
path; a cold downgrade is refused. Normal records retain the 32-KiB admission
bound; operational snapshots are bounded to 4 MiB, and total file reading is
bounded to 21,266,503 bytes including frame headers and one incomplete tail.

Delivered terminal identities are retained. Operational admission additionally
bounds retained identities to 4096 and refuses new increases beyond 3072 retained
identities, preserving at most 1024 identity slots for reductions. Byte/frame
limits can stop admission earlier. Status exposes retained count, limits and
remaining identity slots even when pending count is zero. Successful delivery
does not provide unlimited lifetime. Rollout must check both pending and retained
headroom; do not delete the journal to reset it.

Planned follow-up: source-owned retirement of delivered v2 identities, backed by
exact durable delivery evidence and explicit replay/late-retry semantics. It must
not silently weaken v1 terminal replay or delete protected audit history.

## Coverage and limits

The CapabilityStore persistence funnel covers ordinary/acknowledged grants,
delegation and replacement writes, ordinary/fenced/bulk/scoped/cascade revocations,
replacement compensation, expiry deletion, and local persistence effects of
distributed revocations. Existing signature, issuer, principal, scope and quota
gates remain independent. Exact store observation does not turn an audit record
into permission.

Identity Registry changes, IssuerRegistry enrollments/envelope changes,
SigningKeyStore writes and SystemAuthority key lifecycle are separate owners and
are not covered by this capability journal packet. Extension execution and
process-local usage counters are also outside its authority-mutation coverage.
Remote grant hydration is a projection of an existing stored record, and the
existing security-signal transport retains its independent guarantees. No
cluster-wide commit transaction is introduced.

The local journal's digest chain detects corruption, reordering and interior
deletion relative to a trusted retained tip. It is not a keyed attestation against
an offline writer able to replace the journal and its local anchor. JSONFile's
documented local-node durability applies; unsupported directory sync does not
become a host power-loss guarantee. Ephemeral test mode makes no node-restart
claim. There is no claim of automatic reconstruction of effects performed during
a complete journal outage.

## Applied Learning

Durability evidence must follow the final consumer. The journal is delivered only
after actual EventLog content is read back, not after a backend's `{:ok, ...}` or
a target name containing “durable.” Retained operation identities also consume a
finite lifetime budget after pending work drains; expose that budget separately.
Exact current before-state permits retry of a stable prepared operation, while a
later incarnation cannot establish that a transient effect never happened.
