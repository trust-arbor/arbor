# Arbor Security Architecture Audit

- **Date:** 2026-05-31
- **Auditor:** Codex
- **Scope:** Project-wide security design review across `arbor_dashboard`, `arbor_gateway`, `arbor_security`, `arbor_actions`, `arbor_orchestrator`, `arbor_agent`, `arbor_memory`, `arbor_signals`, `arbor_shell`, `arbor_consensus`, and selected persistence/trust integration paths.

This supersedes the 2026-05-16 kernel-only audit. The prior review focused on `arbor_security`; this review focuses on end-to-end trust boundaries, security architecture, and places where fail-closed behavior is brittle enough to break normal workflows.

This was a static code review. No tests were run as part of this audit.

---

## Executive Summary

Arbor has a strong security concept: capability-based authorization, Ed25519 identities, trust-tier policy, reflex checks, taint metadata, and explicit agent autonomy boundaries. The core `Arbor.Security.authorize/4` and `AuthDecision.evaluate/4` shape is a good foundation.

The main risk is that the security model is not enforced consistently across the system. Some entry points authenticate a caller but then lose the proof before downstream authorization. Some sub-facades skip identity verification because they assume an upstream layer already handled it. Some routers authorize the target resource owner instead of the caller. Several "mandatory" controls can be disabled by untrusted graph input. Multiple subsystems fail open when the security service or registry is unavailable.

The result is a system that is both less secure than intended and more brittle than intended:

- Real authorization bypasses exist around dashboard access, orchestrator middleware, memory/status APIs, channel keys, and hardcoded agent actions.
- Legitimate calls can fail unexpectedly when signed-request verification is required but the verified request is not threaded through.
- Several security boundaries are implemented as conventions or filters rather than as enforceable capabilities or isolation primitives.

---

## Highest-Priority Findings

### P0-1. Dashboard can be open in production

- **Severity:** Critical
- **Area:** `arbor_dashboard`

`Arbor.Dashboard.Endpoint` only plugs `Arbor.Dashboard.OidcAuth`. `OidcAuth` returns the connection unchanged when no OIDC provider is configured. Production sets `config :arbor_dashboard, require_auth: true`, but that flag is not checked by `OidcAuth`.

Relevant files:

- `apps/arbor_dashboard/lib/arbor_dashboard/endpoint.ex`
- `apps/arbor_dashboard/lib/arbor_dashboard/oidc_auth.ex`
- `config/runtime.exs`

Impact:

- A production deployment without OIDC configured can expose the dashboard without authentication.
- Dashboard LiveViews can inspect memory, capabilities, signals, events, agents, and can stop/delete agents through direct calls.

Recommendation:

- Make dashboard startup fail in production unless an auth provider is configured.
- If `require_auth: true` and OIDC is absent, return `503` or redirect to a hard error page, not open access.
- Either remove the unused BasicAuth path or explicitly plug it as fallback when OIDC is absent and credentials are configured.
- Add a production-mode test that proves unauthenticated dashboard requests are denied when OIDC is missing.

### P0-2. Orchestrator "mandatory" middleware is removable by graph input

- **Severity:** Critical
- **Area:** `arbor_orchestrator`

`Arbor.Orchestrator.Middleware.Chain` prepends mandatory middleware, then removes any middleware listed in node-level `skip_middleware`. Tests currently assert that `skip_middleware` removes `CapabilityCheck` and `TaintCheck`.

Relevant files:

- `apps/arbor_orchestrator/lib/arbor/orchestrator/middleware/chain.ex`
- `apps/arbor_orchestrator/test/arbor/orchestrator/middleware/mandatory_middleware_test.exs`

Impact:

- A DOT graph can disable capability checks, taint checks, safe-input checks, budget checks, and signal emission for a node.
- This directly contradicts the term "mandatory" and makes graph input part of the trusted computing base.

Recommendation:

- Split middleware into `mandatory` and `optional` chains.
- Only allow `skip_middleware` to affect optional middleware.
- If debugging bypasses are required, gate them behind an out-of-band trusted option, not graph attrs.
- Add regression tests proving graph-authored `skip_middleware` cannot remove mandatory security controls.

### P0-3. Composite orchestrator handlers bypass per-node authorization

- **Severity:** Critical
- **Area:** `arbor_orchestrator`

Some handlers execute other handlers internally without re-entering `Engine.Authorization` or middleware:

- `MapHandler` builds a child node, resolves its handler, then calls `handler_module.execute/4` directly.
- `PipelineRunHandler` and `SubgraphHandler` call `Arbor.Orchestrator.run/2` for child graphs, but strip auth options such as `:authorization`, `:authorizer`, and `:signer`.
- `pipeline.run` requires no capability in `HandlerSchema`.

Relevant files:

- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/map_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/pipeline_run_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/subgraph_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/ir/handler_schema.ex`

Impact:

- A graph can wrap dangerous behavior in a composition primitive and bypass the per-node authorization model.
- Child pipelines can fail closed unexpectedly because the signed/auth context is dropped.

Recommendation:

- Require all nested handler execution to go through the same authorization and middleware entry point as top-level nodes.
- Preserve auth options across child graph execution.
- Give `pipeline.run`, `graph.invoke`, and `graph.compose` explicit capabilities.
- Decide whether child graphs inherit parent trust context, require their own graph capability, or both.

### P0-4. Memory and status endpoints allow cross-agent data access

- **Severity:** Critical
- **Area:** `arbor_gateway`, `arbor_memory`

The memory router authorizes the requested `agent_id` as the principal, rather than the authenticated caller. It also allows access on unexpected authorization results, missing security modules, and rescue paths.

The MCP `arbor_status` tool accepts a caller-supplied `agent_id`, or defaults to the first known agent, then reads memory, capabilities, and goals directly.

Relevant files:

- `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex`
- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex`
- `apps/arbor_memory/lib/arbor/memory.ex`

Impact:

- An authenticated gateway caller can query or modify another agent's memory if they know or can guess the target ID.
- Omission of `agent_id` can leak data from the first running agent.

Recommendation:

- Every gateway sub-router should derive `caller_id` from `conn.assigns.agent_id` or verified session context.
- Authorize `caller_id` against `arbor://memory/{read|write}/{target_agent_id}`.
- Use `Arbor.Memory.authorize_*` APIs from the router instead of direct `Memory.recall`, `Memory.index`, or `Memory.load_working_memory`.
- Remove fail-open rescue paths. Unexpected authorization results should deny.
- Gate `arbor_status` by component-specific capabilities and require explicit target authorization.

### P0-5. System authority private key is persisted plaintext and silently rotates on load errors

- **Severity:** Critical
- **Area:** `arbor_security`

`SystemAuthority.persist_keypair/1` serializes the authority private key as base64 and writes it to the signing key store backend as plain record data. This bypasses `SigningKeyStore`, which otherwise provides AES-GCM encryption for private keys.

If persisted keypair loading returns an error, `SystemAuthority` logs a warning and generates a new persistent keypair. That silently rotates the trust root.

Relevant files:

- `apps/arbor_security/lib/arbor/security/system_authority.ex`
- `apps/arbor_security/lib/arbor/security/signing_key_store.ex`

Impact:

- Compromise of the backing store compromises the system signing authority.
- A transient persistence or decode failure can invalidate capabilities, receipts, endorsements, and any state tied to the previous authority key.

Recommendation:

- Store the system authority key through `SigningKeyStore` or an equivalent encrypted key-manager API.
- Treat authority-key load errors as fatal unless an explicit recovery command is being run.
- Add a supervised recovery procedure for planned authority rotation.
- Add tests proving the persisted record does not contain `private_key` material in plaintext/base64 form.

---

## High-Severity Findings

### H1. Signed request proof is lost between gateway auth and action auth

- **Area:** `arbor_gateway`, `arbor_actions`, `arbor_security`

`SignedRequestAuth` verifies the request and stores only `agent_id` in Plug assigns and the process dictionary. MCP action execution later calls `Arbor.Actions.authorize_and_execute/4` with no `signed_request`. `Arbor.Actions` only sets `verify_identity: true` when a signed request is present; otherwise it falls back to global identity-verification config. In dev/prod, identity verification is enabled, so this path can fail with `:missing_signed_request`.

Relevant files:

