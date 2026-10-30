# Standalone OIDC consumer

This fixture consumes the actual `arbor_capabilities_oidc` and `arbor_oauth`
artifacts with public dependencies. Both libraries are passive. Before explicit
provider startup, the consumer proves that no product application, HTTP pool,
JWT provider, or JWKS cache singleton starts. The host explicitly supervises
the public OAuth Pool child; the leaf OIDC library owns no cache.

`OIDCStandaloneConsumer.verify!/1` uses owned ephemeral loopback HTTP listeners
for discovery, JWKS, authorization-code/PKCE, device start/poll, and refresh.
It signs real ES256 and RS256 tokens and checks signature, key-id, issuer,
audience, expiration, authorized-party and nonce validation. It also exercises
the opaque prepared-verification API, closed endpoint origins, transport
bounds/deadlines, redirects, retries, encoding refusal and status-only errors.
It returns only check names, application names and code paths; no token,
credential, key, claims, request form, or response body enters the report.

The package qualification script builds two real Hex archives and checks their
checksums, exact source members and dependency metadata. A fresh consumer
compiles both unpacked artifacts and its own code strictly with cold, private
dependency builds. An assembled ERTS release then repeats the probes with Mix
absent after only the qualifier's copied source/tool directories are hidden.
It does not fetch, publish, modify a live checkout, seed build caches, or change
operator homes. Failure retains evidence and stops the run.

Use `packages/arbor_capabilities_oidc/scripts/qualify_standalone.py --help` for
the required pinned tools, source cache and reviewed Main/candidate inputs.
Run only from an isolated clean worktree into a fresh private evidence path.
