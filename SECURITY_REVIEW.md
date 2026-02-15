# Security Review: trust-arbor/arbor

**Date:** 2026-02-15  
**Scope:** `/Users/azmaveth/code/trust-arbor/arbor/` (current `main` working tree)  
**Method:** Manual code audit of ingress/authn/authz, action execution, taint/sandbox enforcement, identity verification, and runtime configuration.

---

## Executive Summary

This review supersedes the 2026-02-07 report. Several previously-remediated controls are still in place, but a new/remaining **critical execution path bypass** exists:

- `POST /mcp` is unauthenticated (`apps/arbor_gateway/lib/arbor/gateway/router.ex:22`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:61`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:63`)
- MCP `arbor_run` allows `agent_id` to be omitted (`apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:95`, `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:98`)
- Omitted `agent_id` routes to unchecked action execution (`apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:263`, `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:264`)
- Unchecked action path bypasses authorization and taint checks (`apps/arbor_actions/lib/arbor_actions.ex:139`, `apps/arbor_actions/lib/arbor_actions.ex:146`)

Removing `/api/bridge` and `/api/signals` reduces attack surface, but **does not close this hole**.

---

## Severity Summary

| Severity | Count |
|---|---:|
| CRITICAL | 2 |
| HIGH | 6 |
| MEDIUM | 5 |
| LOW | 1 |
| **Total** | **14** |

---

## Findings

### CRITICAL

#### C1. Unauthenticated MCP endpoint can execute actions without authorization

**Impact:** Any local process (and potentially browser-origin traffic due CORS) can invoke tools on a running Arbor node without an API key, capability checks, or taint enforcement.

**Evidence**
- `/mcp` bypasses gateway auth: `apps/arbor_gateway/lib/arbor/gateway/router.ex:22`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:61`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:63`
- MCP endpoint enables CORS: `apps/arbor_gateway/lib/arbor/gateway/router.ex:40`
- `arbor_run` documents optional `agent_id`: `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:95`, `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:98`
- Missing `agent_id` triggers unchecked execution: `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:261`, `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:264`
- Unchecked execution path exists by design: `apps/arbor_actions/lib/arbor_actions.ex:139`, `apps/arbor_actions/lib/arbor_actions.ex:146`

**Recommended fix**
1. Require authentication on `/mcp` (same API-key gate as other endpoints).
2. Require `agent_id` for `arbor_run`.
3. Remove unchecked execution path from MCP (`execute_action/3` call path).
4. Disable broad MCP CORS unless explicitly required and origin-allowlisted.

#### C2. MCP unchecked execution can reach dangerous actions (code load + filesystem)

**Impact:** The C1 path can execute privileged actions without capability or taint checks, including runtime code loading and unconstrained filesystem operations.

**Evidence**
- Hot code load compiles runtime source: `apps/arbor_actions/lib/arbor/actions/code.ex:450`
- File path validation is skipped without `:workspace` context: `apps/arbor_actions/lib/arbor/actions/file.ex:38`, `apps/arbor_actions/lib/arbor/actions/file.ex:40`
- MCP unchecked path passes empty context `%{}`: `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:264`

**Recommended fix**
1. Enforce authorized execution only (`authorize_and_execute/4`) for all remotely-triggerable actions.
2. For file actions, require an explicit workspace/root context on all external execution paths.
3. Treat `code_hot_load` as non-default/admin-only and block from remote endpoints unless strongly authenticated.

### HIGH

#### H1. Identity verification does not bind verified signer to authorized principal

**Impact:** A valid signed request from agent A can satisfy verification while authorizing principal B if caller-controlled IDs diverge.

**Evidence**
- Verification result agent ID is ignored: `apps/arbor_security/lib/arbor/security.ex:585`, `apps/arbor_security/lib/arbor/security.ex:586`

**Recommended fix**
- In `authorize/4`, enforce `verified_agent_id == principal_id` when verification is enabled.

#### H2. Unknown identities are treated as acceptable during authorization

**Impact:** Unregistered principal IDs are not rejected early, weakening identity gate semantics.

**Evidence**
- Not-found identity returns `:ok`: `apps/arbor_security/lib/arbor/security.ex:566`, `apps/arbor_security/lib/arbor/security.ex:569`

**Recommended fix**
- Fail closed on unknown identities in production/security mode.

#### H3. Executor still uses shadow-mode authorization and lacks sender auth on intents

**Impact:** Effective decision path still depends on `can?/3` capability-existence checks instead of full `authorize/4` pipeline; cast sender/source remains unauthenticated.

**Evidence**
- Shadow mode enabled: `apps/arbor_agent/lib/arbor/agent/executor.ex:33`
- Missing sender/source auth TODO: `apps/arbor_agent/lib/arbor/agent/executor.ex:172`, `apps/arbor_agent/lib/arbor/agent/executor.ex:175`
- Decision uses `can?/3` when shadow mode enabled: `apps/arbor_agent/lib/arbor/agent/executor.ex:614`, `apps/arbor_agent/lib/arbor/agent/executor.ex:618`

**Recommended fix**
1. Cut over to `authorize/4` as authoritative path.
2. Authorize intent source (`intent.source_agent`) before processing.

#### H4. Signals subscription auth uses `can?/3` (capability-only)

**Impact:** Subscription authorization omits identity verification, constraints, reflex checks, and escalation.

**Evidence**
- Capability-only adapter explicitly uses `can?/3`: `apps/arbor_signals/lib/arbor/signals/adapters/capability_authorizer.ex:6`, `apps/arbor_signals/lib/arbor/signals/adapters/capability_authorizer.ex:53`
- This adapter is default authorizer: `apps/arbor_signals/lib/arbor/signals/config.ex:19`, `apps/arbor_signals/lib/arbor/signals/config.ex:32`

