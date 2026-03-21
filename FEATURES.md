# Arbor Features

*Everything Arbor can do today — the complete feature set.*

---

## Security & Trust (`arbor_security`, `arbor_trust`)

### Authorization
- Capability-based authorization kernel with URI-scoped permissions
- PolicyEnforcer — JIT capability granting from trust profiles
- ApprovalGuard — trust-based escalation to consensus council
- URI Registry with 40+ canonical prefixes and deny-by-default enforcement
- FileGuard — path-scoped file authorization integrated into auth chain
- Reflex system for instant safety blocks (ETS-based, sub-ms latency)
- Delegation chain verification (Ed25519 signed, depth-limited)
- Capability constraints: rate limits, time windows, max_uses, not_before
- Session-scoped and task-scoped capability binding
- Invocation receipts with Ed25519 signing (opt-in audit trail)
- Graceful degradation when CapabilityStore unavailable (falls through to PolicyEnforcer)

### Identity & Cryptography
- Ed25519 cryptographic identity (per-agent keypairs)
- Signed requests with nonce replay protection
- SigningKeyStore with AES-256-GCM encrypted key storage
- Identity lifecycle (active/suspended/revoked states)
- Session tokens (HMAC-SHA256 for human identity verification)
- OIDC authentication (Zitadel, Google, GitHub providers)
- Identity aliases (map secondary OIDC identities to primary Arbor identity)

### Trust Profiles
- URI-prefix trust rules with block/ask/allow/auto modes
- Three-layer resolution: user rules → security ceilings → model constraints
- Sensitivity routing via effective_mode
- Confirmation tracking with streak-based graduation (suggestion-based)
- Shell and governance never auto-approve (security invariant)
- Preset profiles for common trust levels

### Safety
- Prompt hardening and injection defense
- SafeAtom — prevents atom table DoS from untrusted input
- SafePath — path traversal protection for user-provided paths
- Signal-bus privacy hardening
- Taint tracking and enforcement (compile-time + runtime)

---

## Agent Lifecycle (`arbor_agent`)

### Core Architecture
- BranchSupervisor — per-agent rest_for_one supervision (host, executor, session)
- Lifecycle.create + Lifecycle.start — single entry point for all agent creation
- Agent.Registry — centralized discovery with all child PIDs as metadata
- APIAgent host — query interface with session routing
- Executor — intent processing for agent body/actions
- Template system — code-defined agent archetypes (10 builtin templates)
- AgentSeed mixin — portable identity, memory, signals, capabilities
- Bootstrap — auto-start agents on boot from config + persisted profiles
- HealingSupervisor — signal-based agent health monitoring

### Autonomy
- Heartbeat loop with cognitive mode selection (routine/deep/reflective)
- Goal pursuit with decomposition and progress tracking
- Intent store (ring buffer for action intentions)
- Mind→Body (intents) and Body→Mind (percepts) communication channels
- ActionCycleServer — LLM-driven action planning and execution
- Temporal awareness (session timestamps, agent time context)

### Subagents & Workers
- SpawnWorker — ephemeral subagents with intersection trust model
- Worker progress signals (spawned, started, tool_call, completed, failed, destroyed)
- Partial results on timeout (returns accumulated text instead of hard error)
- Intent-based delegation (CapabilityResolver maps natural language → URIs)

### Session Management
- DOT-driven turn and heartbeat execution
- Context compaction (4-step progressive forgetting pipeline)
- Model-aware context windows (ModelProfile, 29+ models)
- SessionConfig — single shared builder for session init
- Per-user supervisors with quota enforcement
- Chat history persistence

---

## LLM Integration (`arbor_ai`, `arbor_orchestrator/unified_llm`)

### Provider Support
- UnifiedLLM Client with 10 provider adapters:
  - Cloud: OpenRouter, Anthropic, OpenAI, Google Gemini, XAI (Grok)
  - Local: Ollama, LM Studio
  - Specialized: Zai, ZaiCodingPlan
  - Agent: ACP (Claude Code, Gemini CLI, Codex as LLM backends)
