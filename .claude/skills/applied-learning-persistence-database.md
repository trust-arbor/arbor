# Applied Learning: Persistence and Database

Read this when changing durable stores, checkpoints, journals, migrations, recovery, CAS, retention, or database adapter behavior.

## Retained Applied Learning

<!-- applied-learning: trust-the-store-s-advertised-durability-class-not-its-configured-backend -->
<a id="applied-learning-trust-the-store-s-advertised-durability-class-not-its-configured-backend"></a>
**Trust the store's advertised durability class, not its configured backend.**
`Arbor.Persistence.BufferedStore` reports `:process_lifetime` even when it fronts
a database, because its cache-first writes deliberately absorb backend failures
and cannot guarantee that every acknowledged value survives restart. Do not call
such data durable merely because `backend: Postgres` is configured; use
`Arbor.Persistence.durability_class/3` through the facade and select a store whose
contract matches the recovery claim (found 2026-07-20 while designing terminal
coding-task artifact retention).

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

<!-- applied-learning: phoenix-tracker-is-a-distributed-projection-not-a-first-writer-cas -->
<a id="applied-learning-phoenix-tracker-is-a-distributed-projection-not-a-first-writer-cas"></a>
**Phoenix.Tracker is a distributed projection, not a first-writer CAS.** Concurrent node owners can publish conflicting metadata, tracking failure may be ignored, and lookup order is not a conflict-resolution protocol. Security-relevant answer/idempotence state needs an atomic shared durable backend; use Tracker/PubSub only after the source-of-truth commit and fail closed when that backend is unavailable (found 2026-07-11 reviewing cluster approval answers).

<!-- applied-learning: a-persisted-fingerprint-marker-is-not-proof-of-persisted-content -->
<a id="applied-learning-a-persisted-fingerprint-marker-is-not-proof-of-persisted-content"></a>
**A persisted fingerprint marker is not proof of persisted content.** A competing or legacy writer can copy an operation ID and claimed digest into metadata while storing different type/data/actor fields. Reconciliation must reconstruct the actual durable row and recompute its fingerprint over every bound field; reserved metadata may locate an operation but must never authenticate it, and all fingerprinted fields must round-trip through every backend (found 2026-07-11 reviewing EventStore append reconciliation).

<!-- applied-learning: injected-storage-identity-must-thread-through-every-operation-not-only-capability-probes -->
<a id="applied-learning-injected-storage-identity-must-thread-through-every-operation-not-only-capability-probes"></a>
**Injected storage identity must thread through every operation, not only capability probes.** Accepting `server:` or backend options for a durability check while later discovery, claim, settlement, or recovery calls silently use the global default creates a split-brain workflow. Carry one normalized store target through every read and mutation, and regress with a non-default store whose global peer contains conflicting data (found 2026-07-13 reviewing RunJournal recovery wiring).

<!-- applied-learning: a-worktree-changes-relative-durable-store-identity -->
<a id="applied-learning-a-worktree-changes-relative-durable-store-identity"></a>
**A worktree changes relative durable-store identity.** Arbor Security's JSONFile backend resolves `.arbor/security` from the server process CWD, so a server launched from a disposable worktree sees a new empty identity/capability/signing-key universe even when it uses the normal master key. For an intentional recovery runtime, explicitly bind the canonical project security store before startup; do not weaken signed-request auth or recreate agent authority piecemeal (found 2026-07-13 recovering the Phase 6 delegator runtime).

<!-- applied-learning: a-single-genserver-is-not-a-cross-beam-durable-store-lock -->
<a id="applied-learning-a-single-genserver-is-not-a-cross-beam-durable-store-lock"></a>
**A single GenServer is not a cross-BEAM durable-store lock.** Two OS processes can load the same snapshot generation and each atomically rename a different successor; the last rename silently drops the other process's intent. Before a durable journal gates an external side effect, enforce one live OS owner per configured path (or use a real compare-and-swap store), and regress a second live process being denied. In-process registration alone proves only one owner inside one BEAM (found 2026-07-14 reviewing the Apple unit-intent journal).