**Recommended fix**
- Move restricted topics to full `authorize/4` path or equivalent hardened adapter.

#### H5. Executor computes sandbox level but does not enforce it on action execution

**Impact:** Trust-tier sandbox selection is currently informational for many act paths; actions are dispatched directly.

**Evidence**
- Sandbox level computed: `apps/arbor_agent/lib/arbor/agent/executor.ex:236`
- Action path ignores sandbox level and dispatches directly: `apps/arbor_agent/lib/arbor/agent/executor.ex:294`, `apps/arbor_agent/lib/arbor/agent/executor.ex:296`

**Recommended fix**
- Enforce sandbox/trust policy per action type before dispatch.

#### H6. Shell authorization path does not pass command/url context into reflex pipeline

**Impact:** Reflex checks that depend on command/URL context are weakened for shell facade calls.

**Evidence**
- Shell auth call omits opts/context: `apps/arbor_shell/lib/arbor/shell.ex:90`, `apps/arbor_shell/lib/arbor/shell.ex:115`, `apps/arbor_shell/lib/arbor/shell.ex:280`
- Reflex context builder expects `:command`/`:url` in opts: `apps/arbor_security/lib/arbor/security.ex:639`, `apps/arbor_security/lib/arbor/security.ex:655`

**Recommended fix**
- Pass command/url/path context into `Arbor.Security.authorize/4` opts for shell/web actions.

### MEDIUM

#### M1. Development eval endpoint remains compiled in dev/test and executes arbitrary code

**Evidence**
- Route mounted in dev/test builds: `apps/arbor_gateway/lib/arbor/gateway/router.ex:48`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:49`
- Endpoint evaluates request body with `Code.eval_string/1`: `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex:32`, `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex:142`

**Recommendation**
- Keep disabled by default and require explicit dev flag + local binding (current local check exists).

#### M2. Runtime `.env` loading trusts current working directory

**Evidence**
- Loads `.env` from `File.cwd!/0`: `config/runtime.exs:4`, `config/runtime.exs:6`

**Recommendation**
- Use fixed trusted path (for example `~/.arbor/.env`) in production/runtime contexts.

#### M3. Atom exhaustion risk in memory insight conversion

**Evidence**
- Dynamic `String.to_atom/1` in `safe_insight_atom/1`: `apps/arbor_memory/lib/arbor/memory.ex:2538`, `apps/arbor_memory/lib/arbor/memory.ex:2542`

**Recommendation**
- Replace with allowlist mapping or `String.to_existing_atom/1` + fallback string.

#### M4. Memory API still trusts caller-provided `agent_id` (cross-agent scope risk)

**Evidence**
- Explicit TODO notes body `agent_id` trust and missing caller binding: `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex:126`, `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex:128`

**Recommendation**
- Bind memory operations to authenticated principal/session identity.

#### M5. Consensus force admin check uses `can?/3` instead of full authorization

**Evidence**
- Force authorization path uses `can?/3`: `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:686`, `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:689`

**Recommendation**
- Use `authorize/4` for force operations.

### LOW

#### L1. MCP tests currently normalize no-`agent_id` execution behavior

**Evidence**
- `arbor_run` tests execute without `agent_id`: `apps/arbor_gateway/test/arbor/gateway/mcp/handler_test.exs:163`, `apps/arbor_gateway/test/arbor/gateway/mcp/handler_test.exs:165`

**Recommendation**
- Update tests to require authenticated principal + `agent_id` to avoid reintroducing C1/C2.

---

## Security Controls Confirmed Present

- Gateway API key auth plug exists for non-bypassed endpoints (`apps/arbor_gateway/lib/arbor/gateway/auth.ex:1`).
- Gateway default bind IP is loopback (`apps/arbor_gateway/lib/arbor/gateway/application.ex:20`).
- Shell execution uses `spawn_executable` + arg list (`apps/arbor_shell/lib/arbor/shell/executor.ex:50`, `apps/arbor_shell/lib/arbor/shell/executor.ex:93`).
- Shell sandbox blocks metacharacters at basic/strict (`apps/arbor_shell/lib/arbor/shell/sandbox.ex:24`, `apps/arbor_shell/lib/arbor/shell/sandbox.ex:68`, `apps/arbor_shell/lib/arbor/shell/sandbox.ex:85`).
- Code hot-load now validates AST before compile (`apps/arbor_actions/lib/arbor/actions/code.ex:432`, `apps/arbor_actions/lib/arbor/actions/code.ex:435`).

---

## Prioritized Remediation Plan

1. **Close C1/C2 immediately**
   - Authenticate `/mcp`, require `agent_id`, remove unchecked execution path.
2. **Finalize identity enforcement**
   - Bind signed request identity to principal; fail unknown identity in security mode.
3. **Cut over runtime authorization paths**
   - Executor + consensus force + restricted signal subscriptions to full `authorize/4`.
4. **Enforce trust-tier sandboxing at execution time**
   - Ensure computed sandbox level actually gates action dispatch.
5. **Clean residual medium issues**
   - CWD `.env`, `String.to_atom`, memory agent scoping, dev eval operational hardening.

---

## Notes For Current Cleanup Work

- Removing `/api/bridge` and `/api/signals` is still worthwhile and lowers risk.
- After removing those routes, the highest-risk remaining surface is still `/mcp` until C1/C2 are fixed.