- Automatic API key injection per provider
- Provider error mapping with retry logic
- Model selection with LLMDB (capabilities, pricing, context sizes)

### Tool Calling
- ToolLoop — multi-turn tool-calling with accumulated usage tracking
- 150+ agent actions with progressive tool disclosure
- Tool discovery via `tool_find_tools` (on-demand, not bulk-loaded)
- Tool documentation via `tool_help` (parameter docs at runtime)
- ToolBridge — registers Arbor actions as Claude SDK-compatible tools
- ToolServer — serves tools over MCP to external clients

### Streaming & Tracing
- SSE streaming support with stream callbacks
- Cost tracking (per-call, per-session, budget warnings)
- Structured LLM tracing with trace_id correlation
- Token counting and budget enforcement
- Sensitivity routing (route by data classification level)

### Embeddings
- Embedding support (OpenAI, Ollama backends)
- Hash-based fallback when no embedding provider available
- Per-agent vector index with LRU eviction

---

## Orchestration (`arbor_orchestrator`)

### DOT Pipeline Engine
- DOT graph parser and engine (parse → compile → execute)
- 15 canonical handler types: start, exit, branch, parallel, fan_in, compute, transform, exec, read, write, compose, map, adapt, wait, gate
- Typed IR compiler with structural validation
- Pipeline templates: ETL, propose-approve, map-reduce, retry-escalate
- Content-hash skip (avoid recomputing unchanged nodes)
- Checkpoint-based crash recovery
- Hot-reload of DOT files for running sessions

### Middleware & Security
- 8-step middleware chain: secret scan, capability check, taint, sanitization, safe input, checkpoint, budget, signal
- Engine authorization (per-node capability checks)
- Fidelity transformer (context summarization per pipeline node)

### Handler System
- Handler DI system with alias resolution
- 12 legacy handler aliases for backward compatibility
- ContextBuilder, ResultProcessor, Persistence (split from monolithic module)

---

## Consensus & Governance (`arbor_consensus`)

### Advisory Council
- 13 analytical perspectives (security, ethics, UX, performance, architecture, etc.)
- Research-backed evaluators (council agents with read-only tools)
- `--research` flag for evidence-backed consultations
- RPC-based `mix arbor.consult` (events persist to Historian)
- ConsultationLog with per-perspective cost/token tracking

### Decision Framework
- Coordinator with proposal lifecycle (submit → evaluate → decide)
- Quorum enforcement (majority, supermajority, unanimous)
- Advisory mode (non-binding analysis) + Decision mode (binding votes)
- Topic registry for routing proposals to relevant evaluators
- Configurable provider/model per perspective
- Multi-model consultations (same perspective, multiple providers)
- Skill library integration for perspective system prompts

---

## Memory (`arbor_memory`)

### Storage Systems
- Working memory (ETS + Postgres persistence via BufferedStore)
- Goal store (active goals with progress tracking)
- Intent store (ring buffer for action intentions)
- Knowledge graph (nodes, edges, semantic relationships)
- Self-knowledge (agent identity model)
- Thinking store (agent reasoning log)
- Code store (code artifacts)
- Preferences store
- Proposal store (memory governance)
- Chat history persistence

### Intelligence
- Semantic embedding search (Ollama/OpenAI + hash fallback)
- Context compactor (4-step progressive forgetting: semantic squash → omission → distillation → narrative)
- Memory consolidation (cross-session knowledge integration)
- Index supervisor (per-agent vector index with LRU eviction)
- File index enrichment (module/function extraction for code context)

### Persistence
- BufferedStore pattern (ETS cache + async Postgres writes)
- Dual-emit (local EventLog for queries + signal bus for real-time)
- JSONFile backend for development (no database needed)

---

## Communication & Interface

### Dashboard (`arbor_dashboard`)
- Phoenix LiveView dashboard with real-time updates
- Chat interface with agent selection and streaming responses
- Inline approval panel (Approve/Always Allow/Deny)
- Resizable panels
- Signal viewer with filtering
- Consensus consultation viewer
- Memory browser
- Agent lifecycle management UI

