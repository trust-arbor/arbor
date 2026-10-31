# Arbor Historian

The canonical `:arbor_historian` application owns the historical `Arbor.Historian`
facade and complete query, stream, delivery and retirement mechanisms. Version
0.1.0 and all module, supervisor, child, stream, wire and durable identities are
preserved. Source is adopted from Main fafa2689158f29f6aa20ccc03ad8b41052a900b6;
`ADOPTION_SOURCE_MAP.json` and `TEST_DISPOSITIONS.json` account for the exact inputs.

```elixir
{:arbor_historian, "~> 0.1.0"}
```

This independent package depends only on Kernel contracts, Support and Persistence
plus its declared public third-party dependencies. Build-only `ARBOR_KERNEL_PATH`,
`ARBOR_SUPPORT_PATH` and `ARBOR_PERSISTENCE_PATH` overrides select local source
checkouts; absent overrides use versioned dependencies. There is no parent config,
lock, build helper, KernelRuntime, product Repo, Capabilities or Signals dependency.
The Hex payload is restricted to lib, mix.exs, README and LICENSE.

## Trusted composition

Set `:arbor_historian, :authorizer` to an implementation of
`Arbor.Historian.Contracts.Authorizer`: authorize/4 and authorize_self_scoped/6.
Missing, unavailable or malformed providers deny agent-facing queries. Trusted
host query APIs remain intentionally ungated and must not be exposed to agents.
Set `:authority_source` to `Contracts.AuthoritySource`, whose reconcile, batch and
acknowledgement callbacks run synchronously in the actual puller's PID. A proxy
process, Task or remote caller cannot replace that provenance. `:event_provider`
is optional diagnostics (`Contracts.Observation.emit/3`); its failure never
acknowledges durable state or authorizes a read.

Configure `:durable_event_log_target` explicitly as `%{name: atom, backend: module,
opts: keyword}`. Static options retain the existing closed admission and deadline
restrictions. Missing storage returns the existing bounded unavailable errors;
there is no SQL/Repo default. The default hot target is the disposable
`Arbor.Historian.EventLog.ETS` projection. No durable events or identities replay
at startup. A node-restart durable target and exact immutable content readback
are required before the authority source can be acknowledged. Lost append ACKs,
outages and conflicts retain the original operation identity and pending state.
Memory-only tests do not qualify audit retirement.

The actual OTP callback still supervises the projection, StreamRegistry and
AuthorityAuditPuller directly under `Arbor.Historian.Supervisor`. The historical
public `start_link/1` two-child path remains distinct. `:start_children` retains
its existing suppression behavior. No product host owns a second authority tree.

## Owning and product tests

Owning tests remain under test with their original assertions and tags. Product
SQL, Capabilities and Signals integration tests live in the passive
`apps/arbor_historian_host` project and are inventoried rather than dropped or
retagged. Their actual production actor/SQL/whole-BEAM proofs remain required.
Use `mix test` in this package for owning tests. Root composition selects explicit
Host.Authorizer, Host.AuthoritySource, Host.Observation and the Host durable-sink
adapter; the historical SecurityEventLog adapter also belongs to that host.
No runtime qualification is claimed by the source disposition records.
