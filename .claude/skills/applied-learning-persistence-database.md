# Applied Learning: Persistence and Database

Read this when changing durable stores, checkpoints, journals, migrations, recovery, CAS, retention, or database adapter behavior.

## Retained Applied Learning

<!-- applied-learning: trust-the-store-s-advertised-durability-class-not-its-configured-backend -->
<a id="applied-learning-trust-the-store-s-advertised-durability-class-not-its-configured-backend"></a>
**Trust the store's advertised durability class, not its configured backend.**
`Arbor.Persistence.BufferedStore` reports `:process_lifetime` even when it fronts
a database, because its default `ack_mode: :cache` writes deliberately absorb
backend failures and cannot guarantee that every acknowledged value survives
restart. `write_mode: :sync` changes scheduling, not that acknowledgement
contract. Authority-critical single writes may opt into `ack_mode: :backend`,
which requires synchronous writes and mutates the cache only after backend
success, but the generic BufferedStore still advertises its conservative class.
Do not call data durable merely because `backend: Postgres` is configured; use
`Arbor.Persistence.durability_class/3` through the facade and select a store whose
contract matches the recovery claim (found 2026-07-20 while designing terminal
coding-task artifact retention; refined 2026-07-26 after agent creation reported
success for a failed profile write).

Probe the exact serving backend through its owning facade, not a status label
or a similarly named store: an audit sink configured with a volatile EventLog
must not advertise restart-durable evidence. Distinguish acknowledged readback,
owner-process reopen, and whole-BEAM loss. A controller-held store surviving a
worker restart proves the first boundaries only; node-loss proof needs a fresh
BEAM reading the same private physical database or journal after the original
BEAM is gone, with exact record and pending-outcome comparisons (reconfirmed
2026-09-24 during audit acceptance).

<!-- applied-learning: persistence-record-logical-ids-are-global-across-the-shared-records-table -->
<a id="applied-learning-persistence-record-logical-ids-are-global-across-the-shared-records-table"></a>
**Persistence Record logical IDs are global across the shared `records` table.**
Postgres uses `(namespace, key)` as physical identity but retains `Record.id` as
the table primary key, so reusing an agent/principal key as the logical ID in
trust, profile, user-config, or memory namespaces causes cross-namespace
`records_pkey` failures. Give domain records stable domain-scoped logical IDs
(`trust_profile:<agent>`, `agent_profile:<agent>`, etc.) while keeping
`Record.key` equal to the physical store key. Never rewrite IDs inside the
backend: CAS and record-incarnation semantics require it to preserve the
caller's logical identity (found 2026-07-26 when a fresh coding agent survived
in trust state but its agent profile disappeared on restart).
For pre-write owner seals, do not guess backend incarnation fields: a CAS after
a tombstone may allocate its new generation only when the backend acknowledges.
Sign the exact domain identity/body and a logical revision, retain the observed
Record as the live CAS fence, and state that an authentic cold snapshot does not
prove freshness against offline rollback (private goals/relationships, 2026-09-09).

<!-- applied-learning: run-postgres-specific-tests-with-the-postgres-test-adapter -->
<a id="applied-learning-run-postgres-specific-tests-with-the-postgres-test-adapter"></a>
**Run Postgres-specific tests with the Postgres test adapter.** Arbor defaults
to SQLite in `config/test.exs`, even for files whose module name says
`Postgres`. Use `ARBOR_DB=postgres MIX_ENV=test`, migrate only the isolated test
database, and then run the `:database` file. Enabling the tag under SQLite
mostly proves dialect mismatch, not a Postgres regression (found 2026-07-13
verifying the persistence CAS foundation).

