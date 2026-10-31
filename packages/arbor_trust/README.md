# Arbor Trust

The active `:arbor_trust` OTP application owns the historical `Arbor.Trust.*`
public API and authority processes. Version 0.1.0 preserves the actual Main
policy, URI, profile encoding, grant-owner custody and supervision identities.
The product integration is the separate passive `arbor_trust_host` application.
No frozen sibling implementation or contract/helper copies are used.

## Explicit composition

The package depends on public Kernel, Capabilities, Support and Persistence
packages. It contains no KernelRuntime, concrete Signals, SQL host or product
PubSub provider. `ARBOR_KERNEL_PATH`, `ARBOR_CAPABILITIES_PATH`,
`ARBOR_SUPPORT_PATH` and `ARBOR_PERSISTENCE_PATH` select source checkouts only
while building; normal dependency metadata uses public version requirements.

`runtime_host: nil` selects the closed package-owned
`runtime: [start_profile: :full | :activation_only]`. Both profiles retain the
real canonical PolicyHost. Activation omits consumers. A configured RuntimeHost
is authoritative: an unavailable, crashed or malformed provider denies startup
before PolicyHost claims. Product RuntimeHost binds KernelRuntime first and
composes the existing provider gate; it never owns a second Trust tree.

Full enabled startup requires explicit `profile_store`. Missing configuration
fails rather than selecting a product SQL backend. The durable shape is:

```elixir
config :arbor_trust,
  profile_store: [
    mode: :durable,
    backend: MyApp.ProfileStore,
    backend_opts: [repo: MyApp.Repo],
    collection: "trust_profiles",
    buffered_name: :arbor_trust_profiles
  ]
```

The backend implements the existing Persistence Store `get/2`, `put/3`,
`delete/2`, `list/1` callbacks. BufferedStore retains its historical name and
collection. Trust.Store still writes directly to the backend and updates its
cache only after acknowledgement; failed-delete tombstones and serialized
profiles are unchanged. `[mode: :memory]` is an explicit local/test choice and
makes no durable restart claim.

`profile_sync_transport: nil` explicitly selects single-node cache ownership.
Configured ProfileSync subscription failure refuses Store startup. Broadcasts
retain the original event types, origin-node data and product `trust:events`
stream. A post-commit broadcast failure is logged and emits
`[:arbor, :trust, :profile_sync, :failed]`; it does not undo or misreport an
acknowledged local write. Product Signals subscriptions belong to the calling
Store PID and are removed by Signals when that owner dies.

`pubsub: nil` omits product PubSub integration and EventHandler ingestion;
CapabilitySync retains its unavailable-subscription state and retry behavior.
A complete consumer supplies its own explicit Phoenix.PubSub name. The product
retains `Arbor.Core.PubSub`. PubSub and ProfileSync serve different purposes.

CapabilitySync observes profile-created, freeze and unfreeze events without
granting or revoking capabilities. Freezing stores the existing frozen state;
it does not itself change a URI's effective policy mode. Capability changes use
explicit caller-owned policy synchronization with actual actor authority.
These are the preserved Main semantics, not an automatic revocation claim.

`observation: nil` omits optional diagnostics. Configured observations cannot
change authority decisions or persistence acknowledgement. Policy-enforcer and
approval-guard flags are owned solely by `:arbor_trust`, with their previous
true defaults; product configuration carries its existing explicit values.

## Owning and integration tests

Owning tests use private test authority state, an explicit memory profile store
and the real public Capabilities test bootstrap. They do not load product
configuration or import another package's test sources. Product boot/gate,
repo-source audit and OIDC-backed approval integration assertions are retained
under `apps/arbor_trust_host/test`. `ADOPTION_SOURCE_MAP.json` and
`TEST_DISPOSITIONS.json` bind original files, labels, assertions and destinations.
The two operator Mix tasks retain their names under Commands.

This source adoption does not claim runtime qualification, cold durable SQL,
rollback, Grok review or product M2 release completion. Those gates belong to
independent verification of the complete paired Trust/Historian composition.
