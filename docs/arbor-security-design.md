# Arbor Security Design: Current State and Delta Register

> Updated: 2026-02-15  
> Scope: `/Users/azmaveth/code/trust-arbor/arbor` current implementation  
> Purpose: capture what security design intends, what code currently does, and what must change in implementation vs design.

---

## 1. Security Intent (Target Design)

Arbor is evolving toward a personal agent that can extend itself (including self-modification) without unsafe default behavior. The intended security model is:

1. **All external execution entrypoints are authenticated and attributable.**
2. **All sensitive operations flow through a single full authorization pipeline** (identity verification, capability checks, constraints, reflexes, escalation, auditing).
3. **Action execution is capability-gated and taint-aware by default**; unchecked/system paths are narrowly scoped and never exposed externally.
4. **Trust tier and sandbox level are enforced at execution time**, not just computed/logged.
5. **Self-modifying operations are explicit high-risk capabilities** and never anonymously triggerable.

This document compares that intent with current code.

---

## 2. Current Security Architecture (Implemented)

### 2.1 Ingress Surfaces

| Surface | Current State | Evidence |
|---|---|---|
| `GET /health` | Unauthenticated (expected) | `apps/arbor_gateway/lib/arbor/gateway/router.ex:27` |
| `POST /mcp` | Unauthenticated, CORS enabled | `apps/arbor_gateway/lib/arbor/gateway/router.ex:34`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:40`, `apps/arbor_gateway/lib/arbor/gateway/router.ex:61` |
| `/api/bridge` | Routed; behind gateway auth (unless removed) | `apps/arbor_gateway/lib/arbor/gateway/router.ex:44`, `apps/arbor_gateway/lib/arbor/gateway/auth.ex:20` |
| `/api/memory` | Routed; behind gateway auth | `apps/arbor_gateway/lib/arbor/gateway/router.ex:45`, `apps/arbor_gateway/lib/arbor/gateway/auth.ex:20` |
| `/api/signals` | Routed; behind gateway auth (unless removed) | `apps/arbor_gateway/lib/arbor/gateway/router.ex:46`, `apps/arbor_gateway/lib/arbor/gateway/auth.ex:20` |
| `/api/dev` | Mounted in `:dev`/`:test`; localhost check in router | `apps/arbor_gateway/lib/arbor/gateway/router.ex:48`, `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex:33`, `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex:131` |

### 2.2 Authorization Pipeline

`Arbor.Security.authorize/4` currently executes:

1. Reflex checks (`check_reflexes`)  
2. Identity status check (`check_identity_status`)  
3. Optional signed-request verification (`maybe_verify_identity`)  
4. Capability lookup (`find_capability`)  
5. Constraint enforcement (`maybe_enforce_constraints`)  
6. Escalation (`Escalation.maybe_escalate`)

Evidence: `apps/arbor_security/lib/arbor/security.ex:303`, `apps/arbor_security/lib/arbor/security.ex:311`

Important caveats in current implementation:
- Unknown identity currently allowed to proceed: `apps/arbor_security/lib/arbor/security.ex:566`.
- Signed request verification does not bind signer to `principal_id`: `apps/arbor_security/lib/arbor/security.ex:585`, `apps/arbor_security/lib/arbor/security.ex:586`.
- `can?/3` remains available and explicitly bypasses full checks: `apps/arbor_security/lib/arbor/security.ex:332`, `apps/arbor_security/lib/arbor/security.ex:338`.

### 2.3 Action Execution Paths

| Path | Auth | Taint | Notes |
|---|---|---|---|
| `Arbor.Actions.authorize_and_execute/4` | Yes (`authorize/4`) | Yes | `apps/arbor_actions/lib/arbor_actions.ex:113`, `apps/arbor_actions/lib/arbor_actions.ex:120` |
| `Arbor.Actions.execute_action/3` | No | No | Explicitly unchecked: `apps/arbor_actions/lib/arbor_actions.ex:139`, `apps/arbor_actions/lib/arbor_actions.ex:146` |
| MCP `arbor_run` with `agent_id` | Yes (via `authorize_and_execute`) | Yes | `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:262` |
| MCP `arbor_run` without `agent_id` | No (via `execute_action`) | No | `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:263`, `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:264` |

### 2.4 Self-Modification and Code Execution

- `code_hot_load` validates AST then compiles source into running VM:
  - validation: `apps/arbor_actions/lib/arbor/actions/code.ex:432`, `apps/arbor_actions/lib/arbor/actions/code.ex:435`
  - compile/load: `apps/arbor_actions/lib/arbor/actions/code.ex:450`
- Security of this action currently depends on entering through authorized path. If reached via unchecked path (MCP no-agent flow), capability/taint controls are bypassed.

### 2.5 Filesystem and Shell Guardrails

- File actions only enforce workspace boundary when `context[:workspace]` exists:
  - `apps/arbor_actions/lib/arbor/actions/file.ex:38`, `apps/arbor_actions/lib/arbor/actions/file.ex:40`
- Shell execution has strong low-level hardening:
  - `spawn_executable`/args path: `apps/arbor_shell/lib/arbor/shell/executor.ex:50`, `apps/arbor_shell/lib/arbor/shell/executor.ex:93`
  - metacharacter blocking: `apps/arbor_shell/lib/arbor/shell/sandbox.ex:24`, `apps/arbor_shell/lib/arbor/shell/sandbox.ex:68`
- Shell authorization calls currently do not pass command/url context into reflex opts:
  - caller side: `apps/arbor_shell/lib/arbor/shell.ex:90`
  - reflex context expects opts: `apps/arbor_security/lib/arbor/security.ex:639`, `apps/arbor_security/lib/arbor/security.ex:655`

### 2.6 Executor and Signals

- Executor runs in shadow mode (decision driven by `can?/3` when enabled): `apps/arbor_agent/lib/arbor/agent/executor.ex:33`, `apps/arbor_agent/lib/arbor/agent/executor.ex:618`.
- Intent source authorization is still TODO: `apps/arbor_agent/lib/arbor/agent/executor.ex:172`, `apps/arbor_agent/lib/arbor/agent/executor.ex:175`.
- Sandbox level is computed but not strongly enforced in dispatch path:
  - computed: `apps/arbor_agent/lib/arbor/agent/executor.ex:236`
  - action dispatch path: `apps/arbor_agent/lib/arbor/agent/executor.ex:294`, `apps/arbor_agent/lib/arbor/agent/executor.ex:296`
- Signals subscription default authorizer is capability-only (`can?/3`): `apps/arbor_signals/lib/arbor/signals/config.ex:19`, `apps/arbor_signals/lib/arbor/signals/adapters/capability_authorizer.ex:53`

---

## 3. Intended vs Actual: Delta Register

| ID | Control Area | Intended Design | Current Implementation | Risk | Disposition |
|---|---|---|---|---|---|
| D1 | External ingress auth | All external execution surfaces authenticated | `/mcp` bypasses auth and enables CORS | Critical | **Change implementation** |
| D2 | Unified authorization path | External action execution always uses `authorize/4` + taint | MCP allows unchecked `execute_action/3` when no `agent_id` | Critical | **Change implementation** |
| D3 | Identity binding | Verified signer must match authorized principal | `maybe_verify_identity/1` ignores verified agent_id | High | **Change implementation** |
| D4 | Unknown identity behavior | Unknown principals rejected in hardened mode | `:not_found` identity returns `:ok` | High | **Change implementation** |
| D5 | Executor decision authority | Runtime enforcement uses full `authorize/4` pipeline | Shadow mode still applies `can?/3` as effective gate | High | **Change implementation** |
| D6 | Intent provenance | Intent sender/source capability-checked before execution | Explicit TODO; currently accepts cast intent | High | **Change implementation** |
| D7 | Trust-tier sandboxing | Sandbox level actually constrains action execution | Level computed, dispatch mostly unconstrained | High | **Change implementation** |
| D8 | Reflex context completeness | Security reflexes see command/path/url context for relevant ops | Shell auth calls omit contextual opts | High | **Change implementation** |
| D9 | Atom safety | Untrusted strings never create new atoms | `safe_insight_atom/1` uses `String.to_atom/1` | Medium | **Change implementation** |
| D10 | Principal scoping | Authenticated caller bound to target `agent_id` | Memory router trusts body `agent_id` with TODO | Medium | **Change implementation** |
| D11 | Dev-code execution exposure | Unsafe dev endpoints never reachable outside explicit dev workflows | Dev eval still exists in dev/test (localhost-guarded) | Medium | **Design choice + operational hardening** |
| D12 | Runtime secret loading | Trusted config source, not cwd-dependent | `.env` loaded from current working directory | Medium | **Change implementation** |

---

## 4. Decisions Needed (Implementation vs Design)

### 4.1 Keep MCP as an external surface, or make it local-internal only?

- If MCP stays: require API-key (or stronger) auth, require `agent_id`, and route only through authorized action execution.
- If MCP becomes internal-only: bind to private transport and remove CORS entirely.

### 4.2 Keep unchecked execution APIs?

- Current design keeps `Arbor.Actions.execute_action/3` for trusted system callers.
- This is acceptable only if unreachable from any external/agent-controlled path.
- Decision: either keep but enforce strict call graph boundaries, or remove and replace with explicit privileged wrapper.

### 4.3 Identity rollout policy

- `identity_verification` defaults to true in security config (`apps/arbor_security/lib/arbor/security/config.ex:26`) but is disabled in dev/test (`config/dev.exs:45`, `config/test.exs:24`).
- Decide whether local development should remain permissive or move to signed-request-by-default with bootstrap tooling.

### 4.4 Self-modification policy

For a self-extending agent, design intent should explicitly split:

1. **Low-risk evolution:** `compile_and_test` in worktree/sandbox.  
2. **High-risk evolution:** `code_hot_load` behind elevated capability + explicit approval/escalation.  
3. **No anonymous runtime mutation:** never reachable via unauthenticated endpoint.

---

## 5. Immediate Hardening Baseline (Recommended)

### P0 (must fix before trusting autonomous/self-modifying flows)

1. Fix D1 + D2 (`/mcp` auth + no unchecked execution path).
2. Fix D3 + D4 (identity signer-principal binding + fail-closed unknown identities in hardened mode).
3. Fix D5 + D6 (executor full auth cutover + source-agent check).

### P1 (next)

1. Fix D7 (enforce sandbox/trust tier at action dispatch time).
2. Fix D8 (include command/url/path context in authorization calls).
3. Fix D9 + D10 (`String.to_atom` removal + memory API principal binding).

### P2 (operational tightening)

1. Fix D12 (`.env` trusted path).
2. Re-evaluate D11 dev endpoint policy; keep explicit off-switch and strict localhost-only behavior.

---

## 6. What Removing Bridge/Signals Routers Changes

If `/api/bridge` and `/api/signals` are removed:

- **Improves:** reduces legacy external Claude integration surface.
- **Does not fix:** current critical chain in `/mcp` (D1/D2).
- **Still remaining core work:** identity verification binding, executor hardening, and sandbox enforcement.

So the remaining priority set is not only "identity verification + executor + sandbox"; `/mcp` ingress hardening is first-class and should be treated as blocking.

---

## 7. Verification Checklist (post-remediation)

- `/mcp` returns `401`/`403` without valid auth.
- `arbor_run` rejects missing `agent_id`.
- No externally reachable path calls `Arbor.Actions.execute_action/3`.
- `authorize/4` fails when signed request agent does not equal principal.
- Unknown identity fails closed in hardened mode.
- Executor logs show no shadow divergence because `authorize/4` is authoritative.
- Intent source authorization enforced before `process_intent/2`.
- `safe_insight_atom/1` no longer creates atoms dynamically.

