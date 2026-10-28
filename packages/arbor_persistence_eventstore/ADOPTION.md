# EventStore adapter adoption

This package adopts the current EventStore application from Arbor Main
`64d3adf1cf7094b8bdcf620f3b3e1a2e2b326cf4`. No frozen sibling runtime source
or qualification archive is restored. See the
[family adoption decision](../arbor_persistence/ADOPTION.md),
[family provenance](../arbor_persistence/adoption-source-map.json) and the
[package inventory](adoption-source-map.json).

The OTP/configuration owner changes from `:arbor_persistence_ecto` to
`:arbor_persistence_eventstore`; public modules remain `Arbor.Persistence.Ecto.*`.
Core is its only Arbor dependency, through a normal runtime path dependency.
The SQL adapter, Kernel, Security, Signals and host are outside this closure.
The existing application callback starts only an empty supervisor. The consumer
explicitly provisions its database, initializes EventStore, applies protocol
migrations and supervises `Arbor.Persistence.Ecto.EventStore`.

The three protocol SQL files move unchanged. Starting the application or
appending an event never installs or repairs missing schema constraints. Current
Main's schema/function/trigger checks, database writer fence, operation markers
and bounded operation behavior are retained. The serializer remains
byte-identical to Main, ignores arbitrary type hints and does not construct
caller-selected structs. Event types remain strings. Trusted host
AppendOperations retain their exact original identity through the Core contract
provider boundary; standalone callers use Core's separately named default.

[Qualification metadata](qualification.json) records eight default tests
(34 excluded) and 42 explicit PostgreSQL tests with zero failures, strict
compilation and formatting. An initial source-guard omission was corrected by
allowing the adapter's own exact supervisor name, without changing its runtime
behavior. The final cold PostgreSQL consumer/release lane passed after the Core
owner fix, with all ten stages bound to current source and the exact
Core+EventStore closure. Dependency compilation reports two inherited EventStore
typing warnings; own strict compilation passes. The inherited Decimal lock advisory is recorded
without changing the lock as part of adoption.

Restart recovery does not add a `durability_class/1` callback: this adapter still
returns `{:error, :unsupported}` through the generic facade for that optional
capability. No power-loss, distributed-failover, downgrade or product M2 release
qualification is implied. Final broad fast-suite, quality/tooling and commit
status is owned by the family qualification record. The atomic family rollback
rehearsal passed its original Persistence/EventStore and Security canaries;
final committed-adoption binding remains pending.

The post-lint selected database suite and strict compile passed again, followed
by fresh source-bound cold consumer/release checks. The final family record
reports zero introduced scoped lint findings.
