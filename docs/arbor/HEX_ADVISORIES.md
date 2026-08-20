# Hex Dependency Advisories

Status recorded 2026-08-20. This inventory is generated from `./bin/mix hex.audit`
after the dependency updates in `mix.lock`. A package remains here when no
compatible patched release can be selected without a separate constraint or
dependency migration.

## Remediated in This Packet

The lockfile updates the smallest supported patched releases verified by the
audit metadata and the umbrella's existing constraints:

- `phoenix` 1.8.3 -> 1.8.9
- `phoenix_live_view` 1.1.21 -> 1.1.33
- `postgrex` 0.22.0 -> 0.22.4
- `swoosh` 1.21.0 -> 1.26.3
- `tesla` 1.16.0 -> 1.18.3

The audit no longer reports advisories for Phoenix, Phoenix LiveView, Postgrex,
Swoosh, or Tesla.

## Residual Advisories

### cowlib 2.19.0

Reverse path: Arbor's `plug_cowboy`/Cowboy HTTP servers -> Cowboy -> cowlib.
The dashboard and gateway expose the relevant server stack; Swoosh and other
HTTP dependencies may also use Cowboy for optional adapters.

Actual exposure: untrusted HTTP request metadata can reach Cowboy's cookie,
Link, and response-header encoders when those APIs are used. Arbor does not
directly call the affected cowlib encoder functions, so the exposure is an
indirect boundary risk in the embedded HTTP server stack.

Advisories:

- `EEF-CVE-2026-43969` / `CVE-2026-43969` / `GHSA-g2wm-735q-3f56` (LOW):
  cookie request header injection.
- `EEF-CVE-2026-43971` / `CVE-2026-43971` (MEDIUM): Link header directive
  smuggling.
- `EEF-CVE-2026-43966` / `CVE-2026-43966` / `GHSA-w4f7-4cxr-rv3c` (MEDIUM):
  HTTP response splitting through non-VCHAR bytes.

Blocker: Hex metadata reports no fixed release for these advisories, and
`cowlib` 2.19.0 is the latest available release as of 2026-08-20.

### decimal 2.4.1

Reverse paths: Arbor persistence -> Ecto/Ecto SQL -> Decimal; Postgrex and
ExJsonSchema also constrain Decimal to the 2.x line.

Actual exposure: database-backed schemas and JSON-schema validation may parse
attacker-controlled numeric values. An unbounded exponent can consume
unbounded resources and cause a denial of service if such input reaches Decimal.

Advisory: `EEF-CVE-2026-32686` / `CVE-2026-32686` /
`GHSA-rhv4-8758-jx7v` (MEDIUM): unbounded exponent DoS.

Blocker: the patched release is Decimal 3.0.0, but Ecto 3.x, ExJsonSchema,
and the selected Postgrex release constrain this umbrella to Decimal 2.x.
Migrating requires coordinated upstream compatibility work rather than a lock
file-only change.

### req 0.5.17

Reverse paths include direct Arbor consumers in `arbor_ai`, `arbor_llm`,
`arbor_comms`, `arbor_kernel_runtime`, `arbor_orchestrator`, and
`arbor_security`, plus `req_llm`, `llm_db`, `jido_action`, `jido_browser`,
`tidewave`, `weather`, and `ex_aws_auth`.

Actual exposure: Arbor uses Req for provider, MCP, ACP, and other outbound HTTP
requests. Compressed responses and multipart form construction can therefore
cross this dependency boundary when those features process remote or
untrusted data.

Advisories:

- `EEF-CVE-2026-49755` / `CVE-2026-49755` / `GHSA-655f-mp8p-96gv` (HIGH):
  decompression bomb DoS.
- `EEF-CVE-2026-49756` / `CVE-2026-49756` / `GHSA-px9f-whj3-246m` (LOW):
  multipart form-data header injection.

Blocker: no patched 0.5.x release exists. Hex audit metadata reports the fixes
in Req 0.6.0 and 0.6.1, but several direct and transitive constraints remain on
`~> 0.5`, including `weather ~> 0.5.0` and `jido_action ~> 0.5.10`. Moving to
Req 0.6 requires coordinated constraint updates and compatibility testing
across those consumers, so Req remains unchanged at 0.5.17.

### hackney 1.25.0

Reverse paths include `httpoison -> hackney`, `joken_jwks -> hackney`,
`tesla -> hackney`, and `tzdata -> hackney`; Swoosh also declares Hackney as
an optional adapter. In Arbor, the most relevant paths are
`arbor_security -> joken_jwks -> hackney` and the Tesla adapter path.

Actual exposure: the affected behavior is reachable only when Hackney is used
as the selected HTTP adapter or when its helper APIs process attacker-controlled
URLs, cookies, query parameters, or SOCKS5 connections. Arbor's primary Req
and Finch paths do not automatically select Hackney, but the dependency remains
available through these adapter paths.

Advisories:

- `EEF-CVE-2026-47075` / `CVE-2026-47075` / `GHSA-j9wq-vxxc-94wf` (MEDIUM):
  CR/LF injection in query parameters.
- `EEF-CVE-2026-47071` / `CVE-2026-47071` / `GHSA-gp9c-pm5m-5cxr` (HIGH):
  SOCKS5 TLS upgrade ignores the caller timeout.
- `EEF-CVE-2026-47069` / `CVE-2026-47069` / `GHSA-mp55-p8c9-rfw2` (LOW):
  CRLF injection in cookie domain/path options.
- `EEF-CVE-2026-47076` / `CVE-2026-47076` / `GHSA-pj7v-xfvx-wmjq` (MEDIUM):
  SSRF allowlist bypass through a percent-encoded host.

Blocker: Hex audit metadata reports the fixes in Hackney 4.0.1. The resolved
umbrella still has 1.x constraints from HTTPoison, Tzdata, and JokenJWKS;
Tesla 1.18.3 admits the 4.x line but does not remove those other blockers.
Migrating requires replacing or upgrading those consumers and validating their
adapter behavior.

## Verification

The post-change command was:

```text
./bin/mix hex.audit
```

It exited `1` with the ten residual findings documented above.