- `apps/arbor_gateway/lib/arbor/gateway/signed_request_auth.ex`
- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex`
- `apps/arbor_actions/lib/arbor_actions.ex`
- `apps/arbor_security/lib/arbor/security/auth_decision.ex`

Security/design issue:

- Transport authentication and resource authorization are conflated.
- Verified identity is not represented as durable request context.

Brittleness:

- Correctly signed MCP requests can be authenticated at the HTTP layer and then fail at action authorization.

Recommendation:

- Introduce a first-class `AuthContext` at the gateway boundary that includes caller, verified identity status, signed request metadata, session token, tenant, and transport proof.
- Thread this context through ExMCP handlers, actions, and facade calls.
- Do not use the process dictionary as the security handoff.
- Separate "the HTTP request was signed" from "this resource operation is authorized."

### H2. FileGuard does not protect against symlink escapes

- **Area:** `arbor_security`, `arbor_common`

`FileGuard` claims symlinks are followed and verified to stay within bounds, but it uses `SafePath.resolve_within/2`, which relies on normalization and explicitly does not follow symlinks. `SafePath.resolve_real/1` exists but is not used in FileGuard.

Relevant files:

- `apps/arbor_security/lib/arbor/security/file_guard.ex`
- `apps/arbor_common/lib/arbor/common/safe_path.ex`

Impact:

- A symlink inside an authorized workspace can point outside the workspace.
- File operations following that symlink can access paths that authorization did not intend to allow.

Recommendation:

- Use realpath-based validation for existing read/execute targets.
- For writes to new files, validate the real parent directory and use no-follow/openat-style semantics where available.
- Add regression tests for symlink-to-`/etc`, symlink-to-parent, and symlink replacement races.

### H3. Shell sandbox is a command filter, not isolation

- **Area:** `arbor_shell`, `arbor_orchestrator`

`Arbor.Shell.Sandbox` blocks some command names, flags, and metacharacters. It does not provide OS containment. `strict` allowlists command names but not safe argument forms. `ToolHandler` bypasses `Arbor.Shell` and runs `System.cmd` directly.

Relevant files:

- `apps/arbor_shell/lib/arbor/shell/sandbox.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/tool_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/shell_handler.ex`

Impact:

- Commands such as `find` can execute destructive or unexpected behavior via arguments.
- `basic` mode leaves broad interpreter and tool surfaces available.
- Orchestrator tool execution is not subject to the same sandbox path.

Recommendation:

- Treat current sandbox levels as advisory filters, not security boundaries.
- Route all command execution through one audited execution service.
- Implement real containment for untrusted commands: container, chroot/sandbox-exec, user namespace, seccomp, or equivalent for the target platform.
- Add per-command argument policies for any allowlisted host command.

### H4. Signals channel security trusts asserted agent IDs

- **Area:** `arbor_signals`

Channel APIs accept `agent_id` strings as authority. `Channels.get_key/2` returns the raw channel key if the supplied ID is a member. The signal bus decrypts channel payloads using `signal.source`, not the subscriber identity. Channel topics are not part of the restricted-topic authorization model by default.

Relevant files:

- `apps/arbor_signals/lib/arbor/signals/channels.ex`
- `apps/arbor_signals/lib/arbor/signals/bus.ex`
- `apps/arbor_signals/lib/arbor/signals/adapters/capability_authorizer.ex`

Impact:

- Any code path that can call the channel API can request keys or perform operations by asserting a member ID.
- Subscribers to broad channel topics can receive decrypted payloads based on sender membership rather than recipient authorization.

Recommendation:

- Require an authenticated caller context for channel create/invite/send/read/key operations.
- Never return raw symmetric channel keys from a public GenServer API based only on an ID string.
- Decrypt per recipient/subscriber authorization, not per sender.
- Add channel topics to restricted authorization or create a separate channel membership authorizer.

### H5. AuthDecision has fail-open fallback paths

- **Area:** `arbor_security`

`AuthDecision` treats all `human_` principals as active without checking registry status. Identity registry failures rescue to allow. CapabilityStore outages fall back to preloaded capabilities that have not been signature-verified.

Relevant file:

- `apps/arbor_security/lib/arbor/security/auth_decision.ex`

Impact:

- Suspended or revoked human identities can continue to authorize if their capabilities remain present.
- Transient registry/store failures can change the trust basis from verified store state to caller-provided/preloaded state.

Recommendation:

- Require registry status checks for human identities.
- In strict/production mode, registry failure should deny.
- Remove unsigned preloaded capability fallback in production.
- If a fallback cache is needed, maintain a signed and verified in-memory mirror owned by the security subsystem.

### H6. Several facade authorization layers fail open when Security is unavailable

- **Area:** `arbor_memory`, `arbor_consensus`, `arbor_agent`

Facade-level authorization helpers permit when the security module or CapabilityStore is unavailable. Some also treat `{:ok, :pending_approval, _}` as effectively allowed.

Relevant files:

- `apps/arbor_memory/lib/arbor/memory.ex`
- `apps/arbor_consensus/lib/arbor/consensus.ex`
- `apps/arbor_agent/lib/arbor/agent.ex`

Impact:

- Partial outages can silently weaken authorization.
- Unit-test accommodations have become runtime behavior.

Recommendation:

- Move test-only permissive behavior behind explicit `Mix.env() == :test` or injectable test authorizers.
- Production/dev should fail closed unless an operation is explicitly marked system-internal and not reachable from user or agent input.
- Normalize pending approval handling: pending is not authorized.

### H7. Agent hardcoded actions bypass the action authorization path

- **Area:** `arbor_agent`, `arbor_actions`

Generic discovered actions are routed through `Arbor.Actions.authorize_and_execute/4`, but hardcoded actions such as proposal submission, code hot-load, and background checks call action modules directly through `run_runtime_action/4`.

Relevant file:

- `apps/arbor_agent/lib/arbor/agent/executor/action_dispatch.ex`

Impact:

- Dangerous action paths can bypass action-layer taint enforcement, resource binding, invocation receipts, and facade-level checks.
- The earlier `Executor.check_capabilities/2` check may use fallback URIs for hardcoded actions, so policy can diverge from actual action requirements.

Recommendation:

- Route all actions, including hardcoded compound actions, through `Arbor.Actions.authorize_and_execute/4`.
- If an action truly must be internal, mark it as internal-only and make it unreachable from external or LLM-produced intents.
- Add tests for `code_hot_load`, `proposal_submit`, and `background_checks_run` proving action-layer auth and taint checks run.

### H8. Claude bridge URI matching is brittle

- **Area:** `arbor_gateway`, `arbor_security`

Claude session default filesystem capabilities end with `/`, but `CapabilityStore` prefix matching appends another `/`, so `arbor://fs/read/` does not reliably match `arbor://fs/read/path`. The bridge also calls `Security.authorize/3` without signed request context, which conflicts with identity verification when enabled.

