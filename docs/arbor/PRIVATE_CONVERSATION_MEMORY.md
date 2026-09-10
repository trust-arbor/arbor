# Private conversation memory admission

The private storage/read lane supports an explicitly configured, authenticated
Session producer. General semantic readers continue excluding recognized
conversations, and private-turn tool writes remain restricted. The default
configuration performs no automatic private conversation embedding or indexing.

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

The source-owned `:arbor_orchestrator, :private_conversation_memory` setting is
`false` by default. An operator can opt in with a closed keyword configuration:

```elixir
config :arbor_orchestrator, :private_conversation_memory,
  enabled: true,
  provider: :lm_studio,
  model: "operator-selected-768-dimensional-embedding-model",
  base_url: "http://127.0.0.1:1234/v1",
  timeout_ms: 10_000
```

This example is not deployment enablement. The exact endpoint must also be
trusted by the LLM endpoint policy. Only `:ollama` and `:lm_studio` with a literal
loopback address (127/8 or `::1`) are supported; hostname aliases are rejected.
The URL must also be trusted by the canonical ProviderRegistry configuration
(`config :arbor_orchestrator, :lm_studio` or `:ollama`, with `base_url:`), or by
the existing exact trusted-proxy endpoint list. The legacy LLM `lm_studio_base_url`
setting alone does not configure that boundary.
The source selects the model and exact URL, checks the public on-host egress
classification and current egress policy, then uses `Arbor.LLM.embed_batch`.
Enabled private memory requires the exact stock ReqLLM pipeline. A custom
Record/Replay/replacement composition returns
`:private_memory_embedding_pipeline_unsupported` before the turn starts; the
operator's list is never silently changed. Disabled private memory and ordinary
LLM calls retain their existing pipeline behavior. The adapter revalidates the
source-owned `require_live_pipeline: true` restriction at each embedding
admission and captures the approved sequence for that call. A later incompatible
configuration makes a query stage unavailable or leaves a committed source
pending; it cannot replace the active call's sequence.

Requests disable redirects. The existing single-attempt Call contract disables
Req retries after provider preparation and prevents RateLimitBackoff redispatch,
including its configured callback. A source HTTP 429 therefore leaves the
acknowledged transcript pair pending without accepting replacement vectors or
appending it again. A later admitted turn may recover the original pair through
a fresh successful HTTP batch. No cloud, hash or generic Memory embedding
fallback is allowed. Model/provider fields supplied with a vector are data,
not evidence of local transport.

The timeout defaults to 10 seconds and may be set to at most 30 seconds. Query,
recovery and post-commit embedding share a 30-second provider budget, excluding
Engine execution. Source validation and synchronous acknowledged storage use
their existing owner calls; this is not a hard wall-clock limit for a whole turn,
and a dispatched store write is never described as rolled back on timeout. A batch contains at most six texts: one query and five pending
sources. Each text is limited to 65,536 UTF-8 bytes, the batch to 393,216 bytes,
and the response to 2 MiB. Results must retain exact input-index association,
the selected provider/model, 768 dimensions and nonzero finite vectors. A
failed query stage continues without recall; it does not select another route.

Before Engine execution, the Session verifies recoverable sources and supplies
only scoped recall data to the graph. Its opaque admission remains in the
Session process. The protected `SessionMemory.Recall` node consumes this
precomputed data, including the explicit empty result; it cannot run generic
query or agent-wide belief recall. The ordinary `memory.recall`/`memory_recall`
tool is refused under the private-turn policy before any provider call.

Before the atomic transcript append, `prepare_private_conversation_source/2`
requires a live admission and signs the exact two roles, content digests,
stable `session_turn:` source identity, original human/agent/session/turn/
engagement and derived record identity. This uses a separate SystemAuthority
purpose from vector attestation. The source signature does **not** prove an
append or acknowledgement. Failure to obtain it on the enabled route returns
`:private_memory_source_unavailable` before append. The actual signed pair is
limited to 65,518 combined content bytes, leaving the canonical row's rendering
overhead within its existing string bound.

Both persisted transcript entries carry the same source proof. After the
atomic pair acknowledgement, the Session retains the live admission through a
bounded, cancellable embedding stage and calls
`index_private_conversation_source/3`. Its record attestation binds the new
vector to the original authenticated source. A successful response reports
`metadata.conversation_memory.status` as `"indexed"` or `"pending"`, with
`transcript: "committed"`; indexing failure never rolls back the acknowledged
pair or appends it again. The embedding worker is tied to the Session lifetime
and receives no admission. Turn cancellation, caller loss or Session death
prevents stale results from acquiring a later turn's authority.

On a later admitted turn, recovery examines the most recent 1,000 transcript
rows under the same stable Session ID and selects at most five pending complete
pairs. It requires matching proofs, roles, consecutive stored ordinals and
original engagement, then verifies the source signature and current owner pair
before returning text for embedding. Foreign or malformed sources are skipped.
`prepare_private_conversation_index/2` verifies an existing strict row before
reporting it indexed; a stored marker alone cannot suppress recovery. An
unknown append outcome is recoverable only when this complete committed pair
is observed. There is no blind append retry. Older pending sources outside the
window and pending sources under another Session ID are not recovered by this
slice. Already indexed recall crosses Session IDs for the same admitted pair.

Cloud/hash fallback, historical unsealed backfill and direct host write
restoration remain unavailable. Working memory, proposals, identity,
relationships and goals need their own visibility policy; index isolation does
not prove those separate stores safe for multiple humans.
