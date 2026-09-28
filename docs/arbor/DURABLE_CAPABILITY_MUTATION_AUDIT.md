# Durable capability mutation audit

Status: implemented for the local CapabilityStore owner, 2026-09-24. This extends
the existing Security authority journal and Historian EventLog. It does not
replace either store or claim coverage of every Security authority owner.

## Commit and recovery boundary

CapabilityStore prepares a version-3 intent before a new or changed capability
can be written or published live (since 2026-09-28; version 3 carries the same
facts as the earlier version 2 under its own identity domain, so the two
identities of identical facts never collide). The intent identifies the exact
store key, Record ID, generation, revision, and digest of the complete
serialized capability.
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
the last owner's `effect` and `audit` (`recorded`, `degraded`, or `refused` for a
refused grant) separately. This is process-local diagnostic state, not durable
evidence. Legacy successful revoke results remain successful after a known effect;
multi-revoke partial failure reports applied and failed counts. No durable audit
record is fabricated during an outage.

Journal refusals keep the public result vocabulary (a refused grant is still
`{:error, :audit_unavailable}`) and add a closed `reason` class to that status
(since 2026-09-28): `capacity` (soft or hard capacity), `identity`
(`operation_terminal` or `retired_version`) or `unavailable` (anything else). A
refused grant emits `[:arbor, :security, :audit_journal, :refused]`. Every
reduction that executes without a journal record emits
`[:arbor, :security, :audit_journal, :degraded_reduction]` and is counted
(`degraded_reductions` in the same status); the first 10 per CapabilityStore
process log a warning, then every 100th with the cumulative count, so a sustained
outage is visible without flooding the log.

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

Operational admission bounds retained identities to 4096 and refuses new
increases beyond 3072 retained identities, preserving at most 1024 identity slots
for reductions. Byte/frame limits can stop admission earlier. Status exposes
retained count, limits and remaining identity slots even when pending count is
zero. On a durable operational journal delivered identities are retired (below),
so the retained count is a working set; ephemeral and small journals do not
retire yet and keep delivered identities retained. Rollout must check both
pending and retained headroom; do not delete the journal to reset it.

Operational snapshots are version 3 (since 2026-09-28). A v3 snapshot carries
the retirement accounting (`retired_total` and the cold retirement-ledger
binding) and sets the journal's admission floor to intent version 3: an unknown
v1/v2 `prepared` is refused `:retired_version` before any capacity check and
writes nothing, while v1/v2 operations already pending complete by id. Retiring
delivered identities out of the hot set is being landed in slices; see
`.arbor/roadmap/3-in-progress/authority-audit-terminal-identity-retirement-protocol.md`.
The durable journal file can retire them (since 2026-09-28): a retiring
publication first writes the exact compact strings it removes from the hot
snapshot as one fsynced frame of a cold, append-only retirement ledger next to
the journal (`audit_journal.v1.retirement.v1.log`, mode 0600), then binds that
frame in the v3 snapshot it renames into place. A transient ledger write
failure leaves the journal unchanged and retires nothing. A ledger that does not match its
binding (`mismatch`) or holds unexpected frames beyond it (`ahead`), whether
found at open or by a failed append, is never overwritten; publications then
keep every delivered identity hot and are never refused for it. Each journal
file owns exactly one ledger name (a journal basename must end in `.log` to
own one; ledger-shaped basenames are refused as journals).

The durable operational journal owner requests retiring publications at three
points (since 2026-09-28):

- At start (T1), after profile promotion, when the snapshot predates v3 or 512
  delivered identities wait. The live exhausted shape (a v2 snapshot holding
  4096 delivered identities) is cut over here before CapabilityStore starts.
  T1 never stops the owner: a publication that was not published leaves the
  journal unchanged and the owner serving (warning, `retirement.last_error`);
  an ambiguous one leaves it poisoned exactly like a runtime publication fault.
- After an acknowledgement (T2), once 512 delivered identities are retirable.
  The acknowledgement is answered first; the publication then runs before the
  owner's next message, so the next acknowledgement or a concurrent prepare
  waits for it. After every attempt the next T2 is armed 512 retirable
  identities later.
- On a capacity refusal (T3), when a publication could admit the refused
  record; the caller's exact record is then retried once.