Relevant files:

- `apps/arbor_gateway/lib/arbor/gateway/bridge/claude_session.ex`
- `apps/arbor_security/lib/arbor/security/capability_store.ex`

Impact:

- Legitimate Claude Code tool calls can be denied despite apparently correct default capabilities.
- Shell URI construction and matching can diverge due to command/path/query formatting.

Recommendation:

- Centralize URI construction and matching in one module.
- Replace trailing-slash prefix semantics with explicit `/**` wildcards or structured URI resources.
- Pass authenticated context into bridge authorization or explicitly mark the bridge as identity-verified at session creation.

---

## Medium-Severity Findings

### M1. OIDC grants admin by default and LiveViews do not consistently enforce tenant scope

- **Area:** `arbor_dashboard`, `arbor_security`

OIDC login loads or creates a human identity and assigns a default role of `:admin` if none is configured. LiveViews receive a `tenant_context`, but many operations still directly inspect arbitrary agent IDs from URL params or UI events.

Relevant files:

- `apps/arbor_dashboard/lib/arbor_dashboard/oidc_auth.ex`
- `apps/arbor_dashboard/lib/arbor_dashboard/nav.ex`
- `apps/arbor_dashboard/lib/arbor_dashboard/live/memory_live.ex`
- `apps/arbor_dashboard/lib/arbor_dashboard/live/agents_live.ex`

Recommendation:

- Default OIDC role should be least privilege.
- Every LiveView action should authorize `current_agent_id` against the target resource.
- Tenant context should be enforced in data-loading functions, not merely assigned for display.

### M2. Taint enforcement is audit-only by default

- **Area:** `arbor_actions`, `arbor_orchestrator`

`config :arbor_actions, default_taint_policy: :audit_only` logs violations but permits execution. Orchestrator taint checks are also skippable through `skip_middleware`.

Relevant files:

- `config/config.exs`
- `apps/arbor_actions/lib/arbor/actions/taint_enforcement.ex`
- `apps/arbor_actions/lib/arbor_actions.ex`

Recommendation:

- Use `:strict` for production or for any externally influenced action parameters.
- Keep audit-only only for migration or evaluation mode.
- Add a runtime metric/alarm for taint violations even if audit-only remains available.

### M3. Unknown orchestrator types are permissive and may default to LLM behavior

- **Area:** `arbor_orchestrator`

Unknown handler schemas require no attrs, no capabilities, and default to public classification. Registry lookup can fall back to `LlmHandler`.

Relevant files:

- `apps/arbor_orchestrator/lib/arbor/orchestrator/ir/handler_schema.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/registry.ex`

Recommendation:

- Unknown node types should be validation errors for untrusted graphs.
- If extensibility is required, custom handlers should register schemas and capabilities explicitly.

### M4. Gateway API key handling is weaker than the rest of the auth model

- **Area:** `arbor_gateway`

The API key plug accepts a query parameter token and compares the configured key with pattern matching rather than constant-time comparison.

Relevant file:

- `apps/arbor_gateway/lib/arbor/gateway/auth.ex`

Recommendation:

- Remove query-param API key support for production.
- Use constant-time comparison.
- Prefer signed request or OIDC JWT flows for all non-health endpoints.

---

## Design Themes

### Security context is fragmented

The project currently passes identity through a mix of:

- Plug assigns
- Process dictionary entries
- `context` maps
- `AuthContext`
- session tokens
- signed request structs
- raw `agent_id` strings

This creates both bypasses and brittle denials. The security boundary should be represented by one explicit context object created at the trust boundary and threaded through every downstream call.

### "Facade-level auth" often assumes upstream verification

Several facades call `Security.authorize(..., verify_identity: false)` because they assume action-layer identity verification already happened. That is valid only if the verified auth context is passed along and cannot be spoofed. Today, many calls pass only `agent_id`, so the assumption is not enforceable.

### Fail-closed and fail-open are both present

Examples of fail-open behavior:

- Dashboard open when OIDC is missing.
- Memory/consensus/agent facades permit when security is unavailable.
- AuthDecision permits on identity registry rescue.
- CapabilityStore outage can use unsigned preloaded capabilities.

Examples of brittle fail-closed behavior:

- Signed gateway requests fail later because the signed request is not passed to action auth.
- Claude bridge capabilities appear correct but do not match actual URI semantics.
- Child orchestrator pipelines drop auth options and then fail unexpectedly.
- System authority load failures silently rotate trust root instead of stopping with a clear recovery path.