<!-- applied-learning: quarantine-recovery-must-preserve-identity-and-parent-child-convergence -->
<a id="applied-learning-quarantine-recovery-must-preserve-identity-and-parent-child-convergence"></a>
**Quarantine recovery must preserve identity and parent-child convergence.** Reactivating an identity-uncertain workspace may restore exact task+principal access, but removal authority requires a stable filesystem/registration identity pinned at reactivation and re-proven at release; capturing whatever occupies the path only at delete time authorizes replacements. When owner-death cleanup has child resources, every successful child-cleanup path (explicit release, retry, or child `DOWN`) must resume the dormant parent policy. Bound retry activity without dropping the quarantine, and make timer tests actually wait according to that test module's helper contract (hardened 2026-07-15).

<!-- applied-learning: a-node-keyed-checkpoint-entry-is-not-proof-of-one-execution-visit -->
<a id="applied-learning-a-node-keyed-checkpoint-entry-is-not-proof-of-one-execution-visit"></a>
**A node-keyed checkpoint entry is not proof of one execution visit.** DOT nodes can repeat, so a later visit can overwrite the same outcome/digest key and accidentally make an older pending intent look applied. Bind recovery evidence to the exact owner-issued `execution_id` plus `input_hash`, outcome status, timestamp, and result digest; compare the visit identity before using node progress or settling an effect (found 2026-07-15 implementing Engine lifecycle L3C).

<!-- applied-learning: a-public-resume-must-claim-and-mutate-the-same-canonical-journal-target -->
<a id="applied-learning-a-public-resume-must-claim-and-mutate-the-same-canonical-journal-target"></a>
**A public resume must claim and mutate the same canonical journal target.** Sanitizing alternate-journal lookup is insufficient if caller-provided `journal_opts` or `server` values still reach Engine after the default record is claimed. Remove internal journal-target selectors at the public boundary and regress that an alternate target remains untouched (found 2026-07-15 reviewing Engine lifecycle L3C public settlement).

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
**Preserve missing-checkpoint ordering without accepting an unverified checkpoint.** On an established public resume surface that already reports `:checkpoint_not_found` before the Engine identity gate, deriving credentials before checking durable presence changes the API contract and can break compatibility tests. In the no-secret branch only, perform the exact Config-owned fetch without HMAC solely to distinguish genuine absence; if a payload exists, discard it and return `:identity_required_for_resume` before claim. Authenticated callers still perform one HMAC-verified fetch, and no unverified payload may reach execution (found 2026-07-15 reviewing L4 public durable resume).

<!-- applied-learning: a-distributed-test-must-restore-the-controller-s-original-distribution-state -->
<a id="applied-learning-a-distributed-test-must-restore-the-controller-s-original-distribution-state"></a>
**A distributed test must restore the controller's original distribution state.** `LocalCluster.start/0` can turn the test runner into a named distributed node; leaving that state behind changes `node()` and makes later local-only claim tests fail as cross-node operations. Record whether the suite started distribution, stop every member, and stop LocalCluster/net_kernel only when the suite owns that transition (found 2026-07-15 composing the L4 proof with the fenced-claim suite).

<!-- applied-learning: boot-lifecycle-normalization-must-publish-durable-authority-before-hot-state -->
<a id="applied-learning-boot-lifecycle-normalization-must-publish-durable-authority-before-hot-state"></a>
**Boot lifecycle normalization must publish durable authority before hot state.** Rehydrating a local `:running` row as hot-only `:interrupted` looks correct until runtime refresh imports the still-durable `:running` row and makes public resume fail with `{:invalid_status, :running}`. Persist the correction first, use structured CAS when available, leave remote ownership untouched, and publish to hot state only after durable success (found 2026-07-15 strengthening the real application-restart proof).

<!-- applied-learning: disable-production-durable-stores-before-the-test-application-starts-do-not-tear-them-down-in-test-helper-exs -->
<a id="applied-learning-disable-production-durable-stores-before-the-test-application-starts-do-not-tear-them-down-in-test-helper-exs"></a>
**Disable production durable stores before the test application starts; do not tear them down in `test_helper.exs`.** A test-helper teardown runs only after the application-owned child may already have opened and hydrated real operator state, and deleting the child can make an incorrect test configuration appear isolated. Set the test-environment child config to disabled, inject temporary roots into focused tests, and assert the production child was never started (found 2026-07-16 reviewing retained-workspace restart persistence).

