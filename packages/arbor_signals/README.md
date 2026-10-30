# Arbor Signals

An independent OTP library for bounded signal history, pub/sub delivery,
restricted topics, secure channels and payload-bound provenance. Its source
lives in this monorepo package; Arbor consumes the same implementation.

```elixir
{:arbor_kernel, "~> 2.0.0-dev", path: "path/to/arbor/packages/arbor_kernel", override: true},
{:arbor_signals, path: "path/to/arbor/packages/arbor_signals"}
```

```elixir
subscriber = self()
{:ok, handle} = Arbor.Signals.subscribe("activity.*", fn signal ->
  send(subscriber, {:observed, signal})
  :ok
end)

:ok = Arbor.Signals.emit(:activity, :started, %{job_id: "job_1"})
{:ok, signals} = Arbor.Signals.recent(limit: 10)
:ok = Arbor.Signals.unsubscribe(handle)
```

All settings belong to the flat `:arbor_signals` application environment. The
former `:arbor_kernel, signals:` configuration is not read. Restricted topics
default to the capability authorizer; missing authorization, cryptography or
identity providers deny the corresponding operations.

Hosts configure the existing `:security_module`, `:crypto_module`,
`:identity_registry_module`, checkpoint and durable sink ports. Opaque channel
credentials pass through `:auth_context_module`, implementing
`Arbor.Signals.Contracts.AuthorizationContext`. An adapter must recognize its
exact context type; ordinary principal maps are not credentials. The default
adapter accepts only `Arbor.Signals.Contracts.AuthContext`.

Signals requires the passive `arbor_kernel` package for the canonical
`Arbor.Contracts.Security.Taint` and `TaintEnvelope` contracts. It does not
depend on Kernel Runtime or other active Arbor libraries. The default
constructors, lattice joins and durable codecs use those Kernel types.
Trusted hosts may still inject `:taint_module` and `:taint_envelope_module`.

Version `0.2.0-dev` changes the source API: replace old
`%Arbor.Signals.Contracts.Taint{}` and `TaintEnvelope` struct literals, patterns
and dynamic struct construction with the corresponding Kernel types. Prefer
their `new` constructors. The old Signals module names remain function-only
delegates that return canonical Kernel values; configuring those exact old
builtin provider names also selects the Kernel types. They no longer define
structs or separate codecs.

Durable version-1 maps, canonical JSON payload bytes and payload SHA-256 values
are unchanged. Legacy string-keyed taint labels remain readable. Arbitrary
foreign or old struct-tagged maps are rejected rather than silently converted.
Persisted Erlang-term structs need an explicit source migration before use.
`Arbor.Signals.Taint.data_hash/1` still hashes the caller's exact Erlang term;
replacing an old struct with a different Kernel struct changes that input and
therefore its hash. Legacy label decoding neither verifies nor rewrites the
optional `taint_data_hash`; use the separate hash verification API or the
payload-bound durable envelope as appropriate.

By default the OTP application owns `Arbor.Signals.Supervisor` directly.
Hosts that deliberately supervise Signals inside a gated application use a
code-only dependency and configure the exact trusted `:supervision_root` and
`:supervision_path`. Arbor retains its boot-admitted Kernel Runtime ownership;
merely occupying a registered process name does not satisfy those checks.

Test fixtures are compiled only when `:arbor_signals, :expose_test_fixtures`
is explicitly enabled. Production defaults expose no fixture bypasses. The
standalone consumer under `examples/standalone` exercises a non-Arbor build and
release. Publication remains a separate decision.

This adoption moves the implementation from Arbor Main `27c4eea80`
(`apps/arbor_kernel_runtime/lib/arbor/signals.ex` and `signals/`). The frozen
sibling extraction supplied boundary guidance; its older implementation and
qualification archives are not copied into this package.
