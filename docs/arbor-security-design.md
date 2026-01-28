# Arbor Security Architecture: Design Document

> Current state, gaps, and roadmap for the security subsystem across Arbor's library hierarchy.
>
> Created: 2026-01-28
> Status: Draft — for discussion

---

## 1. Design Context

Arbor's long-term vision is **multi-node, multi-cluster with durable agents and jobs load-balanced across the system**. Federated clusters may include potentially malicious agents. Security must be foundational — not bolted on after the fact.

This means the security layer must work when you **cannot trust**:
- **The network** — messages between nodes may be intercepted or forged
- **The remote node** — a node in a federated cluster may lie about its agents' capabilities
- **The agent** — an agent may claim to be someone it isn't, or present forged credentials

The single-node, single-operator case (our current state) is the easy degenerate case. If we design for the hard case first, the easy case works automatically.

### Design Principles

**Self-Verifying Credentials.** In a federated system, you can't phone home to check every credential. Capabilities, identities, and delegation chains must be **self-verifying** — any node can validate them using only the credential itself and a set of trusted public keys, without calling back to the issuing authority. This is the fundamental difference from the current design, where capabilities are records in a local ETS table and identity is a string.

**Global Identity, Portable Capabilities, Local Governance.** Three layers, each with the right scope:

| Layer | Scope | Rationale |
|-------|-------|-----------|
| **Identity** | Global | Cryptographic — verifiable anywhere, no opinions involved |
| **Capabilities** | Portable | Signed by issuing authority — any node can verify the signature |
| **Trust** | Local | Subjective — each operator judges agents by their own observations |
| **Consensus** | Local | Policy — each operator defines their own rules, quorum, evaluators |

Trust and consensus are both expressions of local operator policy. A node operator decides:
- What trust tier a foreign agent starts at
- What operations require consensus approval
- How many council members evaluate a proposal
- What quorum is needed for different risk levels
- Whether to use rule-based, LLM, human, or hybrid evaluators

No cross-cluster coordination is needed for trust or consensus. A capability signed by a trusted authority is valid regardless of how the issuing cluster decided to grant it — whether by 7-agent LLM council or a single operator clicking "approve."

---

## 2. Current Architecture

Security is distributed across four libraries:

```
Level 0:  arbor_contracts    Shared types: Capability, Trust.Profile, Trust.Event,
                             Proposal, Evaluation, CouncilDecision, ConsensusEvent
                             Shared behaviours: API.Security, API.Trust, API.Consensus

Level 1:  arbor_security     Capability-based authorization (grant, revoke, check)
          arbor_consensus    Multi-perspective deliberative evaluation
          arbor_signals      Cross-library event notification

Level 2:  arbor_trust        Progressive trust scoring, tiers, decay, circuit breaker
          arbor_bridge       Adapter for external tools (Claude Code → Arbor security)
```

### What Each Library Owns

| Library | Responsibility | Key Question |
|---------|---------------|--------------|
| **Security** | Capability CRUD + authorization checks | "Does this agent hold a valid capability for this resource?" |
| **Trust** | Trust profile lifecycle, scoring, tier progression, freezing | "Has this agent earned sufficient trust through its track record?" |
| **Consensus** | Proposal submission, multi-perspective evaluation, decisions | "Do multiple evaluators agree this action should be allowed?" |
| **Bridge** | Adapter for external tools (Claude Code) into Arbor's capability system | "How does this external tool call map to Arbor's security model?" |

Bridge is specifically the external tool adapter — it wires Claude Code (and potentially other external tools) into Arbor's security model. It is **not** the general authorization orchestration layer. Native Arbor agents running on remote nodes never touch Bridge.

### Authorization Flow (Current — Single Node, Claude Code)