<!-- applied-learning: preflight-database-migrations-before-a-clean-server-restart-after-persistence-schema-changes -->
<a id="applied-learning-preflight-database-migrations-before-a-clean-server-restart-after-persistence-schema-changes"></a>
**Preflight database migrations before a clean server restart after persistence schema changes.** Historian rehydration reads the current EventLog schema during application startup, so restarting new code against an old database can take the entire Gateway/Dashboard down before an operator can use live RPC. Run `./bin/mix ecto.migrations -r Arbor.Persistence.Repo` first and audit any data-checking migration before applying it. For destructive or expensive repair rehearsal, boot against a disposable database selected with `ARBOR_DB_NAME` (PostgreSQL) or `ARBOR_SQLITE_PATH` (SQLite) rather than modifying the development database (found 2026-07-13 while validating EventLog protocol migrations).

<!-- applied-learning: dbconnection-timeout-does-not-bound-time-already-spent-in-the-pool-queue -->
<a id="applied-learning-dbconnection-timeout-does-not-bound-time-already-spent-in-the-pool-queue"></a>
**DBConnection `:timeout` does not bound time already spent in the pool queue.** The connection deadline timer starts when a queued checkout finally receives a connection, so a caller can wait through the pool's queue interval before the timeout is observed. For a hard caller-owned deadline, use `queue: false`, retry checkout in the caller with bounded backoff, and pass the same absolute `:deadline` to the transaction and every query (found 2026-07-11 while testing EventLog append deadlines with an exhausted one-connection PostgreSQL pool).

For SQLite lock warnings, identify the transaction phase and read back durable
outcomes before changing retries. `EventLog.Ecto` and `SessionStore` use
deadline-capped 5 ms lock waits; Exqlite disconnects on transaction-control SQL
errors, so a successful acquisition retry can still emit a connection error.
Measure contention before tuning the wait, retain no-late-commit regressions and
post-write uncertainty handling, and never suppress genuine database failures
(source-backed lesson from recurring warnings during completed cross-surface
turns, 2026-09-29).

Keep read-only observation out of SQLite writer transactions. Use one bounded
SELECT when it can return the rows and source head together, or an explicit
DEFERRED snapshot for a multi-query read. Verify the read on an independent WAL
connection while another connection holds the writer lock. An implicit
`BEGIN IMMEDIATE` for activity discovery needlessly blocks both reads and writes
(found 2026-10-03 while qualifying command discovery during real turn execution).

<!-- applied-learning: phoenix-tracker-is-a-distributed-projection-not-a-first-writer-cas -->
<a id="applied-learning-phoenix-tracker-is-a-distributed-projection-not-a-first-writer-cas"></a>
**Phoenix.Tracker is a distributed projection, not a first-writer CAS.** Concurrent node owners can publish conflicting metadata, tracking failure may be ignored, and lookup order is not a conflict-resolution protocol. Security-relevant answer/idempotence state needs an atomic shared durable backend; use Tracker/PubSub only after the source-of-truth commit and fail closed when that backend is unavailable (found 2026-07-11 reviewing cluster approval answers).

<!-- applied-learning: a-persisted-fingerprint-marker-is-not-proof-of-persisted-content -->
<a id="applied-learning-a-persisted-fingerprint-marker-is-not-proof-of-persisted-content"></a>
**A persisted fingerprint marker is not proof of persisted content.** A competing or legacy writer can copy an operation ID and claimed digest into metadata while storing different type/data/actor fields. Reconciliation must reconstruct the actual durable row and recompute its fingerprint over every bound field; reserved metadata may locate an operation but must never authenticate it, and all fingerprinted fields must round-trip through every backend (found 2026-07-11 reviewing EventStore append reconciliation).

<!-- applied-learning: injected-storage-identity-must-thread-through-every-operation-not-only-capability-probes -->
<a id="applied-learning-injected-storage-identity-must-thread-through-every-operation-not-only-capability-probes"></a>
**Thread injected storage identity through every operation, not only capability probes.** One normalized authorized store is the target of every internal read and mutation. Public resume drops caller-selected `:journal_opts`, `:server`, `:store`, `:store_name`, `:store_opts`, and `:checkpoint_store_opts` in `sanitize_public_resume_opts/1`. A caller-selected journal or store on the public resume API must not move claim or execution off the canonical target the probe used. A capability probe that succeeds against one store does not authorize a mutation against another. Lookup, claim, and mutation stay on that same authority. (Merged 2026-10-16 from 2 entries; first found 2026-07-13, last 2026-07-15.)

