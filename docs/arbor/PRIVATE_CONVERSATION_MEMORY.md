# Private conversation memory admission

M1b2 adds a positive private storage/read lane. Session conversation production is
not enabled by this change. General semantic readers continue excluding recognized
conversations, and private-turn tool writes remain restricted.

## Public boundaries

`Arbor.Security.exchange_private_memory_receipt/4` consumes a genuine one-use chat
receipt for the exact human and agent, and returns an opaque pending admission.
Only the process that exchanged it may activate, use or close it. Session resolves
and validates the private human engagement, rechecks it when a queued turn starts,
and activates the admission there. Pending tokens cannot read, write or attest.
The broker closes admissions on explicit removal, process death or immutable TTL.

`Arbor.Memory.index_private_conversation/4` accepts the active admission, text,
a strict precomputed embedding result and only `source_id:`. The source ID belongs
to the producer. `recall_private_conversations/3` accepts the admission, a strict
precomputed query embedding and only `limit:`/`threshold:`. Neither API calls an
embedding provider. Provider/model descriptors are validated data; transport
provenance must be established separately by the producing Session route.

Both operations require current ordinary chat and memory capabilities as well as
the receipt-derived pair. Tokens, owner claims, metadata, namespace options and
capability IDs are not interchangeable credentials. The token is never put in
Engine values, provider options, public Session state or checkpoint data.

## Durable representation

The existing strict vector store holds one namespace derived from the agent/human
pair. Deterministic entry identity also includes the stable source ID. Identical
source/content/vector retries return the existing ID, retaining the original
sealed session, turn and engagement; changed content or model is a conflict.

A purpose-specific SystemAuthority attestation binds the exact owner facts,
record identity, body digest, vector digest and model/storage descriptors. A root
acknowledged by a node-restart-durable authority store is required; an ephemeral
root cannot create or verify these records. Current-root verification deliberately
rejects old stamps after rotation until historical-root policy is qualified.
Record authenticity is separate from current read authorization.

Cold reads validate complete returned records, recompute their digests and verify
the root stamp before ranking/disclosure. Namespace, owner or descriptor mismatch
fails closed. Ordinary capability authorization is rechecked before disclosure.
General readers also exclude rows retaining the reserved private body markers even
if their category was relabelled. This is restrictive recognition, not a claim that
arbitrarily erased historical provenance can be recovered.

SQLite's unsupported-ANN fallback reads at most 1,000 records from this pair's
namespace and computes cosine similarity. This is a bounded recall window, not
complete pagination. Zero vectors and malformed embeddings fail before I/O;
unknown store errors do not trigger a fallback. Legacy/unscoped conversations
remain stored but unavailable through this private lane.

## Producer follow-through

M2 must authorize the exact on-host embedding endpoint/model, index only after
acknowledged transcript append, and preserve authenticated source identity for
recovery of missed indexing. Cloud/hash fallback, historical backfill and direct
host write restoration are not enabled here. Working memory, proposals, identity,
relationships and goals need their own visibility policy; index isolation does not
prove those separate stores safe for multiple humans.