### URI authorization is too ad hoc

Several subsystems build resource URIs manually. Matching semantics differ by module and depend on trailing slashes, `/**`, query strings, action encoded in path, or facade-specific canonicalization. This creates authorization bypass risk and false denials.

---

## Additional Findings from Independent Validation (2026-06-02)

During code-level validation of this audit, the following issues were identified that were either missed entirely or under-emphasized. They are presented in the same format as the original findings for consistency.

### H9. Additional unsafe `String.to_atom` fallbacks in job and agent spec paths

- **Severity:** High
- **Area:** `arbor_orchestrator`, `arbor_agent`

Two new sites follow the `String.to_existing_atom/1` rescue → `String.to_atom/1` pattern on data that can be influenced by persisted job records, DOT graph node names, or agent specs (which may originate from untrusted LLM output or restored seeds):

- `apps/arbor_orchestrator/lib/arbor/orchestrator/job_registry.ex:381-385`
- `apps/arbor_agent/lib/arbor/agent/spec.ex:393-398`

This is the same atom-exhaustion class as the February 2026 H4/H5 findings (which were reported as remediated via `SafeAtom`).

**Impact:**
- An attacker who can inject or persist job metadata or influence agent specs can exhaust the atom table, crashing the node.
- The fallback path makes the "safe" conversion unsafe under adversarial input.

**Recommendation:**
- Replace both sites with `SafeAtom.to_existing/1` (returning an error or safe default on unknown atoms).
- Add property-based tests that feed arbitrary binary node names and spec strings.
- Run a project-wide search for the `to_existing_atom` + `to_atom` rescue pattern and eliminate remaining instances.

**Relevant files:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/job_registry.ex`
- `apps/arbor_agent/lib/arbor/agent/spec.ex`
- `apps/arbor_common/lib/arbor/common/safe_atom.ex` (for the correct helper)

### H10. Second raw `System.cmd` execution path in tool hooks (bypasses sandbox)

- **Severity:** High
- **Area:** `arbor_orchestrator`

In addition to the `ToolHandler` direct `System.cmd` already noted in H3, `ToolHooks` performs another unsandboxed execution:

- `apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex:123` — `System.cmd("/bin/sh", ["-lc", wrapped], ...)`

This path is reachable from any `tool` node that declares pre/post hooks.

**Impact:**
- When combined with P0-2 (graph-authored `skip_middleware`), a DOT pipeline can completely bypass the declared `Arbor.Shell.Sandbox` and the orchestrator's declared command filtering.
- Gives untrusted graph input a second, independent route to arbitrary host command execution.

**Recommendation:**
- Consolidate **all** host command execution (ToolHandler + ShellHandler + ToolHooks) into a single audited execution service.
- Apply the same capability, sandbox level, and argument policy checks to hook commands as to explicit `shell` nodes.
- Add a regression test proving that hook execution respects the current sandbox configuration (or fails closed when sandboxing is required).

**Relevant files:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/tool_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/shell_handler.ex`

### M8. `arbor_status` MCP tool leaks first-agent data with no caller authorization

- **Severity:** Medium
- **Area:** `arbor_gateway`

Even when the caller supplies no `agent_id`, several `arbor_status` components default to `find_first_agent_id()` and return sensitive data:

- `memory`, `capabilities`, `goals` components
- `overview` and `get_memory_summary` paths

The `authenticated_agent_id/0` helper (populated by `SignedRequestAuth` via the process dictionary) exists but is **never consulted** by the status handlers.

This amplifies P0-4 (cross-agent data access via the MCP bridge).

**Impact:**
- Any authenticated MCP client (including low-trust or compromised agents) can enumerate and dump working memory, goals, and capabilities of whichever agent happens to be first in the registry.
- No authorization gate stands between the MCP tool and cross-agent memory/goal leakage.

**Recommendation:**
- Require an explicit, authorized target `agent_id` for every component of `arbor_status` that returns agent-specific data.
- Default to denial (or a minimal non-sensitive overview) rather than "first running agent."
- Use the authenticated caller identity from the gateway context instead of (or in addition to) the process-dictionary value.

**Relevant files:**
- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex` (especially `get_status/2`, `find_first_agent_id/0`, and the memory/goals/capabilities helpers)

### H11. OIDC automatically grants administrative consensus rights to all users

- **Severity:** Critical
- **Area:** `arbor_dashboard`, `arbor_security`

The `ensure_role` function in `OidcAuth` automatically grants the `arbor://consensus/admin` capability to any user who logs in via OIDC.

**Impact:**
- Every authenticated OIDC user, regardless of their intended role or organization membership, gains the ability to `force_approve` or `force_reject` any proposal in the system.
- This effectively collapses the multi-perspective consensus model into a single-operator model where any human user is a root administrator.

**Recommendation:**
- Remove the automatic grant of administrative capabilities in the OIDC login flow.
- Implement a proper role-to-capability mapping that respects the principle of least privilege.
- Require explicit authorization for the `arbor://consensus/admin` resource.

