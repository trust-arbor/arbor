# Security synchronization transport

Arbor configures `:arbor_security, :signal_transport` as
`Arbor.Security.Adapters.SignalsTransport`. The adapter delegates to the public
Signals facade in the actual security-store process, preserving supervised-owner
checks, subscription provenance and publication admission.

An absent key or explicit `nil` is local-only. A configured provider must
implement `Arbor.Security.Contracts.SignalTransport` completely. Missing modules,
missing callbacks, exceptions and malformed results refuse subscription startup;
they do not fall back to ambient Signals or silently become local-only. With the
default adapter, an empty Signals subscriber map retains its existing local-only
behavior.

Each `SignalSync` captures its provider once. All subscriptions in that instance,
retries after a transport restart, partial cleanup, release, emission and remote
mutation admission use that same provider. Changing the configured provider affects
new instances; restart security-store owners to switch an existing instance.
The `:distributed_signals` flag can suppress publication without selecting a
different provider for an established owner.

A subscription returns `{:ok, id, local_pid, delivery_reference}`. Multiple events
must identify the same live transport process. Delivery references remain in the
security owner's private custody, and received messages retain the authenticated
`{:signal_received, reference, signal}` shape. Old references are invalidated on
transport death. Forged mailbox messages and undecryptable deliveries remain
rejected; the latter retain their existing warning and telemetry.

The default adapter preserves authority direction: remote revocations and
identity reductions apply, while remote grants, registrations and resumptions
remain denied without authenticated transport. Nonce delivery keeps its existing
authenticated-reference and exact-type checks. Signed-request replay admission
continues to refuse relevant connected peers independently of this transport.

Publication is best effort after local effects; its failure does not undo an
acknowledged local mutation. This interface does not implement authenticated
cross-node transport, atomic cross-node nonce ownership or cluster durability.