```
Claude Code tool call
       │
       ▼
Bridge.ClaudeSession.authorize_tool/4
       │
       ├─ ensure_registered ──► Trust.create_trust_profile (once)
       │                        Security.grant (default capabilities)
       │
       ├─ map tool → resource URI
       │   Read("file.ex")      → arbor://fs/read/path/to/file.ex
       │   Bash("git status")   → arbor://shell/exec/git?cwd=...
       │   Task(...)            → arbor://agent/spawn
       │
       └─ Security.authorize(agent_id, resource_uri, action)
              │
              ├─ CapabilityStore.find_authorizing  (~μs)
              │   Hierarchical URI matching:
              │   capability for arbor://fs/read/
              │   authorizes   arbor://fs/read/project/src/file.ex
              │
              └─► {:ok, :authorized} | {:error, :unauthorized}
```

### What Works Well

- **Capability model** is clean: unforgeable tokens, hierarchical URI matching, delegation with depth limits, expiration, constraints
- **Trust/Security separation** is correct: Security answers "can?", Trust answers "should?"
- **Consensus is independent**: pluggable evaluators, doesn't depend on Security or Trust directly
- **Signal-based observability**: all authorization events emitted for monitoring
- **Resource URI scheme** is extensible and hierarchical

### Capability Data Model (Current)

```elixir
%Capability{
  id: "cap_a1b2c3...",
  resource_uri: "arbor://fs/read/project/src",
  principal_id: "agent_claude_abc123",
  granted_at: ~U[2026-01-28 00:00:00Z],
  expires_at: ~U[2026-01-29 00:00:00Z],    # optional
  parent_capability_id: nil,                 # set if delegated
  delegation_depth: 3,                       # decrements on delegation
  constraints: %{rate_limit: 100},           # not yet enforced
  signature: nil,                            # reserved, not yet used
  metadata: %{}
}
```

---

## 3. Threat Model

Updated for current architecture and federation-aware threat surface.

### Assets

| Asset | Owner Library | Protection Level |
|-------|--------------|-----------------|
| Capabilities | Security | Good locally — ETS store, GenServer choke point. **No protection across nodes.** |
| Trust Profiles | Trust | Good locally — GenServer-mediated, event-sourced. **Not portable.** |
| Consensus Decisions | Consensus | Good — sealed evaluations, quorum-based |
| Audit Trail | Historian/Persistence | Partial — events recorded, no access control |
| Agent Identity | **None** | **Not implemented** |
| Configuration | All | Partial — runtime access, no change auditing |

### Threat Summary

| ID | Threat | Severity | Status | Owner | Federation Impact |
|----|--------|----------|--------|-------|-------------------|
| **T8** | **Agent Impersonation** | **CRITICAL** | **None** | **Security** | **Trivial in federated env** |
| **T1** | **Capability Forgery** | **CRITICAL** | **Partial** | **Security** | **Trivial across nodes** |
| T9 | Node Spoofing | CRITICAL | Partial | Ops/Infra | Core federation risk |
| T2 | Trust Score Manipulation | HIGH | Good | Trust | Score inflation across clusters |
| T3 | Privilege Escalation via Delegation | HIGH | Good | Security | Delegation chain across clusters |
| T4 | Consensus Manipulation | HIGH | Good | Consensus | Sybil attack with fake agents |
| T11 | Federation Trust | HIGH | None | Cross-cutting | By definition |
| T13 | Agent Collusion | HIGH | None | Cross-cutting | Easier across clusters |
| T10 | Resource Exhaustion | HIGH | Partial | All | Amplified by federation |
| T12 | Trust Threshold Race Condition | MEDIUM | None | Trust/Security | Harder to detect across nodes |
| T5 | Audit Log Information Leakage | MEDIUM | Partial | Historian | Log aggregation risk |
| T6 | Denial of Service | MEDIUM | Partial | All | Amplified by federation |
| T7 | TOCTOU (check vs use gap) | MEDIUM | Partial | Security | Worse with network latency |

### The Federation Amplifier

In a single-node setup, T8 (impersonation) requires a malicious process in the same BEAM VM — unlikely in practice. In a federated setup, any node can send any message claiming any agent identity. Every trust-the-string assumption becomes an exploitable attack vector.

