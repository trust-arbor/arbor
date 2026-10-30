# Capabilities Signals adapters

This passive package supplies `Arbor.Capabilities.Signals` for the three
Signals authorization, crypto and identity-key ports. The historical
`Arbor.Security.Adapters.SignalsTransport` implements Capabilities' explicit
security synchronization transport through the public Signals facade in the
actual security-store caller process. It starts no authority tree or Signals
supervisor. Hosts select both adapters explicitly; nil transport remains local-only.

## Local development

The public dependency defaults remain versioned Capabilities Core and Signals,
plus the build-only Boundary tool. Local source builds use `ARBOR_CAPABILITIES_PATH`
and `ARBOR_SIGNALS_PATH`, with Core's `ARBOR_KERNEL_PATH`, `ARBOR_CUSTODY_PATH`,
`ARBOR_SUPPORT_PATH`, `ARBOR_OAUTH_PATH` and optional `ARBOR_CAPABILITIES_OIDC_PATH`.
When `ARBOR_KERNEL_PATH` is present, this project's build adds the same explicit
versioned Kernel path override with `runtime: false`. This resolves the shared
Core/Signals dependency to one local source without adding a Kernel dependency
to the published defaults or starting any runtime provider.
