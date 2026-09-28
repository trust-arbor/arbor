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
targets leave journal evidence pending. An operation stuck on conflicting or
unreadable content (`audit_content_conflict`, `audit_content_unavailable`,
from the readback or from the journal's acknowledgement check) is retried on
every poll but reported once per stuck episode: one `Logger.warning` per
delivery pass naming the newly stuck operations, and
`[:arbor, :historian, :authority_audit, :conflict]` telemetry per operation
(metadata `operation_id`, `reason`, `source` = `event_log | journal`). An
operation that leaves the batch is forgotten, so a recurrence is reported
again. Only the configured registered consumer PID can fetch delivery bodies or
acknowledge them; caller-provided ACKs cannot erase pending evidence. The
trusted BEAM and its process registration remain part of this boundary.

`Security.current_invocation_id/0` is captured at the mutation caller before the
CapabilityStore mailbox. The closed `inv_` identifier is carried as correlation
and cleared after the serialized message. Capability metadata cannot select it.
No invocation outside an admitted source-owned context is inferred. Delivery
preserves the original prepare timestamp and marks the effect as applied; that
timestamp is not represented as the exact wall-clock effect time.

## Operational capacity and identity retirement

Implemented 2026-09-28 (Floor-and-Ledger v3). Design, decision rulings H1-H12
and the live recovery runbook:
`.arbor/roadmap/3-in-progress/authority-audit-terminal-identity-retirement-protocol.md`
and `.arbor/decisions/2026-09-28-authority-audit-terminal-identity-retirement.md`.

### Capacity is a working set, not a lifetime quota

Application and TestBootstrap select a persisted, versioned operational profile:
4096 frames / 16 MiB, with 1024 frames / 4 MiB reserved for reductions and
finishing admitted lifecycles. New increases must fit the 3072-frame / 12-MiB
soft budget, including the records they reserve for their remaining
applied/delivered steps. A bounded 48-frame profile remains available to
explicit local test owners; it never retires. Durable profile promotion uses the
existing proven compaction/publication path and never retires; a cold downgrade
is refused. Normal records keep the 32-KiB admission bound; operational
snapshots are bounded to 4 MiB, and total file reading is bounded to
21,266,503 bytes including frame headers and one incomplete tail.

The constants did not change; their meaning did. The retained set is
`pending + effect_rejected + delivered-not-yet-retired`. Increases are refused
beyond 3072 retained identities and every new `prepared` beyond 4096, which
preserves at most 1024 identity slots for reductions; byte and entry limits can
stop admission earlier. Delivered identities leave the retained set at the next
retiring publication, so with a healthy sink the delivered-not-yet-retired term
stays below 512 and the limits bound the working set:

- Pending work is bounded independently of retention: N prepared-only pending
  operations refuse a new increase at about N = 1023 (each reserves two more
  records) and everything at about N = 1364; the pending manifest keeps its
  4096 cap.
- The 1024-slot reduction reserve is consumed only by undelivered reductions
  (and by every delivered operation while the ledger is paused, below).
- Backpressure now means one of: Historian is not acknowledging (`pending_count`,
  `oldest_pending_age_seconds`), storage cannot publish
  (`retirement.last_error`), the ledger is paused (`retirement.ledger_state`),
  or prepared operations accumulate (`retirement.prepared_count`,
  `retirement.oldest_prepared_age_seconds`). It never means cumulative delivery.

Measured on the development laptop on 2026-09-28: 2300 public grant/revoke
pairs (4600 identities) drained through the real Historian puller into a
committed SQLite EventLog in 30-46 s across runs, with eight retiring
publications and no refusal; the previous release refuses grant 1537
(identity 3073) of the same workload.

### Identity v3 and the admission floor

CapabilityStore's producer emits version-3 intents: the same facts as version 2
under their own identity domain, so the two identities of identical facts never
collide. Operational snapshots are version 3. A v3 snapshot carries
`retirement.retired_total` and the binding of the cold retirement ledger, and
sets the journal's admission floor to intent version 3: an unknown v1/v2
`prepared` is refused `:retired_version` before any capacity check and writes
nothing, while v1/v2 operations already pending complete by id. A v2 operation
pending at the cutover is continued (not forked) by a v3 prepare of the same
facts; that alias lookup runs only while such an operation is pending.

Before the cutover publication lands (for example while T1 keeps failing), a v3
prepare with the same facts as a hot delivered v1/v2 operation is a new
identity, not `:operation_terminal`: the cutover alias continues pending
operations only. The facade cannot present such a prepare against a monotonic
store; it is the raw/rollback residual below. `prepare` answers
`:operation_terminal` for every terminal identity, compacted or not.

### Retirement happens at publication, into the cold ledger

Only `delivered` identities retire; `effect_rejected` terminals (journal-only
evidence) and pending operations never do. A retiring publication first writes
the exact compact strings it removes from the hot snapshot as one frame of an
append-only retirement ledger next to the journal,
`audit_journal.v1.retirement.v1.log` (mode 0600, the frame fsynced, the parent
directory fsynced when the ledger file is created), and only then renames the
v3 snapshot that binds that frame into place. The rename is the single flip
point: a crash before it leaves the old journal authoritative (an unbound frame
is an overwritable orphan, rewritten by the next retiring publication); a crash
after it leaves a published v3 snapshot whose frame is already durable. A
transient ledger write failure leaves the journal unchanged and retires
nothing. Each journal file owns exactly one ledger name (a journal basename
must end in `.log` to own one; ledger-shaped basenames are refused as
journals).

No code ever prunes or rewrites bound ledger frames (H2), and retirement deletes
no protected history: every retired identity's compact evidence is in the
ledger and, once delivered, its event is in Historian.

### Triggers and backoff

The durable operational journal owner requests retiring publications at three
points, all through the same checked compaction/publication pipeline:

- At start (T1), after profile promotion, when the snapshot predates v3 or 512
  delivered identities wait. The live exhausted shape (a v2 snapshot holding
  4096 delivered identities) is cut over here before CapabilityStore starts.
  T1 never stops the owner: a publication that was not published leaves the
  journal unchanged and the owner serving (warning, `retirement.last_error`,
  backoff armed); an ambiguous one leaves it poisoned exactly like a runtime
  publication fault. A torn-tail journal skips T1 and starts degraded as
  before.
- After an acknowledgement (T2), once 512 delivered identities are retirable.
  The acknowledgement is answered first; the publication then runs before the
  owner's next message, so the next acknowledgement or a concurrent prepare
  waits for it. After every attempt the next T2 is armed 512 retirable
  identities later.
- On a capacity refusal (T3), when a publication could admit the refused
  record; the caller's exact record is then retried once. No record carries an
  epoch, so the retry of the same raw record is correct by construction.

A T2/T3 publication that is not published, and every T2/T3 attempt while the
ledger is paused, starts a 5-second backoff (monotonic clock) in which T2 is
skipped and T3 answers the capacity refusal without publishing. T1 ignores it.
The small profile keeps its historical compaction behavior with no backoff.

### Publication latency

Every publication re-folds the journal several times (candidate encoding,
candidate proof, source-tip proof, published replay), so its time is linear in
the hot set plus the pending records. The reducer keeps the pending operations'
reserved records as a running total, so each fold step's admission check is
O(1) in the pending count. (Before this, each step re-derived every pending
operation's reservation: the first publication after a sink outage that left
about 1000 operations pending took about 10 s, and appends under that backlog
about 12 ms each.) Measured on the development laptop on 2026-09-28:

- about 0.45-0.8 s per 512-identity T2 publication with nothing pending (owner
  lane with an in-process consumer);
- about 0.6-1.8 s per 512-identity T2 publication in the real-SQL-sink lane
  (the Historian puller acknowledging after committed SQLite writes);
- about 1.3 s for the first T2 after a sink outage left 1023 operations pending
  (the most the entry clause admits);
- about 0.3-0.6 s per 512-identity in-memory retirement on an ephemeral journal.

A call that still waits longer than the 5-second journal call timeout answers
`{:commit_uncertain, :timeout}` (for the Historian puller a false "pending"; the
queued acknowledgement still commits), a grant `:audit_unavailable`, and a
revoke executes `:degraded` while its queued prepare still lands. If a
publication's `duration_ms` (logged and in the
`[:arbor, :security, :audit_journal, :retired]` telemetry) approaches that
timeout, investigate the disk before anything else.