### External Communication (`arbor_comms`)
- Signal app integration (async messaging via signal-cli)
- Limitless pendant integration (inbound voice memos)
- Channel system with 9 actions: create, join, leave, send, read, list, invite, update, members
- Channel encryption and identity verification
- Channel discovery and management

### Gateway (`arbor_gateway`)
- MCP gateway (agent-to-agent communication via Model Context Protocol)
- AgentEndpoint — expose agent actions as MCP tools
- EndpointRegistry — discover and route to agent MCP endpoints

---

## Observability (`arbor_signals`, `arbor_historian`, `arbor_monitor`)

### Signal Bus
- PubSub-based event delivery with category/type filtering
- Signals.durable_emit — centralized emission (signal bus + EventLog ETS + Postgres)
- Backpressure handling (message queue length checks, drop when >500)
- Debounced signal-triggered reloads (500ms window)

### Durable Events
- Worker lifecycle signals
- Security audit events
- Trust change events
- Shell command events
- Agent lifecycle events
- Memory events
- Consensus events
- Taint blocked/reduced events
- LLM trace events

### Historian
- Event store with Postgres backend
- Query API for event retrieval and analysis
- Stream-based event organization

### Monitoring
- Arbor Monitor (GenServer + recon + ETS, 10 monitoring skills)
- HealingSupervisor (anomaly detection + auto-recovery)
- Diagnostician agent (ops room with real-time monitoring)
- Process diagnostics via recon (top processes, memory, reductions)

---

## Multi-User (`arbor_security`, `arbor_dashboard`)

- OIDC authentication (provider-agnostic, tested with Zitadel)
- TenantContext (workspace scoping per user)
- Identity aliases (map external identities to Arbor identity)
- Per-user DynamicSupervisors with quota enforcement
- Session tokens for human identity in signal subscriptions
- Agent scoping by principal_id

---

## Actions (`arbor_actions`)

### 73+ Built-in Actions

**File Operations**
- Read, Write, List, Search, Move, Delete
- FileGuard path-scoped authorization
- Taint tracking on file content

**Shell**
- Execute commands with command-specific URI authorization
- Direct execution (bypasses shell parsing)
- Async execution with result streaming
- Sandbox modes: none, basic, strict, container

**Code**
- HotLoad — dynamic module loading with authorization
- Analyze, Format, Eval (sandboxed execution)

**AI / LLM**
- GenerateText, AnalyzeCode, Summarize
- Sensitivity-routed to appropriate providers

**Browser Automation**
- Session-based browser control (7 subcategories)
- Navigation, interaction, query, content extraction
- JavaScript evaluation, synchronization primitives

**Memory Operations**
- Read, Write, Search, Index (global memory)
- Session-specific: memory, goals, LLM, execution
- Code store, Cognitive mode, Identity model
- Relationship management (get, save, moment, browse, summarize)
- Memory review and consolidation

**Communication**
- Channel: create, join, leave, send, read, list, invite, update, members
- Signal sending and subscription

**Agent Management**
- Spawn ephemeral workers with intersection trust
- Delegate tasks via intent-based routing
- Profile operations (set display name, preferences)
- Identity endorsements and web-of-trust signing

**Governance**
- Submit proposals, vote
- Consensus consultation

**Evaluation & Quality**
- LLM-as-judge evaluation pipeline with rubric-based verdicts
- Code quality checks (idiom, documentation, naming, PII detection)
- Pipeline evaluation and validation

**System & Remediation**
- Monitor, Diagnostics, Configuration
- BEAM runtime remediation: kill process, stop supervisor, restart child, force GC, drain queue
- Background checks for data source health (6 diagnostic checks)
- Skill library management (search, activate, deactivate, import, compile)
- Jobs — persistent task tracking

**Taint & Security Actions**
- Taint role checking and enforcement
- Taint signal emission for violations
- Policy enforcement with sanitization requirements