<!-- applied-learning: a-single-genserver-is-not-a-cross-beam-durable-store-lock -->
<a id="applied-learning-a-single-genserver-is-not-a-cross-beam-durable-store-lock"></a>
**A single GenServer is not a cross-BEAM durable-store lock.** Two OS processes can load the same snapshot generation and each atomically rename a different successor; the last rename silently drops the other process's intent. Before a durable journal gates an external side effect, enforce one live OS owner per configured path (or use a real compare-and-swap store), and regress a second live process being denied. In-process registration alone proves only one owner inside one BEAM (found 2026-07-14 reviewing the Apple unit-intent journal).

<!-- applied-learning: quarantine-recovery-must-preserve-identity-and-parent-child-convergence -->
<a id="applied-learning-quarantine-recovery-must-preserve-identity-and-parent-child-convergence"></a>
**Quarantine recovery must preserve identity and parent-child convergence.** Reactivating an identity-uncertain workspace may restore exact task+principal access, but removal authority requires a stable filesystem/registration identity pinned at reactivation and re-proven at release; capturing whatever occupies the path only at delete time authorizes replacements. When owner-death cleanup has child resources, every successful child-cleanup path (explicit release, retry, or child `DOWN`) must resume the dormant parent policy. Bound retry activity without dropping the quarantine, and make timer tests actually wait according to that test module's helper contract (hardened 2026-07-15).

<!-- applied-learning: a-node-keyed-checkpoint-entry-is-not-proof-of-one-execution-visit -->
<a id="applied-learning-a-node-keyed-checkpoint-entry-is-not-proof-of-one-execution-visit"></a>
**A node-keyed checkpoint entry is not proof of one execution visit.** DOT nodes can repeat, so a later visit can overwrite the same outcome/digest key and accidentally make an older pending intent look applied. Bind recovery evidence to the exact owner-issued `execution_id` plus `input_hash`, outcome status, timestamp, and result digest; compare the visit identity before using node progress or settling an effect (found 2026-07-15 implementing Engine lifecycle L3C).

<!-- applied-learning: terminal-checkpoint-fast-paths-must-pass-through-canonical-recovery -->
<a id="applied-learning-terminal-checkpoint-fast-paths-must-pass-through-canonical-recovery"></a>
**Terminal checkpoint fast paths must pass through canonical recovery.** `next_node_id: nil` means traversal is complete, not that pending/completed effect evidence is safe to ignore. Restore checkpoint tracking, reconcile the current effect, and only then finalize; also normalize checkpoint chronological `completed_nodes` into the Engine's newest-first internal stack exactly once (found 2026-07-15 closing the L3C terminal resume bypass and ordering bug).

<!-- applied-learning: a-durable-artifact-reader-must-reuse-the-writer-s-exact-key-and-envelope-contract -->
<a id="applied-learning-a-durable-artifact-reader-must-reuse-the-writer-s-exact-key-and-envelope-contract"></a>
**A durable artifact reader must reuse the writer's exact key and envelope contract.** Recovery code that guesses a raw run ID or directly calls one historical store can miss a checkpoint written under a prefixed key, accept a swapped `Persistence.Record`, or diverge from configured backend selection. Expose a bounded owner primitive that binds lookup key, envelope key, authenticated payload run ID, and the same Config-owned store resolver used by persist/load (found 2026-07-15 adding L4 checkpoint retrieval).