### Ledger postures and the paused endpoint

The ledger is verified when the journal opens and after every adopted
publication; admission never reads it. `absent` (no ledger yet, genesis
binding), `bound` (the file ends exactly at the bound frame) and `bound_orphan`
(a torn prefix or one complete unbound frame whose identities are all still hot)
are retiring postures. A ledger that does not match its binding (`mismatch`) or
holds unexpected frames beyond it (`ahead`), whether found at open or proven by
a failed append, is never overwritten and pauses retirement: the node serves,
every publication runs non-retiring (delivered identities stay hot, occupancy
relief keeps working, the binding and `retired_total` are carried forward),
retirement headroom counts as zero, `admission_open` is false, and the owner
logs `Logger.error` once and emits
`[:arbor, :security, :audit_journal, :ledger_paused]`.

The endpoint of a pause is stated, not hidden: retained grows by one per
delivered operation; beyond 3072 retained identities increases are refused
(`:audit_unavailable` with reason class `capacity`), and beyond 4096 every
`prepared` is refused and reductions execute `:degraded`, unjournaled, each one
counted, telemetered and (rate-limited) logged. A paused posture changes only by
restart after the matching journal/ledger pair is restored.

### Ephemeral journals retire in memory

An ephemeral operational journal (the test default, and production-reachable
when the journal mode is `:ephemeral`) makes no durability claim and has no
file or ledger. Its delivered identities retire in memory (H11): T2 and T3 run
the same core compaction a durable publication would rename into place, over
the genesis source and the unchanged genesis ledger binding, and T3 then
retries the caller's exact record once. The first in-memory retirement installs
a v3 snapshot, so the floor becomes 3 as on a durable journal. Status reports
real retirement headroom with `retirement.ledger_state` `"none"` and
`ledger_frames` 0. A failed in-memory compaction keeps the state, sets
`retirement.last_error` and arms the same backoff. Restarting an ephemeral
journal loses everything, as before.

