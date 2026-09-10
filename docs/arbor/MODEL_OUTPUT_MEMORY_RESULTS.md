# Model-authored memory results

Decision recorded on 2026-09-09 for SU-3/M4b.

Ordinary Session turns return plain chat text and tool results. They do not
promise heartbeat JSON and do not produce `session.turn_data`. The production
turn graph therefore ends after response formatting; its former `update_memory`
node had no producer. Session remains the owner of transcript and scoped
conversation commits. Private-turn memory write restrictions remain in force.

Heartbeat retains its explicit JSON cognitive-output contract and production
parser. `memory_notes` become working-memory thoughts; `concerns` and `curiosity`
enter their respective working-memory collections. These are agent-global
working-memory updates, not semantic conversation records or evidence of human
ownership. `identity_insights` accepts nonempty content, a numeric confidence in
`[0, 1]`, and category `capability`, `skill`, `personality`, `trait`, `value`, or
`preference`. Invalid items are skipped individually so a malformed first item
does not discard valid later insights. A missing confidence defaults to `0.5`.

`Arbor.Memory.index_memory_notes/2` remains the note-only compatibility entry
point. `Arbor.Memory.apply_working_memory_updates/2` applies all three working
collections in one authoritative read/save. Both return `{:ok, report}` or
`{:error, report}` with `updated`, `applied_count`, `skipped_count`, `error_count`
and bounded error descriptions. Empty or wholly invalid inputs perform no
read/save. A failed authoritative read does not construct a replacement value,
and a failed save cannot report applied notes. Counts describe input
transformations; existing retention and duplicate handling still apply.

The corresponding Actions return `memory_updated` plus `memory_notes_result`, or
`wm_updated` plus `working_memory_result`. Failure returns an error to the Engine.
The private compatibility no-op for `SessionMemory.Update` still returns
`memory_updated: false` without calling Memory.

`SessionGoals.StoreIdentity` reports `identity_admitted_count`,
`identity_skipped_count`, `identity_error_count` and per-item errors. It processes
the remaining items after a write failure, then returns failure for the batch.
Successful self-knowledge writes acknowledge local mutation and ownership of
asynchronous persistence. `identity_persistence: "unconfirmed"` makes that limit
explicit; an empty batch reports `"not_requested"`. These counts never claim
confirmed backend completion. The existing `Memory.add_insight/4` facade now
propagates the saver’s refusal instead of returning a successful updated struct.
A later asynchronous backend failure remains outside the synchronous admission
result. This packet does not introduce a strict synchronous identity writer.

Suggestion review retains one proposal queue. Public tool discovery/name
resolution leads to `ReviewSuggestions`, whose actual pending IDs can be passed
to the existing accept/reject tools or `ReviewQueue`. Acceptance changes the
knowledge graph; rejection does not add knowledge. Missing/foreign IDs and denied
write authority cannot mutate either graph. A memory decision does not grant
broader tool authority.

The standalone `self_knowledge_chain_test.exs` executes two production heartbeat
graphs through the real Actions executor and a deterministic provider adapter,
observes the actual provider request, and separately reads SQLite records and
reopens the Repo/BufferedStore before the second request. Only test-agent
projections are evicted. It proves process/storage reload within one BEAM, not
whole-BEAM, node, or host restart. A held provider response permits exact-agent
mutation-admission failure injection. A separate proposal loop in that fixture
checks accepted knowledge after the same SQLite reopen.

Run that file alone with `ARBOR_TEST_MEMORY_AUTHORITY=external` and include
`isolated_repo`, `database`, `sqlite`, and `integration`. The Orchestrator test
helper rejects other marker values or combined file selectors; the normal
bootstrap is unchanged. The fixture creates and migrates a private SQLite
database and owns its authority from startup. All validation must use isolated
test homes/builds and data paths. Exact execution results and immutable revision
IDs belong in the execution ledger after qualification.

The heartbeat's `session.identity_insights` context key becomes the flat
`identity_insights` action parameter at ExecHandler. StoreIdentity accepts that
canonical schema key before the legacy `insights` alias; otherwise real graph
output is silently missed. Two production DOT executions, not direct action
calls alone, qualify this binding.

The following heartbeat also binds the flattened `self_knowledge` string into
BuildPrompt's declared schema. Supporting only the atom and old prefixed key
silently dropped the loaded summary after the graph boundary. The SQLite chain
checks the existing normalized capability name in the next provider request and
the full original wording in the durable evidence field.
