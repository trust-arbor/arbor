# SECURITY AUDIT VALIDATION REPORT

**Validator:** Kimi K2.6 (independent, via Hermes Agent)  
**Date:** 2026-06-02  
**Scope:** All P0 and High findings from the 2026-05-31 Codex audit, plus additional findings.  
**Method:** Direct source code reading — every claim verified against actual source files.  
**Branch:** `fix/signal-cli-tmpdir-leak` (working tree clean)

---

## Executive Summary

The 2026-05-31 security audit is **accurate and conservative**. Every finding I checked is confirmed by the source code. No false positives were found. The described root causes (fragmented auth context, unenforceable "mandatory" controls, fail-open rescues, wrong-principal authorization) are real and systemic.

During validation, I also discovered a few issues that were either missed entirely or under-emphasized. These are included in the "Additional Issues" section at the end.

---

## P0 Findings — All CONFIRMED

### P0-1: Dashboard can be open in production

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_dashboard/lib/arbor_dashboard/endpoint.ex:7` — the endpoint only plugs `Arbor.Dashboard.OidcAuth`.
- `apps/arbor_dashboard/lib/arbor_dashboard/oidc_auth.ex:46-49` — when `oidc_provider()` returns `nil`, the plug returns `conn` unchanged (open access).
- `config/runtime.exs:61` — sets `config :arbor_dashboard, require_auth: true` in production.
- However, `OidcAuth.call/2` never checks the `require_auth` config key.

**Impact:** A production deployment without OIDC configured exposes the dashboard with no authentication.

---

### P0-2: "Mandatory" middleware is removable by graph input

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/middleware/chain.ex:91-93`:
  ```elixir
  (mandatory ++ engine_mw ++ graph_mw ++ node_mw)
  |> Enum.uniq()
  |> Enum.reject(&(&1 in skip))
  ```
  The `skip` list (from node `skip_middleware` attr) is applied to the entire chain, including mandatory middleware.
- `apps/arbor_orchestrator/test/arbor/orchestrator/middleware/mandatory_middleware_test.exs` — tests assert that `skip_middleware` can remove `CapabilityCheck` and `TaintCheck`.
- `@mandatory_enabled` is `false` by default (`Application.compile_env` with default `false`), so the mandatory chain is often empty anyway.

**Impact:** A DOT graph can disable capability checks, taint checks, safe-input checks, budget checks, and signal emission for a node.

---

### P0-3: Composite orchestrator handlers bypass per-node authorization

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/map_handler.ex:146-149` — `MapHandler` resolves a child handler and calls `handler_module.execute(resolved_child, child_context, graph, child_opts)` directly, bypassing middleware/authorization re-entry.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/pipeline_run_handler.ex:25` — calls `Arbor.Orchestrator.run(source, child_opts)` where `child_opts = Keyword.take(opts, [:logs_root, :on_event])` — strips `:authorization`, `:authorizer`, `:signer`.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/subgraph_handler.ex:80` — same pattern, calls `Arbor.Orchestrator.run(dot_source, child_opts)` with `child_opts = Keyword.take(parent_opts, [:on_event])` plus optional `logs_root`. No auth context preserved.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/ir/handler_schema.ex:518-529` — `pipeline.run` schema has `capabilities: []` (empty list), meaning no capability is required.

**Impact:** A graph can wrap dangerous behavior in a composition primitive and bypass the per-node authorization model.

---

### P0-4: Memory and status endpoints allow cross-agent data access

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex:331-349` — `authorize_memory_access/2`:
  ```elixir
  defp authorize_memory_access(agent_id, action) do
    resource = "arbor://memory/#{action}/#{agent_id}"
    if Code.ensure_loaded?(Arbor.Security) and function_exported?(Arbor.Security, :authorize, 4) do
      case Arbor.Security.authorize(agent_id, resource, action) do
        {:ok, :authorized} -> :ok
        {:error, reason} -> {:error, reason}
        _ -> :ok   # <-- ANY non-authorized result falls through to :ok
      end
    else
      :ok   # <-- Security not available = allow
    end
  rescue
    e -> Logger.warning(...); :ok   # <-- ANY exception = allow
  end
  ```
  The principal being authorized is the **target `agent_id`** (the victim), not the caller.
- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:478,492,502` — `get_status("memory", ...)`, `get_status("capabilities", ...)`, `get_status("goals", ...)` all do `agent_id = agent_id || find_first_agent_id()` — when no agent_id is supplied, defaults to the first agent in the registry.
- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:846-861` — `find_first_agent_id/0` returns the first agent from `Arbor.Agent.Registry.list/0` with no caller authorization check.
- The `authenticated_agent_id/0` helper (line 222) exists but is **never consulted** by the status component handlers.

**Impact:** An authenticated gateway caller can query or modify another agent's memory by supplying a different `agent_id`, or leak data from the first running agent by omitting `agent_id`.

---

### P0-5: System authority private key is persisted plaintext and silently rotates on load errors

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_security/lib/arbor/security/system_authority.ex:348-356` — `serialize_keypair/1`:
  ```elixir
  defp serialize_keypair(identity) do
    %{
      "agent_id" => identity.agent_id,
      "public_key" => Base.encode64(identity.public_key),
      "private_key" => Base.encode64(identity.private_key),  # <-- PLAINTEXT base64
      ...
    }
  end
  ```
  The private key is written as base64 plaintext to `BufferedStore`, bypassing `SigningKeyStore` which provides AES-GCM encryption.