### Action Framework
- Jido-based action modules with schema validation
- Facade pattern — auth at the facade level, not the action level
- Canonical URI mapping per action (UriRegistry with 40+ prefixes)
- Taint enforcement per action with extended role format `{:control, requires: [...]}`
- Progressive tool disclosure (core tools + on-demand discovery via `tool_find_tools`)
- Tool documentation at runtime via `tool_help`

---

## Infrastructure

### Architecture
- Umbrella project with 22 apps and strict library hierarchy (Level 0-2 + Standalone)
- Contract-first design (shared types and behaviours in arbor_contracts)
- Facade pattern (one public module per library, no cross-library internal imports)
- Zero-cycle dependency graph enforced by hierarchy

### Persistence
- Postgres via Ecto + BufferedStore (ETS cache + async writes)
- SQLite as default development database
- JSONFile backend for zero-database development
- Checkpoint system for crash recovery

### Distributed
- Distributed Erlang support (longnames, clustering, EPMD)
- Cross-machine clustering via `mix arbor.cluster connect`
- Cartographer (node discovery, osquery enrichment, scheduling)
- ARBOR_NODE_HOST env var for cluster configuration

### Sandbox
- Four execution modes: pure, limited, full, container
- Docker-based container isolation (optional)
- SafeAtom/SafePath for untrusted input

### Shell (`arbor_shell`)
- Command execution with per-command URI authorization
- PortSession — port-based session management
- ExecutionRegistry — tracking of shell executions
- execute_direct/3 — structured command execution bypassing shell parsing
- execute_async/2 — asynchronous command execution with streaming
- Sandbox modes: none, basic, strict, container (future)
- Shell commands NEVER auto-approve (security invariant)

### Sandbox (`arbor_sandbox`)
- Four execution modes: pure, limited, full, container
- Docker-based container isolation (optional)
- Resource limits and timeout enforcement

### ExMCP Integration
- Full MCP protocol support (4 protocol versions: 2024-11-05 through 2025-11-25)
- 100% official conformance: 262/262 core + 42 extension/backcompat = 304 total checks
- OAuth 2.1 with PKCE, scope step-up, dynamic client registration, CIMD
- Enterprise SSO: ID-JAG token exchange (RFC 8693) + JWT bearer grant (RFC 7523)
- Cross-app access flow (full enterprise token exchange chain)
- Client credentials with JWT assertion (private_key_jwt)
- Server-side Plugs: JWKS, PRM (RFC 9728), TokenRevocation (RFC 7009), TokenIntrospection (RFC 7662)
- Token revocation client (RFC 7009)
- Pluggable auth providers (OAuth, Static, custom)
- ACP protocol for controlling coding agents:
  - Native agents: Gemini CLI, Hermes, OpenCode, Qwen Code
  - Adapted agents: Claude Code, Codex, Pi (with full RPC)
  - Session management, modes, config options, tool introspection
- Multiple transports: HTTP/SSE, stdio, native BEAM (~15μs)
- Async POST for bidirectional flows (elicitation, sampling)
- Push model (event-driven) for Test, Local, Stdio transports
- DSL server with declarative tools, resources, and prompts
- 88 telemetry events across all components
- Interactive and callback elicitation handlers

---

## Shared Utilities (`arbor_common`)

### Registries & Discovery
- CapabilityIndex — runtime discovery of actions and their URI capabilities
- CapabilityResolver — natural language to URI resolution for intents
- ActionProvider + SkillProvider — capability enumeration strategies
- ActionRegistry — registration and discovery of all available actions
- ComputeRegistry — computation registry for handler dispatch
- HandlerRegistry — DOT handler type registry
- PipelineResolver — runtime resolution of pipeline definitions
- NodeRegistry — cluster node tracking

### Safety & Sanitization
- 9 sanitizer types: command injection, deserialization, log injection, path traversal, prompt injection, SQL injection, SSRF, XSS, plus base
- SafeRegex — safe regex compilation from untrusted input
- SensitiveData — sensitive information detection and masking
- LogRedactor — log sanitization utilities
- ConfigValidator — configuration validation

