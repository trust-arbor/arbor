# Security Review: trust-arbor/arbor

**Date:** 2026-02-07
**Scope:** `/Users/azmaveth/code/trust-arbor/arbor/` (25-app Elixir/OTP umbrella)
**Method:** 4-agent parallel review (Auth, Code Exec, Sandbox/BEAM, Config/Fail-open)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 5 |
| HIGH | 15 |
| MEDIUM | 20 |
| LOW | 10 |
| **Total** | **50** |

---

## Remediation Status

- [x] **Phase 1** — Critical (C1-C5) — All 5 remediated
- [ ] **Phase 2** — High (H1-H15) — 10/15 done, 2 deferred (H1/H2), 3 remaining (H9/H13/H15)
- [ ] **Phase 3** — Medium (M1-M20)
- [ ] **Phase 4** — Low (L1-L10)

---

## CRITICAL (5)

### C1: No Authentication on Gateway HTTP API
- **File:** `apps/arbor_gateway/lib/arbor/gateway/router.ex`
- **Issue:** Zero auth plugs on any endpoint. Any localhost process can: authorize tools (`/api/bridge`), read/write any agent's memory (`/api/memory`), inject signals (`/api/signals`), execute code (`/api/dev/eval`).
- **Remediation:** Add authentication plug (API key or bearer token) to Gateway router.
- **Status:** [x] Remediated — `Arbor.Gateway.Auth` plug (API key via env/config)

### C2: Shell Metacharacter Sandbox Bypass
- **Files:** `apps/arbor_shell/lib/arbor/shell/sandbox.ex:137-143`, `apps/arbor_shell/lib/arbor/shell/executor.ex:43`, `apps/arbor_shell/lib/arbor/shell/port_session.ex:162`
- **Issue:** Sandbox only checks first word of command. `;`, `&&`, `||`, `|`, `` ` ``, `$()` all bypass. `Port.open({:spawn, command})` passes through `/bin/sh -c`.
- **Remediation:** Use `{:spawn_executable, path}` with args list; add metacharacter detection to sandbox.
- **Status:** [x] Remediated — metacharacter detection + spawn_executable in executor/port_session

### C3: Reflex Safety System Fails Open on Any Exception
- **File:** `apps/arbor_security/lib/arbor/security.ex:608-612`
- **Issue:** `rescue _ -> :ok` catches all exceptions. If Reflex.Registry crashes, ALL reflex protections (rm -rf, sudo, SSH, SSRF blocks) permanently disabled.
- **Remediation:** Change to `rescue _ -> {:error, :reflex_check_failed}` (fail-closed).
- **Status:** [x] Remediated — fail-closed with Logger.error

### C4: HotLoad Compiles Arbitrary Code Without Sandbox Validation
- **File:** `apps/arbor_actions/lib/arbor/actions/code.ex:407`
- **Issue:** `Code.compile_string(source_code)` runs without passing through `Arbor.Sandbox.Code.validate/2` despite that module existing. Module immediately loaded into VM.
- **Remediation:** Route source through `Arbor.Sandbox.Code.validate/2` before compilation.
- **Status:** [x] Remediated — `validate_source_safety/1` added before `compile_source/1`

### C5: Hardcoded Erlang Cookie + Unrestricted RPC
- **Files:** `apps/arbor_common/lib/mix/tasks/arbor/arbor_helpers.ex:11`, `apps/arbor_common/lib/mix/tasks/arbor/eval.ex:34`
- **Issue:** Cookie `:arbor_dev` in source. `:rpc.call(node, Code, :eval_string, [expr])` enables full RCE if distribution port reachable.
- **Remediation:** Generate random cookie at runtime, don't commit to source.
- **Status:** [x] Remediated — cookie from `ARBOR_COOKIE` env var, no fallback

---

## HIGH (15)

### H1: Identity Verification Bypass (no signed_request)
- **File:** `apps/arbor_security/lib/arbor/security.ex:556-561`
- **Issue:** When `signed_request` is nil (omitted), returns `:ok` even with verification enabled.
- **Status:** [ ] Deferred — requires identity infrastructure (19 callers pass no signed_request)

### H2: Unregistered Identities Pass Authorization
- **File:** `apps/arbor_security/lib/arbor/security.ex:545-547`
- **Issue:** `{:error, :not_found} -> :ok` — any arbitrary principal_id works without registration.
- **Status:** [ ] Deferred — requires identity infrastructure (most callers use unregistered IDs)

### H3: `can?/3` Skips All Security Checks
- **File:** `apps/arbor_security/lib/arbor/security.ex:332-338`
- **Issue:** Only checks capability existence. Bypasses identity, constraints, rate limits, escalation, reflexes.
- **Status:** [x] Remediated — Logger.warning on every call + deprecation comment

### H4: Dev Eval Endpoint
- **File:** `apps/arbor_gateway/lib/arbor/gateway/dev/router.ex:142`
- **Issue:** `Code.eval_string(code)` on HTTP POST body. Route mounted unconditionally; guard is config-based.
- **Status:** [x] Remediated — compile-time guard: only mounted in dev/test

### H5: Unauthenticated Dashboard
- **File:** `apps/arbor_dashboard/lib/arbor_dashboard/router.ex`
- **Issue:** Zero auth on `/eval`, `/agents`, `/consensus`, `/signals`, `/monitor`.
- **Status:** [x] Remediated — HTTP Basic Auth plug (`Arbor.Dashboard.Auth`), required in prod

### H6: Consensus force_approve Accepts Any Caller
- **File:** `apps/arbor_consensus/lib/arbor/consensus/coordinator.ex:469-496`
- **Issue:** `force_approve/3` accepts any `approver_id` without authority verification.
- **Status:** [x] Remediated — `can?/3` check for `arbor://consensus/admin` capability

