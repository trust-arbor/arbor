# Arbor Feature Roadmap

*A comprehensive view of what's built, what's in progress, and what's planned.*

---

## Security (`arbor_security`)

### Shipped
- Capability-based authorization kernel with URI-scoped permissions
- Ed25519 cryptographic identity (per-agent keypairs, signed requests)
- Trust profiles with block/ask/allow/auto modes per URI prefix
- PolicyEnforcer — JIT capability granting from trust profiles
- ApprovalGuard — trust-based approval escalation to consensus
- URI Registry with deny-by-default enforcement
- FileGuard — path-scoped file authorization integrated into auth chain
- Reflex system for instant safety blocks
- Delegation chain verification (Ed25519 signed chains)
- Capability constraints (rate limits, time windows, session/task scoping)
- Identity lifecycle (active/suspended/revoked states)
- Invocation receipts (opt-in per-tool-call audit trail)
- Session tokens (HMAC-SHA256 for human identity verification)
- OIDC authentication (Zitadel, Google, GitHub providers)
- Prompt hardening and injection defense
- SafeAtom/SafePath for untrusted input protection
- Signal-bus privacy hardening

### In Progress
- Onboarding interview for initial trust profile establishment (Phase 6)

### Planned
- Distributed capability store (cross-node)
- Distributed trust zones with migration
- SPIFFE agent identity (brainstorming)
- NIST alignment gaps (brainstorming)
- PII tokenization for cloud LLM calls (brainstorming)

---

## Agent Lifecycle (`arbor_agent`)

### Shipped
- BranchSupervisor — per-agent rest_for_one supervision (host, executor, session)
- Lifecycle.create + Lifecycle.start — single entry point for all agent creation
- Agent.Registry — centralized discovery with all child PIDs as metadata
- APIAgent host — query interface with session routing
- Executor — intent processing for agent body/actions
- Profile persistence (BufferedStore + Postgres)
- Template system — code-defined agent archetypes (10 builtin templates)
- AgentSeed mixin — portable identity, memory, signals, capabilities
- Bootstrap — auto-start agents on boot from config + persisted profiles
- HealingSupervisor — signal-based agent health monitoring
- SpawnWorker — ephemeral subagents with intersection trust model
- Intent-based delegation (CapabilityResolver maps natural language → URIs)
- Worker progress signals (spawned, started, tool_call, completed, failed, destroyed)
- Partial results on timeout (returns accumulated text instead of hard error)
- Context compaction (progressive forgetting for long-running sessions)
- Per-user supervisors with quota enforcement

### In Progress
- Subagent parallel fan-out (spawn_workers plural)
- Escalate-to-parent tool for workers

### Planned
- Specialized agents (Security Auditor, Test Agent, Pipeline Agent)
- Cost budget enforcement per worker spawn

---

## LLM Integration (`arbor_ai`, `arbor_orchestrator/unified_llm`)

### Shipped
- UnifiedLLM Client with 10 provider adapters (OpenRouter, Anthropic, OpenAI, Gemini, XAI, Ollama, LM Studio, Zai, ZaiCodingPlan, ACP)
- ToolLoop — multi-turn tool-calling with accumulated usage tracking
- Streaming support (SSE events, stream callbacks)
- Cost tracking (per-call, per-session, budget warnings)
- Structured LLM tracing with trace_id correlation (Logger + Historian)
- Model-aware context windows (ModelProfile, 29+ models)
- Sensitivity routing (route by data classification level)
- Embedding support (OpenAI, Ollama backends + hash fallback)
- ACP protocol — CLI agents (Claude, Gemini, Codex) as LLM backends
- Provider error mapping with retry logic
- Tool help action — on-demand parameter documentation

### In Progress
- Comprehensive model evaluation framework

### Planned
- LLM prefill and interleaving (brainstorming)
- Dynamic provider parsing (brainstorming)

---

## Orchestration (`arbor_orchestrator`)

### Shipped
- DOT graph parser and engine (parse → compile → execute)
- 15 canonical handler types (start, exit, branch, parallel, fan_in, compute, transform, exec, read, write, compose, map, adapt, wait, gate)
- 12 legacy handler aliases for backward compatibility
- Handler DI system with alias resolution
- Typed IR compiler with structural validation
- 8-step middleware chain (secret scan, capability check, taint, sanitization, safe input, checkpoint, budget, signal)
- Checkpoint-based crash recovery
- Pipeline templates (ETL, propose-approve, map-reduce, retry-escalate, etc.)
- Engine authorization (per-node capability checks)
- Fidelity transformer (context summarization per pipeline node)
- Content-hash skip (avoid recomputing unchanged nodes)
- Session — DOT-driven turn and heartbeat execution
- SessionConfig — single shared builder for session init
- ContextBuilder, ResultProcessor, Persistence (split from monolithic Builders)

### In Progress
- DOT pipeline consolidation

### Planned
- Investigation.ex → DOT migration
- Orchestrator HTTP server (brainstorming)

---

## Consensus & Governance (`arbor_consensus`)

