# ExMCP 1.3.0 → ArborMCP / ArborACP upgrade assessment

**Date:** 2026-10-29
**Status:** assessment only. This document does not change dependencies.
**Host pin today:** Hex `ex_mcp` `1.3.0` (`override: true` in the umbrella root, `arbor_ai`, and `arbor_gateway`).
**Application config today:** `config :ex_mcp, protocol_mode: :legacy_only`.

Security fixes for this stack now land in [trust-arbor/arbor_mcp](https://github.com/trust-arbor/arbor_mcp) and [trust-arbor/arbor_acp](https://github.com/trust-arbor/arbor_acp). The host does not depend on those packages. Hex `ex_mcp` 1.3.0 is the pre-split library; later 1.x security patches still publish as Hex `ex_mcp` from the arbor_mcp 1.x maintenance line (`codex/maintenance-1.x`). The v2 split publishes MCP as Hex `arbor_mcp` (`Arbor.MCP.*`) and ACP as Hex `arbor_acp` / `arbor_acp_adapters` (`Arbor.ACP.*`).

This is a design call for the maintainer: stay on 1.x (optionally bump Hex `ex_mcp`), or cut over to the split packages. Do not treat this note as an upgrade commit.

## What the host uses from `ex_mcp` 1.3.0

### Direct dependents

| App | Pin | Role |
| --- | --- | --- |
| umbrella `mix.exs` | `{:ex_mcp, "1.3.0", override: true}` | Forces one version across the umbrella |
| `arbor_gateway` | same | MCP server at `/mcp`, outbound MCP client, BEAM agent endpoints |
| `arbor_ai` | same | ACP sessions, adapter-backed coding agents, ACP ToolServer |

Config comment in `config/config.exs` (2026-era pin): ExMCP 1.0.0-rc.6+ defaults to `:prefer_modern` (MCP 2026-07-28 first). Arbor pins `:legacy_only` so existing HTTP MCP clients, BEAM agent endpoints, and ACP ToolServer peers keep the pre-2026-07-28 initialize handshake.

### MCP modules and transports (`arbor_gateway`)

| Surface | 1.3.0 module | How the host uses it |
| --- | --- | --- |
| HTTP MCP server | `ExMCP.HttpPlug` | `Arbor.Gateway.Router` forwards `/mcp` with host-owned CORS-off / auth / body-cache options. `SignedRequestAuth` leaves `conn.assigns[:raw_body]` for ExMCP to parse. |
| Handler API | `ExMCP.Server.Handler` | `Arbor.Gateway.MCP.Handler` implements `handle_initialize/2`, `handle_list_tools/2`, `handle_call_tool/3`. Tools include `arbor_actions`, `arbor_help`, `arbor_run`, status, approvals, and coding-task dispatch. |
| Message path | `ExMCP.MessageProcessor` | Direct HTTP dispatch and handler tests. SignedRequestAuth comments assume ExMCP does not need a patched processor to thread assigns. |
| Protocol helpers | `ExMCP.Protocol.VersionNegotiator`, `ExMCP.Protocol.ResponseBuilder` | Initialize capabilities and BEAM agent-endpoint responses. |
| Outbound client | `ExMCP.Client` | `Arbor.Gateway.MCP.ClientConnection` wraps `start_link/1`, `ping/2`, `server_info/1`, `list_tools/2`, `list_resources/2`, `read_resource/3`, `call_tool/4` (`format: :map`, `retry_policy: false`, `http_stream_retry: :safe_only`), `disconnect/1`. |
| Client transports | `:stdio`, `:http`, `:sse`, `:beam` | Documented on `Arbor.Gateway`. Agent-to-agent is `:beam` with `protocol_mode: :legacy_only`. External servers use the configured command/URL. |
| Error shapes | `ExMCP.Error.ValidationError`, `ExMCP.Error.TransportError` | `Arbor.Gateway.MCP.CallOutcome` classifies 1.3 `call_tool/4` results into `:not_sent` / `:refused` / `:failed` / `:unknown`. |
| Session owner | `ExMCP.SessionManager` | ACP ToolServer initialize fails closed if the `:ex_mcp` application (and this process) is not running. |
| Test kit | `ExMCP.Testing.MockServer` | Gateway MCP security-regression and integration tests. |

`Arbor.Gateway.connect_to_agent/2` starts `ExMCP.Client` with `transport: :beam` and `protocol_mode: :legacy_only`.

### ACP modules and adapters (`arbor_ai`)

| Surface | 1.3.0 module | How the host uses it |
| --- | --- | --- |
| ACP client | `ExMCP.ACP.Client` | `Arbor.AI.AcpSession` default client. `new_session/3`, prompt, config, cancel, disconnect. |
| Client handler | `ExMCP.ACP.Client.Handler` | `Arbor.AI.AcpSession.Handler` answers permission / file / elicitation from Arbor capabilities. |
| Adapter transport | `ExMCP.ACP.AdapterTransport` | Launch path for adapted CLIs (stdio JSON-RPC via the adapter). |
| Claude | `ExMCP.ACP.Adapters.ClaudeSDK` | Default `:claude` provider. Stream-json SDK control channel, permission mode, `--mcp-config` launch wiring. The older `ExMCP.ACP.Adapters.Claude` is not the host default. |
| Codex | `ExMCP.ACP.Adapters.Codex` | Default `:codex` provider. Trusted MCP-server list at `session/new`. |
| Pi | `ExMCP.ACP.Adapters.Pi` | Default `:pi` provider. Host treats bound `mcpServers` as an error (`{:acp_mcp_servers_unsupported, ExMCP.ACP.Adapters.Pi}`). Session-map path remains `~/.ex_mcp/pi/session-map.json` even after a namespace move. |
| ZCode | `ExMCP.ACP.Adapters.ZCode` | Not a default provider; `McpLaunchCore` trusts its MCP list the same way as Codex. |
| Native ACP | command + `ExMCP.Transport.Stdio` | Gemini, Antigravity, Grok, OpenCode, Goose, Copilot, Kiro, Qwen Code, Hermes, Cursor. Top-level `:command` / `:cd` / `:env` are forwarded through the client. |
| HTTP ToolServer | `ExMCP.HttpPlug` | `Arbor.AI.AcpPool.ToolServer` mounts a per-session bearer-gated MCP server so adapted CLIs can call Arbor tools. |

Operator override map: `config :arbor_ai, :acp_providers`. Overrides **replace** the per-provider default rather than deep-merging. The committed example pins Claude to `ExMCP.ACP.AdapterTransport` + `ExMCP.ACP.Adapters.ClaudeSDK`.

Logger: `Arbor.AI.Application` sets `ExMCP.ACP.Client` to `:info` because ExMCP debug-logs entire unsupported provider notifications.

### Config and wire identities the host owns

- `config :ex_mcp, protocol_mode: :legacy_only` — host-wide MCP era pin.
- ACP `_meta.ex_mcp.*` and `_ex_mcp.pi/*` appear in session tests and provider-session-id handling. Those are **wire/storage identities**, not Elixir module names.
- Pi's managed session map stays at `~/.ex_mcp/pi/session-map.json` on the split packages (documented by ArborACP). Do not rename that path as part of a source rewrite.
- `CallOutcome` matches `%{__struct__: ExMCP.Error.*}`. A namespace move without updating that classifier silently turns structured errors into `:unknown`.

## What moving to `arbor_mcp` + `arbor_acp` would need

Published candidates assessed here (2026-10-29):

| Package | Hex | Namespace | Notes |
| --- | --- | --- | --- |
| ArborMCP | `arbor_mcp` `2.0.0-rc.6` | `Arbor.MCP.*` | MCP only. OTP app `:arbor_mcp`. |
| ArborACP | `arbor_acp` `1.0.0-rc.4` | `Arbor.ACP.*` | ACP client / native agent / generic adapter contract. |
| ArborACP adapters | `arbor_acp_adapters` `1.0.0-rc.4` | `Arbor.ACP.Adapters.*` | Claude, Codex, Pi, ZCode. |
| ArborRPC | `arbor_rpc` `1.0.0-rc.3` | `Arbor.RPC.*` | Transitive JSON-RPC / framing / native subprocess helper. |

Canonical migration guide: [MIGRATING_V1_TO_V2.md](https://github.com/trust-arbor/arbor_mcp/blob/master/docs/guides/MIGRATING_V1_TO_V2.md).

### API / module differences that hit this host

1. **Package split.** Remove every `{:ex_mcp, "1.3.0", override: true}`. Gateway needs `arbor_mcp`. AI needs `arbor_acp` + `arbor_acp_adapters`. Do not add a direct `arbor_rpc` unless host code calls `Arbor.RPC.*`.
2. **Namespaces.** `ExMCP.*` → `Arbor.MCP.*`; `ExMCP.ACP.*` → `Arbor.ACP.*`; vendor adapters → `Arbor.ACP.Adapters.*`. Update aliases, behaviours, child specs, `config :arbor_ai, :acp_providers`, tests, and Logger module levels.
3. **Application config.** Move `config :ex_mcp, protocol_mode: :legacy_only` to `config :arbor_mcp, protocol_mode: :legacy_only`. A dependency's `config/config.exs` is **not** auto-loaded by the consumer. Keep `:legacy_only` until every Gateway client, BEAM endpoint, and ToolServer peer is re-qualified on 2026-07-28.
4. **HTTP mount.** `ExMCP.HttpPlug` with `handler:` is replaced by `Arbor.MCP.HttpPlug` that **requires `:runtime`**. Start `{Arbor.MCP.Server.Runtime, handler: Arbor.Gateway.MCP.Handler, name: ..., transport: :mounted_http, request_timeout_ms: ...}` **before** the Gateway endpoint. `:handler_call_timeout` becomes root `:request_timeout_ms`. Stopping the Runtime does not stop Phoenix/Cowboy.
5. **Handler process model.** Callbacks run in managed Tasks, concurrently by default. 1.x-style sequential GenServer state needs `execution: :stateful` or handler state must live in ETS/another process. Gateway handler init currently installs per-request signed-request assigns into a short-lived handler process — re-verify that under Runtime.
6. **`VersionNegotiator.build_capabilities/1`.** Retired as the complete initialize wrapper. Return capabilities from `handle_initialize/2` and let dispatch normalize.
7. **Client results.** Canonical `Arbor.MCP.Client` operations return `{:ok, %Arbor.MCP.Response{}}` unless `format: :map`. `CallOutcome` and `ClientConnection` already request maps in some places; audit every call for struct-vs-map and `Response.error?/1` vs JSON-RPC error.
8. **Disconnect / stop.** `Client.disconnect/1` keeps the process; `Client.stop/3` waits for cleanup and can return cleanup errors. `ClientConnection` must not treat process death as proof of IO cleanup.
9. **ACP prompt.** `Arbor.ACP.Client.prompt/4` returns the peer JSON unchanged. Hosts that synthesized `result["text"]` from streamed updates must switch to `prompt_text/4` (`truncated?` is load-bearing).
10. **SessionManager / Tools DSL.** There is no global Tools registry. ToolServer must not assume `ExMCP.SessionManager` under `:ex_mcp`. Use the v2 Runtime/session contract.
11. **Test kit.** `ExMCP.Testing.MockServer` → `Arbor.MCP.Testing.*`. Gateway MCP regressions are load-bearing; port them before flipping the pin.
12. **Pi / Claude / Codex adapters.** Module names change; launch option atoms largely stay. Pi still has no MCP-server support — keep the host fail-closed plan. Claude still needs `--mcp-config` + `--strict-mcp-config` because it ignores `session/new` `mcpServers`. Codex/ZCode still need `trusted_mcp_servers`. Preserve `_meta.ex_mcp` and the Pi session-map path.
13. **Native helper.** ArborRPC builds a C17 subprocess helper. Source `mix deps.get` needs `cc` (or `CC`). `config :arbor_rpc, native_helper: :required` fails the build if the helper is missing. Windows native subprocesses are unsupported. Assembled releases ship the helper and do not need a compiler at runtime.
14. **Decimal 3.** ArborMCP 2.0.0-rc.6 **requires Decimal `~> 3.1` and `>= 3.1.2`**. This umbrella is on Decimal 2.x (Ecto 3.x / ExJsonSchema / Postgrex). `docs/arbor/HEX_ADVISORIES.md` already records Decimal 3 as a coordinated migration, not a lockfile bump. **This is a hard blocker for a same-PR or casual cutover.**

### Config the host would have to own after the move

```elixir
# MCP era — keep until wire peers are re-qualified
config :arbor_mcp, protocol_mode: :legacy_only

# Fail closed if ACP adapters cannot spawn
config :arbor_rpc, native_helper: :required

# Provider map: replace ExMCP.* modules, do not deep-merge casually
config :arbor_ai, :acp_providers, %{
  claude: %{
    transport_mod: Arbor.ACP.AdapterTransport,
    adapter: Arbor.ACP.Adapters.ClaudeSDK,
    adapter_opts: [model: "opus"]
  }
}
```

Logger: `Logger.put_module_level(Arbor.ACP.Client, :info)`.

### Pi-specific notes

- Default adapted provider today: `ExMCP.ACP.Adapters.Pi` with empty `adapter_opts`.
- Bound `mcpServers` must remain an error after the rename (`Arbor.ACP.Adapters.Pi`).
- ArborACP 1.0.0-rc.4 keeps Pi's session-map location and `_ex_mcp.pi/*` wire keys.
- Pi probes (version / npm update) become bounded ArborRPC captures (800 ms / 64 KiB). Treat missing metadata as optional, not a session failure.
- Host tests in `acp_session_test.exs` assert real Pi config-option IDs; re-run those against `arbor_acp_adapters` golden fixtures before declaring Pi done.

## Risks

| Risk | Why it matters here |
| --- | --- |
| **Decimal 3 vs Ecto 2.x** | `arbor_mcp` 2.0.0-rc.6 will not resolve against the current lock without an Ecto/ExJsonSchema/Postgrex plan. |
| **RC, not stable** | 48-hour qualification is incomplete (request-ID capacity on a persistent BEAM peer). Stable `arbor_mcp` 2.0 is not released. |
| **HTTP mount / Runtime rewrite** | Gateway `/mcp` and ACP ToolServer both use `HttpPlug`. A handler-only rename will fail `HttpPlug.init/1`. |
| **Concurrent handler callbacks** | Signed-request assigns and per-request handler state can race if left on the v2 default. |
| **`:legacy_only` vs default `:prefer_modern`** | Dropping the pin mid-cutover breaks current clients and BEAM endpoints. |
| **CallOutcome drift** | Struct module names in `classify/1` are part of the security/timeout story (`:unknown` vs `:not_sent`). |
| **ACP prompt text** | Council / coding dispatch that reads synthesized `text` will silently change. |
| **C17 / native helper** | CI and operator machines that compile from Hex source need a compiler; ACP adapters will fail at spawn with `:native_helper_unavailable` otherwise. |
| **Hot upgrade** | 1.x process state cannot be loaded into v2. Needs a cold restart and a rehearsed rollback to the saved 1.3.0 lock. |
| **Staying on 1.3.0** | Misses 1.x security patches that already shipped as Hex `ex_mcp` 1.7.3 (global `Logger.configure/1` via `logging/setLevel`; `ExMCP.ACP.Registry.fetch/1` following redirects and replaying `Authorization`). Those fixes are **not** in 1.3.0. |

### Smaller alternative (not this PR)

If the goal is “get the security fixes” rather than “adopt the v2 split”, the lower-risk path is to bump Hex `ex_mcp` along the maintained 1.x line (`~> 1.7`, currently 1.7.3) and keep `ExMCP.*` + `:legacy_only`. That is still a design call (compat with Gateway `CallOutcome`, ACP adapters, and SessionManager). It does **not** require Decimal 3 or the Runtime/HttpPlug rewrite. This assessment does not perform that bump.

## Step-by-step plan (when the maintainer chooses v2)

1. **Decide the product question.** Need 1.x security patches soon, or the v2 runtime/API? If only the former, bump Hex `ex_mcp` 1.x first and stop. If the latter, continue.
2. **Unblock Decimal.** Plan Ecto / ExJsonSchema / Postgrex onto Decimal 3.x (or get an ArborMCP release that does not force Decimal 3). Do not start the MCP cutover while `mix deps.get` cannot resolve.
3. **Save rollback artifacts.** Commit-quality copy of `mix.lock`, `config/*.exs`, and the 1.3.0 release notes. v2 is a cold-restart cutover.
4. **Install a C17 compiler** on every compile host. Set `config :arbor_rpc, native_helper: :required` in the upgrade branch.
5. **Replace the pins** with exact RCs (`arbor_mcp == 2.0.0-rc.6`, `arbor_acp == 1.0.0-rc.4`, `arbor_acp_adapters == 1.0.0-rc.4`). Drop `ex_mcp`. Review the full lockfile, including Mint / JOSE / Cowlib floors.
6. **Move config** `:ex_mcp` → `:arbor_mcp`. Keep `protocol_mode: :legacy_only`. Update `:acp_providers` module atoms.
7. **Rewrite Gateway HTTP.** Supervise an `Arbor.MCP.Server.Runtime` for `Arbor.Gateway.MCP.Handler`; mount `forward "/mcp", Arbor.MCP.HttpPlug, runtime: ...`. Re-test `SignedRequestAuth` raw-body + MessageProcessor.
8. **Port `ClientConnection` and `CallOutcome`** to `Arbor.MCP.Client` / `Arbor.MCP.Error.*`. Keep `format: :map` or teach the classifier the new structs. Re-run every MCP security-regression file that uses `MockServer`.
9. **Port BEAM agent endpoints** to `Arbor.MCP.Client.start_link(transport: :beam, protocol_mode: :legacy_only)` and the v2 ResponseBuilder.
10. **Port ACP.** `Arbor.AI.AcpSession` → `Arbor.ACP.Client`; handler behaviour → `Arbor.ACP.Client.Handler`; adapters → `Arbor.ACP.Adapters.{ClaudeSDK,Codex,Pi}`. Re-run `mcp_launch_core` (Claude file, Codex/ZCode trust list, Pi unsupported). Confirm `_meta.ex_mcp` and Pi session-map path are unchanged.
11. **Port ToolServer** off `ExMCP.HttpPlug` / `ExMCP.SessionManager` onto a mounted Runtime + bearer plug.
12. **Qualify wire peers** still on `:legacy_only` (Claude Code / Codex stdio signer, BEAM agents, ToolServer). Only then consider `:prefer_modern`.
13. **Exercise** startup, tool call, approval, coding dispatch, ACP prompt/cancel, peer turnover, and public shutdown. Confirm native helper presence on the target OS/arch.
14. **Cut over with a cold restart.** Drain 1.3.0, start a fresh VM on v2, keep the 1.3.0 lock as the rollback release. Do not hot-upgrade process state.

## Out of scope for the current PR

- No `mix.exs` / `mix.lock` change.
- No module rename.
- No protocol_mode change.
- No ArborMCP/ArborACP dependency.

The security fix in this same PR (Req `x-api-key` must not follow a cross-origin redirect) is independent of the ExMCP pin. 1.7.3's `ExMCP.ACP.Registry.fetch/1` redirect fix is a **library** issue; the host Exa/Tinyfish/Limitless/AnthropicLoop leak was a **host Req** issue.
