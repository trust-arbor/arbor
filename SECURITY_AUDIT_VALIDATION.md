# Validation of SECURITY_AUDIT.md (2026-05-31)

**Validator:** Grok 4.3 (xAI)  
**Date:** 2026-06-02  
**Scope:** Full code review of all P0 and High findings from the 2026-05-31 Codex audit, plus search for missed issues.  
**Method:** Static analysis of source files, cross-reference with prior 2026-02-16 SECURITY_REVIEW.md remediations, and targeted pattern searches (fail-open rescues, atom conversions, auth context threading, bypass paths).

This document serves as an independent validation and addendum to [SECURITY_AUDIT.md](./SECURITY_AUDIT.md). All findings below were verified by reading the live source (not build artifacts).

---

## Validation Summary

| Finding | Status | Notes |
|---------|--------|-------|
| **P0-1** Dashboard open when OIDC absent | **Confirmed** | `OidcAuth` ignores `require_auth: true`. Old `Auth` plug (which respected the flag) is not in the endpoint pipeline. |
| **P0-2** Mandatory middleware removable via `skip_middleware` | **Confirmed** | `Chain.build/3` applies skip filter to the mandatory chain. Test at `mandatory_middleware_test.exs:700` explicitly asserts the bypass. |
| **P0-3** Composite handlers bypass per-node auth | **Confirmed** | `MapHandler`, `PipelineRunHandler`, and `SubgraphHandler` execute child logic without re-entering middleware/authorization. `pipeline.run` schema declares zero capabilities. |
| **P0-4** Cross-agent memory / status access | **Confirmed** | Memory router authorizes using caller-supplied target `agent_id` as principal + multiple `rescue _ -> :ok` paths. MCP `arbor_status` leaks via `find_first_agent_id()` with no caller authorization. |
| **P0-5** SystemAuthority plaintext key + silent rotation | **Confirmed** | `serialize_keypair/1` writes base64 private key via `BufferedStore` (bypasses `SigningKeyStore`). Load failure path generates + persists new root. |
| **H1** Signed request proof lost | **Confirmed** | Gateway verifies, drops proof before calling `Actions.authorize_and_execute`. Context passed lacks `:signed_request`. |
| **H2** FileGuard symlink escapes | **Confirmed** | Docstring claims symlink verification; implementation uses only `SafePath.resolve_within` (no realpath). |
| **H3** Shell sandbox is filter, not isolation | **Confirmed** | `tool_handler.ex:68` does raw `System.cmd` (credo disable). Tool path bypasses `Arbor.Shell.Sandbox`. |
| **H4–H8** (signals, AuthDecision, facades, hardcoded actions, Claude bridge) | **Confirmed** | All patterns match the described failure modes. |

**Overall assessment:** The audit is accurate and conservative. No false positives were found. The described root causes (fragmented auth context, unenforceable "mandatory" controls, fail-open rescues, wrong-principal authorization) are real and systemic.

---

## Additional Issues Discovered During Validation (Not in Original Audit)

### V1. New unsafe atom conversion fallbacks (atom exhaustion)

Two new sites with the classic `to_existing_atom` rescue → `String.to_atom` pattern (same class as the Feb 2026 H4/H5 findings that were supposedly remediated):

- [apps/arbor_orchestrator/lib/arbor/orchestrator/job_registry.ex:381-385](/Users/azmaveth/code/trust-arbor/arbor/apps/arbor_orchestrator/lib/arbor/orchestrator/job_registry.ex)
  ```elixir
  defp parse_node_name(n) when is_binary(n) do
    String.to_existing_atom(n)
  rescue
    ArgumentError -> String.to_atom(n)   # <--- attacker-controlled via persisted jobs?
  end
  ```

- [apps/arbor_agent/lib/arbor/agent/spec.ex:393-398](/Users/azmaveth/code/trust-arbor/arbor/apps/arbor_agent/lib/arbor/agent/spec.ex)
  ```elixir
  defp safe_to_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> String.to_atom(s)
  end
  ```

These are reachable from DOT graphs, persisted state, and agent specs. The prior remediation effort with `SafeAtom` did not cover these paths.

**Recommendation:** Replace with `SafeAtom.to_existing/1` + explicit error handling or a bounded registry. Add to the regression test suite.