### Shipped
- Advisory council with 13 analytical perspectives
- Research-backed evaluators (council agents with read-only tools)
- `--research` flag for evidence-backed council consultations
- RPC-based `mix arbor.consult` (events persist to server's Historian)
- ConsultationLog with per-perspective cost/token tracking
- Coordinator with proposal lifecycle (submit → evaluate → decide)
- Quorum enforcement (majority, supermajority, unanimous)
- Advisory mode (non-binding analysis) + Decision mode (binding votes)
- Topic registry for routing proposals to relevant evaluators
- Configurable provider/model per perspective
- Multi-model consultations (same perspective, multiple providers)
- Skill library integration for perspective system prompts

### In Progress
- Council v2 Phase 2: multi-round deliberation with evidence sharing
- Council v2 Phase 3: fresh eyes (new perspectives after round 1)

### Future
- Philosophical council variant (same question, same perspective, multiple models)
- Sycophancy detection (Phase 6)
- Adaptive depth (Phase 5)

---

## Memory (`arbor_memory`)

### Shipped
- Working memory (ETS + Postgres persistence)
- Goal store (active goals with progress tracking)
- Intent store (ring buffer for action intentions)
- Knowledge graph (nodes, edges, semantic relationships)
- Self-knowledge (agent identity model)
- Chat history persistence
- Thinking store (agent reasoning log)
- Code store (code artifacts)
- Preferences store
- Proposal store (memory governance)
- Index supervisor (per-agent vector index with LRU eviction)
- Semantic embedding search (Ollama/OpenAI + hash fallback)
- Context compactor (4-step progressive forgetting pipeline)
- Memory consolidation (cross-session knowledge integration)
- BufferedStore (ETS cache + async Postgres persistence)

### In Progress
- Memory subsystem evaluations (v1/v2 prompt-only done, v3 real-task pending)

---

## Communication (`arbor_comms`, `arbor_dashboard`, `arbor_gateway`)

### Shipped
- Phoenix LiveView dashboard (chat, agents, signals, consensus, memory views)
- Inline approval panel (Approve/Always Allow/Deny)
- Resizable panels in chat interface
- Signal-based real-time updates with backpressure
- Signal integration (async messaging via Signal app)
- Limitless pendant integration (inbound voice memos)
- MCP gateway (agent-to-agent communication via Model Context Protocol)
- Channel system (9 actions: create, join, leave, send, read, list, invite, update, members)
- Channel encryption and identity verification

### In Progress
- Unified channel communications Phase 5 (external service adapters)

### Planned
- Voice pipeline with phone cluster
- XMTP federation layer (brainstorming)

---

## Observability (`arbor_signals`, `arbor_historian`)

### Shipped
- Signal bus (PubSub-based event delivery)
- Signals.durable_emit — centralized durable emission (signal bus + EventLog ETS + Postgres)
- Historian (event store with Postgres backend, query API)
- Structured LLM tracing (trace_id, provider, model, tokens, cost, duration)
- Worker lifecycle signals (durable)
- Security audit events (durable)
- Trust change events (durable)
- Shell command events (durable)
- Agent lifecycle events (durable)
- Memory events (durable)
- Consensus events (durable)
- Taint blocked/reduced events (durable)

### Shipped (Monitoring)
- Arbor Monitor (GenServer + recon + ETS, 10 skills)
- HealingSupervisor (anomaly detection + auto-recovery)
- Diagnostician agent (ops room with real-time monitoring)

---

## Multi-User (`arbor_agent`, `arbor_security`, `arbor_dashboard`)

### Shipped
- OIDC authentication (provider-agnostic, Zitadel tested)
- TenantContext (workspace scoping per user)
- Identity aliases (map secondary OIDC identities to primary Arbor identity)
- Per-user DynamicSupervisors with quota enforcement
- Session tokens for human identity in signal subscriptions
- Agent scoping by principal_id

### Planned
- Dashboard scoping and visibility (Phase 3)
- Cross-user collaboration (Phase 4)

---

## Developer Experience

### Shipped
- 150+ agent actions with progressive tool disclosure
- `mix arbor.consult` — council consultation from CLI
- `mix arbor.start/stop/restart/status` — server lifecycle
- `mix arbor.agent` — agent management (create, resume, chat, destroy)
- `mix arbor.user` — user/identity management
- `mix arbor.pipeline.run/validate/viz/compile` — pipeline tools
- `mix arbor.hands.spawn/send/stop` — worktree agent management
- `mix quality` — format + credo strict
- `mix test.fast` — unit tests only
- Template system with 10 builtin templates
- CapabilityIndex with ActionProvider + SkillProvider
- Tool discovery via `tool_find_tools`
- Tool documentation via `tool_help`
- Behavioral test framework (BehavioralCase, LLMAssertions, MockLLM)
- Test tagging conventions (fast/slow, integration, database, external, llm)
- Eval framework (DOT compilation, advisory, memory, summarization)

### Planned
- Documentation pass (comprehensive user guides)
- CI/CD with GitHub Actions (brainstorming)

---

## Infrastructure

### Shipped
- Umbrella project (22 apps) with strict library hierarchy (Level 0-2 + Standalone)
- Contract-first design (shared types and behaviours in arbor_contracts)
- Facade pattern (one public module per library)
- Postgres persistence (via Ecto + BufferedStore)
- Distributed Erlang support (longnames, clustering, EPMD)
- Sandbox system (pure/limited/full/container modes)
- Cartographer (node discovery, osquery enrichment, scheduling)

### Planned
- Distributed BEAM architecture (multi-node agent migration)

---

*Last updated: 2026-03-17*
