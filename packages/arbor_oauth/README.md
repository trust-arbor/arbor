# Arbor OAuth

Provider-neutral authorization-code/PKCE and device-code protocols, with bounded
HTTP transport. This package owns the existing `Arbor.Common.OAuth` modules;
request, response and parameter struct identities are unchanged. It requires
no other Arbor library.

```elixir
{:arbor_oauth, "~> 0.1.0-dev", path: "path/to/arbor/packages/arbor_oauth"}
```

The public primitives are `Arbor.Common.OAuth.AuthCode`, `DeviceCode` and
`HttpClient`. Hosts supply and validate provider endpoints, enforce identity
policy, and decide how acquired credentials are stored. The protocols preserve
PKCE S256, single-use exchange behavior, issuance-based polling deadlines,
bounded decoding and credential-redacting inspection.

The Req adapter disables redirects, automatic retries, decompression and body
decoding. A whole-request monotonic deadline and streaming byte bound limit
responses; a dedicated HTTP/1 Finch pool applies Mint's parser-level response
header limit. The host's endpoint policy remains necessary; this package does
not grant trust to a URL supplied by an external caller.

## Transport lifetime

The OTP application is passive: loading or starting `:arbor_oauth` starts no
network provider or pool. HTTP dependencies are declared with `runtime: false`.
The owner explicitly starts its provider applications and supervises the public
pool child specification before using the default Req adapter:

```elixir
{:ok, _applications} = Application.ensure_all_started(:req)

# Include this child exactly once in the owning application's supervisor.
children = [{Arbor.Common.OAuth.HttpClient.Pool, []}]
```

Keep that child behind the host's boot admission. Arbor retains its existing
Common supervisor ownership, including isolated full-profile tests where
optional Common children are disabled. Activation-only boot starts no OAuth
pool or HTTP providers. Custom HTTP adapters may provide their own lifecycle.

## Adapter configuration

An explicit per-call `:http_client` wins. A missing or nil per-call option
resolves the configured adapter. New hosts configure:

```elixir
config :arbor_oauth, http_client: MyApplication.OAuthHttpClient
```

When the package key is present it is authoritative, including an explicit nil
or invalid value: requests fail closed instead of falling back to a legacy
adapter. When it is absent, the existing
`config :arbor_kernel, common: [oauth_http_client: ...]` seam remains supported.
The package reads that compatibility setting as data and never loads or calls
Kernel Runtime's Common configuration module. With neither setting present,
the default is `Arbor.Common.OAuth.HttpClient.Req`.

Adapters implement `HttpClient.request/1` with the existing `Request` and
`Response` structs. The facade validates request and response budgets, headers
and error vocabulary; adapter exceptions, exits and unexpected return values
become body-free transport errors.

The owning suites and external consumer are in `test/` and
`examples/standalone/`. The qualifier builds an actual Hex archive and verifies
a fresh consumer and source-hidden ERTS release without Mix. Publication remains
a separate decision. Source is adopted from Arbor Main `4076dfce1`.