### V2. Deeper fail-open surface in memory/consensus facades and routers

The audit correctly flagged permissive behavior when security is unavailable. The concrete implementations are worse:

- `authorize_memory_access/2` in the gateway router returns `:ok` on any non-`{:ok, :authorized}` result and on every rescue.
- Similar patterns exist in `Arbor.Memory`, `Arbor.Consensus`, and `Arbor.Agent` facades (as noted) but also in supporting routers and MCP bridges.
- These are not merely "test accommodations"; they are live production code paths.

**Recommendation:** Enforce a strict "deny on any security uncertainty" rule outside of explicitly injected test authorizers. Add a project-wide grep + credo check for `rescue.*:ok` inside authorization modules.

### V3. Tool execution has a second unsandboxed `System.cmd` path

In addition to the `tool_handler.ex` case already noted:

- [apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex:123](/Users/azmaveth/code/trust-arbor/arbor/apps/arbor_orchestrator/lib/arbor/orchestrator/tool_hooks.ex) also does raw `System.cmd("/bin/sh", ...)` inside hook execution.

Combined with P0-2 (`skip_middleware`), any pipeline node that can trigger tool hooks can execute arbitrary host commands without the declared sandbox.

### V4. `arbor_status` MCP tool leaks even more broadly than described

- `get_status("overview", ...)` + `get_memory_summary/0` etc. all call `find_first_agent_id()` when no `agent_id` is supplied.
- The `authenticated_agent_id/0` helper (process dictionary) exists but is **never consulted** by the status component handlers.
- Any authenticated MCP client (even with a low-trust identity) can enumerate and dump state from the first running agent.

### V5. No committed regression tests for the P0 findings

Per the project rule in CLAUDE.md ("Security Bug Fixes Need Regression Tests"), each of P0-1 through P0-5 should have a test that:
- Fails on `git checkout HEAD~1` (or the commit before the fix)
- Passes on current HEAD
- Lives in the affected library
- Uses public APIs (`Security.authorize/4`, LiveView/endpoint behavior, `Arbor.Orchestrator.run/2`, etc.)

None of these tests appear to exist yet. Manual verification via iex/tidewave is insufficient for long-term regression protection.

---

## Prior Review Remediation Spot-Checks (Feb 2026 → Now)

| Old Finding | Claimed Status | Current Reality |
|-------------|----------------|-----------------|
| Channel authority private keys in GenServer state (C1) | REMEDIATED | Still encrypted with per-process ephemeral key (good, no regression). |
| Working memory endpoints lack auth (M1) | REMEDIATED | Structurally calls `authorize_memory_access`, but implementation has the fail-open + wrong-principal problems described in P0-4. Partial regression in spirit. |
| Atom exhaustion vectors (H4/H5) | REMEDIATED | New instances (V1 above) introduced in job registry and agent spec. Regression. |

---

## Recommendations Beyond the Original Remediation Roadmap

1. **Immediate (Phase 0+)**: Close the five P0s. Treat V1–V4 as P0-adjacent.
2. **Add a "Security Hardening" credo check** that fails on `String.to_atom` (outside approved allowlists) and on broad `rescue _ -> :ok` inside any `*auth*`, `*authorize*`, or `*security*` file.
3. **Create the required regression tests** for P0-1..P0-5 (and V1) before the next release. These tests must be part of the committed diff.
4. **Introduce a first-class `AuthContext` struct** (as the audit suggests) and make it mandatory for all gateway → action → facade paths. Remove process-dictionary handoffs for identity.
5. **Audit every composition primitive** (`map`, `pipeline.run`, `graph.*`, tool hooks) for auth-context propagation.

---

## Conclusion

The 2026-05-31 audit is a high-quality piece of work. Its findings are reproducible and represent real, currently exploitable (or near-exploitable) weaknesses in a system that otherwise has excellent security primitives.

The additional issues (V1–V5) are of the same family as problems the project has already identified and partially fixed. They reinforce the central diagnosis: the security model is sound in design but not yet enforced uniformly at every boundary and composition point.

**Next concrete step:** Create the five (plus V1) committed regression tests, then close the P0s. After that, the remaining high/medium items become tractable.

---

*This validation was performed on the `fix/signal-cli-tmpdir-leak` branch at the time of review (working tree clean). All line numbers refer to that revision.*