<!-- applied-learning: a-cas-takeover-claim-elects-a-survivor-it-does-not-fence-an-old-partitioned-owner -->
<a id="applied-learning-a-cas-takeover-claim-elects-a-survivor-it-does-not-fence-an-old-partitioned-owner"></a>
**A CAS takeover claim elects a survivor; it does not fence an old partitioned owner.** Generation/revision CAS prevents two recovery coordinators from both claiming the same durable row, but generic later lifecycle writes from the old owner are not automatically lease-fenced. Scope the current L4 proof to an owner BEAM that is actually terminated; do not claim partition or physical-host safety until every effect/write path carries and verifies a fencing epoch (found 2026-07-15 reviewing L4B fenced recovery).

<!-- applied-learning: keep-a-recovery-coordinator-s-first-tick-separate-from-its-steady-state-cadence -->
<a id="applied-learning-keep-a-recovery-coordinator-s-first-tick-separate-from-its-steady-state-cadence"></a>
**Keep a recovery coordinator's first tick separate from its steady-state cadence.** The configured startup delay controls how quickly boot recovery begins; replacing it with a conservative recurring interval can silently add tens of seconds to restart recovery. Schedule the first discovery with the startup delay, later ticks with the bounded recurring interval, and route synchronous and asynchronous failures through the same per-run bounded deduplication path so periodic discovery cannot grow history without bound (found 2026-07-15 reviewing L4 runtime durable refresh).

<!-- applied-learning: preserve-missing-checkpoint-ordering-without-accepting-an-unverified-checkpoint -->
<a id="applied-learning-preserve-missing-checkpoint-ordering-without-accepting-an-unverified-checkpoint"></a>
**Preserve missing-checkpoint ordering without accepting an unverified checkpoint.** Require identity before Engine resume. The public facade's only exception is a bounded presence probe: `Arbor.Orchestrator.Engine.Checkpoint.fetch_persisted/2` without an HMAC. If a payload exists, return `:identity_required_for_resume` and discard that payload before any claim or execution. If none exists, return `:checkpoint_not_found`. Do not turn the probe into a lifecycle lookup that reveals or applies unverified contents. A missing checkpoint and an unverified checkpoint are different answers; the probe must not collapse them. Authenticate before any other existence-bearing resume step. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-15.)

<!-- applied-learning: boot-lifecycle-normalization-must-publish-durable-authority-before-hot-state -->
<a id="applied-learning-boot-lifecycle-normalization-must-publish-durable-authority-before-hot-state"></a>
**Boot lifecycle normalization must publish durable authority before hot state.** Rehydrating a local `:running` row as hot-only `:interrupted` looks correct until runtime refresh imports the still-durable `:running` row and makes public resume fail with `{:invalid_status, :running}`. Persist the correction first, use structured CAS when available, leave remote ownership untouched, and publish to hot state only after durable success (found 2026-07-15 strengthening the real application-restart proof).

For same-node authority, serialize acknowledged writes and authoritative reads
through the same fixed owner. Retiring a lower broker generation does not fence
a caller continuation: after broker restart, a new reader can pin old SQL facts
before the held caller resumes its write. Execute closed mutations in the owner,
then queue authority acquisition behind them. Legacy migration must insert only
if the authoritative slot is absent, using backend CAS; a cache absence check
followed by unconditional put can overwrite a newer revocation. Regress the held
writer/restarted reader and lazy/bulk migration races against real storage
(2026-10-03 Profile notice authority review).

