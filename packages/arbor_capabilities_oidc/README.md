# Arbor Capabilities OIDC

OpenID Connect discovery, authorization-code/PKCE, device flows and JWT
verification for Elixir. `Arbor.Capabilities.OIDC` is the public facade. The
package depends on the public `arbor_oauth` transport library and has no
dependency on Arbor Security, Kernel Runtime, identity stores or authority
owners.

```elixir
{:arbor_capabilities_oidc, "~> 0.1.0-dev"}
```

The source is adopted from Arbor Main `e876097cf`. Existing protocol behavior
and limits are retained under the independent `Arbor.Capabilities.OIDC`
namespace. This package does not create durable identities, authorize
configured providers, register principals or issue signing authorities.

## Protocol operations

`generate_pkce/0`, `generate_state/0` and `generate_nonce/0` generate the existing
cryptographic values. `build_authorize_url/4` and `exchange_code/4` implement
authorization-code acquisition; `start_device_flow/1`, `poll_device_flow/2`
and `refresh_device_flow/2` implement device acquisition and refresh.

Providers carry `:issuer` and `:client_id`, plus explicit protocol options such
as `:client_secret`, `:scopes`, `:allow_http`, `:endpoints`, `:trusted_origins`
and `:http_client`. Defaults and bounded-input admission match the original
protocols. Unknown provider keys do not install cache or fetch callbacks.

Discovery validates issuer shape before IO, checks document issuer binding,
and accepts endpoints on the issuer's origin by default. Additional origins
or pinned endpoints require explicit trusted caller configuration. HTTP is
closed unless the caller explicitly admits it. These origin checks do not
constitute DNS-pinned SSRF protection.

The shared OAuth transport applies response bounds and deadlines, rejects
redirects and compression, performs no automatic retry, and avoids returning
provider response bodies in error terms. Hosts still own endpoint admission
and the lifecycle of acquired credentials.

## Verification and cache ownership

`verify(id_token, provider)` performs standalone verification with an uncached
JWKS fetch. Successful verification returns `{:ok, claims}` after signature,
issuer, audience/authorized-party, subject, time and optional nonce checks.
`decode_unverified/1` only inspects a payload and never authenticates it.

A host that owns a trusted cache can keep that policy outside the package:

```elixir
with {:ok, context} <- Arbor.Capabilities.OIDC.prepare_verification(token, provider),
     {:ok, jwks} <- MyApplication.JwksOwner.get_or_fetch(provider) do
  Arbor.Capabilities.OIDC.verify_prepared(context, jwks)
end
```

Preparation validates the provider and decodes the header before IO. Its
opaque context contains the original token and has fully redacted inspection;
preparation is not authentication. The pure verification stage accepts JWKS
containing 1–128 maps and owns key selection, signature and claim validation.
A `{:kid_not_found, kid}` error lets the host decide whether its admitted cache
should refresh once. The package has no cache singleton, storage mutation,
cache selector or request-provided fetch callback.

Identity and key owners must independently reverify the original signed token
at each authority boundary. Claims or prepared contexts supplied by an
external caller are not proof of identity.

## Explicit resource lifetime

The OTP application is passive and has no application callback. Starting it
does not start Joken/JOSE, Plug.Crypto's store, HTTP providers, an OAuth pool or
a JWKS cache. Joken and Plug.Crypto are compile dependencies declared with
`runtime: false`; their pure verification and comparison functions remain
available. A host starts any required provider applications and supervises
`Arbor.Common.OAuth.HttpClient.Pool` explicitly, as documented by `arbor_oauth`.

The package's owning tests supervise their own HTTP pool and use token-only
fixtures. For a local standalone checkout, set `ARBOR_OAUTH_PATH` to the
`arbor_oauth` source directory when resolving dependencies. Leave it unset
when building a Hex artifact so published dependency metadata remains
version-only. The lockfile retains only the public third-party closure from
the adopted Main lock; no network resolution is needed for the qualified
cached-source workflow.