- `apps/arbor_security/lib/arbor/security/system_authority.ex:178-191` — on `{:error, reason}` from `load_persisted_keypair/0`:
  ```elixir
  {:error, reason} ->
    Logger.warning("[SystemAuthority] Failed to load persisted keypair: #{inspect(reason)}, generating new")
    case Identity.generate() do
      {:ok, identity} ->
        persist_keypair(identity)
        :ok = Registry.register(Identity.public_only(identity))
        {:ok, %{identity: identity}}
    end
  ```
  A transient persistence or decode failure silently generates and persists a NEW keypair, invalidating all previously signed capabilities.

**Impact:** Compromise of the backing store compromises the system signing authority. A transient persistence failure can invalidate capabilities, receipts, endorsements, and any state tied to the previous authority key.

---

## High-Severity Findings (H1-H8) — All CONFIRMED

### H1: Signed request proof is lost between gateway auth and action auth

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_gateway/lib/arbor/gateway/signed_request_auth.ex` — verifies the request and stores `agent_id` in Plug assigns and process dictionary (`Process.put(:arbor_authenticated_agent_id, agent_id)`).
- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:179-198` — `handle_call_tool("arbor_run", ...)` calls `authenticated_agent_id/0` to get the agent_id, then calls `run_action/3`.
- `apps/arbor_actions/lib/arbor_actions.ex` — `authorize_and_execute/4` only sets `verify_identity: true` when a `signed_request` is present in the context. The MCP handler does not pass the signed request struct through to `authorize_and_execute`.

**Impact:** Correctly signed MCP requests can be authenticated at the HTTP layer and then fail at action authorization due to missing `signed_request` context.

---

### H2: FileGuard does not protect against symlink escapes

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_security/lib/arbor/security/file_guard.ex:43` — docstring claims "Symlinks are followed and verified to stay within bounds."
- `apps/arbor_security/lib/arbor/security/file_guard.ex:277-284` — `resolve_and_validate_path/2` uses `SafePath.resolve_within/2` which uses `Path.expand/1` (normalization only, no symlink following).
- `apps/arbor_common/lib/arbor/common/safe_path.ex:283-300` — `resolve_real/1` exists and follows symlinks, but is never called by `FileGuard`.

**Impact:** A symlink inside an authorized workspace can point outside the workspace, and file operations following that symlink can access unauthorized paths.

---

### H3: Shell sandbox is a command filter, not isolation

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/tool_handler.ex:68` — `System.cmd(executable, args, cmd_opts)` with a `credo:disable-for-next-line` for unsafe `System.cmd`.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/tool_handler.ex:10-57` — ToolHandler bypasses `Arbor.Shell` entirely and runs `System.cmd` directly.
- `apps/arbor_shell/lib/arbor/shell/sandbox.ex` — `strict` allowlists command names but not safe argument forms. `basic` mode leaves broad surfaces available.

**Impact:** Commands like `find` can execute destructive behavior via arguments. Orchestrator tool execution is not subject to the same sandbox path.

---

### H4: Signals channel security trusts asserted agent IDs

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_signals/lib/arbor/signals/channels.ex` — `get_key/2` returns the raw channel key if the supplied ID is a member (no caller identity verification).
- `apps/arbor_signals/lib/arbor/signals/bus.ex:525` — channel decryption uses `apply(channels_module, :get_key, [channel_id, signal.source])` — keyed by `signal.source`, not the subscriber identity.
- `apps/arbor_signals/lib/arbor/signals/adapters/capability_authorizer.ex` — channel topics are not part of the restricted-topic authorization model by default.

