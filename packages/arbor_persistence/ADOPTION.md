# Persistence adoption into the monorepo

This family adopts current Arbor Main at
`64d3adf1cf7094b8bdcf620f3b3e1a2e2b326cf4` into three packages. Main supplies
behavior; the frozen `arbor_persistence` sibling at
`945442620bf25aa994af27d1c8e35b619bf203fc` supplies a boundary and move list only.
No sibling runtime source, old qualification archive or dependency override is
used as the implementation.

The approved local roadmap is
`.arbor/roadmap/2-planned/monorepo-packages-source-of-truth-and-rl6-adoption.md`,
with the 2026-10-19 decision that Main's `packages/` directory is authoritative.
It requires atomic adoption per family, independent cold consumers and rollback
rehearsal. The ignored planning record is not newly tracked by this change;
its content hash is recorded in the provenance manifest. Publication remains a
separate decision.

## Source ownership

| Owner | Responsibility |
| --- | --- |
| `packages/arbor_persistence` / `:arbor_persistence` | Generic Store/QueryableStore, BufferedStore, EventLog, projection, checkpoint and passive contracts; public generic facade `Arbor.Persistence.Core` |
| `packages/arbor_persistence_sql` / `:arbor_persistence_sql` | Generic PostgreSQL/SQLite backends, schemas, protocol repair and busy-timeout helper; independent optional `Arbor.Persistence.SQL.Repo` |
| `packages/arbor_persistence_eventstore` / `:arbor_persistence_eventstore` | EventStore adapter, keeping its public `Arbor.Persistence.Ecto.*` module names |
| `apps/arbor_persistence_host` / `:arbor_persistence_host` | Product facade, Repo, native/vector integration, sessions, channels, conversations, notices, telemetry, evaluations, backup and full historical migrations |

[`adoption-source-map.json`](adoption-source-map.json) accounts for all 239
pre-adoption files in the two original applications, including tests and
configuration. It records immutable Main blobs and destination hashes, ten
passive-contract/test copies from Kernel, eight new boundary helpers and all
49 package production source files. Package-specific manifests link back to
this family inventory. The original embedded owners are removed in the same
change; copied passive contracts, Repo and SQL migration modules receive
separate namespaces. Keeping embedded runtime definitions alongside the
packages would create competing module owners.

The unpublished frozen boundary used a generic `Arbor.Persistence` facade.
Adoption deliberately names it `Arbor.Persistence.Core`, allowing the host to
retain its existing broader `Arbor.Persistence` facade and behavior contract.
The host forwards 91 generic clauses across 76 functions, including current
Main's authority, CAS, canonical event matching, projection and bounded event
APIs. Product bodies stay in the host. The recorded source comparison preserves
the host's complete public export/default-arity set; final runtime checks are
reported separately in qualification metadata.

The original public `Arbor.Persistence.Record` and `Arbor.Persistence.Filter`
modules also remain available. Core owns these selected-provider forwarders,
including every original public function and default arity. The required Host
contract map yields the exact original Kernel Record/Filter implementations;
record transforms preserve logical ID, generation/revision, insertion time and
unchanged data as specified. A focused Host regression covers the complete
legacy exports and constructor/update/filter behavior. Standalone composition
uses the distinct package-owned contract identities. No duplicate Host
forwarder definition is introduced.

## Application and repository composition

Core is an ordinary library application with Logger, Crypto and Telemetry,
without an application callback or implicit supervisor/stores. Its direct
third-party dependencies are Jason, TypedStruct and Telemetry. SQL depends on
Core and public Ecto/database libraries and also starts no Repo or migrations.
EventStore depends on Core and public EventStore/database libraries; its
application callback starts only its existing empty supervisor. Both adapters
use normal runtime dependencies on Core, preserving ordinary release closure.
Neither adapter requires the other, Kernel, Security, Signals or the host.

The host callback is `Arbor.Persistence.Host.Application`. It keeps the
registered `Arbor.Persistence.Supervisor` and original child order: checkpoint,
default stores, optional Repo, backup scheduler, snapshotter. Host startup
configuration moves to `:arbor_persistence_host`; it has no legacy-owner fallback.
Core's contracts and ports remain under `:arbor_persistence`. SQL Repo selection
belongs to `:arbor_persistence_sql`; EventStore configuration belongs to
`:arbor_persistence_eventstore`.

`Arbor.Persistence.Repo` remains the host Repo. Its `otp_app`, adapter selection,
Repo configuration and `ecto_repos` ownership move together to the host app so
Ecto resolves the complete original migration history. Native/vector schemas
and `Arbor.Persistence.DatabaseCase` remain host-owned. SQL's convenience Repo
is a distinct `Arbor.Persistence.SQL.Repo`; it does not replace or alias the
host Repo. The SQLite busy handler retains its exact original module identity
and current Main implementation.

## Contract and security compatibility

