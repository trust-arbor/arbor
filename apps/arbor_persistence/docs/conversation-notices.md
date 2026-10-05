# Durable conversation notices

The notice store is a lower storage boundary, not publisher authentication.
Higher native source authority verifies the actual producer, fresh proof, exact
recipient, capability, trust and taint before using the public Persistence facade.
Pure validation helpers do not grant publishing authority. Arbitrary trusted BEAM
code remains in the application trust boundary.

Scope is exactly `owner_id`, `target_agent_id`, `engagement_id`, referring to an
existing durable `user` / `private` engagement owned by that canonical human.
No missing engagement, Session, membership or transcript entry is created.
Facts are exactly `notice_id`, `recipient_subject_id`, `kind`, `text`, `provenance`.
The original human subject is an immutable fact, independent of linked human
family readers. Authenticated wire readers receive recipient_subject_id only as
readonly provenance for independent envelope verification; it is never a
selector, proof or publisher authority. Semantic UI projections remove it. The notice ID has the form `notice_` plus 32 lowercase hex digits.
Kinds are `notification` or `progress`; valid nonblank UTF8 text is at most32768
bytes. String/atom duplicate keys, extra keys, caller timestamps and caller
ordinals are refused. Conservative native provenance binds the entire fixed-order
scope/recipient/ID/kind/text payload through the existing TaintEnvelope, with
untrusted or hostile level, internal/confidential/restricted sensitivity, zero sanitizations, unverified confidence
and `native_conversation_notice` source. This label never declassifies data.

`append_conversation_notice/2` assigns a positive ordinal in the exact engagement
and a server UTC timestamp. The notice, head and engagement activity touch commit
in one SQL transaction. The durable Home query combines exactly scoped notice
activity with stamped conversation entry activity; notices never appear as user
or assistant turns. A repeated ID with identical caller facts returns `existing`
and keeps the first timestamp/ordinal. A new producer generation does not create
a new storage identity. Changed facts conflict. Timestamp, ordinal, signature,
nonce, source permit, process/generation and callback are not immutable caller
facts. The SHA256 digest uses canonical fixed-order JSON, including provenance.
The fixed-order digest payload has the domain tag `arbor.conversation.notice.publication.v1`. It is storage integrity data, never a bearer credential.

`reconcile_conversation_notice/2` performs a read-only exact-facts lookup after a
lost append reply. Missing identity is explicitly `notice_not_found`; it does not
create or automatically retry an effect. Higher authority must independently
make any subsequent publishing decision. No receipt or transient source handle
is persisted.

`read_conversation_notice_page/2` accepts only `limit` (default20, maximum50),
`before` (strictly older positive ordinal), and `through` (inclusive positive
ordinal). The default through is the current scoped head. A future through is
refused. Each read is a fresh SQL snapshot; the head is live, while through can
pin the traversal cutoff against interleaved appends. Ordinals are immutable and
may be sparse. The head survives gaps. Scope filtering precedes all limits.
`complete: true` means this authoritative SQL snapshot was read, not that there
are no older records. `has_older` and `next_before` describe the remaining pinned
window. Empty pages have no continuation. The next cursor is always the last
included record, so byte cuts do not discard or skip a record.

The full lower envelope, including scope, head, through and cursors, is at most
129024 encoded bytes, reserving2048 for the higher128KiB host wrapper. Full text
is preserved. A single record whose JSON escaping cannot fit is refused before
SQL, rather than stranded behind an untraversable page. Read projections omit
facts_digest and all transient source/proof/control fields. The store verifies the original
subject-bound taint envelope before projecting a record; corrupt durable data
fails closed.

Append acquisition and settlement share one absolute5s budget. SQLite acquires
BEGIN IMMEDIATE with a connection-local5ms native busy slice and queue:false,
restoring the original busy setting before returning the connection. Only
acquisition before the callback/effect is retried within that same deadline.
Nothing after the first transactional query is retried. PostgreSQL locks the
existing engagement row before allocating the scoped ordinal. Reads use a
deferred SQLite snapshot and do not acquire a writer lock. A failed or lost reply
is unavailable/uncertain until explicit read-only reconciliation. These bounds
apply to this notice store; they do not claim general SQL availability.

## Native commit gate

`append_native_conversation_notice/2` is distinct from trusted storage append.
It accepts exactly the same scope/value, with no authority options, callbacks or
proof fields. The SQL callback runs on the original native worker, not a spawned
helper. After acquiring the existing private engagement lock and checking exact
same-ID facts, Security rechecks that worker's private source admission and the
fresh owner/policy/exact selected grant. A new identity consumes capability
effects once immediately before INSERT. Identical existing facts use a fresh
reconciliation check without another allowance charge. Denial rolls back with
no notice, head or engagement activity mutation. Prepared publisher admission is
held until the higher Comms shell receives the terminal SQL outcome. It is never
stored in the notice or caller-visible result. The gate does not authorize an
external caller from a map, process dictionary, capability ID or validation hash.
