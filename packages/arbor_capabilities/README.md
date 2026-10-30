# Arbor Capabilities

`arbor_capabilities` owns capability authorization, cryptographic identity,
revocation, signing and receipt authorities, durable authority stores, and the
complete authority supervision tree. Its canonical OTP application and
configuration namespace is `:arbor_capabilities`. Existing `Arbor.Security.*`
public module identities are preserved.

The package depends on the public Kernel contracts, Custody, Support and OAuth
libraries. It does not depend on KernelRuntime, Signals, Historian, Persistence,
Trust or another product host. OIDC protocols are an optional, caller-composed
`arbor_capabilities_oidc` provider. Configured OIDC policy remains authoritative
when that provider is absent or unavailable, so provider failure cannot enable
local-human admission.

## Ownership and configuration

The real OTP callback is `Arbor.Security.Application`. The historical
`Arbor.Security.Supervisor`, child IDs, ETS names, persistent-term identities,
signed domains and durable wire formats remain stable. A host must not start a
second copy of the authority tree.

Standalone consumers leave `:runtime_host` unset or set it to `nil`. The closed
local runtime configuration is `[start_profile: :full]` or
`[start_profile: :activation_only]`. A full standalone start omits the product's
HTTP provider gate and preserves the authority foundation, hydration, readiness,
downstream startup order and partial-start cleanup.

Configure an absolute `:authority_state_root` and an independent absolute
`:revocation_ledger_path` when using durable stores, a private `:master_key_path`,
and the required explicit `:signing_key_owner_roles`. The package supplies no
checkout-relative authority root or implicit product providers. Ephemeral test
consumers may explicitly select `storage_backend: nil`,
`audit_journal_mode: :ephemeral` and `system_authority_mode: :ephemeral`.
Configure the session-token secret using the existing
`Arbor.Security.SessionToken` contract before starting the application.

Full startup requires the internal `:system_authority`, `:signing_broker` and
`:channel_broker` roles plus the closed `:scheduler_owner`, `:trust_grant_owner`
and `:system_lifecycle_owner` descriptors. Each role specifies its application,
exact supervised path, registered name and purposes. Unused external roles may
name dormant owners; operations remain denied while those owners are absent.
The required `:approval_receipt_issuer_owner` descriptor similarly specifies
`:application`, `:path` and `:registered_name` for the exact supervised approval
issuer. A dormant descriptor permits broker startup without admitting an issuer;
it supplies no fallback authority.

Product integration selects one trusted static `:runtime_host` module implementing
`Arbor.Security.Contracts.RuntimeHost`. Its preparation runs before authority
claims or freezes. It supplies the bound boot profile and the existing provider
gate startup operations. Invalid, unavailable or crashing configured hosts fail
closed; they never select standalone fallback. Standalone boot-profile reads
return `{:error, :not_bound}`.

Optional audit, consensus, interaction routing, signal and other ports require
explicit trusted configuration. Their concrete adapters belong to the caller.
The public root has a strict independent Boundary and exports the historical
Security module surface to preserve compatibility.

## Development

Dependencies are versioned public packages. Local source overrides are explicit:
`ARBOR_KERNEL_PATH`, `ARBOR_CUSTODY_PATH`, `ARBOR_SUPPORT_PATH`,
`ARBOR_OAUTH_PATH` and `ARBOR_CAPABILITIES_OIDC_PATH`. No package file loads a
parent configuration, root lockfile or build helper.

The Hex archive contains only `lib`, `mix.exs`, this README and the license.
Tests, qualification fixtures and adoption evidence are repository tooling.
See `ADOPTION.md` and `ADOPTION_SOURCE_MAP.json` in the repository for the bounded
source relocation record.
