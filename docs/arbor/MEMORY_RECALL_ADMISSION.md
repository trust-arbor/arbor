# Semantic memory read admission

SU-3/M1a excludes recognized conversation records from interactive semantic
reads. It is a restrictive prerequisite to trusted conversation ownership, not
full human-owner isolation. Other memory types can still contain private data;
passing this exclusion policy does not establish that a record is safe to share.

## Recognized records

A record is excluded when either atom-keyed or string-keyed metadata `type`, or
its top-level `type` or `category`, equals the atom `:conversation` or the string
`"conversation"`. Restrictive evidence wins when representations conflict.
Strict vector views carry metadata inside `body`; the same rule applies there.
Recognition uses these exact markers, not content heuristics.

All recognized conversation records are treated as unowned for this purpose.
Claims such as `owner_id`, `engagement_id`, `visibility: public`, `trusted` or
`provenance_status: verified` do not create an exception. Existing embedding
provenance binds payload/vector/taint integrity; it does not establish a human's
ownership or permission to disclose the content.

## Affected reads and preservation

The shared pure `Arbor.Memory.RecallAdmissionCore` policy applies to:

- `Arbor.Memory.recall/3`, including the authorized facade wrapper, through
  Index's ETS, ANN and dual paths and its SQLite/unsupported-ANN fallback.
- `Arbor.Memory.search_embeddings/3`, which searches durable vectors directly.
- `Arbor.Memory.let_me_recall/3`, including `backend: :persistent`, whose
  Retrieval path otherwise bypasses the Index readers.
- `Arbor.Memory.Index.get/2`, which reports `{:error, :not_found}` for an
  excluded record and does not update its access count or access time.

List/search reads omit recognized conversations. Existing strict record
validation remains in force for every returned backend row, including an
excluded row and any malformed row later in the result set. A malformed
provenance, tenant, model, category or tombstone is not hidden as empty recall.

Exclusion does not delete records, rewrite metadata, migrate data or discard
records from caches during warm-up or restart. Warm/cold reconstruction retains
the durable category and a cache-local restrictive marker captured before
metadata key normalization. That marker is neither persisted nor an ownership
credential. Raw Persistence and Embedding owner I/O remains storage machinery;
this policy does not claim to isolate arbitrary code running inside the VM.

ETS applies exclusion before ranking and limiting. Durable ANN preserves its
existing query bounds, so excluding backend top-N results can return fewer than
N results even when other admissible records exist. M1a does not implement
owner-aware ANN completeness or an overfetch policy.

## Qualification and next work

The same-library public-reader regressions exercise deterministic embeddings,
strict envelope construction, non-conversation controls, forged metadata,
ANN/fallback, warm/cold reconstruction and stored-record preservation. They
test the production reader boundary rather than mocking the admission policy.
Separate AgentSeed characterization observes its actual DateTime metadata
rejection through `Memory.index`; absent recall is not evidence of that failure
once recognized conversations are deliberately withheld.

M1b must establish trusted source ownership and the policy for tool-derived
writes. The intended admission mechanism reuses source-owned exact ordinary
capabilities and an admitted durable owner stamp outside arbitrary metadata.
Private-turn writes must inherit that scope or remain unavailable; changing
`type` to `fact` must not become a declassification mechanism. Caller-provided
owner labels and taint digests alone are insufficient owner proof.

M2's automatic Session conversation indexing follows M1b. AgentSeed timestamp
normalization, restored host writes, new authority descriptors and expanded
prompt sections are not part of M1a.