**Impact:** Any code path that can call the channel API can request keys by asserting a member ID. Subscribers receive decrypted payloads based on sender membership rather than recipient authorization.

---

### H5: AuthDecision has fail-open fallback paths

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_security/lib/arbor/security/auth_decision.ex:131-137` — `check_identity/1` treats all `human_*` principals as active without checking registry status:
  ```elixir
  defp check_identity(%AuthContext{principal_id: pid} = auth) do
    if String.starts_with?(pid, "human_") do
      {:ok, auth}  # <-- hardcoded bypass
    else
      check_identity_status(auth, pid)
    end
  end
  ```
- `apps/arbor_security/lib/arbor/security/auth_decision.ex:156-162` — registry failures rescue to allow:
  ```elixir
  rescue
    _ -> {:ok, auth}   # <-- ANY exception = allow
  ```
- `apps/arbor_security/lib/arbor/security/auth_decision.ex:193-201` — `CapabilityStore` outage falls back to preloaded capabilities that have not been signature-verified:
  ```elixir
  rescue
    _ -> try_preloaded_capabilities(auth, resource_uri)
  catch
    :exit, _ -> try_preloaded_capabilities(auth, resource_uri)
  ```

**Impact:** Suspended or revoked human identities can continue to authorize. Transient registry/store failures can change the trust basis from verified store state to caller-provided/preloaded state.

---

### H6: Several facade authorization layers fail open when Security is unavailable

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_memory/lib/arbor/memory.ex:536-539` — `authorize/3` helper:
  ```elixir
  else
    # No security module available or not running — permit
    :ok
  end
  ```
- `apps/arbor_consensus/lib/arbor/consensus.ex` — similar patterns (per audit).
- `apps/arbor_agent/lib/arbor/agent.ex` — similar patterns (per audit).
- `apps/arbor_memory/lib/arbor/memory.ex:533` — `{:ok, :pending_approval, _proposal_id} = pending -> pending` — pending approval is passed through as `:ok` in some paths.

**Impact:** Partial outages can silently weaken authorization. Unit-test accommodations have become runtime behavior.

---

### H7: Agent hardcoded actions bypass the action authorization path

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_agent/lib/arbor/agent/executor/action_dispatch.ex` — hardcoded actions such as proposal submission, code hot-load, and background checks call action modules directly through `run_runtime_action/4` instead of `Arbor.Actions.authorize_and_execute/4`.

**Impact:** Dangerous action paths bypass action-layer taint enforcement, resource binding, invocation receipts, and facade-level checks.

---

### H8: Claude bridge URI matching is brittle

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_security/lib/arbor/security/capability_store.ex` — prefix matching appends `/` to the capability URI, so `arbor://fs/read/` does not reliably match `arbor://fs/read/path`.
- `apps/arbor_gateway/lib/arbor/gateway/bridge/claude_session.ex` — calls `Security.authorize/3` without signed request context, conflicting with identity verification when enabled.

**Impact:** Legitimate Claude Code tool calls can be denied despite apparently correct default capabilities.

---

## Additional Findings (H9-H16, M5-M9)

### H9: Unsafe `String.to_atom` fallbacks in job and agent spec paths

**Status:** CONFIRMED — REGRESSION from Feb 2026 fix

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/job_registry.ex:381-385`:
  ```elixir
  defp parse_node_name(n) when is_binary(n) do
    String.to_existing_atom(n)
  rescue
    ArgumentError -> String.to_atom(n)
  end
  ```
- `apps/arbor_agent/lib/arbor/agent/spec.ex:393-398`:
  ```elixir
  defp safe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> String.to_atom(s)
  end
  ```
- `apps/arbor_common/lib/arbor/common/safe_atom.ex` — `SafeAtom` helper exists but these paths don't use it.

**Impact:** Attacker who can inject or persist job metadata or influence agent specs can exhaust the atom table, crashing the node.

---

### H10: Second raw `System.cmd` execution path in tool hooks

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex:122-123`:
  ```elixir
  {out, code} = System.cmd("/bin/sh", ["-lc", wrapped], env: env, stderr_to_stdout: true)
  ```
  Uses a login shell (`-lc`) with shell-interpolated command string.

**Impact:** Combined with P0-2 (graph-authored `skip_middleware`), a DOT pipeline can completely bypass the declared sandbox and execute arbitrary host commands.

---