**Relevant files:**
- `apps/arbor_dashboard/lib/arbor_dashboard/oidc_auth.ex`

### H12. Hardcoded authorization bypass for "human_" identities in Consensus

- **Severity:** Critical
- **Area:** `arbor_consensus`

The Consensus Coordinator contains a hardcoded bypass that authorizes any operation if the `actor_id` starts with `human_`.

**Impact:**
- This bypasses all capability-based security checks for human users.
- Combined with H11, it ensures that any OIDC user (whose ID starts with `human_`) can perform any administrative action without a valid capability being verified by the `AuthDecision` engine.
- It makes the security model advisory rather than enforceable for human actors.

**Recommendation:**
- Remove the `String.starts_with?(actor_id, "human_")` check from the Coordinator.
- Ensure that human identities are subject to the same capability-based authorization as agents.

**Relevant files:**
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex`

### H13. "Always Allow" in dashboard permits permanent unvetted capability grants

- **Severity:** High
- **Area:** `arbor_dashboard`, `arbor_trust`

The `always-allow-proposal` event in `ConsensusLive` allows a user to approve a proposal and simultaneously update the agent's trust profile to `:auto` for the requested resource.

**Impact:**
- Because of H11 and H12, any OIDC user can permanently grant an agent unrestricted access to critical resources (like `arbor://shell/execute` or `arbor://fs/write/**`) with a single click.
- There is no secondary confirmation or policy check for these permanent trust profile mutations.

**Recommendation:**
- Gate the "Always Allow" functionality behind a specific, high-privilege administrative capability.
- Require a separate confirmation step for updating trust profiles to `:auto`.

**Relevant files:**
- `apps/arbor_dashboard/lib/arbor_dashboard/live/consensus_live.ex`

### H14. Shell injection vulnerability in ToolHooks execution

- **Severity:** High
- **Area:** `arbor_orchestrator`

The `run_command` function in `ToolHooks` executes hooks using `System.cmd("/bin/sh", ["-lc", wrapped], ...)`, where `wrapped` contains a shell-interpolated command.

**Impact:**
- The use of `-lc` (login shell) is dangerous as it loads shell profiles and can be manipulated by environment variables.
- The command string interpolation is vulnerable to shell injection if the command name or payload contains shell metacharacters.
- This path bypasses the `Arbor.Shell.Sandbox` and provides a direct route to arbitrary host command execution.

**Recommendation:**
- Do not use a login shell for hook execution.
- Use a safe, non-shell execution method (like `System.cmd` with a direct argument list) and apply the same sandbox filters as `ShellHandler`.

**Relevant files:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex`

### H15. `Security.Kernel.grant_capability/1` bypasses SystemAuthority signing

- **Severity:** High
- **Area:** `arbor_security`

`Security.Kernel.grant_capability/1` creates a capability and stores it via `CapabilityStore.put(cap)` directly, without calling `SystemAuthority.sign_capability/1`. The public facade `Security.grant/1` correctly signs before storing. Code paths using `Kernel.grant_capability` produce unsigned capabilities that may be rejected by signature verification in `CapabilityStore.find_authorizing`, or accepted inconsistently depending on the verification path.

**Impact:**
- Unsigned capabilities bypass the trust chain that `SystemAuthority` is meant to enforce.
- If `find_authorizing` does not consistently verify signatures, unsigned caps are equivalent to forged caps.
- The two grant paths (signed vs unsigned) create divergent trust semantics that callers may not be aware of.

**Recommendation:**
- Audit all call sites of `Kernel.grant_capability` and migrate them to the signed facade path.
- Add a signature validation guard in `CapabilityStore.put` that rejects unsigned capabilities unless explicitly marked as system-internal.
- Add a regression test proving `Kernel.grant_capability` produces capabilities that pass signature verification.

**Relevant files:**
- `apps/arbor_security/lib/arbor/security/kernel.ex`
- `apps/arbor_security/lib/arbor/security.ex` (facade for comparison)

### H16. Unbounded subgraph recursion enables denial of service

- **Severity:** High
- **Area:** `arbor_orchestrator`

Neither `SubgraphHandler` nor `PipelineRunHandler` passes a recursion depth limit to child `Arbor.Orchestrator.run/2` calls. Each child execution gets a fresh 500-step budget from the engine. A deeply nested DOT graph (or a `graph.compose` node where LLM output generates more subgraphs) can execute `N × 500` total steps where N is the nesting depth. No depth counter exists in `build_child_opts`.

**Impact:**
- A malicious or misbehaving DOT pipeline can exhaust CPU, memory, and LLM API budgets through deep recursion.
- Combined with P0-2 (graph-controlled middleware bypass), an untrusted graph can create arbitrarily deep execution trees with no security controls at any level.
- A `graph.compose` node that reads LLM output as DOT source creates a recursive loop if the LLM generates another `graph.compose` node.

**Recommendation:**
- Add a `:max_depth` option to `Arbor.Orchestrator.run/2`, decremented in `build_child_opts` for child graph invocations.
- Default depth limit should be small (e.g., 3).
- Fail the pipeline if the depth limit is exceeded.
- Add regression tests proving deeply nested graphs terminate with a clear error.

**Relevant files:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/subgraph_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/pipeline_run_handler.ex`
- `apps/arbor_orchestrator/lib/arbor/orchestrator/engine.ex`

