# Passive Kernel package adoption

The source moves from `apps/arbor_kernel` to `packages/arbor_kernel` as one
physical owner. The application remains `:arbor_kernel` at `2.0.0-dev`. Public
module names, struct fields, validation results, Inspect redaction, and encoding
behavior remain unchanged. The former umbrella source is removed in the same
adoption change.

## Shared authority contracts

SigningAuthority, SigningAuthorityBootstrap, and their shared Validator already
belong to the passive Kernel. Security, Engine, and other callers can consume
these types without starting the Security authority tree. A separate authority
contract package would add a dependency from Kernel to another first-party
application because SignedRequest, DeliveryReceipt, TurnAuthority,
ForgeProjection, and the Security facade behavior also use this Validator.
Keeping this existing ownership preserves the Kernel dependency direction and
avoids a second set of authority struct identities.

The frozen `arbor_capabilities` sibling remains reference material. Future
Capabilities adoption must consume the canonical Kernel types instead of
shipping its older `Arbor.Capabilities.Contracts` copies for shared concepts.
This package move does not adopt the Security runtime, consolidate taint
semantics, or split OIDC providers.

## Standalone closure

The Mix project uses ordinary package-local build, dependency, lockfile, and
configuration defaults. It no longer requires the monorepo path helper or
loads Arbor's config. Boundary, ExDoc, and Dialyxir retain their compiler or
development roles. No first-party dependency is introduced.

The OTP Crypto dependency is explicit: public functions generate identities,
sign requests, create identifiers, and calculate or verify digests. Logger was
already required. Kernel still has no OTP application callback and owns no
supervisor, broker, registry, store, or background process.

The Hex file allowlist contains the library, project definition, README,
license, and this rationale. Monorepo tests, standalone fixture sources, and
historical qualification archives are not release payload. The standalone
consumer resolves an unpacked package path so qualification can prove that
these omitted host files are not required at runtime.

## Compatibility and rollback

This is a dependency and source-location change. No module rename, wire-schema
change, authority rotation, or durable-state migration is required. Existing
opaque references continue to use their original module identities. Namespace
or validation changes belong to separately reviewed work.

A local rollback reverts the adoption commit, restoring the umbrella source
and dependency declarations together. Qualification must check the rollback
tree and the package consumer independently; a normal umbrella build alone
does not prove standalone closure.
