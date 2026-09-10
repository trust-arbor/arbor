# Pipeline durability deployment defaults

Production selects the existing Repo-backed Store for Memory's durable owner,
the current-run journal, and Engine checkpoints. Despite its historical name,
`Arbor.Persistence.QueryableStore.Postgres` supports the configured Ecto adapter:
SQLite by default, PostgreSQL only when the build and runtime select
`ARBOR_DB=postgres`. Database credentials and paths remain in `runtime.exs`.
This change introduces no new store, table, migration, warning, or deployment
target.

Development already selects these SQL owners. Without an explicit journal
backend, RunJournal reports `:volatile`; the default Engine BufferedStore
checkpoint reports `:process_lifetime`. Neither class enables automatic crash
recovery. The older roadmap wording describing both as process-lifetime and
claiming no warning is stale: RecoveryCoordinator already warns when automatic
recovery is disabled and rechecks eligibility on later discovery ticks.

Durability configuration is a ceiling, not evidence of a successful write.
RunJournal and Engine checkpoint status consult the selected backend and report
errors honestly. Memory's ordinary async/cache write policy is unchanged; its
critical acknowledged CAS and authoritative-read APIs use the actual SQL owner.
Configuring that backend does not make ordinary cache acknowledgements durable.

Crash-durable storage enables recovery eligibility, not arbitrary execution
authority. The production `CodingRunRecovery.resolve_coordinator_options/1`
leaves TaskStore-owned runs to their owner and refuses other runs without an
authorized recovery route. Public resume still needs current authority and
authenticated checkpoint material. This packet does not mint production grants
or install a permissive resume resolver.

## Isolated whole-BEAM proof

`engine_sqlite_whole_beam_recovery_test.exs` starts workload VMs through owned
Ports. It does not start distribution or keep a surviving controller store.
Each VM owns its own Repo, Security, journal, checkpoint consumers, and Engine.
Only a private SQLite database/WAL, source DOT, fixture identity, and fsynced
effect counter survive between workload VMs.

The first VM runs the public authenticated `run_file_as` boundary. Its canonical
`write target="file"` node uses the existing bound `FileWriteHandler` to append
the JSON-clean witness to `effects.log` within the private workdir. The fixture
grants its identity root/typed-node execution and the normalized concrete file
write resource; it adds no custom opcode or authorization bypass. A test-only
Store decorator delegates every operation and durability report to the real SQL
Store, then verifies and fsyncs the already-written witness before holding the
first completed-effect progress acknowledgement after SQL commits it. This sync
belongs to the crash fixture, not the production file handler. The controller
confirms the workload's reported BEAM PID equals its
Port's OS PID and kills that exact process. The checkpoint compatibility file is
removed only after exit, forcing subsequent recovery to obtain its checkpoint
from SQL.

A fresh VM reconstructs the interrupted run, stops its Repo, and proves public
resume refuses the outage without replay or file fallback. Another fresh VM
opens a new fixture-owned SigningAuthority, discovers the run through
`list_resumable`, resumes it, and verifies a successful terminal journal with
one effect invocation. Resume explicitly retains `authorization: true` and the
original private workdir alongside the fresh signing handle, so the immutable
run binding must match the authenticated checkpoint. A final cold VM verifies
the completed state is no longer
resumable. The controller holds no authority or persistence data. Port closure
delivers EOF to a workload watcher; fixture cleanup waits for the captured child
PIDs to disappear and preserves the directory if shutdown remains unobserved.

The probe imports only the selected production owner settings into an otherwise
isolated test boot. It requires a clean checkout without `.env`, compiled SQLite
support, and private absolute fixture paths. It does not evaluate production
runtime paths or contact providers. This is a SQL reconstruction and public
resume qualification, not a complete production-release boot or live deployment
claim. It does not prove physical-host/power loss, storage-device durability,
network partitions, remote outstanding effects, or universal automatic recovery.

The selected deployment target remains a separate operator decision. No live
configuration, runtime, deployment, database, or journal is changed by this
source packet. Its tests must be run in the isolated qualification environment
before reporting the proof as passed.