### M5. `IdentityAliases.link/2` has no authorization check

- **Severity:** Medium
- **Area:** `arbor_agent`

The `link/2` function verifies only self-aliasing and circular alias chains. It does not verify that the caller owns or is authorized to modify either identity. Any code that can call `IdentityAliases.link("human_victim_hash", "attacker_id")` would redirect the victim's OIDC sessions to resolve to the attacker's identity.

**Impact:**
- Combined with H11 (OIDC auto-grants `arbor://consensus/admin`), this enables identity takeover: link a victim's human ID to an attacker-controlled ID, then log in via OIDC to receive the victim's admin capabilities.
- The alias resolution is used by `OidcAuth` during login (`resolve_identity_alias`), so the redirect happens before any session validation.

**Recommendation:**
- Gate `link/2` behind an explicit authorization check (e.g., `arbor://identity/alias/manage`).
- Require a system-internal or admin capability to create or modify identity aliases.
- Log all alias link/unlink operations as security events.

**Relevant files:**
- `apps/arbor_agent/lib/arbor/agent/identity_aliases.ex`

### M6. Consensus default authorizer is nil (allow-all proposals)

- **Severity:** Medium
- **Area:** `arbor_consensus`

When `state.authorizer` is `nil` (the default), `maybe_authorize(nil, _proposal)` returns `:ok`, skipping all proposal authorization. Topic rules default to `allowed_proposers: :any`. The `propose/2` facade submits directly to the Coordinator without an authorization gate.

**Impact:**
- Any agent can submit proposals on any topic without authorization.
- Combined with H12 (human_ bypass) and H11 (auto-grant admin), this means any OIDC user can submit and auto-approve proposals on any topic.

**Recommendation:**
- Require an authorizer module in production.
- Default to a basic authorizer that checks `arbor://consensus/propose` capability.
- Make `propose/2` call `authorize_propose/3` internally rather than requiring callers to opt in.

**Relevant files:**
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex`
- `apps/arbor_consensus/lib/arbor/consensus.ex`

### M7. Advisory proposals bypass deduplication and quota enforcement

- **Severity:** Medium
- **Area:** `arbor_consensus`

`mode: :advisory` skips both `check_duplicate` and `check_agent_quota`. An agent can submit unlimited advisory proposals with identical content, each triggering 13 LLM calls for advisory council evaluation.

**Impact:**
- Resource exhaustion through unbounded LLM API spend.
- An attacker with any agent access can exhaust the daily API budget through repeated advisory proposals.

**Recommendation:**
- Apply deduplication and quota checks to advisory proposals, or use separate (lower) limits.
- Rate-limit advisory submissions per agent per time window.
- Add monitoring for abnormal advisory proposal volume.

**Relevant files:**
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex`

### M9. `binary_to_term` on channel message data

- **Severity:** Medium
- **Area:** `arbor_actions`

DM-encrypted message headers use `:erlang.binary_to_term(header_bin, [:safe])`. While `[:safe]` prevents atom creation, it allows constructing arbitrary Erlang terms (lists, maps, tuples with existing atoms). If the persistence layer is compromised, crafted terms could exploit header parsing logic in the Double Ratchet implementation.

**Impact:**
- A compromised persistence backend can inject crafted terms into the ratchet header deserialization path.
- The `[:safe]` option mitigates atom-table exhaustion but does not prevent structural attacks on the parsing code.

**Recommendation:**
- Validate the deserialized header structure against an expected schema before use.
- Consider using a structured serialization format (e.g., JSON or a custom binary protocol) instead of `term_to_binary` for channel message headers.
- Add property tests that feed arbitrary `[:safe]`-deserializable terms into the header parser.

**Relevant files:**
- `apps/arbor_actions/lib/arbor/actions/channel.ex`

### Note on Phase 5 (Regression Coverage)

Phase 5 correctly identifies the critical test targets. As of this validation, **none** of the P0 items (P0-1 through P0-5) nor the new H9/H10 have committed regression tests that would have failed on the vulnerable code and pass after the fix (the requirement stated in the project CLAUDE.md security policy).

Manual verification via iex, tidewave, or ad-hoc scripts is useful for discovery but does not satisfy the "committed test that fails on `HEAD~1`" rule for security regressions.

**Recommendation:** Treat the missing regression tests as part of the P0 remediation work. The tests should live in the affected libraries and exercise the public APIs (`Security.authorize/4`, endpoint behavior, `Arbor.Orchestrator.run/2` with crafted graphs, `MCP.Handler.handle_call_tool("arbor_status", ...)` etc.).

