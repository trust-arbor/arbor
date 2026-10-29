# MCP tool re-approval UI

**Created:** 2026-10-23
**Status:** planned
**Severity:** medium
**Category:** security / dashboard

Official roadmap items live in `.arbor/roadmap/` (`0-inbox/` → …). That nested
Git repository is gitignored from the parent and may be absent in a checkout,
so this tracked file is the parent-repo copy. Keep this file separate from
other `docs/arbor/roadmap/` items so parallel PRs do not conflict.

## Summary

The outbound MCP client already pins each tool's `name`, `description`,
`annotations`, `inputSchema`, and `outputSchema`, quarantines a drifted
definition, persists the pin across
restart, and exposes `Arbor.Gateway.approve_mcp_tool_fingerprint/2` plus
`:mcp_tool_fingerprint_changed`. There is no dashboard flow yet. Operators
must call the API (or Tidewave / IEx) to inspect a quarantine and re-pin.

This item is a later dashboard flow. The pin store and quarantine behavior
are already implemented.

## Dashboard flow

- List quarantined tools for each connected MCP server (from
  `ClientConnection.status/1` `quarantined_tools`, plus the observed
  definition held in connection state).
- Show the pinned (old) description and `inputSchema` next to the observed
  (new) ones, with a readable diff.
- **Approve** calls `Arbor.Gateway.approve_mcp_tool_fingerprint/2` and writes
  an audit entry (who accepted which identity, tool name, old hash, new hash).
- **Deny** keeps the tool quarantined (do not pin the observed definition)
  and writes an audit entry. Deny does not delete the accepted pin.

## Out of scope for this item

- Changing first-discovery further (new names on an already-pinned server
  are already held for re-approval).
- Replacing `ToolPinStore` or the approval-URI identity key.
- A Security capability URI per tool description.

## Related

- [Security architecture — MCP client tool-fingerprint pins](../SECURITY_ARCHITECTURE.md#mcp-client-tool-fingerprint-pins)
- [External MCP client](../EXTERNAL_MCP_CLIENT.md)
- `apps/arbor_gateway/lib/arbor/gateway/mcp/tool_fingerprint_core.ex`
- `apps/arbor_gateway/lib/arbor/gateway/mcp/tool_pin_store.ex`
- `apps/arbor_gateway/lib/arbor/gateway/mcp/client_connection.ex`
