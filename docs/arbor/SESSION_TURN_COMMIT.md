# Acknowledged Session Turn Commits

## Contract

A successful public Session reply requires acknowledgement of one atomic
user/assistant pair append. Only `{:ok, 2}` is admitted. Ensure/append errors,
malformed results, exceptions and expired completion evidence fail closed as
`{:error, :turn_commit_failed}` at the Session boundary.

Messages, working memory, turn count, compaction, the completed-turn checkpoint
and success signals are adopted only after acknowledgement. Authority cleanup
precedes the commit wait. The failure path does not invoke partial finalization
and therefore does not attempt a second append. Partial/cancel persistence and
heartbeat persistence retain their separate existing behavior.

This is an acknowledgement guarantee, not a distributed transaction or
exactly-once delivery guarantee. A database may commit before its caller loses
the acknowledgement. Timeout, owner loss or process termination does not prove
rollback; do not automatically replay an uncertain append. Indexing and recall
on the authenticated Session path are separate follow-up work.

## Lifetime and Deadline

Session monitors one private guard. The guard monitors Session, traps exits,
and links one non-trapping writer. No named supervisor, journal, new graph or
public authority object is introduced. Persistence adapters are trusted code,
not worker-supplied executable input.

The guard observes writer termination before publishing success. Completion
must carry an owner-generated monotonic timestamp within the absolute commit
deadline. A queued late result cannot become success merely because `receive`
examines it before an expired `after` clause.

The default commit budget is 10 seconds. `turn_commit_timeout_ms` in Session
config can reduce it; invalid values, `:infinity` and larger values use the
default. Failure cleanup has one additional 1-second observation budget. These
are process wait budgets, not real-time guarantees under VM suspension or a
blocking native call. The Session mailbox is held during this synchronous
boundary, so steering and cancellation remain queued until it returns.

On abnormal guard death or exhausted cleanup, a closed failure is returned.
Linked termination and kill requests bound normal BEAM writer lifetime, but
guard `DOWN` alone is not evidence that the writer or database has finished.
Failure does not promise confirmed descendant settlement or database rollback.

## SU-3A Design Amendment, 2026-09-08

The delegated operator admits the single-guard design implemented by
`48fce59c16eced47b145418b660426221e7e27f5`, subject to owner qualification.
This explicitly replaces the original design's Session-side writer monitor,
arming handshake and second post-kill observation window. It does not replace
the mandatory writer-exit confirmation on the success path.

The two-observer protocol duplicated lifetime ownership. The smaller design
keeps the required acknowledgement evidence while making failure uncertainty
explicit instead of implying rollback from process monitors. Stronger
transaction settlement, retry deduplication or immediate cancellation would
require separate contracts and tests, not a larger watchdog hidden here.

Factory task `task_86b9459943c07ef94f3230993cd0f6cd` ended as
`rework_exhausted`; its final council was 10 approve, 1 reject, 0 abstain.
The remaining design-conformance finding required either the old two-observer
protocol or explicit admission of its replacement. This document records that
admission. It does not relabel the factory outcome or claim council approval
for the owner's additional fixture corrections.

## Evidence

`turn_commit_acknowledgement_test.exs` exercises the public Session boundary
with held, failed, malformed, raised and late persistence, owner/guard death,
and a subsequent successful turn without a duplicate failure-path append.
The authenticated J0 journey uses real SQLite persistence and immediately
requires the exact pair in a fresh engagement, without a polling allowance.
Owner qualification also runs the surrounding Session integrations and the
new regression tests against the pre-fix source. Preserved runs are tracked in
the Proxmox factory roadmap; a compile-only factory pass is not this test proof.