This is why **cryptographic identity is the foundation**, not a nice-to-have. Everything else (capability signing, delegation chains, trust portability) builds on it.

---

## 4. Gaps Analysis

### 4.1 Agent Identity (DONE — Phase 1, commit `baab417`)

No cryptographic agent identity exists. Agents are string IDs like `"agent_claude_abc123"`. Consequences:

- Any process/node can impersonate any agent
- No non-repudiation (agent can deny making a request)
- Delegation chains are trust-based, not cryptographically verified
- No basis for cross-node or cross-cluster authentication

**What's needed:**

```
Agent Identity = Ed25519 Keypair
├── Private key: held by agent, signs requests and delegations
├── Public key: registered, used by anyone to verify signatures
└── Agent ID: derived from public key hash (verifiable binding)

Signed Request Envelope
├── Request payload
├── Agent ID (claimed)
├── Timestamp (freshness)
├── Nonce (replay protection)
└── Ed25519 signature (proof)
```

**Where it belongs:** `arbor_security` — authentication is the first half of authorization.

### 4.2 Self-Verifying Capabilities (DONE — Phase 2, commit `c6cee64`)

Current capabilities are ETS records looked up by a local GenServer. In a federated environment, a node receiving a capability from a remote agent needs to verify it without calling the originating node.

**What's needed:**

```
Signed Capability
├── All current fields (resource_uri, principal_id, etc.)
├── Issuer ID: which authority granted this capability
├── Issuer signature: Ed25519 signature over capability contents
└── Delegation chain: array of signed delegation records
    └── Each: delegator_id + delegator_signature + constraints

Verification (local, no network call):
1. Verify issuer signature against known authority public key
2. Verify each delegation signature in chain
3. Verify constraints only get more restrictive down chain
4. Verify expiration
5. Verify principal_id matches presenting agent
```

**Where it belongs:** `arbor_security` + `arbor_contracts` (Capability struct evolves)

### 4.3 Constraint Enforcement (DONE — Phase 3)

The `constraints` field exists on capabilities but is ignored during authorization. `rate_limit: 100` is metadata, not a gate.

**What's needed:**
- Token bucket rate limiting per agent per resource
- Constraint evaluation during `authorize/4`
- Extensible constraint types (rate_limit, time_window, max_size, allowed_paths)

**Where it belongs:** `arbor_security`

### 4.4 Consensus Escalation (DONE — Phase 5)

Security's `authorize/4` type spec allows `{:ok, :pending_approval, proposal_id}` but no code path triggers it. High-risk operations get a binary answer.

**What's needed:**
- Configurable escalation rules in Security (not Bridge — native agents need this too)
- `authorize/4` checks escalation rules after capability check
- If escalation required: submit to Consensus, return `:pending_approval`
- Callback/signal mechanism for decision notification