<!-- applied-learning: durable-creation-intent-must-precede-the-create-side-effect-durable-ownership-must-precede-acquisition-success -->
<a id="applied-learning-durable-creation-intent-must-precede-the-create-side-effect-durable-ownership-must-precede-acquisition-success"></a>
**Durable creation intent must precede the create side effect; durable ownership must precede acquisition success.** If a newly created workspace exists only in a GenServer map, a registry/BEAM crash erases its task/principal binding and a later acquisition can treat the surviving path as reusable work, reset it, and destroy dirty evidence. Reserve a bounded non-authoritative `creating` marker before Git may create, then replace it with an identity-bearing `active` marker before replying success. An unresolved intent blocks adoption but grants no deletion authority; settle it only after both path and Git registration are proven absent (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: a-durable-writer-and-restart-reader-must-enforce-the-same-closed-schema -->
<a id="applied-learning-a-durable-writer-and-restart-reader-must-enforce-the-same-closed-schema"></a>
**A durable writer and its restart reader must enforce the same closed schema.** Apply the same closed structural schema and the same aggregate capacity before a write and during hydration. A cache of that store revalidates the bounded backing inventory — names, sizes or digests, and root identity — before any security decision or mutation. Drift between the cache and the backing store fails closed. A limit that exists only on the write path, or only on reload, is not a limit. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-07-16.)

<!-- applied-learning: a-retention-ttl-starts-when-ownership-becomes-retainable-not-when-the-active-lease-was-acquired -->
<a id="applied-learning-a-retention-ttl-starts-when-ownership-becomes-retainable-not-when-the-active-lease-was-acquired"></a>
**A retention TTL starts when ownership becomes retainable, not when the active lease was acquired.** An active marker may legitimately outlive the eventual retention window; when a prior-runtime active marker is first converted to retained evidence, give it exactly one fresh bounded TTL and persist that conversion. Later restarts consume the persisted remaining lifetime instead of refreshing it again (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: a-checkpoint-receipt-digest-must-cover-a-losslessly-rehydratable-outcome -->
<a id="applied-learning-a-checkpoint-receipt-digest-must-cover-a-losslessly-rehydratable-outcome"></a>
**A checkpoint receipt digest must cover a losslessly rehydratable outcome.** `Arbor.Orchestrator.Engine.EffectOwner.outcome_result_digest/1` hashes the complete `%Outcome{}` with `:erlang.term_to_binary/2` and `[:deterministic]`, omitting only an empty legacy `input_taint`. Every other digest-bearing field, including defaults, is part of the schema: adding or dropping one changes the receipt. A durable store and a JSON mirror can preserve different scalar forms, so normalize only closed key and scalar representations and restore them losslessly. `Arbor.Orchestrator.Engine.Checkpoint` parses `output_taint` as both the closed atom and its string. Do not copy the empty-`input_taint` omission onto any other owner. Load persisted checkpoints with `Checkpoint.fetch_persisted/2`. (Merged 2026-10-16 from 3 entries; first found 2026-07-16, last 2026-10-06.)

<!-- applied-learning: no-start-checkpoint-diagnostics-must-select-file-only-persistence-explicitly -->
<a id="applied-learning-no-start-checkpoint-diagnostics-must-select-file-only-persistence-explicitly"></a>
**No-start checkpoint diagnostics must select file-only persistence explicitly.** `Checkpoint.write/3` still resolves its configured store when the application is not started, so a local `mix run --no-start` probe can fail with `{:store_put_failed, :store_unavailable}` before writing its JSON mirror. Pass `store: nil` when the diagnostic intentionally tests only the file boundary; leave the default intact when testing production store behavior (found 2026-07-16 probing Outcome digest round-trips).

<!-- applied-learning: generated-durable-identifiers-need-one-shared-contract-from-creation-through-recovery -->
<a id="applied-learning-generated-durable-identifiers-need-one-shared-contract-from-creation-through-recovery"></a>
**Generated durable identifiers need one shared contract from creation through recovery.** Use one versioned, case-stable constructor and validator for creation, filenames, journal codecs, recovery, and inventory. Reject a noncanonical authority-bearing form. Do not silently rename it: a case-insensitive filesystem treats the renamed spelling as the same file and hides a collision. Apply the same constructor at recovery that was used at creation, including when the identifier is also a filename. The grammar is part of the authority check, not a display preference. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-07-16.)

