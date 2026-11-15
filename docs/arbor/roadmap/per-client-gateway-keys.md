# Per-client gateway API keys

**Created:** 2026-10-23
**Status:** planned
**Category:** security / gateway

Official roadmap items live in `.arbor/roadmap/` (`0-inbox/` → …). That nested
Git repository is gitignored from the parent and was not present in this
checkout, so this tracked file is the parent-repo copy.

## Summary

Give the gateway more than one API credential, each bound to its own session
principal, so mutually untrusted HTTP/Bearer clients cannot attach to each
other's `/mcp` sessions.

Today the gateway accepts a single configured key (`ARBOR_GATEWAY_API_KEY` or
`:arbor_gateway, :api_key`). MCP sessions without an `agent_id` bind to
`apikey:<sha256>` of that presented key. Every holder of the one configured
key therefore shares one principal and can attach, replay, or close each
other's Streamable HTTP / legacy SSE sessions. That is accepted current
behavior: treat the shared key as single-tenant. SignedRequest and JWT
callers already isolate by `agent_id`.

## Scope

- **Multiple named API keys or per-client credentials.** An operator can
  provision more than one HTTP credential (named keys, per-client tokens, or
  an equivalent issuance record). Each credential authenticates independently.
- **One principal per credential.** Session binding uses a distinct
  `apikey:<fingerprint>` (or a named client id) per credential, so client A
  cannot attach to client B's `mcp-session-id`.
- **Session isolation.** GET/SSE, POST, and DELETE refuse a session owned by
  another client principal, with no event replay — the same fail-closed
  behavior already used between `agent_id` principals.
- **Rotation and revocation.** An operator can rotate or revoke one client's
  credential without rotating the whole deployment. Revoked credentials fail
  authentication and cannot resume previously bound sessions.
- **Audit attribution per client.** Logs, receipts, and authorization
  evidence name the client (or key id) that authenticated, not only the shared
  `apikey:<sha256>` of the single deployment key.

## Why it is planned

The current fingerprint binding already isolates API-key sessions from
agent-authenticated sessions and avoids storing the raw key. The remaining
gap is multi-tenant HTTP/Bearer: one deployment key is one principal. Closing
that gap is credential issuance and identity, not a change to the session
attach check. Hysun accepted the shared-key behavior on 2026-10-23 and asked
that it be documented and tracked rather than redesigned in the binding fix.

## Related

- [Security architecture — Gateway MCP session binding](../SECURITY_ARCHITECTURE.md#gateway-mcp-session-binding)
- [External MCP client — session binding](../EXTERNAL_MCP_CLIENT.md#session-binding)
- `apps/arbor_gateway/lib/arbor/gateway/router.ex` (`mcp_principal_id/3`)
- `apps/arbor_gateway/lib/arbor/gateway/auth.ex`
- `apps/arbor_gateway/test/arbor/gateway/mcp/session_principal_binding_security_regression_test.exs`