**Where it belongs:** `arbor_security` owns the escalation check (it's part of the authorization pipeline). `arbor_consensus` owns the evaluation. Security depends on Consensus through a behaviour/config injection (not a hard dependency) — escalation rules reference a module that implements proposal submission.

**Why not Bridge:** Native Arbor agents on remote nodes need consensus escalation too. Bridge is only for external tool adapters. If escalation lives in Bridge, native agents bypass it entirely.

**Consensus is local policy.** Escalation rules, council composition, quorum thresholds, and evaluator types are all local operator configuration. Different nodes can have completely different consensus policies:

```elixir
# Node A: security-focused operator
config :arbor_security, :escalation_rules, [
  {"arbor://code/write/**", council: :security_review, quorum: 4},
  {"arbor://shell/exec/rm", council: :human_approval}
]

# Node B: permissive dev environment
config :arbor_security, :escalation_rules, [
  {"arbor://governance/**", council: :basic_review, quorum: 2}
]
# (everything else: no consensus needed)
```

No cross-cluster consensus coordination is required. A capability granted after consensus on Node A is just a signed capability to Node B — Node B doesn't care how it was approved, only that the signature is valid. Node B then applies its own escalation rules to whatever that agent tries to do locally.

### 4.5 Trust-Capability Synchronization (DONE — Phase 4)

Trust profiles exist but don't dynamically control capabilities. Trust tier changes should automatically grant/revoke capabilities.

**What's needed:**
- Tier promotion → grant capabilities from CapabilityTemplates
- Tier demotion → revoke capabilities above new tier
- Trust frozen → suspend all capabilities
- Trust unfrozen → restore suspended capabilities

**Where it belongs:** `arbor_trust` (owns the trigger via CapabilitySync, calls Security facade to grant/revoke)

**Design note:** This makes trust enforcement implicit — Security only checks capabilities, and capabilities already reflect trust state. No Security→Trust dependency needed.

### 4.6 Trust Locality (design principle — no infrastructure needed)

Trust is inherently local and subjective. Each node or cluster maintains its own trust profiles based on its own observations and its own operator's policies. Trust does not need to be portable or transferable.

**The model:**
- **Identity** is global — cryptographic, verifiable anywhere
- **Capabilities** are portable — signed, self-verifying, cross any boundary
- **Trust** is local — each node/cluster/operator decides what to trust

When an agent crosses a trust boundary (node → cluster → federation), it arrives with its identity and capabilities intact. But trust starts fresh at the receiving end, governed by the local operator's policy:
- Default: foreign agent starts at `:untrusted` regardless of home cluster score
- Configurable: operator can set per-cluster policies (e.g., "agents from cluster X start at `:probationary`")
- Earned locally: trust increases through local observations, not imported claims

**Why not portable trust:** Transferable trust scores create an attack surface — a compromised cluster could inflate scores for malicious agents. And trust is fundamentally a local judgment: "I've observed this agent behave well in *my* environment." Another operator's observations in *their* environment may not mean much here.

**Trust boundary spectrum:** Trust can degrade proportionally to the number of boundaries crossed:
- Same process → full local trust
- Same node, different process → local trust
- Same cluster, different node → slightly reduced trust
- Federated cluster → operator-defined starting point (default: untrusted)

This is a configuration concern, not an infrastructure one. No new code or cryptographic machinery needed — just operator-configurable trust policies for foreign agents.

### 4.7 Resource Quotas (not started)

No limits on capabilities per agent, active proposals, delegation chain growth, or storage.

**Where it belongs:** `arbor_security` (capability quotas), `arbor_consensus` (proposal quotas)

---

## 5. Authorization Spectrum (Target State)

The target is a layered authorization model. Every authorization request — whether from an external tool via Bridge, a native agent on the local node, or a remote agent across clusters — passes through the same pipeline.

```
Authorization request (from any source)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 0: Identity Verification                  (Security) │
│  "Is this actually agent_alice?"                            │
│  Verify Ed25519 signed request envelope                     │
│  Check timestamp freshness, nonce uniqueness                │
│  ~50μs                                                      │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: Capability Check                       (Security) │
│  "Does agent_alice hold a valid capability for this?"       │
│  Hierarchical URI matching, expiration, delegation chain    │
│  Verify capability signature + delegation signatures        │
│  ~10-50μs (local) / ~100μs (verify signed capability)      │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: Constraint Enforcement                 (Security) │
│  "Are rate limits / resource quotas satisfied?"             │
│  Token bucket, time windows, quota checks                   │
│  ~100μs                                                     │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: Trust Gate                             (implicit) │
│  "Is agent's trust tier sufficient?"                        │
│  Not a runtime check — trust tier changes trigger           │
│  capability grants/revocations via CapabilitySync.          │
│  Frozen agent = capabilities suspended.                     │
│  0μs (baked into capability state)                          │
├─────────────────────────────────────────────────────────────┤
│  Layer 4: Consensus Escalation                   (Security) │
│  "Does this resource require multi-perspective review?"     │
│  Configurable escalation rules per resource URI pattern.    │
│  If triggered: submit to Consensus, return :pending.        │
│  seconds to minutes                                         │
└─────────────────────────────────────────────────────────────┘

       │
       ▼
  {:ok, :authorized}
  {:ok, :pending_approval, proposal_id}
  {:error, :unauthorized | :identity_invalid | :rate_limited | ...}
```

### Where Each Layer Lives

| Layer | Library | Runs When |
|-------|---------|-----------|
| 0: Identity | Security | Every request (toggleable for single-node dev) |
| 1: Capability | Security | Every request |
| 2: Constraints | Security | Every request (when capability has constraints) |
| 3: Trust Gate | Trust (implicit) | On tier/freeze changes only |
| 4: Consensus | Security → Consensus | When escalation rules match |

### Entry Points

| Source | Entry Point | Layers Hit |
|--------|------------|------------|
| Claude Code (external tool) | Bridge → Security.authorize | 0-4 |
| Native local agent | Security.authorize | 0-4 |
| Remote agent (same cluster) | Security.authorize | 0-4 |
| Remote agent (federated cluster) | Security.authorize + verify signed capability | 0-4 |

Bridge adapts external tools into the standard authorization flow. It doesn't own any authorization logic itself — it translates tool calls into resource URIs and passes them to Security.

---

## 6. Evaluator Taxonomy (Consensus Roadmap)

Consensus currently has a `RuleBased` evaluator. The behaviour supports more:

| Evaluator | Use Case | Latency | Cost | Status |
|-----------|----------|---------|------|--------|
| **RuleBased** | Pattern matching on change type/scope | ~ms | Free | Exists |
| **Deterministic** | Run mix test, credo, dialyzer, sobelow | ~seconds | Free | Not started |
| **LLM** | Security review, code quality, architecture | ~30-60s | API cost | Not started |
| **Hybrid** | Deterministic gate → LLM if gate passes | ~60s | Conditional | Not started |
| **Human** | Critical decisions, escalations | ~hours | Staff time | Not started |
| **Composite** | Chain evaluators, early-exit on rejection | Varies | Varies | Not started |

The **Deterministic** evaluator is the highest-value next addition. Running `mix test` and `mix credo --strict` as council perspectives gives concrete, zero-cost safety checks before escalating to expensive LLM evaluation.

---

## 7. Roadmap

Ordered by foundational dependency and security impact. Each phase compiles and passes tests independently. The key reordering from the original draft: **identity first**, because it's the foundation everything else builds on in a multi-node world.

### Phase 1: Agent Identity (T8 — DONE ✓ `baab417`)

**Goal:** Cryptographic agent identity. Every agent has a keypair. Every request can be authenticated.

**Scope:**
- `Arbor.Security.Identity`: Ed25519 keypair generation, agent_id derivation from public key hash
- `Arbor.Security.Identity.Registry`: public key storage and lookup (GenServer + ETS)
- `Arbor.Security.Identity.SignedRequest`: sign/verify request envelopes with timestamp + nonce replay protection
- Identity types in `arbor_contracts`
- Identity verification toggleable in `authorize/4` (on by default, disable for dev convenience)

**Libraries touched:** `arbor_security`, `arbor_contracts`

**Why first:** This is the foundation. Capability signing needs an issuer identity. Delegation chains need delegator signatures. Federation needs cross-cluster identity verification. Without cryptographic identity, none of the subsequent phases have a root of trust.

**Single-node benefit:** Even on one node, identity prevents accidental privilege confusion between agents and provides non-repudiation for audit trails.

### Phase 2: Self-Verifying Capabilities (T1 — DONE ✓ `c6cee64`)

**Goal:** Capabilities are cryptographically signed by their issuer and verifiable without network calls.

**Scope:**
- Sign capabilities on creation using issuer's private key (system authority or delegating agent)
- Verify signature on every `find_authorizing` call
- Sign delegation chains: each delegation signed by the delegator's private key
- Reject capabilities with invalid or missing signatures
- Capability struct evolves: `issuer_id`, `issuer_signature` fields (alongside existing `signature`)

**Libraries touched:** `arbor_security`, `arbor_contracts`

**Why second:** Depends on Phase 1 (need identities to sign with). After this phase, capabilities are self-verifying — a remote node can validate a capability using only the capability itself and a set of trusted public keys.

### Phase 3: Constraint Enforcement (DONE ✓)

**Goal:** Make the `constraints` field on capabilities actually enforced.

**Scope:**
- Token bucket rate limiting per agent per resource
- Constraint evaluation during `authorize/4`
- Extensible constraint types: `rate_limit`, `time_window`, `allowed_paths`, `requires_approval` (placeholder)

**Implemented:**
- `Arbor.Security.Constraint` — stateless-first evaluator (time_window, allowed_paths before rate_limit)
- `Arbor.Security.Constraint.RateLimiter` — GenServer, per-{agent, resource} token buckets, monotonic time, periodic cleanup
- `authorize/4` enforces constraints; `can?/3` remains pure (no side effects)
- Config: `constraint_enforcement_enabled?`, rate limiter tuning knobs

**Libraries touched:** `arbor_security`, `arbor_contracts`

**Why third:** Low risk, high practical value. Bridge's default capabilities already specify `rate_limit` values that aren't enforced. This makes them real.

### Phase 4: Trust-Capability Synchronization (DONE ✓)

**Goal:** Trust tier changes automatically reflected in capabilities.

**Scope:**
- Tier promotion: grant capabilities from CapabilityTemplates (signed by system authority)
- Tier demotion: revoke capabilities above new tier
- Trust frozen: revoke modifiable capabilities (non-readonly)
- Trust unfrozen: restore capabilities from templates for current tier

**Status:** Already implemented in `CapabilitySync` module. Phase 2's automatic capability signing made all synced capabilities cryptographically valid. Added integration tests to verify full flow.

**Libraries touched:** `arbor_trust` (CapabilitySync), `arbor_security` (grant/revoke via facade)

**Why fourth:** Completes Layer 3 (implicit trust gate). Capabilities now reflect trust state without a runtime trust check, preserving the hierarchy (no Security→Trust dependency).

### Phase 5: Consensus Escalation (DONE ✓)

**Goal:** High-risk operations escalate to multi-perspective consensus review.

**Scope:**
- Capabilities with `requires_approval: true` trigger consensus submission
- `authorize/4` checks escalation after constraint enforcement
- Consensus module injected via config (no hard dep from security → consensus)
- Returns `{:ok, :pending_approval, proposal_id}` when escalated
- Signal emitted: `:authorization_pending`

**Implemented:**
- `Arbor.Security.Escalation` — handles consensus submission via configurable module
- Config: `consensus_escalation_enabled?`, `consensus_module` (injectable)
- Graceful degradation: returns error if consensus unavailable (fail closed)
- Full test coverage for escalation paths

**Libraries touched:** `arbor_security` (Escalation module, facade update)

**Why fifth:** Completes Layer 4. Depends on Layers 0-3 working correctly. Lives in Security so native agents (not just Bridge) get consensus escalation.

### Phase 6: Deterministic Evaluator (DONE ✓)

**Goal:** Concrete, zero-cost evaluator perspectives for consensus.

**Scope:**
- `mix test` evaluator: run tests in sandbox, vote based on pass/fail
- `mix credo --strict` evaluator: vote on code quality
- `mix compile --warnings-as-errors` evaluator
- Integration with `arbor_shell` / `arbor_sandbox` for isolated execution

**Implemented:**
- `Arbor.Consensus.EvaluatorBackend.Deterministic` — runs actual shell commands via `Arbor.Shell`
- Supported perspectives: `:mix_test`, `:mix_credo`, `:mix_compile`, `:mix_format_check`, `:mix_dialyzer`
- Config: `deterministic_evaluator_timeout`, `deterministic_evaluator_sandbox`, `deterministic_evaluator_default_cwd`
- Requires `project_path` in proposal metadata
- Votes based on exit code (0 = approve, non-zero = reject)

**Libraries touched:** `arbor_consensus`, `arbor_shell`

### Phase 7: Resource Quotas (T6, T10)

**Goal:** Prevent resource exhaustion.

**Scope:**
- Per-agent capability limits in CapabilityStore
- Global capability limits
- Delegation chain depth enforcement at store level
- Active proposal limits per agent in Consensus

**Libraries touched:** `arbor_security`, `arbor_consensus`

### Phase 8: LLM Evaluator

**Goal:** LLM-based evaluation perspectives for consensus.

**Scope:**
- LLM evaluator backend with structured prompts per perspective
- Response parsing and vote extraction
- Model diversity per perspective (reduces shared bias)
- Cost controls (deterministic gate before LLM)

**Libraries touched:** `arbor_consensus`

### Phase 9: Federation Security

**Goal:** Cross-cluster capability exchange and identity verification.

**Scope:**
- Cluster identity: each cluster has a keypair (like agent identity but for clusters)
- Cluster public key registry: known/trusted clusters
- Cross-cluster capability verification: verify capability signed by trusted cluster authority
- Foreign agent trust policy: configurable starting tier for agents from each known cluster
- No trust portability — trust is local, foreign agents re-earn it

**Libraries touched:** `arbor_security` (cluster identity, foreign capability verification), `arbor_trust` (foreign agent trust policy config)

**Why last:** Depends on all prior phases. Identity, signing, and trust sync must be solid before extending across trust boundaries. Trust itself doesn't need federation infrastructure — it's inherently local.

### Future Considerations (Not Roadmapped)

- **Signed Delegation Tokens** — compact JWT-like tokens for agent-to-agent task delegation
- **External Identity Providers** — LDAP, OAuth for human-agent binding
- **Human-Agent Accountability** — trace agent actions to responsible humans
- **Cross-Agent Collusion Detection** (T13) — data flow taint tracking, capability incompatibility rules
- **TLS Distribution** (T9) — operational concern, documented but not library code
- **Trust Reputation Hints** — optional, non-authoritative hints from home cluster ("this agent had score X here") that receiving operators can choose to consider or ignore. Not attestations — just hints. Receiving node is never obligated to act on them.

---

## 8. Architectural Constraints

These hold across all phases:

1. **Security stays Level 1.** Depends on contracts and signals only. Does not depend on Trust, Consensus, or Bridge.

2. **Trust controls capabilities through CapabilitySync, not runtime checks.** Trust tier changes trigger capability grants/revocations. Security never calls Trust.

3. **Consensus is opt-in and injected.** Security references a consensus submission module via config/behaviour, not a hard dependency. System works without consensus enabled.

4. **No circular dependencies.** The hierarchy:
   ```
   contracts → signals, security, consensus → trust → bridge
   ```

5. **Facades only.** Libraries interact through public facades, never internal modules.

6. **Capabilities are the universal authorization primitive.** All authorization checks reduce to "does this agent hold a valid, signed capability for this resource?" Identity, trust, and consensus feed into what capabilities exist and how they're verified — but the check is always a capability lookup.

7. **Self-verifying credentials.** Capabilities, identities, and delegation chains must be verifiable without calling back to the issuing authority. This enables federation and offline verification.

8. **Authorization pipeline is universal.** The same `Security.authorize/4` pipeline handles external tools (via Bridge), native local agents, and remote/federated agents. Bridge is an adapter, not an authorization authority.

9. **Trust and consensus are local governance.** Each node/cluster operator defines their own trust policies and consensus rules. No cross-cluster coordination needed for either. Identity is global, capabilities are portable, governance is local.

---

## 9. Decision Log

| Decision | Rationale | Alternative Considered |
|----------|-----------|----------------------|
| Identity first, not constraints first | Foundation for signing, delegation, federation. Single-node constraints are useful but not critical. | Constraints first — lower risk but doesn't unlock anything |
| Consensus escalation in Security, not Bridge | Native agents need consensus too. Bridge is only for external tools. | Bridge owns escalation — breaks for native agents |
| Self-verifying capabilities | Federation requires offline verification. Can't call home to check every capability. | Server-verified capabilities — breaks in federated/partitioned networks |
| Trust gate is implicit (capability sync) | Avoids Security→Trust dependency. Keeps authorize fast. | Runtime trust check — violates hierarchy |
| Identity lives in Security | Authentication + authorization are the same boundary | Separate identity library — too small, adds unnecessary dep |
| Consensus injected via config | Keeps Security independent of Consensus at compile time | Hard dependency — couples Level 1 libraries |
| Ed25519 over RSA/ECDSA | Fast signatures, small keys, BEAM `:crypto` native support, modern standard | RSA — slower, larger keys. ECDSA — more complex, fewer advantages |
| Trust is local, not portable | Trust is a subjective local judgment. Portable trust creates attack surface (inflated scores from compromised clusters). Foreign agents re-earn trust locally. | Portable trust attestations — adds crypto complexity, questionable value, new attack vector |
| Trust boundary spectrum via config | Operator decides starting tier for foreign agents. No infrastructure needed — just config. | Cryptographic trust transfer — over-engineered for a policy question |
| Consensus governance is local | Each operator defines own rules, quorum, evaluators. No cross-cluster consensus coordination. | Federated consensus protocol — distributed consensus about consensus is turtles all the way down |

---

## Appendix A: Resource URI Scheme

```
arbor://fs/read/{path}          File system read
arbor://fs/write/{path}         File system write
arbor://shell/exec/{command}    Shell command execution
arbor://agent/spawn             Agent creation
arbor://net/http/{url}          HTTP requests
arbor://net/search              Web search
arbor://tool/{name}             Generic tool access (fallback)
arbor://code/write/self/*       Self-modification (future)
arbor://governance/change/*     Governance changes (future)
arbor://capability/modify/*     Capability modification (future)
arbor://audit/read/*            Audit log access (future)
```

## Appendix B: Capability Lifecycle (Target State)

```
            System Authority
            (cluster keypair)
                  │
                  │ signs
                  ▼
         ┌─────────────────┐
         │   Capability     │
         │  resource_uri    │
         │  principal_id    │
         │  issuer_id       │◄── system authority ID
         │  issuer_sig      │◄── Ed25519 signature
         │  delegation: 3   │
         │  constraints     │
         │  expires_at      │
         └────────┬────────┘
                  │
                  │ agent delegates (signs with own key)
                  ▼
         ┌─────────────────┐
         │   Delegated Cap  │
         │  resource_uri    │◄── same or narrower scope
         │  principal_id    │◄── new agent
         │  parent_cap_id   │◄── points to original
         │  delegation: 2   │◄── decremented
         │  constraints     │◄── can only add, not remove
         │  delegation_chain│
         │  ├─ delegator_id │
         │  ├─ delegator_sig│◄── Ed25519 signature
         │  └─ constraints  │
         └────────┬────────┘
                  │
                  │ verification (any node, no network call)
                  ▼
         1. Verify issuer_sig against system authority pubkey  ✓
         2. Verify delegation_chain signatures                 ✓
         3. Verify constraints only get more restrictive       ✓
         4. Verify expiration                                  ✓
         5. Verify principal_id matches presenting agent       ✓
         ──────────────────────────────────────────────────────
         Result: AUTHORIZED (self-verified)
```

## Appendix C: Dangerous Command List

Commands that require elevated trust (currently hard-blocked in Bridge):

```
rm, sudo, su, chmod, chown, kill, pkill, dd, mkfs, fdisk
```

Target: map these to trust tier requirements via CapabilityTemplates rather than hard blocks. An autonomous-tier agent should be able to `rm` within its project scope. An untrusted agent should not.
