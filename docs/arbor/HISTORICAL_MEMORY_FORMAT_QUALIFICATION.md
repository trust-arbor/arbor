# SU-3/D historical accumulation diagnosis

Source audit: **2026-09-09**, base `02d318db1815d16e4535833a8c912ee05ca17afe`.
This packet adds representative fixtures and tests only. It changes no product
serializer, migration, authorization, producer, or persisted operator data.

## What the source establishes

The August report records aggregate counts and write windows, not individual
payloads or the deployed revision. Its proposed relationship between the format
transition and the August 2 cutoff remains unproven. No affected row export was
found among the task's preserved repository artifacts. Commit dates are not
deployment dates and cannot identify the cause of that production cutoff.

The stores have different contracts:

| Store | Historical/current behavior | Diagnosis |
| --- | --- | --- |
| Knowledge graph | Old `KnowledgeGraph.to_map/1` wrote a bare graph. Current `KnowledgeGraph.Codec.decode/4` recognizes it, validates it, and assigns conservative missing-provenance labels. `KnowledgeGraphStore.read_authority/2` commits conversion with compare-and-swap before returning it. | Legacy data is supported; an ordinary **read can write a format migration**. No live KG loader was called for this audit. Malformed or oversized records fail closed, so an actual affected payload is needed to distinguish rejected input from an inactive producer. |
| Goals | The old producer wrote one record per `<agent>:<goal>` and normalized its own timestamps. Current GoalStore reads namespaced and legacy bare keys, reconstructs dates, and conservatively labels unlabeled rows. Current writes use authoritative CAS. | The report's `<category>:<agent>` shorthand hides the per-goal key. AgentSeed's semantic-index metadata contract is not this serializer. |
| Intents | The old producer wrote an aggregate of intents, percepts, and lifecycle statuses with serialized timestamps. Current readers explicitly decode legacy aggregates and preserve statuses; current changes persist versioned provenance. | This is a separate aggregate and writer. The current legacy lifecycle regression already targets a real historical weakness: old startup trimming constructed only intents/percepts and dropped statuses. That does not establish why writes stopped in the reported deployment. |
| Old `chat_history` | Each appended message had its own physical key. Commit `145769a2e` moved writes to ChannelStore; `dbc9e8103` removed ChatHistory and consolidated current chat persistence on SessionStore. | Retirement is explicit. Zero updates is expected for append-only message records; it is not an accumulation failure by itself. Current Session transcript continuity is qualified by SU-3/R2, separately from those retained old rows. |
| Semantic conversation index | `AgentSeed.finalize_query` attempts Q/A indexing with rich `DateTime` metadata; strict semantic input rejects it. M1a contains its real producer characterization. | Confirmed distinct write defect. It cannot, by itself, explain KG, goal, or intent record write windows. The later M3a packet deliberately leaves automatic direct-host private writes unavailable and assigns that producer to authenticated Session turns; host-write normalization is not a pending requirement. |

One historical KG producer failure **is** source identified and repaired:
`5b7080b20` added `:agent_tool` to the closed metadata atom registry. Before that
change, `Memory.add_knowledge/2` with the exact Remember metadata source failed
with `:invalid_graph`. The existing regression retains both the accepted source
and rejection of unknown atoms. Its existence does not prove that it caused the
August report. The separately completed heartbeat investigation identified a
missing memory grant plus ignored graph failure; that evidence also must not be
expanded into a universal historical cause.

## Fixture-only dry-run disposition

The inventory below comes from the four explicitly synthetic fixture files.
It is not a production row count or an executed migration. Current-format rows
in the tests are produced by current writes after legacy reads; their restart
checks cannot accidentally use another current serializer as the old fixture.

