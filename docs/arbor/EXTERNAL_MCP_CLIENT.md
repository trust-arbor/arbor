# External MCP Client Setup

Canonical guide for connecting an external MCP client (Claude Code, Codex, other
stdio MCP hosts) to Arbor Gateway at `/mcp`.

## Two connection modes

| Mode | When to use | Identity |
| --- | --- | --- |
| **Direct HTTP / Bearer** | Tools that do **not** require a verified principal (for example listing public tool metadata such as `arbor_actions` / `arbor_help` without running principal-scoped work) | No agent principal |
| **Stdio signing proxy** | Mutating and principal-scoped tools (`arbor_run`, task dispatch/status/result/cancel/steer, approvals, and any status component that authorizes a target agent) | Verified `SignedRequest` principal |

Arbor does **not** accept a caller-supplied `agent_id` in tool arguments as
proof of identity. Principal-scoped tools resolve the caller only from a
verified per-request Ed25519 signature (`Arbor.Gateway.SignedRequestAuth`).

Direct HTTP/Bearer is therefore **not** enough for principal-scoped tools even
if a dashboard session or API key can reach other Gateway routes. Use the
signing proxy for those tools.

## Signing proxy (required for principal-scoped tools)

1. Register an external agent in the Arbor dashboard (**Settings → External
   Agents**). Local-dev auto-saves `~/.arbor/keys/<name>_<id8>.arbor.key` at
   mode `0600` (no overwrite) and shows ready-to-paste `mcpServers` JSON.
   Download remains the fallback. See [QUICKSTART.md](../QUICKSTART.md).
2. Ensure the Arbor Gateway is running and serving MCP at
   `http://localhost:4000/mcp` (or your deployed upstream URL).
3. From the Arbor repository root, verify the **stdio** signer command:

```bash
./bin/mix arbor.signer --key-file <path-to-agent.arbor.key> --upstream http://localhost:4000/mcp
```

Use the repository wrapper `./bin/mix` so the proxy runs under the pinned
Erlang/Elixir toolchain. Configure the MCP host to change into that repository
root first because MCP server processes do not inherit a predictable working
directory.

### Example Claude Code MCP config

```json
{
  "mcpServers": {
    "arbor": {
      "command": "sh",
      "args": [
        "-c",
        "cd /absolute/path/to/arbor && exec ./bin/mix arbor.signer --key-file /absolute/path/to/agent.arbor.key --upstream http://localhost:4000/mcp"
      ]
    }
  }
}
```

Shell-quote real paths if they contain spaces. An MCP host with an explicit
working-directory setting can use `./bin/mix` directly after setting that
directory to the Arbor repository root.

Each client session spawns its own proxy subprocess. Stdout is reserved for
MCP JSON-RPC; proxy logs go to stderr. There is no extra listening port: the
private key stays in that subprocess and signs each upstream HTTP request.

## Progressive disclosure on MCP tools

- `arbor_actions` **without** `category` returns a compact category index
  (names + per-category counts, including the dynamic `mcp` category). It does
  **not** enumerate every action or include descriptions.
- `arbor_actions` **with** `category` lists that category's tools in detail
  (and `category=mcp` lists connected external MCP server tools).
- `arbor_help` returns the schema for one action name.
- `arbor_status` with `component=mcp` reports **Arbor's** MCP client
  connections and agent MCP endpoints — not the caller's own MCP connection to
  Gateway. `agent_id` is required for `memory`, `capabilities`, and `goals`
  (and for per-agent detail under `agents`); the agents list summary without
  `agent_id` remains open.

## Arbor as an MCP client (outbound)

This guide is about connecting an external host *to* Arbor. Arbor also
connects *out* to third-party MCP servers. Those tool descriptions are pinned
after first discovery (or later re-approval) so a refresh cannot silently
replace the text shown to the model.

Pins are SHA-256 of `name` / `description` / `annotations` /
`inputSchema` / `outputSchema`, keyed by
`Arbor.Security.mcp_server_approval_uri/2` and the tool name, and stored in
`~/.arbor/mcp_tool_pins` (`config :arbor_gateway, :mcp_tool_pin_dir`). A
mismatch quarantines the tool and emits `:mcp_tool_fingerprint_changed`.
Re-approve today with `Arbor.Gateway.approve_mcp_tool_fingerprint/2`. Revoking
or changing a server's config approval drops that identity's pins. A dashboard
re-approval UI is planned
([roadmap](./roadmap/mcp-tool-reapproval-ui.md)).

See [Security architecture — MCP client tool-fingerprint pins](./SECURITY_ARCHITECTURE.md#mcp-client-tool-fingerprint-pins).

## Related

- `mix arbor.signer` — `apps/arbor_gateway/lib/mix/tasks/arbor.signer.ex`
- `Arbor.Gateway.Signer.Proxy` — stdio signing proxy implementation
- `Arbor.Gateway.SignedRequestAuth` — HTTP signature verification
- [SOFTWARE_FACTORY.md](./SOFTWARE_FACTORY.md) — what the factory is,
  prerequisites, and first-run setup
- [CODING_TASK_DISPATCH.md](./CODING_TASK_DISPATCH.md) — signed dispatch of
  structured coding tasks after the proxy is configured
