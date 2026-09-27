# Authenticated conversation transcript freshness

2026-09-27

An authenticated Orchestrator Session reads the durable transcript before each
new turn, including a queued turn and a return to a stashed engagement. A Voice
turn acknowledged through `Arbor.Comms.record_engagement_turn/5` is therefore
available to the next model prompt without restarting the Session. The live
model graph must use `messages_context_key="session.messages"`, as the normal
session turn graph does.

## Source and admission

`Arbor.Persistence.read_session_transcript/4` checks the session's agent owner,
filters the exact named engagement before limiting, and reads in durable ordinal
order. It retains content blocks, metadata, timestamps, model/usage, stable entry
IDs, and verified or conservatively unlabeled taint. Invalid durable provenance,
malformed entries, unavailable storage, and invalid cursors return errors.
Display history is not used as cognitive input.

The first read bootstraps the most recent 1,000 entries and explicitly reports
whether older entries were omitted. Later reads use an ordinal cursor and a
captured head. A delta exceeding 1,000 entries or the 8 MiB page budget fails
closed; it does not silently skip to the tail. Entries are bounded to 256 KiB.
The public read also accepts `:through` for a pinned paginated snapshot.

Session checks current receipt-derived subject, canonical owner, grant, and
engagement before reading, stages the reconciliation, and rechecks that same
binding before adopting it. Denial leaves the old transcript and compactor intact
and does not call the model. `recover_session: false` cannot disable this gate.

## Local commits and compaction

`Arbor.Persistence.identify_session_entries/1` assigns stable IDs before a local
turn's existing acknowledged atomic pair append. The append acknowledgment still
uses the existing bounded commit-guard protocol. Only after acknowledgment does
Session adopt the live messages and remember the pair's immutable descriptors.
Identical text in different entries remains distinct.

Session keeps a per-engagement cursor, the compactor at that cursor, and at most
one acknowledged local pair not yet observed by a read. An unchanged or own-only
delta preserves the current compactor exactly, including its current summary.
An external suffix is appended. If another channel committed before the local
pair, only that bounded unobserved suffix is replayed onto the saved compactor;
earlier history is not rebuilt. Full messages, compactor, and `session_state`
are adopted together. An intentionally absent live assistant projection remains
absent even though the durable empty assistant entry belongs to the pair.

Attested private-memory source rows must form a coherent observed pair under
the existing private-memory proof rules. An orphan or mismatched pair refuses
continuation rather than contributing partial text to the model or advancing
the cursor. If the recent 1,000-row bootstrap starts with an attested assistant,
Session reads its immediately preceding user row from the same source scope as
a validation-only witness. At most 1,000 rows are adopted and one additional row
is observed; both reads retain the page and entry byte bounds. The public reader
remains row-paginated, including `limit: 1`.

Refresh rechecks authority before the pure compactor append/rebase callbacks and
again before adopting the projection. It does not invoke `maybe_compact`, whose
optional narrative stage can call a model. That stage remains on the existing
admitted turn commit path, after the regular route/disclosure gates.

## Boundaries

This is a bounded transcript reconciliation mechanism, not a new journal or
recovery engine. A source failure never becomes an empty history. Missing local
acknowledgment IDs, unexpected conversational edits, or an imported checkpoint
without a durable synchronization anchor refuse authenticated continuation as
`transcript_unavailable`; cached state is retained. Starting a fresh Session
reboots from the durable source. Initial system messages are preserved.

Unauthenticated compatibility turns retain their existing behavior. Voice's
provider history injection and token lifetime checks are separate channel work;
this slice qualifies completed Voice/Comms pairs as input to Session cognition.

The source tests run against private SQLite. The Session journey uses actual
receipt authentication, public Comms append, and a capturing model adapter to
check active/stashed scopes, interleaving, repeated text, outages, provenance,
compactor summaries, and revocation or owner changes during a read.