### Status and readiness

`Security.audit_journal_status/0` reports the retirement state: under
`capacity`, `retirable_operation_count`, `retired_operation_total`,
`retire_batch`, `remaining_increase_admissions` (increase headroom after the
retirement the next refusal would perform; retirement counts as zero while the
ledger is paused, while the last retiring attempt failed, and on small
journals) and `reserved_entries`/`reserved_bytes`; a top-level `last_refusal`;
a top-level `admission_open`; and a `retirement` map with the admission
`floor`, the `ledger_state` (`none` without a ledger), `ledger_frames`,
`prepared_count`, `oldest_prepared_age_seconds` and the last retirement
`last_error`. Existing fields keep their map-size definitions, so an empty queue
is never read as capacity. The `ledger_state` is the one of the handle's last
open or adopted publication: after an unpublished attempt that left an orphan
frame a live owner may report `absent` while a restart over the same bytes
reports `bound_orphan`; both retire. Two opens of the same bytes report the same
status except wall-clock ages.

`admission_open` is a readiness signal, never the admission decision: true when
the journal is serving, the ledger is not paused, and one more increase would
pass the retained (`remaining_increase_admissions > 0`), entry
(`remaining_soft_entries - reserved_entries >= 3`, the increase's own record
plus the two it reserves) and soft-byte (room for a maximum-size record beyond
reservations) clauses. It lives in `audit_journal_status/0` only. It is
deliberately not part of `Security.execution_policy_snapshot/0`: that snapshot
is digested into the security-qualification profile fingerprint (and so into
the exact approval capability), and a load-dependent field there would
un-qualify every qualified session whenever a delivery backlog closed
admission. Decision H9 is "expose, do not gate"; whether qualification should
gate on readiness is a separate roadmap item.

### Replay semantics and the accepted residual

- A retired v1/v2 identity is refused `:retired_version` whatever its bytes,
  never admitted as new; its continuation records are `:out_of_order`, and a
  late acknowledgement of any retired identity is `:audit_content_conflict`
  with no state change.
- Through the production facade a retired identity is unreachable against a
  monotonic store: an unchanged live capability short-circuits before the
  journal, and a re-grant after revocation is a different identity.
- Admission never consults Historian. Deleting a retired operation's stream
  (`Historian.delete_stream_content/2`) or replacing the durable EventLog
  target changes no journal decision; new operations deliver to the new
  target and retired ones are never redelivered.
- Accepted residual (H4): a retired v3 identity is not remembered in the hot
  set. If identical facts are re-presented through a same-UID rollback of the
  authority store or an in-BEAM raw journal append, the operation is admitted
  as new. Its effect then applies again, and delivery either merges onto the
  original event (same prepare second) or, far more likely, meets the original
  event with a different prepare time: the operation stays `effect_applied`,
  is retried and never acknowledged or retired, is counted in the pending
  status, and the Historian puller reports it (below). This never yields
  authority the rolled-back store did not already permit, and the ledger keeps
  the original compact evidence for offline detection.

### Operator notes

- Before the first start of this code on a node, take a read-only side copy of
  `audit_journal.v1.log` (and of `audit_journal.v1.retirement.v1.log` if one
  exists). The previous release cannot read the journal once this code has
  started on it: its snapshot rules refuse the v3 snapshot (exact-parent proof
  against 52a2cc3fa on 2026-09-28: frame admission, snapshot admission and
  open all `:malformed`; a v3 intent record `:unsupported_version`).
- Never delete the journal or the ledger, and never reset the journal to regain
  capacity. They are one recorder: copy, move and restore them only as a pair.
  A journal restored from an older copy while the newer ledger stays in place
  opens with the ledger `ahead`, and a journal whose bound ledger is missing
  opens `mismatch`: both are the paused endpoint above, never silent.
- Rolling back code means stopping the node, moving the journal/ledger pair
  aside with `mv` (never deleting it) and restoring the pre-cutover journal
  copy; everything journaled since the cutover is then absent from the
  restored journal (delivered operations survive in Historian).
- Watch `pending_count`/`oldest_pending_age_seconds` (the sink is not
  acknowledging), `retirement.last_error` (storage cannot publish),
  `retirement.ledger_state` (`mismatch`/`ahead` = paused), `last_refusal`,
  `admission_open`, the owner's publication logs and `:retired` /
  `:publication_failed` / `:ledger_paused` telemetry, and the Historian
  puller's stuck-operation warnings. The runbook's recovery steps are in the
  roadmap item named at the top of this section.

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
finite lifetime budget after pending work drained until operational journals
began retiring delivered identities (2026-09-28: durable journals into the cold
ledger, ephemeral ones in memory); expose the retained and retirable budgets
separately.
Exact current before-state permits retry of a stable prepared operation, while a
later incarnation cannot establish that a transient effect never happened.