### Skill System
- Skill library with adapters (fabric, raw, skill adapters)
- DOT caching for compiled skills
- SkillImporter — external skill importing
- SessionReader — session file parsing (Claude provider adapter)

### Utilities
- ModelProfile — model metadata for 29+ models (context sizes, capabilities, pricing)
- TemplateRenderer — template rendering
- TemporalGrouping — time-based grouping
- Pagination — cursor-based pagination with Cursor type
- LazyLoader — runtime lazy-loading
- Time utilities — temporal awareness helpers

---

## Developer Experience

### CLI Tools (39+ commands)

**Server & App**
- `mix arbor.start/stop/restart/status` — server lifecycle
- `mix arbor.setup` — initial project setup
- `mix arbor.apps` — list umbrella apps
- `mix arbor.config` — configuration inspection
- `mix arbor.doctor` — diagnostic health checks
- `mix arbor.attach` — REPL attachment to running server
- `mix arbor.recompile` — hot recompilation
- `mix arbor.logs` — log viewing

**Agent Management**
- `mix arbor.agent` — create, resume, chat, destroy
- `mix arbor.agent templates` — list available templates
- `mix arbor.profile` — agent profile management
- `mix arbor.template` — template operations

**Orchestration**
- `mix arbor.pipeline.run/validate/viz/compile` — pipeline tools
- `mix arbor.pipeline.new/list/status/resume` — pipeline lifecycle
- `mix arbor.pipeline.benchmark/dotgen` — performance and generation
- `mix arbor.orchestrate` — direct pipeline execution

**Consensus & Governance**
- `mix arbor.consult` — council consultation (RPCs into running server)

**User & Identity**
- `mix arbor.user` — user management
- `mix arbor.user.config` — user configuration
- `mix arbor.user.link` — identity linking

**Infrastructure**
- `mix arbor.cluster connect/status` — distributed cluster management
- `mix arbor.security` — security operations
- `mix arbor.signals` — signal bus inspection
- `mix arbor.backup.list/restore` — backup operations
- `mix arbor.phone` — phone integration

**Worktree Agents (Hands)**
- `mix arbor.hands.spawn` — spawn worktree agent
- `mix arbor.hands.send` — send message to hand
- `mix arbor.hands.stop` — stop hand
- `mix arbor.hands.capture` — capture hand output
- Automatic cleanup of stale worktrees

**Quality & Testing**
- `mix quality` — format + credo strict
- `mix test.fast` — fast unit tests (8,600+ tests)
- `mix test.all` — full suite including LLM/integration
- `mix test.distributed` — distributed tests

**Evaluation**
- `mix arbor.eval_memory/eval_task/eval_window` — evaluation suites
- `mix arbor.eval.generate_corpus/salience/summarization/temporal` — advanced evals

### Testing
- 8,600+ fast tests across 22 apps, 0 failures
- Behavioral test framework (BehavioralCase, LLMAssertions, MockLLM)
- Test tagging conventions (fast/slow, integration, database, external, llm)
- Eval framework (DOT compilation, advisory, memory, summarization)
- Model comparison evaluations (14 models, 254 runs analyzed)

### Agent Development
- Template system with 10 builtin templates
- CapabilityIndex with ActionProvider + SkillProvider
- DOT pipeline authoring with validation and visualization
- Skill library for composable agent behaviors
- Progressive tool disclosure pattern

---

---

## By the Numbers

- **22 umbrella apps** with strict dependency hierarchy
- **73+ action modules** across 15+ categories
- **39+ CLI commands** for every aspect of the system
- **8,600+ fast tests** across all apps, 0 failures
- **377 feature commits** since January 2026
- **304/304 MCP conformance checks** (core + extensions + backcompat)
- **13 advisory council perspectives** with research backing
- **10 provider adapters** for LLM integration
- **29+ model profiles** with context sizes and pricing
- **88 telemetry events** in ExMCP for full observability
- **9 sanitizer types** for defense-in-depth input validation
- **8-step middleware chain** in DOT pipeline engine
- **4 protocol versions** supported with backwards compatibility

*Last updated: 2026-03-20*