<!-- applied-learning: test-vms-must-not-inherit-durable-operator-runtime-configuration -->
<a id="applied-learning-test-vms-must-not-inherit-durable-operator-runtime-configuration"></a>
**Test VMs must not inherit durable operator runtime configuration.** Disable inherited operator loaders and production durable children before the test application starts. Do not tear those stores down from `test_helper.exs` after boot; that races a child that has already opened the operator root. Fixtures opt into private configured roots. A helper that stops or deletes a production store after the application has started can destroy operator data the test VM inherited. Assert that the real operator state was never opened. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-07-17.)

<!-- applied-learning: a-failed-durable-transition-must-preserve-truthful-residue-even-without-a-prior-hot-record -->
<a id="applied-learning-a-failed-durable-transition-must-preserve-truthful-residue-even-without-a-prior-hot-record"></a>
**A failed durable transition must preserve truthful residue even without a prior hot record.** Refusing to install an uncommitted retained or dormant state is correct when authoritative hot evidence already exists, but applying that rule after an active remove has deleted the path and dropped the lease can erase all in-memory evidence while the durable active marker survives. Represent the last committed lifecycle plus observed side effects explicitly, poison admission, arm no authority-bearing retry until its reservation persists, and regress both same-BEAM and restart views (found 2026-07-21 integrating managed-branch settlement with retained-workspace cleanup).

<!-- applied-learning: idempotent-side-effects-must-reconstruct-their-full-durable-receipt -->
<a id="applied-learning-idempotent-side-effects-must-reconstruct-their-full-durable-receipt"></a>
**Idempotent side effects must reconstruct their full durable receipt.** An Engine retry can occur after an action's external side effects succeed but before its result is checkpointed. Returning a generic `already_released` response is not enough when downstream logic needs immutable evidence from the original response. Reconstruct the receipt only from durable state and reverify it before reporting success; for workspace publication, the retry carries the repo root and succeeds only when the deterministic task/workspace hidden ref still points to the exact candidate OID. Normalize failed replay proofs so the recovery path does not become a repository-state oracle (found 2026-07-21 while reviewing candidate publication crash replay).

<!-- applied-learning: raw-sql-mutation-receipts-must-match-orm-record-contracts -->
<a id="applied-learning-raw-sql-mutation-receipts-must-match-orm-record-contracts"></a>
**Raw SQL mutation receipts must match ORM record contracts.** Postgrex `RETURNING`
rows can expose timestamp columns as `%NaiveDateTime{}` even when the Ecto schema
normalizes ordinary reads to UTC `%DateTime{}`. Normalize every raw mutation
acknowledgement at its adapter boundary and reject invalid timestamp types
explicitly. Regress exact equality between the insert/update receipt and an
immediate ORM reread; otherwise a committed CAS can be reported as malformed,
making first execution fail while idempotent replay succeeds (found 2026-07-26
when durable interaction hydration committed its claim but discarded the receipt).

<!-- applied-learning: process-local-monotonic-ids-cannot-name-durable-resources -->
<a id="applied-learning-process-local-monotonic-ids-cannot-name-durable-resources"></a>
**Process-local monotonic ids cannot name durable resources.** `System.unique_integer/1` is unique only inside one VM. Durable resource ids, and fixture names that can outlive that VM, use `Arbor.Identifiers.generate_id/1`, which draws `:crypto.strong_rand_bytes(16)`. Reject a duplicate ownership claim before replacing the existing record. An immutable store fails closed when the same name arrives with different content. Cleanup deletes only the exact owned fixture identity captured at creation, not a name regenerated after restart. (Merged 2026-10-16 from 2 entries; first found 2026-07-16, last 2026-07-28.)

