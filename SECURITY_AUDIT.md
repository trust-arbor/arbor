# Arbor Security Kernel Audit

**Date:** 2026-05-16  
**Auditor:** Hermes Agent  
**Scope:** Core security kernel in `arbor_security` (facade, kernel, AuthDecision, Reflex, FileGuard, ApprovalGuard, capability handling) and integration points with `arbor_trust`.

---

## Summary

Arbor's security kernel implements a capability-based authorization system with cryptographic identities, trust-tier integration, fast reflex checks, and path protection. The design is more sophisticated than most agent frameworks, particularly in its attempt to combine zero-trust architecture with earned autonomy.

The core authorization pipeline is generally sound, but the implementation contains technical debt stemming from library dependency ordering, heavy defensive runtime loading, and incomplete regression test coverage for past security issues.

---

## What Lives Up to the Claims

### Capability-Based Authorization Pipeline
- The flow in `Security.authorize/4` → `AuthDecision.evaluate/4` is well-structured.
- Clear separation of pure decision logic (`AuthDecision`) from side effects.
- Checks run in order: reflexes → identity → signed request → capability lookup → delegation chain → time/scope constraints → FileGuard → approval gating.

### Reflex System (`Arbor.Security.Reflex`)
- Fast, pattern-based, sub-millisecond safety blocks.
- Built-in protections for `rm -rf /`, SSH keys, cloud metadata SSRF, sudo/su, etc.
- Composable and extensible via `Reflex.register/2`.
- Runs before any capability checks — good fail-fast design.

### FileGuard + SafePath
- Proper path traversal protection using `SafePath.resolve_within`.
- Supports patterns, excludes, max_depth, and wildcard (`arbor://fs/**`) capabilities.
- Wildcard capabilities correctly bypass root validation while still resolving absolute paths.

### Cryptographic Identity & Delegation
- Ed25519 identities with `SigningKeyStore` (AES-256-GCM encrypted at rest).
- Signed request verification with nonce replay protection.
- Delegation chain verification with depth limits.
- `delegate_to_agent/3` helper provides ergonomic bulk delegation.

### Past Regression Fix (2026-04-07)
- The shell auto-execution regression has been addressed in `AuthDecision.check_approval/3`:
  ```elixir
  needs_approval =
    has_approval_constraint?(cap) or
      trust_profile_gates?(auth.principal_id, resource_uri)
  ```
- `ApprovalGuard` enforces the invariant that shell and governance actions are never auto-approved.

---

## What Falls Short

### Fragile Defensive Runtime Loading
`AuthDecision` and multiple supporting functions contain extensive `Code.ensure_loaded?` + `function_exported?` + rescue/catch blocks because `arbor_trust` depends on `arbor_security` (not vice versa). This leads to:

- Silent degradation to permissive behavior when modules are unavailable.
- Identity checks falling back to allowing unknown identities in non-strict mode.
- Delegation verification being bypassed under certain loading conditions.
- Poor testability and high cognitive overhead.

### Configurable Weakening of Security
`ApprovalGuard` can be disabled via `approval_guard_enabled: false`. When disabled, it falls back to the older `Escalation.maybe_escalate` behavior that only checks per-capability flags — bypassing trust profile integration.

### CapabilityStore as Single Point of Failure
When the store is unavailable, the system falls back to pre-loaded capabilities in the `AuthContext` that have **not** been signature-verified. This creates a window where tampered capabilities could be accepted.

### Ad-Hoc URI Matching Logic
`uri_matches?/2` in `AuthDecision` implements prefix and wildcard matching manually. Similar logic exists in `CapabilityStore.find_authorizing`. Any divergence between these implementations risks authorization bypasses.

### Reflex Registry Lacks Access Control
Any code path that can call `Reflex.register/2` can add or override reflexes. There is no capability gate or ownership model protecting reflex registration.

### Insufficient Regression Test Coverage
Despite the project guideline requiring committed regression tests for security fixes, there do not appear to be tests that would have caught the 2026-04-07 shell auto-execution regression (i.e., proving that trust profile `:gated` rules are enforced even when the capability lacks an explicit `requires_approval` flag).

---

## Recommendations

### 1. Fix Dependency Direction or Introduce Narrow Contract
Create a small `Arbor.Security.TrustIntegration` behaviour or config-driven callback module. This would eliminate the `Code.ensure_loaded?` / rescue spaghetti and make trust integration explicit and testable.

### 2. Remove the ApprovalGuard Escape Hatch
Make `ApprovalGuard` always-on. If legacy behavior is needed, require an explicit legacy mode rather than a simple boolean flag.

### 3. Strengthen CapabilityStore Resilience
Maintain an in-memory ETS mirror with signature verification that remains available even if the primary persistence layer is down.

### 4. Centralize URI Matching
Move all URI matching rules into `Arbor.Contracts.Security.Uri` (or a dedicated matcher) and have both `AuthDecision` and `CapabilityStore` delegate to it. Add property-based tests.

### 5. Default to Signed Invocation Receipts for Sensitive Operations
Make `InvocationReceipt` mandatory (or at least strongly encouraged) for shell execution, governance actions, and cross-agent delegation.

### 6. Add Specific Security Regression Tests
Add tests that assert:
- `shell.execute` always requires approval unless explicitly graduated via `ConfirmationTracker`.
- Trust profile `:gated` or `:deny` takes precedence over missing per-capability flags.
- Suspended/revoked/unknown identities are rejected in strict mode.
- Reflexes cannot be bypassed by capability grants.

---

## Conclusion

The Arbor security kernel represents a serious and principled attempt at building a capability-based system that supports genuine agent autonomy while maintaining strong boundaries. The design intent is sound and several components (Reflexes, FileGuard, cryptographic identity) are well-executed.

However, the current implementation carries notable technical debt around cross-library integration and defensive coding patterns. These issues create real risks of silent security degradation. Addressing the dependency ordering, removing configuration escape hatches, and adding targeted regression tests would significantly strengthen the kernel.

The project would benefit from treating the security kernel with the same rigor applied to its philosophical goals: clear boundaries, explicit contracts, and verifiable invariants.