The host must explicitly configure the single atomic `:contract_modules` map
with its original four modules:

```elixir
%{
  record: Arbor.Contracts.Persistence.Record,
  revision: Arbor.Contracts.Persistence.Revision,
  filter: Arbor.Contracts.Persistence.Filter,
  append_operation: Arbor.Contracts.Persistence.AppendOperation
}
```

Before building children or causing storage effects, the host startup gate
requires this exact map and validates the required callbacks/struct shapes.
Missing, partial, malformed or standalone-default bindings refuse host startup.
There is no Kernel dependency back into Core. Standalone consumers use the
separately named `Arbor.Persistence.Contracts.*` defaults.

Storage owners pin their trusted contracts before allocation. Client helpers
select that owner's PID and actual owned ETS table; nested operations retain
the same owner even if its registered name is rebound. SQL captures one exact
binding per operation and inherits an enclosing owner scope. The selected
Record/Revision pair therefore retains logical ID, timestamps, key binding,
generation/revision CAS and delete/reinsert fencing. Facade query admission for
Core-owned backends occurs inside their owner-bound Filter validation. These
rules do not broadly convert foreign structs or maps into trusted Records or
AppendOperations. EventLog operation validation recognizes and reconstructs
through one provider snapshot. This is not a general contract hot-swap or
stored-data conversion facility.

The optional `:authorization_provider` implements `authorize/4`; missing,
malformed, raising, throwing and exiting providers fail closed, and pending
approval performs no storage effect. Arbor supplies its Security module at
composition. The optional `:event_bus` implements `emit/4` and `subscribe/2`;
Arbor supplies Signals for best-effort observability/invalidation. Host
credentials, authorization contexts and taint-bearing product data remain
host-owned. The dependency switch does not rename those identities or the
existing `Arbor.Persistence.Event` wire struct.

## Durable state and migrations

All **32** original host migration filenames, versions, module names and bodies
remain byte-identical in `apps/arbor_persistence_host/priv/repo/migrations`.
They are neither replaced by delegates nor reduced to the generic subset.
The SQL package has **11** independently named generic migrations under
`Arbor.Persistence.SQL.Repo.Migrations`; only those module namespaces differ
from Main's corresponding bodies. The three EventStore protocol SQL files are
also moved unchanged into the EventStore package. The manifest lists and
hashes each history explicitly.

Dependency adoption starts no migration, schema repair or data/wire rewrite.
Consumers explicitly provision their own database and apply the appropriate
history. Host adoption keeps its existing history and Repo. Current Main's
writer/schema epoch fences, committed-event fingerprints, serializer behavior,
privacy/cleanup changes and native SQLite busy handling are retained. Successful
fresh-database or restart checks do not certify power-loss durability,
distributed failover, or arbitrary downgrade compatibility.

## Qualification status

[`qualification.json`](qualification.json) is the machine-readable family
record. Its source and final-commit binding fields must be checked before
calling adoption qualified. At this documentation snapshot:

- Core strict compilation, all **589** portable tests and package formatting
  pass. Deterministic regressions fail before the provider/owner fixes and pass
  afterward, including name rebinding and facade Filter admission.
- Adapter checks report SQL's default **67** tests, explicit SQLite **161**
  tests, explicit PostgreSQL **175** tests, EventStore's default **8** tests and
  explicit PostgreSQL **42** tests, all with zero failures. Default database
  exclusions are recorded rather than treated as database qualification.
- Four independent cold-consumer lanes passed: Core, SQL/SQLite, SQL/PostgreSQL
  and EventStore/PostgreSQL. They cover locked dependency resolution, strict
  consumer compilation, explicit initialization, fresh-process readback and
  production release evaluation without Mix. All four lanes were rerun after
  the final owner-binding repair: **34 stages passed**, with copied sources,
  current snapshots and exact compiled/loaded/started Arbor closures verified.

Root host checks passed: 270 default tests, 377 explicitly selected ordinary
database tests, and 45 tests across six exclusive database fixture invocations.
The exclusive invocations include the four new host/SQL adoption regressions.
Production host startup passed its isolated check. A fresh host release was
assembled and evaluated without Mix through the public cleanup API; all 32
packaged host migration hashes matched Main, and its private database records
the exact 32 original migration versions. This scoped release evaluation
kept the host supervisor absent and does not claim a whole-product node boot.
Seven security-authority files passed 50 tests, and the Agent profile SQLite
consumer passed three. Strict umbrella and production host compilation passed.
After lint cleanup, Core again passed 589, composed Host 380, isolated Host SQL
four, and database lanes 161/175/42; all 34 cold stages were repeated. A fresh
production host release again passed public cleanup without Mix with all 32
migration hashes exact. Security 50, Memory 102 and Agent SQL three also passed
against the final source.