<!-- applied-learning: negative-reconciliation-needs-complete-inventory-and-durable-terminal-evidence -->
<a id="applied-learning-negative-reconciliation-needs-complete-inventory-and-durable-terminal-evidence"></a>
**Negative reconciliation needs complete inventory and durable terminal
evidence.** A source owner may return `already_absent` only after complete
hydration proves the resource is absent; partial recovery must remain degraded
and fail closed. For an existing resource, persist the terminal cancellation or
abandonment event before changing hot state or publishing success, and regress
both restart replay and append failure so a transient reply cannot resurrect
the resource later (found 2026-07-28 while hardening exact pending-approval
settlement across Consensus and Comms).

<!-- applied-learning: collection-reducers-must-fail-on-malformed-members-not-return-the-accumulator -->
<a id="applied-learning-collection-reducers-must-fail-on-malformed-members-not-return-the-accumulator"></a>
**Collection reducers must fail on malformed members, not return the accumulated
prefix.** A catch-all reduction clause that halts with the current accumulator
can turn a bad later row into successful partial data. Halt with a typed error
for every invalid element, convert only the canonical success tuple to output,
and regress malformed first and later entries (found 2026-07-28 reviewing Apple
Container recovery reconstruction).

<!-- applied-learning: durable-identity-schema-upgrades-must-cross-every-lifecycle-adapter -->
<a id="applied-learning-durable-identity-schema-upgrades-must-cross-every-lifecycle-adapter"></a>
**Durable identity schema upgrades must cross every lifecycle adapter.** Adding
owner fields to the writer and loader is incomplete if a wire adapter, worker
state, pending or settled ledger, exact comparator, reconstruction snapshot, or
admission path drops them. Trace one record through reserve, worker start,
restart, reconciliation, and settlement; normal workers require known lineage,
while legacy unknown lineage is admitted only to cleanup recovery (found
2026-07-28 reviewing the Apple Container journal v2 migration).

<!-- applied-learning: shared-durable-storage-does-not-make-hot-projections-cluster-global -->
<a id="applied-learning-shared-durable-storage-does-not-make-hot-projections-cluster-global"></a>
**Shared durable storage does not make hot projections cluster-global.** Startup rehydration is not runtime discovery of a remote owner. Refresh remote durable changes with a bounded runtime reconciliation, and do not boot-normalize a live remote owner. Keep a local pid only while the durable ownership and status still match that pid. Do not delete on a missing hot projection. A shared database row is not a live process registration on every node. Signals are latency hints, not control-plane truth. (Merged 2026-10-16 from 2 entries; first found 2026-07-15, last 2026-07-31.)

<!-- applied-learning: bound-active-audit-work-separately-from-durable-history -->
<a id="applied-learning-bound-active-audit-work-separately-from-durable-history"></a>
**Bound active audit work separately from durable history.** A finite outbox or recovery working-set budget must not become a lifetime event quota when completed-operation fingerprints accumulate. Keep durable history and duplicate/conflict evidence in scalable storage, reclaim hot admission capacity only after verified durable transfer, and qualify sustained operation beyond the hot bound as well as outage/restart behavior. An empty pending queue does not prove sustainable admission. Do not declare rollout ready while terminal retirement remains deferred (user challenge and live security-journal exhaustion, 2026-09-27).

<!-- applied-learning: durable-security-fences-must-align-encoding-locking-and-bootstrap-with-declared-capacity -->
<a id="applied-learning-durable-security-fences-must-align-encoding-locking-and-bootstrap-with-declared-capacity"></a>
**Durable security fences must align encoding, locking, and bootstrap with declared capacity.** A 100,000-entry revocation ledger failed on entry 257 because its generic canonical encoder capped object keys; per-namespace locks also raced on one shared whole-map file, and lazy initialization treated a missing fence as pristine. Choose an encoding whose structural limits cover the persisted schema, lock by canonical backing-artifact identity across the full read/modify/publish transaction, and preserve independent initialization evidence so loss cannot silently reset history. Regress the real capacity boundary, concurrent writers, and loss plus restart (found 2026-10-07 while closing SSEC-010 rollback replay).