A T2/T3 publication that is not published, and every T2/T3 attempt while the
ledger is paused, starts a 5-second backoff in which T2 is skipped and T3
answers the capacity refusal without publishing. A paused ledger is logged as an
error once and reported; retirement headroom then counts as zero.

Every publication re-folds the journal several times (candidate encoding,
candidate proof, source-tip proof, published replay), so its time is linear in
the hot set plus the pending records. The reducer keeps the pending operations'
reserved records as a running total, so each fold step's admission check is
O(1) in the pending count. (Before this, each step re-derived every pending
operation's reservation: the first publication after a sink outage that left
about 1000 operations pending took about 10 s, and appends under that backlog
about 12 ms each.) Measured on the development laptop on 2026-09-28: about
0.45-0.8 s per 512-identity T2 publication with nothing pending, and about
1.3 s for the first T2 after a sink outage left 1023 operations pending (the
most the entry clause admits). A call that still waits longer than the
5-second journal call timeout answers `{:commit_uncertain, :timeout}` (for the
Historian puller a false "pending"; the queued acknowledgement still commits),
a grant `:audit_unavailable`, and a revoke executes `:degraded` while its queued
prepare still lands. If a publication's `duration_ms` (logged and in the
`[:arbor, :security, :audit_journal, :retired]` telemetry) approaches that
timeout, investigate the disk before anything else.

`Security.audit_journal_status/0` reports the retirement state: under
`capacity`, `retirable_operation_count`, `retired_operation_total`,
`retire_batch`, `remaining_increase_admissions` (increase headroom after the
retirement the next refusal would perform; retirement counts as zero while the
ledger is paused or the last retiring attempt failed) and `reserved_entries`/
`reserved_bytes`; a top-level `last_refusal`; a top-level `admission_open`; and
a `retirement` map with the admission `floor`, the `ledger_state`,
`ledger_frames`, `prepared_count`, `oldest_prepared_age_seconds` and the last
retirement `last_error`. The `ledger_state` is the one of the handle's last open
or adopted publication: after an unpublished attempt that left an orphan frame a
live owner may report `absent` while a restart over the same bytes reports
`bound_orphan`; both retire.

`admission_open` is a readiness signal, never the admission decision: true when
the journal is serving, the ledger is not paused, and one more increase would
pass the retained (`remaining_increase_admissions > 0`), entry
(`remaining_soft_entries - reserved_entries >= 3`, the increase's own record
plus the two it reserves) and soft-byte (room for a maximum-size record beyond
reservations) clauses. It lives in status only. It is deliberately not part of
`Security.execution_policy_snapshot/0`: that snapshot is digested into the
security-qualification profile fingerprint (and so into the exact approval
capability), and a load-dependent field there would un-qualify every qualified
session whenever a delivery backlog closed admission. Decision H9 is "expose,
do not gate"; whether qualification should gate on readiness is a separate
roadmap item.

Before the cutover publication lands (for example while T1 keeps failing), a
v3 prepare with the same facts as a hot delivered v1/v2 operation is a new
identity, not `:operation_terminal`: the cutover alias continues pending
operations only. The facade cannot present such a prepare against a monotonic
store; it is the raw/rollback residual below.

The previous release cannot read a journal once this code has started on it:
its snapshot rules refuse the v3 snapshot (exact-parent proof against
52a2cc3fa on 2026-09-28: frame admission, snapshot admission and open all
`:malformed`; a v3 intent record `:unsupported_version`). Rolling back code
therefore means stopping the node, moving the journal/ledger pair aside (never
deleting it) and restoring the pre-cutover journal copy; everything journaled
since the cutover is then absent from the restored journal.

Retirement never deletes protected audit history, and a retired v1/v2 identity
is refused `:retired_version`, never admitted as new. A retired v3 identity is
not remembered in the hot set: it can be admitted again as a new operation,
but only if identical facts are re-presented through a same-UID rollback of
the authority store or an in-BEAM raw journal append (the production facade
cannot reach it against a monotonic store). The ledger keeps the original
compact evidence so such a recurrence is detectable offline (see the residuals
section of the roadmap item above).

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
a target name containing “durable.” Retained operation identities consumed a
finite lifetime budget after pending work drained until durable operational
journals began retiring delivered identities (2026-09-28); expose the retained
and retirable budgets separately.
Exact current before-state permits retry of a stable prepared operation, while a
later incarnation cannot establish that a transient effect never happened.