---

## Remediation Roadmap

### Phase 0: Stop known exposure paths

1. Close the dashboard by default in production unless OIDC or another auth mechanism is configured. (P0-1)
2. Prevent graph-authored `skip_middleware` from disabling mandatory middleware. (P0-2)
3. Lock memory/status endpoints to authenticated caller context and target-resource authorization. (P0-4, M8)
4. Stop returning or using channel symmetric keys based only on asserted member IDs. (H4)
5. Make system authority persisted-key load failure fatal. (P0-5)
6. Remove automatic grant of `arbor://consensus/admin` to OIDC users. (H11)
7. Remove hardcoded `human_` identity authorization bypass in the Consensus Coordinator. (H12)
8. Gate the dashboard "Always Allow" functionality behind an explicit admin capability. (H13)
9. Fix unsafe `String.to_atom` fallbacks in `JobRegistry` and `Agent.Spec`. (H9)
10. Ensure all capability grant paths go through `SystemAuthority.sign_capability`. Audit `Kernel.grant_capability` call sites. (H15)
11. Add a recursion depth limit to subgraph and pipeline execution. (H16)
12. Gate `IdentityAliases.link/2` behind an authorization check. (M5)
13. Require a consensus authorizer in production; do not default to nil. (M6)
14. Apply deduplication and quota checks to advisory proposals. (M7)

### Phase 1: Unify authorization context

1. Define one runtime `AuthContext` contract for external requests, LiveViews, sessions, agent actions, MCP tools, and channel operations.
2. Include caller principal, identity verification result, session token or signed request metadata, tenant/workspace, trace ID, and delegation/provenance.
3. Require all facade-level authorization calls to receive this context or an explicit system-internal marker.
4. Remove process dictionary security handoffs. (H1, P0-4)

### Phase 2: Normalize resource authorization

1. Create a single resource URI builder/matcher module. (H8)
2. Replace string prefix matching with structured resource matching.
3. Standardize wildcard semantics.
4. Add property tests for path boundary, wildcard boundary, query-string, and trailing-slash cases.

### Phase 3: Harden execution boundaries

1. Route all command execution through one sandbox service. (H3, H10)
2. Treat command filters as preflight checks only.
3. Add real OS/container isolation for untrusted shell execution.
4. Route every agent action, including hardcoded actions, through `Arbor.Actions.authorize_and_execute/4`. (H7)
5. Require invocation receipts for shell, code hot-load, governance, cross-agent delegation, and persistence mutation.
6. Remove shell injection vulnerability in `ToolHooks` by switching to direct `System.cmd` execution. (H14)
7. Add subgraph/pipeline recursion depth limit to prevent unbounded execution. (H16)

### Phase 4: Make failure modes explicit

1. Production should fail closed on missing security dependencies.
2. Test-only permissive behavior should be injected via mocks or explicit test config.
3. Pending approval should never be treated as authorized.
4. Add operational health checks for Security, CapabilityStore, Identity.Registry, SystemAuthority, and SigningKeyStore.

### Phase 5: Regression coverage

Add focused tests for:

- Dashboard production auth when OIDC is absent.
- Mandatory middleware cannot be skipped by DOT.
- Nested `map`, `pipeline.run`, and `subgraph` execution cannot bypass auth.
- Signed MCP action request succeeds end-to-end with identity verification enabled.
- Cross-agent memory/status requests are denied.
- SystemAuthority persisted record contains no plaintext private key.
- FileGuard rejects symlink escapes.
- Channel subscribers cannot decrypt unless the subscriber is authorized.
- CapabilityStore outages do not accept unsigned caller-provided capabilities.
- Hardcoded agent actions run through action-layer auth and taint checks.
- `Kernel.grant_capability` produces capabilities that pass signature verification. (H15)
- Deeply nested subgraphs terminate with a clear error when depth limit is exceeded. (H16)
- `IdentityAliases.link/2` rejects unauthorized callers. (M5)
- Consensus proposals are denied when no authorizer is configured in production mode. (M6)
- Advisory proposals are subject to deduplication and quota checks. (M7)
- `binary_to_term` deserialized channel headers are validated against expected structure. (M9)

---

## Conclusion

Arbor's security architecture has strong primitives, but the current system does not yet enforce them uniformly. The highest-value work is not adding more security features. It is making the existing security model coherent end to end:

- one authenticated caller context,
- one resource authorization model,
- one command execution boundary,
- no graph-controlled bypasses of mandatory controls,
- no production fail-open on missing security services,
- no silent trust-root rotation,
- no unsigned capabilities in the trust chain,
- no unbounded recursion in graph execution,
- no authorization-free identity alias management.

Fixing these will improve both security and reliability. It will also reduce the brittle fail-closed behavior the project has already experienced, because legitimate calls will carry the proof and context needed for downstream authorization instead of rediscovering or re-verifying identity at each layer.
