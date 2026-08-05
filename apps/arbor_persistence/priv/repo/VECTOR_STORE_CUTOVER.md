# Vector Store V1 Cutover

The C3G1A migration is additive. It does not make legacy memory rows part of
the vector-store protocol and does not remove or reinterpret the existing
`content`, `content_hash`, `embedding`, or `(agent_id, content_hash)` unique
index.

New vector-store writes populate the nullable V1 columns and dual-write the
legacy non-null columns. `source_namespace IS NOT NULL` marks a V1-managed row.
The legacy `content_hash` mirror is identity-scoped so equal canonical payloads
can exist under distinct logical identities; `payload_digest` remains the exact
canonical payload digest.

A later operator-approved maintenance window must:

1. stop or drain legacy writers;
2. classify and backfill legacy rows with explicit logical identities;
3. verify every backfilled row through `VectorRecord` and verify receipt-ledger
   coverage for every operation committed through the V1 protocol;
4. switch readers only after reconciliation and tenant-isolation checks pass;
5. separately approve any removal or replacement of legacy columns/indexes.

No destructive step is authorized by the C3G1A migration.