### H7: Audit Event Persistence Fails Silently
- **File:** `apps/arbor_security/lib/arbor/security/events.ex:332-337`
- **Issue:** `rescue _ -> :ok` drops all audit events if EventLog backend is down.
- **Status:** [x] Remediated — Logger.error + error return instead of silent swallow

### H8: Filesystem Sandbox Symlink Escape
- **File:** `apps/arbor_sandbox/lib/arbor/sandbox/filesystem.ex:67-74`
- **Issue:** `Path.expand` doesn't resolve symlinks. SafePath module exists but not used.
- **Status:** [x] Remediated — `SafePath.resolve_within/2` integrated into `resolve_path/2`

### H9: Code Sandbox Dynamic Dispatch Bypass
- **File:** `apps/arbor_sandbox/lib/arbor/sandbox/code.ex:260-261`
- **Issue:** AST walker only catches `apply` with literal atom module. Variable modules bypass.
- **Status:** [ ] Not started — medium effort, needs design decision

### H10: Unsigned Capabilities Accepted by Default
- **File:** `apps/arbor_security/lib/arbor/security/config.ex:53`
- **Issue:** `capability_signing_required` defaults to `false`.
- **Status:** [x] Remediated — default changed to `true`

### H11: CompileAndTest Shell Injection
- **File:** `apps/arbor_actions/lib/arbor/actions/code.ex:176`
- **Issue:** `test_files` joined into shell command unsanitized with `sandbox: :none`.
- **Status:** [x] Remediated — validate_test_files/1 (must end _test.exs, no metacharacters, no ..)

### H12: :os.cmd Insufficient Shell Escaping
- **File:** `apps/arbor_ai/lib/arbor/ai/agent_sdk/transport.ex:189`
- **Issue:** `shell_escape/1` only escapes double quotes. `$()`, backticks, pipes pass through.
- **Status:** [x] Remediated — replaced with System.cmd (no shell interpretation)

### H13: No HTTP-Level Rate Limiting on Gateway
- **File:** `apps/arbor_gateway/lib/arbor/gateway/router.ex`
- **Issue:** Unlimited requests to all API endpoints.
- **Status:** [ ] Not started — medium effort, needs plug implementation

### H14: No Production secret_key_base
- **Files:** `config/dev.exs:26`, no `prod.exs`/`runtime.exs` override
- **Issue:** Deterministic dev key, no production override exists.
- **Status:** [x] Remediated — SECRET_KEY_BASE required from env var in prod

### H15: Macro-Generated Code After Sandbox Check
- **File:** `apps/arbor_sandbox/lib/arbor/sandbox/code.ex`
- **Issue:** AST validated pre-expansion. Macros expand after check.
- **Status:** [ ] Document only — inherent limitation of pre-compilation validation

---

## MEDIUM (20)

