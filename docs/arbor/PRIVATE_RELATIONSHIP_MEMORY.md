# Private relationship focus

The selected authenticated Session turn can remember one explicit, human-owned
`current_focus` for its agent/human pair. This lane runs when the source-owned
`private_conversation_memory` route is enabled and admitted. The disabled mode
does not produce or project private relationship memory. Existing legacy
relationship rows do not establish human ownership and are never imported.

The entire user message must have exactly one of these forms:

```text
Remember my current focus: observatory calibration
Correction: my current focus is: telescope alignment
```

Prefixes are case sensitive. The value must contain 1–512 UTF-8 bytes, with no
leading/trailing whitespace, control characters, or line separators. Quoted
directives, third-person statements, and ordinary conversation infer nothing.
An initial declaration creates the focus; an identical value is unchanged. A
different declaration conflicts. A correction requires an existing focus and
replaces its value, retaining evidence that the source was a correction.

Session reads `Memory.get_private_relationship(admission)` before Engine and
keeps its exact observed Record fence privately. Only its bounded JSON focus
projection enters `session.private_relationship`, with untrusted-data taint.
The real turn graph passes the declared `private_relationship` parameter into
BuildPrompt, which places the focus in the current user message. It is not a
system instruction. The admission and Record fence never enter graph context,
model parameters, or provider options.

After the existing transcript append acknowledges both roles, Session calls
`Memory.apply_private_relationship_source(admission, source, expected_fence)`
once. Memory verifies the exact M2 source content and root stamp and requires
all five original source facts—agent, human, engagement, session, turn—to match
the active caller-bound admission. It derives the operation from the signed
user text. A source stamp proves origin, not transcript acknowledgement; the
trusted Session owns the post-ACK sequencing. These are source-owned APIs,
not a same-VM hostile-caller confinement claim.

The snapshot lives in MemoryStore's `private_relationships` namespace, keyed
by the canonical SHA-256 of `[agent_id, human_id]`. Its root signature uses the
separate `arbor.private-relationship-snapshot.v1` purpose and binds its exact
physical namespace/key/id, five scope facts, complete body digest, and logical
`snapshot_revision`. The body retains the last source ID, declaration/correction
kind, focus value, and original source descriptor/stamp. Cold reads verify both
signatures and reconstruct the directive to verify its signed content digest.

Writes require backend-acknowledged node-restart durability. Live compare-and-swap
uses the exact observed physical Record; a changed fence is a conflict without
reload/retry. Physical generation/revision are checked on ACK but are not
predicted or signed. Thus delete/reinsert remains valid even when storage chooses
a new incarnation. Cold verification proves root-origin authenticity; it does
not prove freshness against an offline replay or reinsertion of an old valid
snapshot. Root rotation fails closed under the existing current-root-only policy.

Conversation indexing and relationship application report separate outcomes in
`PipelineResponse.metadata`. `relationship_memory` has `transcript: "committed"`
and status `saved`, `unchanged`, `not_requested`, `conflict`, or `unavailable`.
A vector embedding failure does not undo a saved relationship. A relationship
failure never retries the transcript. The post-ACK stage shares the remaining
M2 wall budget; relationship work starts only while the caller and admission
are live.

Historical conversation-source recovery never applies relationship directives.
A crash or failed relationship write requires a new explicit interaction; a
fresh turn cannot replay an older signed source over newer state. Adding such
recovery would require a pre-append signed update intent with its expected
relationship fence. M5 does not provide it.

The five legacy relationship actions now use the existing Memory read/write
capability family, matching their owning library and conversational profile.
They retain the self-scoped block check. No grant or trust rule is added.
Receipt-authenticated private turns reject legacy Get/Browse/Summarize before
effects, as their agent-wide rows cannot prove human ownership; existing private
write containment still denies Save/Moment. Absent-policy legacy calls retain
their normal behavior.

RelationshipStore remains the agent-destruction owner. Its deletion and absence
operations include the new namespace, verify the bounded authoritative inventory
before filtering agents, and compare-delete only exact verified Records. They
fail closed on malformed, unverifiable, ambiguous, or unavailable inventory;
they cannot claim absence while private relationship snapshots remain.
