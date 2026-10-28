# Vector Store V1 Cutover

The C3G1A migration is additive. It does not make legacy memory rows part of
the vector-store protocol and does not remove or reinterpret the existing
`content`, `content_hash`, `embedding`, or `(agent_id, content_hash)` unique
index.

New vector-store writes populate the nullable V1 columns and dual-write the
legacy non-null columns. The backend-owned `vector_protocol` value
`arbor_vector_store_v1` marks a V1-managed row; legacy operations additionally
require a null `source_namespace`. The legacy `content_hash` mirror is
identity-scoped so equal canonical payloads can exist under distinct logical
identities; `payload_digest` remains the exact canonical payload digest.

The preparation and protocol-isolation migrations are intentionally
irreversible. Their `down/0` callbacks refuse to drop authority columns,
protocol markers, or immutable receipts. Reversal requires a separately
approved migration that drains writers, exports and verifies V1 state, and
defines how every receipt remains reconcilable.

A later operator-approved maintenance window must:

1. stop or drain legacy writers;
2. classify and backfill legacy rows with explicit logical identities;
3. verify every backfilled row through `VectorRecord` and verify receipt-ledger
   coverage for every operation committed through the V1 protocol;
4. switch readers only after reconciliation and tenant-isolation checks pass;
5. separately approve any removal or replacement of legacy columns/indexes.

No destructive step is authorized by the C3G1A migration.