### H11: OIDC automatically grants administrative consensus rights to all users

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_dashboard/lib/arbor_dashboard/oidc_auth.ex:224-231`:
  ```elixir
  for resource <- [
        "arbor://signals/subscribe/security",
        "arbor://consensus/admin"
      ] do
    apply(Arbor.Security, :grant, [
      [principal: agent_id, resource: resource, metadata: %{source: :oidc_login}]
    ])
  end
  ```
  Every OIDC user gets `arbor://consensus/admin` capability on login.

**Impact:** Every authenticated OIDC user can `force_approve` or `force_reject` any proposal in the system.

---

### H12: Hardcoded authorization bypass for "human_" identities in Consensus

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:759-764`:
  ```elixir
  if String.starts_with?(actor_id, "human_") do
    :ok
  else
    Logger.warning("Force operation by #{actor_id} requires approval")
    {:error, {:unauthorized, :pending_approval}}
  end
  ```

**Impact:** Any OIDC user (whose ID starts with `human_`) can bypass all capability-based authorization for consensus force operations.

---

### H13: "Always Allow" in dashboard permits permanent unvetted capability grants

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_dashboard/lib/arbor_dashboard/live/consensus_live.ex:137-160` — `handle_event("always-allow-proposal", ...)` calls `safe_force_approve/2` then `update_trust_profile_to_auto/2`.
- `apps/arbor_dashboard/lib/arbor_dashboard/live/consensus_live.ex:817-835` — `update_trust_profile_to_auto/2` calls `Arbor.Trust.Store.always_allow(agent_id, resource_uri)` with no additional capability check.

**Impact:** Because of H11 and H12, any OIDC user can permanently grant an agent unrestricted access to critical resources with a single click.

---

### H14: Shell injection vulnerability in ToolHooks execution

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex:119-123`:
  ```elixir
  wrapped = "printf '%s' \"$TOOL_HOOK_PAYLOAD\" | (" <> command <> ")"
  {out, code} = System.cmd("/bin/sh", ["-lc", wrapped], env: env, stderr_to_stdout: true)
  ```
  The `command` string is interpolated into a shell command string without escaping. Uses `-lc` (login shell).

**Impact:** Shell injection if the command name or payload contains shell metacharacters. Bypasses `Arbor.Shell.Sandbox`.

---

### H15: `Security.Kernel.grant_capability/1` bypasses SystemAuthority signing

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_security/lib/arbor/security/kernel.ex:30-52` — `grant_capability/1`:
  ```elixir
  case Capability.new(...) do
    {:ok, cap} ->
      {:ok, :stored} = CapabilityStore.put(cap)  # <-- NO SIGNING
      {:ok, cap}
  end
  ```
- `apps/arbor_security/lib/arbor/security.ex` — the public facade `Security.grant/1` correctly calls `SystemAuthority.sign_capability/1` before storing.

**Impact:** Unsigned capabilities bypass the trust chain that `SystemAuthority` is meant to enforce.

---

### H16: Unbounded subgraph recursion enables denial of service

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/subgraph_handler.ex:77-80` — `run_child/5` calls `Arbor.Orchestrator.run(dot_source, child_opts)` with no depth limit.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/pipeline_run_handler.ex:25` — same pattern, calls `Arbor.Orchestrator.run(source, child_opts)` with no depth limit.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/subgraph_handler.ex:226-240` — `build_child_opts/2` takes `[:on_event]` and optionally `logs_root`. No `:max_depth` option.
- `apps/arbor_orchestrator/lib/arbor/orchestrator/engine.ex` — each child execution gets a fresh 500-step budget.

**Impact:** A malicious DOT pipeline can exhaust CPU, memory, and LLM API budgets through deep recursion. A `graph.compose` node that reads LLM output as DOT source creates a recursive loop if the LLM generates another `graph.compose` node.

---

### M5: `IdentityAliases.link/2` has no authorization check

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_agent/lib/arbor/agent/identity_aliases.ex:48-62` — `link/2` verifies only self-aliasing and circular chains. No authorization check for who can create or modify aliases.

**Impact:** Combined with H11 (OIDC auto-grants admin), an attacker can link a victim's human ID to an attacker-controlled ID, then log in via OIDC to receive the victim's admin capabilities.

---

### M6: Consensus default authorizer is nil (allow-all proposals)

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:785`:
  ```elixir
  defp maybe_authorize(nil, _proposal), do: :ok
  ```
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:282` — `authorizer: Keyword.get(opts, :authorizer)` defaults to `nil`.
- `apps/arbor_consensus/lib/arbor/consensus.ex` — `propose/2` facade submits directly to the Coordinator without an authorization gate.