| # | Finding | File |
|---|---------|------|
| M1 | `requires_approval` constraint is no-op | `constraint.ex:100-102` |
| M2 | Escalation bypassed when config disabled | `escalation.ex:46-67` |
| M3 | Trust points only boost tier, never lower | `trust/store.ex:255-268` |
| M4 | Prefix-based URI matching over-grants access | `capability_store.ex:327-334` |
| M5 | Signal bus uses OpenAuthorizer | `config.exs:85` |
| M6 | Missing dangerous `:erlang` functions in code sandbox | `sandbox/code.ex` |
| M7 | `Agent`/`Task` in `@always_allowed` at `:pure` level | `sandbox/code.ex:65-66` |
| M8 | Dangerous commands in `:strict` allowlist | `sandbox.ex:36-50` |
| M9 | PATH manipulation bypass at `:basic` level | `sandbox.ex` |
| M10 | Public ETS tables (21+) including reflex registry | `reflex/registry.ex:151` + others |
| M11 | TOCTOU race in filesystem sandbox | `sandbox/filesystem.ex` |
| M12 | `String.to_atom` atom exhaustion in Executor | `executor.ex:523,537` |
| M13 | Memory API has no agent-level authorization | `memory/router.ex` |
| M14 | `check_origin: false` in dev, no prod override | `dev.exs:29` |
| M15 | Git dependency without commit pinning | `mix.exs:29` |
| M16 | 7 path dependencies with `override: true` | `mix.exs:20-26` |
| M17 | No CSP, HSTS, or TLS configuration | Gateway + Dashboard |
| M18 | Path normalization inconsistency in bridge | `claude_session.ex:283-289` |
| M19 | Executor accepts unauthenticated GenServer casts | `executor.ex:167-189` |
| M20 | Lua eval via JidoSandbox (external trust) | `sandbox/virtual.ex:95-101` |

---

## LOW (10)

| # | Finding | File |
|---|---------|------|
| L1 | Default sandbox path in `/tmp` (world-writable) | `filesystem.ex:9` |
| L2 | EPMD on localhost | `arbor_helpers.ex:10,52` |
| L3 | Process enumeration at `:limited` level | Multiple |
| L4 | `String.to_atom` fallback in self_knowledge | `self_knowledge.ex:764` |
| L5 | `term_to_binary` nil-key acceptance | `topic_registry.ex:488-489` |
| L6 | Runtime .env loading from CWD | `runtime.exs:4-22` |
| L7 | Old identity entries default to `:active` | `identity/registry.ex:397-398` |
| L8 | Bridge signal emission swallows errors | `bridge/router.ex:100-102` |
| L9 | tmux send-keys injection (local CLI) | `hands/send.ex:59` |
| L10 | Hands.Spawn script interpolation | `hands/spawn.ex:165-179` |

---

## Positive Security Findings

- `SafeAtom` — proper atom safety with allowlists and `to_existing` only
- `SafePath` — symlink detection, path traversal prevention (exists but not integrated with sandbox)
- Custom Credo checks for `unsafe_atom_conversion` and `unsafe_binary_to_term`
- All `binary_to_term` calls use `[:safe]` flag
- No `keys: :atoms` in JSON decoding
- No NIF usage
- Trust store ETS tables use `:protected` access
- Bridge authorization fails closed (returns "deny" on error)
- Delegation tokens properly signed
- Rate limiter uses GenServer serialization (no TOCTOU)
- `SECURITY.md` with responsible disclosure guidance

---

## Remediation Roadmap

### Phase 1 — Immediate (C1-C5)
1. Add authentication to Gateway HTTP API (C1)
2. Fix shell sandbox metacharacter bypass (C2)
3. Change reflex rescue to fail-closed (C3)
4. Route HotLoad through sandbox validation (C4)
5. Generate random Erlang cookie (C5)

### Phase 2 — Short-term (H1-H15)
6. Fix identity verification to require signed_request (H1)
7. Fail-closed on unregistered identities (H2)
8. Audit `can?/3` callers (H3)
9. Add auth to dashboard (H5)
10. Add authorization to force_approve/force_reject (H6)
11. Make audit persistence non-optional (H7)
12. Integrate SafePath into filesystem sandbox (H8)
13. Set capability_signing_required: true (H10)
14. Fix code sandbox dynamic dispatch (H9, H15)
15. Add HTTP rate limiting (H13)

### Phase 3 — Medium-term (M1-M20)
### Phase 4 — Long-term (L1-L10)