| Input | Inventory | Proposed isolated disposition | Human ownership |
| --- | --- | --- | --- |
| Bare KG | 2 nodes, 1 edge, 1 pending learning | Validate, read through existing CAS conversion, append one fact, restart owners and compare exact exported state. Keep conservative labels. | Unproven; no private-conversation backfill. |
| Bare goal | 1 active goal, progress 0.25 | Read dates, change progress to 0.75, add a second goal, restart owners and retain both. Keep conservative labels. | Unproven; no private-conversation backfill. |
| Bare intent aggregate | 1 intent, 1 percept, 1 locked status with retry count 3 | Read linked data, complete original intent, add another, restart owners and preserve original completion/status/percept. Keep conservative labels. | Unproven; no private-conversation backfill. |
| Retired chat record | 1 user message | Preserve as historical data. Do not invent a Session, engagement, human, or private-index owner. | Unproven; no automatic import or backfill. |

This packet makes **no ownership upgrade**. Structural validity, agent ID,
timestamp, taint provenance, and possession of an old transcript are insufficient
to claim a trusted admitted human/agent pair. Unknown or malformed real rows must
remain preserved for diagnosis; no delete, blanket relabel, or destructive
migration is part of this plan.

## Isolated qualification

New test selector:

```text
apps/arbor_memory/test/arbor/memory/historical_accumulation_format_test.exs
```

The three tests install old raw records via the Persistence facade into the
test-owned `DurableGraphAuthority` fixture. Domain reads and writes use public
Memory operations; owning-store tainted reads check that labels are not upgraded.
They terminate/restart the domain owners, provenance owner, and BufferedStore;
the test-only ETS backing store stays alive. Secondary embedding work uses the
test configuration's deterministic hash provider and is settled before restart.
This proves **owner-process format continuity**, not database close/reopen,
whole-BEAM, node, or host durability, nor a production heartbeat producer.

Retained complementary selectors, to run in separate isolated app invocations:

```text
apps/arbor_memory/test/arbor/memory/knowledge_graph/metadata_atom_encoding_test.exs
apps/arbor_memory/test/arbor/memory/knowledge_graph_store_test.exs:269
apps/arbor_memory/test/arbor/memory/goal_store_provenance_test.exs:469
apps/arbor_memory/test/arbor/memory/intent_store_provenance_test.exs:773
apps/arbor_memory/test/arbor/memory/intent_store_provenance_test.exs:1177
apps/arbor_persistence/test/arbor/persistence/queryable_store/sqlite_json_regression_test.exs
```

The SQLite selector needs an isolated migrated SQLite Repo and its database tags;
it validates nested record serialization, not the full historical Memory
assembly. SU-3/R2's
`apps/arbor_orchestrator/test/arbor/orchestrator/session/transcript_recovery_test.exs`
provides the separate modern Session/SQLite close-reopen proof (standalone with
`--include isolated_repo --include database --include sqlite --include integration`).

Validation on 2026-09-09 passed against immutable test-only revision
`50331eb367f9472e2f4a340dcb81f84f91889245`: **3 new format tests, 7 selected
compatibility controls, and 1 separate SQLite record test**. Compilation with
warnings as errors and exact-file formatting passed; scoped strict Credo found
zero issues. The controls selected seven tests and excluded 106 other tests in
those files; they were not full-file qualification. The `:773` intent status
selector remains listed for additional targeted use but was not part of this run.

Checks used the pinned factory container with no network, read-only source, and
private home, dependencies, build, and SQLite paths. No local Mix or production
database operation was performed. These results qualify the representative
formats, not every historical record or the reported write cutoff. This packet
introduces no product security fix; the old `:agent_tool` regression retains its
original source/test history in `5b7080b20`.

## Input still needed for the actual August diagnosis

Provide a preserved affected database snapshot or a narrowly scoped export from
that snapshot, together with the deployed source revision/configuration identity.
For representative old populated and new empty KG rows, goal rows, and an intent
aggregate, retain the physical namespace/key, record ID, revision/generation,
timestamps, payload, and provenance metadata. Content may be deterministically
redacted while preserving structure, enum values, timestamp forms, and identity
relationships; integrity checks require either the original protected copy or
an explicit note that redaction invalidated its digest. Retain the corresponding
producer failure/outcome evidence if available. Do not reconstruct it from live
loaders that can CAS-migrate the rows being diagnosed.

Until that evidence exists, the August cause remains **pending input**, while
current format qualification and the rest of the unwired repair plan continue.
