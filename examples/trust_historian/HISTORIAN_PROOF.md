# Historian composed proof

Qualification status belongs to each attempt's reviewed source/build/runtime
receipts. The leaf and composed consumers make distinct claims: ETS is process-lifetime ordinary history; actual SQL is the
node-restart authority. No DiskLog/File backend or fake durability is introduced.

The module is `PairedStandaloneConsumer.HistorianProof`. It uses the historical
public `Arbor.Security` facade from `arbor_capabilities`, the public
`Arbor.Security.Contracts.AuditJournal.canonical_intent_bytes/1`, actual canonical
Historian application/Puller, public `Arbor.Persistence.Core`, and actual public
`Arbor.Persistence.EventLog.Ecto` with `Arbor.Persistence.SQL.Repo`. It uses no
Core test API, raw journal append, fixture mutation or ambient product facade.

The composed consumer owns its private host, Repo and provisioner; the external
runner owns archive and release construction. Expected
static target under `:paired_standalone_consumer, :historian_sql_target` is:

```elixir
%{name: :historian_durable_event_log,
  backend: Arbor.Persistence.EventLog.Ecto,
  opts: [repo: Arbor.Persistence.SQL.Repo]}
```

`PAIRED_STATE_ROOT` is an absolute private real directory. Public receipt defaults
to `historian-public-receipt.json` there; `PAIRED_HISTORIAN_STATE_PATH` can choose a
different direct child only. Auxiliary `.conflict` and `.namespace-seed` receipts
contain public IDs/digests/fingerprints/prepare timestamp, never signing material.
Every receipt is reread from actual SQL before reuse; a receipt is no authority.
Writes are bounded exclusive temporary files, mode0600, synced before rename.

The configured Core audit consumer remains exactly the real registered
`Arbor.Historian.AuthorityAuditPuller` owned directly by canonical
`:arbor_historian`. The fixture's AuthoritySource delegates three actual public
Security calls inline in that same PID. It neither proxies nor impersonates a
journal. Optional callback observations retain public operation metadata only.
A bounded native call trace on that exact private Puller observes public
Persistence durability/read/append/read followed by actual inline ACK. It refuses
an existing tracer or preexisting function trace pattern and cleans its own
trace/patterns in `after`; only action names/stream IDs leave the trace collector.

API and postconditions:

- `pause!/0 -> :ok`: trusted authority source becomes nil; a serialized real
  flush drains any prior pass. SQL invocation audit remains available.
- `write!/0 -> checks map`: capture actual stable pending operations while paused,
  deliver through actual SQL, verify exact intent digest/canonical event
  fingerprint/one-row position, merge prior receipts idempotently. The public
  ordinary SQL append/query/timeline record is also checked. Source ends paused.
- `recover!/0 -> checks map`: fresh-VM actual SQL readback of every retained public
  receipt plus complete ordinary SQL history; no new evidence is minted.
- `refused!/0 -> :ok`: requires real new pending mutations. Direct caller PID is
  rejected by all three public Core consumer gates. Actual caller-owned ETS is
  selected temporarily and cannot ACK/erase any pending operation or write a
  volatile audit row. Restores SQL and leaves pending untouched/source paused.
- `outage!/0 -> :ok`: with real pending effects, terminate only the actual private
  Repo direct child of `PairedStandaloneConsumer.Supervisor`. Real delivery cannot
  ACK while Repo is absent; restart that exact child, retain all pending effects,
  verify old SQL receipts. No outage backend or journal injection is used.
- `lost_ack!/0 -> :ok`: requires those same pending effects and empty new SQL
  streams. The only fault wrapper delegates real SQL durability/read/append and
  drops append ACK after a successful SQL commit. Exact readback/ACK succeeds,
  each stream has one row, public receipt merges, and normal SQL target/source
  paused are restored. A recorded actual successful append is mandatory.
- `retirement!/1 -> checks map`: arity1 callback does one actual public grant and
  revoke, returning `:ok`, inline in the composing consumer's admitted Provisioner. Run2300 pairs in
 32-pair batches. Observe exactly4600 new distinct journal operation IDs, real
  SQL rows/fingerprints, no degraded reductions, retained count<4096, actual
  retired count>=4096, >=8 bound ledger frames, floor3, open drained authority.
  Persist the measured workload receipt. No fixture signer or threshold change.
- `retirement!/0 -> checks map`: fresh-VM workload-receipt+real status/SQL gate;
  cannot credit a small workload based on an empty queue.
- `namespace_attack_seed!/1 -> checks map`: after runner snapshots pre-seed
  namespaces, zeroarg callback performs public `Security.acknowledged_grant/1`
  with deterministic capability_id, stable granted_at/principal/resource and
  actual operator authority, returning `{:ok,:applied,cap_id}`. Exactly one real
  mutation is delivered and its public seed receipt preserved. Run it BEFORE
  retirement; no authority keys or namespace files are copied by this module.
- `namespace_rollback_attack!/1 -> checks map`: after external owned
  capability-namespace-only restore, run the exact same public callback. It must
  reapply the same capID and same operationID with different intent digest and
  prepare second. Actual Puller repeatedly refuses old SQL content, preserves
  `effect_applied` and unchanged retired total/SQL fingerprint/old prepare time.
  Deliberately leaves one pending conflict. **Same-candidate attack proof only;
  it provides no predecessor version compatibility rollback credit.**
- `conflict!/0 -> checks map`: in a separate owned copy, exactly one new genuine
  pending mutation is required. Write deliberately wrong content to its actual
  SQL stream through public Persistence append. Real Puller refuses ACK and
  leaves that operation pending/unchanged. There is no repair/delete path.

The main sequence is install -> write -> recover (volatile/wrong-PID refusal,
actual Repo outage, lost ACK) -> namespace seed -> retirement -> refused ->
source-hidden ERTS refused. Each VM has a real private Repo and canonical roots;
all phase/callback budgets are3600s. The caller must reacquire real actor handles legitimately
if their public lifetime contract requires it; credentials never leave Provisioner. The artifact runner
supplies nine real freshly built/unpacked archives and exact closure/no-Mix gates.

Namespace-attack branch protocol mirrors actual current public owning regression:
snapshot `authority/ns_*` directories before seed; compare nonhidden direct
filenames after seed and require exactly ONE namespace gains exactly the new
record. After retirement/quiescence/full VM stop, copy the whole owned state to
an independent attack branch, rename its current selected namespace to a
preserved artifact, restore only the pre-seed copy of that namespace. Keep
current journal, independent revocation ledger, SQL and all other namespaces.
A fresh VM executes the same exact public seed callback and the attack gate.
This branch is deliberately non-quiescent. A different copied branch runs the
wrong-SQL conflict gate. Neither branch repairs or deletes conflicting evidence.

Mandatory predecessor compatibility rollback is SEPARATE: the runner requires an
external manifest and an actual fafa predecessor boot against compatible current
quiescent state, with current SQL/journal/ledger retained and source-version
provenance. The namespace attack result explicitly refuses that credit. No module
metadata or leaf result supplies that separate execution receipt.