<!-- applied-learning: durable-evidence-limits-must-be-symmetric-on-write-and-reload-and-a-cache-must-detect-backing-store-drift -->
<a id="applied-learning-durable-evidence-limits-must-be-symmetric-on-write-and-reload-and-a-cache-must-detect-backing-store-drift"></a>
**Durable evidence limits must be symmetric on write and reload, and a cache must detect backing-store drift.** A journal that enforces aggregate bytes or exact inventory only at startup can accept writes that poison its next restart; a cache-only `list` can also hide added, deleted, or corrupted evidence from a fail-closed allocation probe. Bind a bounded on-disk snapshot (exact names, raw sizes/digests, root identity), revalidate it before security decisions and mutations, and apply the same capacity math to replacement writes and hydration (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: durable-creation-intent-must-precede-the-create-side-effect-durable-ownership-must-precede-acquisition-success -->
<a id="applied-learning-durable-creation-intent-must-precede-the-create-side-effect-durable-ownership-must-precede-acquisition-success"></a>
**Durable creation intent must precede the create side effect; durable ownership must precede acquisition success.** If a newly created workspace exists only in a GenServer map, a registry/BEAM crash erases its task/principal binding and a later acquisition can treat the surviving path as reusable work, reset it, and destroy dirty evidence. Reserve a bounded non-authoritative `creating` marker before Git may create, then replace it with an identity-bearing `active` marker before replying success. An unresolved intent blocks adoption but grants no deletion authority; settle it only after both path and Git registration are proven absent (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: a-durable-writer-and-restart-reader-must-enforce-the-same-closed-schema -->
<a id="applied-learning-a-durable-writer-and-restart-reader-must-enforce-the-same-closed-schema"></a>
**A durable writer and restart reader must enforce the same closed schema.** Accepting task and principal as independently optional on write while requiring them as a pair on restore lets the system write a marker that poisons its own next boot. Validate paired fields and all structural limits on both encode and decode paths, preferably before the side effect that would require the record (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: identifiers-used-as-durable-filenames-need-one-canonical-case-stable-grammar -->
<a id="applied-learning-identifiers-used-as-durable-filenames-need-one-canonical-case-stable-grammar"></a>
**Identifiers used as durable filenames need one canonical, case-stable grammar.** Distinct logical IDs such as `ws_A` and `ws_a` can alias on the default case-insensitive macOS filesystem even when they are separate map keys. Validate filename-backed IDs to one case before any path construction, and reject non-canonical forms rather than normalizing an authority-bearing identifier after the fact (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: a-retention-ttl-starts-when-ownership-becomes-retainable-not-when-the-active-lease-was-acquired -->
<a id="applied-learning-a-retention-ttl-starts-when-ownership-becomes-retainable-not-when-the-active-lease-was-acquired"></a>
**A retention TTL starts when ownership becomes retainable, not when the active lease was acquired.** An active marker may legitimately outlive the eventual retention window; when a prior-runtime active marker is first converted to retained evidence, give it exactly one fresh bounded TTL and persist that conversion. Later restarts consume the persisted remaining lifetime instead of refreshing it again (found 2026-07-16 reviewing retained-workspace restart durability).

<!-- applied-learning: a-durable-store-and-its-json-mirror-can-preserve-different-scalar-representations -->
<a id="applied-learning-a-durable-store-and-its-json-mirror-can-preserve-different-scalar-representations"></a>
**A durable store and its JSON mirror can preserve different scalar representations.** Arbor's checkpoint store keeps known outcome-status atoms while `checkpoint.json` encodes them as strings; recursively normalizing map keys does not normalize scalar values. Decode closed enums from both trusted atom and JSON string forms, fail closed on unknown values, and regress both store-backed resume and file round-trips so one path cannot silently turn `:fail` into `:success` (found 2026-07-16 exposing validation failures after terminal recovery).

<!-- applied-learning: a-checkpoint-receipt-digest-must-cover-a-losslessly-rehydratable-outcome -->
<a id="applied-learning-a-checkpoint-receipt-digest-must-cover-a-losslessly-rehydratable-outcome"></a>
**A checkpoint receipt digest must cover a losslessly rehydratable Outcome.** `EffectOwner` hashes the complete `%Outcome{}`, so `Checkpoint.deserialize/1` must restore every non-transient hashed field in its original closed type. Dropping `output_taint` changed a valid settled receipt after JSON reload and made same-run recovery fail with `:result_digest_mismatch`; never hide that defect by clearing `current_effect` or resetting its generation in a test fixture. Regress atom and full-struct taint through both file and configured-store loading whenever the persisted Outcome shape changes (found 2026-07-16 repairing stale checkpoint-resume tests).

<!-- applied-learning: no-start-checkpoint-diagnostics-must-select-file-only-persistence-explicitly -->
<a id="applied-learning-no-start-checkpoint-diagnostics-must-select-file-only-persistence-explicitly"></a>
**No-start checkpoint diagnostics must select file-only persistence explicitly.** `Checkpoint.write/3` still resolves its configured store when the application is not started, so a local `mix run --no-start` probe can fail with `{:store_put_failed, :store_unavailable}` before writing its JSON mirror. Pass `store: nil` when the diagnostic intentionally tests only the file boundary; leave the default intact when testing production store behavior (found 2026-07-16 probing Outcome digest round-trips).

<!-- applied-learning: generated-durable-identifiers-need-one-shared-contract-from-creation-through-recovery -->
<a id="applied-learning-generated-durable-identifiers-need-one-shared-contract-from-creation-through-recovery"></a>
**Generated durable identifiers need one shared contract from creation through recovery.** The Apple Container executor generated DNS-safe `a<hex>` names while the journal and recovery cores admitted only `arbor-v1-<32 lowercase hex>`, so every live workload failed at journal reservation with `:invalid_unit_name` despite passing executor preflight. Put versioned identifier construction and validation in one pure module, exercise the generated value through the downstream durable cores, and use the same validator in leaked-resource inventories so a stale test regex cannot hide cleanup failures (found 2026-07-16 during the Slice 2D live matrix).

<!-- applied-learning: test-vms-must-not-inherit-durable-operator-runtime-configuration -->
<a id="applied-learning-test-vms-must-not-inherit-durable-operator-runtime-configuration"></a>
**Test VMs must not inherit durable operator runtime configuration.** A spawned `MIX_ENV=test` process inherited the live server's `ARBOR_APPLE_CONTAINER_CONFIG_PATH`, started the production unit journal, and failed on the live journal lock before tests ran. Runtime loaders for operator-owned durable state must be explicitly disabled under `config_env() == :test`; test fixtures should opt into isolated configuration themselves (found 2026-07-17 during contained cross-app validation).

<!-- applied-learning: a-failed-durable-transition-must-preserve-truthful-residue-even-without-a-prior-hot-record -->
<a id="applied-learning-a-failed-durable-transition-must-preserve-truthful-residue-even-without-a-prior-hot-record"></a>
**A failed durable transition must preserve truthful residue even without a prior hot record.** Refusing to install an uncommitted retained or dormant state is correct when authoritative hot evidence already exists, but applying that rule after an active remove has deleted the path and dropped the lease can erase all in-memory evidence while the durable active marker survives. Represent the last committed lifecycle plus observed side effects explicitly, poison admission, arm no authority-bearing retry until its reservation persists, and regress both same-BEAM and restart views (found 2026-07-21 integrating managed-branch settlement with retained-workspace cleanup).

<!-- applied-learning: idempotent-side-effects-must-reconstruct-their-full-durable-receipt -->
<a id="applied-learning-idempotent-side-effects-must-reconstruct-their-full-durable-receipt"></a>
**Idempotent side effects must reconstruct their full durable receipt.** An Engine retry can occur after an action's external side effects succeed but before its result is checkpointed. Returning a generic `already_released` response is not enough when downstream logic needs immutable evidence from the original response. Reconstruct the receipt only from durable state and reverify it before reporting success; for workspace publication, the retry carries the repo root and succeeds only when the deterministic task/workspace hidden ref still points to the exact candidate OID. Normalize failed replay proofs so the recovery path does not become a repository-state oracle (found 2026-07-21 while reviewing candidate publication crash replay).