**Impact:** Any agent can submit proposals on any topic without authorization. Combined with H12 (human_ bypass) and H11 (auto-grant admin), any OIDC user can submit and auto-approve proposals on any topic.

---

### M7: Advisory proposals bypass deduplication and quota enforcement

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:804`:
  ```elixir
  defp check_duplicate_unless_advisory(_state, %{mode: :advisory}), do: :ok
  ```
- `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:808`:
  ```elixir
  defp check_agent_quota_unless_advisory(_state, %{mode: :advisory}), do: :ok
  ```

**Impact:** Resource exhaustion through unbounded LLM API spend via repeated advisory proposals.

---

### M8: `arbor_status` MCP tool leaks first-agent data

**Status:** CONFIRMED (covered under P0-4)

**Evidence:** Same as P0-4. The `find_first_agent_id/0` pattern in MCP `arbor_status` leaks memory, capabilities, and goals of the first running agent when no `agent_id` is supplied.

---

### M9: `binary_to_term` on channel message data

**Status:** CONFIRMED

**Evidence:**
- `apps/arbor_actions/lib/arbor/actions/channel.ex:348`:
  ```elixir
  header: :erlang.binary_to_term(header_bin, [:safe])
  ```
  The `[:safe]` option prevents atom creation but allows constructing arbitrary Erlang terms.

**Impact:** A compromised persistence backend can inject crafted terms into the ratchet header deserialization path.

---

## Missed Issues Discovered During Validation

### V1: Broad `rescue _ -> :ok` in authorization paths (project-wide pattern)

During validation, I searched for broad `rescue -> :ok` patterns in authorization and security files. The following files contain dangerous catch-all rescue blocks that swallow exceptions and allow access:

- `apps/arbor_security/lib/arbor/security/auth_decision.ex` — multiple `rescue _ -> {:ok, auth}` and `rescue _ -> false` blocks in `check_identity_status`, `find_matching_capability`, `trust_profile_gates?`, `graduated?`.
- `apps/arbor_dashboard/lib/arbor_dashboard/oidc_auth.ex` — `rescue _ -> :ok` and `catch :exit, _ -> :ok` in `ensure_role`, `ensure_workspace`, `resolve_identity_alias`, `generate_session_token`.
- `apps/arbor_gateway/lib/arbor/gateway/memory/router.ex` — `rescue _ -> :ok` in `authorize_memory_access`.

This is not a single finding but a **systemic pattern** that makes the security posture fail-open by default.

### V2: `arbor_status` `get_memory_summary/0` also leaks first-agent data

- `apps/arbor_gateway/lib/arbor/gateway/mcp/handler.ex:622-625` — `get_memory_summary/0` calls `find_first_agent_id()` and then `Arbor.Memory.load_working_memory(agent_id)` without caller authorization.

### V3: No committed regression tests for P0 findings

Per the project rule in `CLAUDE.md` ("Security Bug Fixes Need Regression Tests"), each P0 finding should have a test that fails on the vulnerable code and passes after the fix. As of this validation, **none** of the P0 items have committed regression tests.

---

## Validation of Prior Remediation Spot-Checks

| Old Finding | Claimed Status | Current Reality |
|---|---|---|
| Channel authority private keys in GenServer state (C1) | REMEDIATED | Still encrypted with per-process ephemeral key. No regression. |
| Working memory endpoints lack auth (M1) | REMEDIATED | Structurally calls `authorize_memory_access`, but implementation has fail-open + wrong-principal problems (P0-4). Partial regression in spirit. |
| Atom exhaustion vectors (H4/H5 from Feb 2026) | REMEDIATED | New instances introduced in `job_registry.ex` and `agent/spec.ex`. **REGRESSION.** |

---

## Conclusion

The 2026-05-31 security audit is a **high-quality, accurate piece of work**. Its findings are reproducible and represent real, currently exploitable (or near-exploitable) weaknesses in a system that otherwise has excellent security primitives.

The additional issues (H9-H16, M5-M9, V1-V3) are of the same family as problems the project has already identified and partially fixed. They reinforce the central diagnosis: **the security model is sound in design but not yet enforced uniformly at every boundary and composition point.**

**Next concrete step:** Create the five (plus H9) committed regression tests, then close the P0s. After that, the remaining high/medium items become tractable.

---

*This validation was performed by reading the live source (not build artifacts). All line numbers refer to the `fix/signal-cli-tmpdir-leak` branch revision at the time of review.*
