# Arbor Signals

An independent OTP library for bounded signal history, pub/sub delivery,
restricted topics, secure channels and payload-bound provenance. Its source
lives in this monorepo package; Arbor consumes the same implementation.

```elixir
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

Taint and durable-envelope contracts have package-owned defaults. A host can
inject `:taint_module` and `:taint_envelope_module` to retain its exact
process-local structs and legacy Erlang-term hashes. Canonical durable maps,
wire keys, identifiers and telemetry names are preserved. The package does not
coerce arbitrary foreign structs into its own contracts.

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