Memory consumer selections passed 102 tests; Historian selections passed four
(with five excluded). The release ExUnit fixture passed its corrected rerun.
Three additional Host regressions preserve the complete legacy Record/Filter
forwarder exports and exact original Kernel struct identities. No production
change was needed for those compatibility checks.

Final ownership checks passed: Kernel 49 tests, Trust 34, the AppEnv regression
one, and the ownership/symbolic-map regressions eight. Construction checks pass
for all 31 Core, 11 SQL and seven EventStore production files. Exact Mix
formatting passed for 104 owned paths; the final 21 touched files were also
formatted after cleanup. A second independent read-only review
found no remaining defects in the corrected Core, CI lanes and scanner.

The pre-cleanup umbrella fast attempt stopped at 900 seconds after Memory: it is
incomplete. Host passed 250 fast tests, Kernel Runtime 1,795, Security 1,917 and
Memory 1,663. Kernel's two hierarchy failures from an earlier test-parser
snapshot were repaired and the final 49-test guard group passes. Shell reported
15 failures and AI two. Parent controls reproduce both Shell failure classes
and the Grok repository-root refusal; the isolated parent shell-lock test
passes, so that aggregate failure remains unresolved.

`quality` remains red: unchanged Dashboard formatting, 24 unused lock records,
xref 104 against cap 88, source-coupling baseline comparisons, unreviewed
Platform classifications and an unqualified recovery artifact. The committed
input artifact probe and exact final commit/revert binding are retained in the
local final task ledger. Undeclared coupling falls from 5,183 to 4,759, with
upward edges unchanged at 60; no reviewed baseline was refreshed. The final
exact baseline guard reports 162 differences: 141 removed, 18 new, and three
count/metadata changes. All 30 introduced lint findings were fixed. Final scoped Credo reports 371
inherited/equivalent findings across 300 candidate files against 380 in 275
mapped parent files, with zero candidate-only or new security findings. Nine
parent occurrences belong to the other split owner and are not debt removals. Platform v2 reports
11 owners and 460 files, with 214 unreviewed and 417 comparison failures. AppEnv
passes. Recovery profile/closure evidence checks pass while architecture stays
blocked. These results leave the broad adoption gates open.

An early database command accidentally admitted exclusive fixtures through
ExUnit tag precedence; the explicit file selections above corrected the
invocation. An initial release ExUnit attempt encountered a shared test-build
consolidation race; the direct release evaluation passed. These failed
attempts, negative controls and corrected reruns remain in private evidence.
Tracked summaries include no database credentials, runtime directories or raw
command arguments.

The independent package release checks do not implement or qualify the
roadmap's proposed M2 per-product-profile release gate. Likewise, simulated
invalidation tests do not establish cross-node coherence. Broad umbrella or
quality debt is not silently converted into a passing gate or hidden by a
baseline refresh.

## Rollback

Rollback is a revert of the complete atomic family adoption, followed by a
fresh build and the original host persistence/security canaries. The local
rehearsal used immutable snapshot
`ce80d27df8a63c8e1a8e6392e02d2a766332c6e2`, tree
`741dd53a3317348b82738c69cf7f467c7fbad757`, with the recorded Main base as its
parent. Snapshot creation used an alternate index and left the candidate index
unchanged. In a separate detached checkout, `git revert --no-commit` restored
exact base tree `6a8f8d7dcd77abafcadb5cd504e0820fd5f560da`. All **5,352**
tracked files matched base bytes and modes before and after verification.

Only 120 third-party build-cache directories were seeded; all first-party
artifacts were freshly compiled in that checkout's standard build layout.
Strict compilation passed, followed by the original **797** Persistence tests,
**seven** EventStore tests and **50** Security authority tests, all with zero
failures. The 462-file shared-dependency audit reported no changes. An initial
preparation guard stopped before any Mix build because a historical audit had
one preexisting generated Telemetry cache difference; the failed attempt and
fresh before/after audit are retained rather than resetting shared files.

A separate transcript-recovery parent control failed all four tests with the
same unresolved-adapter-destination sensitivity block observed on the
candidate, before its fake provider was reached. This reproduces the existing
fixture/guard failure; it does not qualify that broader integration gate.

The adoption performs no schema migration, so rollback does not mean
downgrading an installed protocol epoch or undoing application-owned database
changes. The final task ledger records the committed adoption and its exact
reversion against this rehearsal. The later Commands dependency-ownership census
parser repair has its own red/green proof; it does not change the tested
Persistence-family runtime or build composition. The detached checkout and raw evidence are
retained privately. Reintroducing only some embedded definitions while retaining
path dependencies is not supported.

The final runtime validation snapshot is `828fcd9334d40d2a6a6381b8b89d7336babb256b`, tree
`8b54fd3d1a55b5e02cd197342b31d81df912cb40`. All runtime/build/configuration/CI and
test sources match the final adoption; only adoption/provenance records are
completed afterward. The final commit ledger records a separate actual revert
of the committed adoption to the exact freshly tested parent tree.
