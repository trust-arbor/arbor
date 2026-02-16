# Arbor Code Review — Remediation Tracker

> **Date:** 2026-02-16
> **Scope:** All 26 umbrella apps | 800+ source files | 189,453 LOC
> **Branch:** `refactor/code-review-remediation`

---

## Phase 1: Security (Fix Immediately)

### S1. Unsafe `String.to_atom/1` — LLM JSON keys (CRITICAL)
- [x] `apps/arbor_actions/lib/arbor/actions/judge/prompt_builder.ex:211` — replaced with `SafeAtom.to_existing/1`, fallback keeps string key
- [x] `apps/arbor_actions/lib/arbor/actions/judge/evaluate.ex:314` — replaced with `SafeAtom.to_existing/1`, fallback keeps string

### S2. Unsafe `String.to_atom/1` — orchestrator map context (CRITICAL)
- [x] `apps/arbor_orchestrator/lib/arbor/orchestrator/handlers/eval_run_handler.ex:101` — replaced with inline `String.to_existing_atom` + rescue (no arbor_common dep)

### S3. Unsafe `String.to_atom/1` — contracts error module (HIGH)
- [x] `apps/arbor_contracts/lib/arbor/contracts/error.ex:266` — replaced with `String.to_existing_atom` + rescue to `:wrapped_error` (Level 0, no arbor_common dep)

### S4. Unsafe `String.to_atom/1` — cartographer ollama detection (MEDIUM)
- [x] `apps/arbor_cartographer/lib/arbor/cartographer.ex:436` — replaced with `String.to_existing_atom` + rescue keeps string (no arbor_common dep)

### S5. Unsafe `String.to_atom/1` — common mix helpers (LOW)
- [x] `apps/arbor_common/lib/mix/tasks/arbor/arbor_helpers.ex:35` — acceptable: ARBOR_COOKIE is operator-controlled env var, required as atom for Erlang distribution. Clarified comment.

### S6. Unsafe `String.to_atom/1` — SDLC mix task (LOW)
- [x] `apps/arbor_sdlc/lib/mix/tasks/arbor/sdlc.ex:228` — replaced with `SafeAtom.to_allowed/2` using `[:cli, :api]` allowlist

### S7. File I/O without SafePath validation (HIGH)
- [x] `apps/arbor_sdlc/lib/arbor/sdlc.ex:622-669` — added `SafePath.sanitize_filename` + `SafePath.safe_join` for dest path validation

### S8. Sandbox silently continues without filesystem on init failure (HIGH)
- [x] `apps/arbor_sandbox/lib/arbor/sandbox.ex:169-173` — now returns `{:error, {:filesystem_init_failed, reason}}` instead of silently continuing

---

## Phase 2: Extract Shared Utilities (Duplication)

### D1. `parse_int/2` duplicated 15+ times across orchestrator handlers
- [x] Create `Arbor.Orchestrator.Handlers.Helpers.parse_int/2`
- [x] Replace all handler-local copies (13 handlers + engine.ex). Remaining: `ir/compiler.ex` has different semantics (returns nil), left as-is.

### D2. `maybe_add/3` duplicated 30+ times across orchestrator, ai, comms, demo
- [x] Add to `Arbor.Orchestrator.Handlers.Helpers`
- [x] Replace orchestrator-internal copies (10 handlers + engine.ex + claude_cli.ex). Cross-app copies (arbor_ai, arbor_comms) left as-is — 2-line function doesn't warrant cross-library import.

### D3. `parse_csv/1` duplicated 5+ times across orchestrator handlers
- [x] Add to `Arbor.Orchestrator.Handlers.Helpers`
- [x] Replace 6 handler copies. `eval_aggregate_handler.ex` skipped — has different default return value.

### D4. `safe_to_atom/1` with unsafe fallback duplicated in judge modules
- [x] Fixed in Phase 1 (S1) — both copies now use `SafeAtom.to_existing/1` internally. Functions retained as local wrappers with safe implementation.

### D5. `safe_call/2` rescue wrapper duplicated across apps
- [x] Reviewed: 10+ variants across arbor_agent, arbor_demo, arbor_web, arbor_orchestrator. Different signatures (nil vs default, with/without logging). Monitor has none. Variants are intentionally different — not worth unifying.

### D6. `via/1` registry tuple duplicated in arbor_agent modules
- [x] Reviewed: Two copies use different registries (ExecutorRegistry vs ReasoningLoopRegistry). One-liner functions that are intentionally separate per GenServer.

### D7. SafeAtom allowlist boilerplate — 5 x 40 lines in safe_atom.ex
- [ ] Create `define_enum/2` macro for identity_statuses, taint_levels, taint_roles, taint_policies, signal_categories
- [ ] Replace ~200 lines of repetitive code

### D8. Shell authorization pattern repeated 3 times identically
- [x] Extracted `authorize_and_dispatch/4` in `apps/arbor_shell/lib/arbor/shell.ex`. Three `authorize_and_execute*` functions now delegate to shared dispatch.

### D9. Shell sandbox+registration setup repeated 3 times
- [x] Reviewed: Sync and async share 3-line preamble (sandbox check + register). Streaming version is quite different (PortSession). Minimal duplication — not worth extracting.

### D10. Signal subscription boilerplate repeated in 7+ LiveViews
- [ ] Extract `SignalSubscription` helper/component in arbor_dashboard
- [ ] Replace mount/terminate/handle_info patterns across all LiveViews

### D11. Validation pattern (optional type check) repeated 4 times
- [x] Extracted `validate_optional/3` in `apps/arbor_contracts/lib/arbor/contracts/error.ex`. Four `validate_optional_*` functions now delegate to generic function with type check callback.

### D12. Advisory LLM system prompts — 13 perspectives with repetitive preamble
- [x] Reviewed: Preamble already templated via `@arbor_context` and `@response_format` module attributes. Each perspective has unique focus areas. Already well-structured.

### D13. Historian membership event handling — 6 identical clauses
- [x] Extracted `extract_event_data/1` in `apps/arbor_historian/lib/arbor/historian.ex`. Removed duplicated `data = event[:data] || event["data"] || %{}` and `agent_id` extraction from 5 clauses.

### D14. Persistence filter application — 5 filters with identical pattern
- [x] Consolidated 4 `where` filter clauses into single generic clause using `field(r, ^field)` dynamic field access with `@eval_where_filters` allowlist.

### D15. Flow item_parser enum parsing — 3 identical functions
- [x] Extracted `parse_enum/2` in `apps/arbor_flow/lib/arbor/flow/item_parser.ex`. `parse_priority/1`, `parse_category/1`, `parse_effort/1` now delegate to shared function.

### D16. SDLC new vs changed file handlers nearly identical
- [x] Reviewed: Handlers share structure but have meaningful behavioral differences — different events (item_detected vs item_changed), different tracker logic, different async patterns. Not worth unifying.

### D17. Two separate SessionReader modules
- [x] Reviewed: `AI.SessionReader` (domain-specific, reads Claude Code thinking blocks) and `Common.Sessions.Reader` (generic streaming JSONL with SafePath). Different abstraction levels — proper layering, not duplication.

### D18. `__using__/1` import pattern repeated 4 times in arbor_web
- [x] Moved shared `Arbor.Web.{Components,Helpers,Icons}` imports into `html_helpers/0`. Four definitions (live_view, live_component, component, html) simplified.

### D19. Demo/production config — same keys, different values
- [x] Extracted `@demo_monitor_config` and `@production_monitor_config` module attributes with `apply_monitor_config/2` shared function.

### D20. Monitor skill boilerplate — 9 modules with 40-60 lines each
- [x] Reviewed: Skills already implement `@behaviour Arbor.Monitor.Skill` with unique `collect/0` and `check/1`. Each skill has domain-specific logic. Behaviour IS the right abstraction — macro would save minimal code.

---

## Phase 3: Split Large Modules (Refactoring)

### R1. `arbor_dashboard/live/chat_live.ex` — 2,057 lines
- [ ] Extract state into structs (AgentState, UIState, ChatState, TokenState, MemoryState, LLMState, CognitiveState)
- [ ] Extract `ChatLive.AgentManager` — start/stop agent events
- [ ] Extract `ChatLive.MessageHandler` — send-message logic (78 lines!)
- [ ] Extract `ChatLive.UIController` — 16 toggle event clauses
- [ ] Extract `ChatLive.ProposalHandler` — proposal events

### R2. `arbor_memory/context_window.ex` — 1,939 lines
- [ ] Split into `ContextWindowLegacy` and `ContextWindowMultiLayer` with router

### R3. `arbor_consensus/coordinator.ex` — 1,923 lines
- [ ] Split by concern: coordination, voting, lifecycle

### R4. `arbor_memory/knowledge_graph.ex` — 1,814 lines
- [ ] Split into `GraphStructure`, `DecayEngine`, `GraphSearch`

### R5. `arbor_memory/memory.ex` — 1,681 lines (150+ functions)
- [ ] Create sub-facades: `Memory.IndexOps`, `Memory.GraphOps`

### R6. `arbor_memory/signals.ex` — 1,382 lines
- [ ] Group by signal domain

### R7. `arbor_orchestrator/engine.ex` — 1,311 lines
- [ ] Split into `EngineValidator`, `EngineExecutor`, `Engine`

### R8. `arbor_memory/identity_consolidator.ex` — 1,272 lines
- [ ] Split consolidation phases into separate modules

### R9. `arbor_memory/reflection_processor.ex` — 1,215 lines
- [ ] Separate LLM interaction from processing logic

### R10. `arbor_ai/ai.ex` — 1,068 lines
- [x] Extract `Arbor.AI.ToolAuthorization` (~100 lines) — confused deputy prevention bridge to arbor_security
- [ ] Split `generate_text_with_tools` (97 lines) into build/execute/emit/record pipeline

### R11. `arbor_sdlc/processors/in_progress.ex` — 958 lines
- [ ] Extract common handler pattern

### R12. `arbor_orchestrator/session.ex` — 919 lines
- [ ] Split into `SessionState`, `SessionTurn`, `Session`

### R13. `arbor_actions/background_checks.ex` — 892 lines
- [ ] Split by check type

### R14. `arbor_agent/executor.ex` — 777 lines
- [ ] Split into `IntentDispatcher`, `CapabilityValidator`, `SandboxExecutor`

### R15. `arbor_signals/channels.ex` — 796 lines
- [ ] Split into `Channels.Manager`, `Channels.KeyRotation`, `Channels.Messaging`

### R16. `arbor_security/capability_store.ex` — 741 lines
- [ ] Split into `CapabilityStore.Index`, `CapabilityStore.Validator`

### R17. `arbor_security/security.ex` — 730 lines (47+ public functions)
- [ ] Split into `Security.Capabilities`, `Security.Identities`, `Security.Reflexes`

---

## Phase 4: Testing Gaps

### T1. `arbor_contracts` — 72 modules, 16 tests (22% ratio)
- [ ] Add tests for `error.ex` `wrap/1` edge cases (lines 202-242)
- [ ] Add tests for consensus modules (6 modules, 400+ lines)
- [ ] Add tests for judge modules (4 modules)
- [ ] Add tests for comms contracts (question_registry, message, response_envelope)
- [ ] Add tests for memory types, persistence contracts
- [ ] **Target: 80% module coverage**

### T2. `arbor_dashboard` — 27 modules, 10 tests (37% ratio)
- [ ] Add ChatLive event handler tests (start-agent, send-message, toggles)
- [ ] Add AgentsLive tests
- [ ] Add MonitorLive tests
- [ ] Add SignalsLive tests
- [ ] Add MemoryLive tests
- [ ] Add EvalLive tests
- [ ] **Target: 80% module coverage**

### T3. `arbor_common` — 43 modules, 15 tests (35% ratio)
- [ ] Add tests for `sessions/` parsers (message_parser, turn_parser, adapter)
- [ ] Add tests for `skill_library.ex` (475 lines, 0 tests)
- [ ] **Target: 80% module coverage**

### T4. `arbor_orchestrator` — 167 modules, 105 tests (63% ratio)
- [ ] Add integration tests for full graph execution (start -> compute -> end)
- [ ] Add handler edge case tests (error conditions, type mismatches)
- [ ] Add context threading tests across multiple handlers
- [ ] **Target: 80% module coverage**

### T5. `arbor_ai` — 42 modules, 27 tests (64% ratio)
- [ ] Add tests for `ResponseNormalizer` (5 public functions, 0 tests)
- [ ] Add tests for `RoutingConfig` (7 public functions, 0 tests)
- [ ] Add tests for `BackendRegistry` (ETS caching, TTL)
- [ ] Add tests for `route_task/2` tier-based routing
- [ ] **Target: 80% module coverage**

### T6. `arbor_web` — 12 modules, 8 tests (67% ratio)
- [ ] Add tests for hooks.ex
- [ ] Add tests for signal_live.ex
- [ ] Add tests for telemetry.ex
- [ ] **Target: 80% module coverage**

### T7. `arbor_monitor` — 20 modules, 14 tests (70% ratio)
- [ ] Add CascadeDetector state machine tests
- [ ] Add HealingSupervisor integration tests
- [ ] Add RejectionTracker three-strike logic tests
- [ ] **Target: 80% module coverage**

### T8. `arbor_gateway` — 14 modules, 6 tests (43% ratio)
- [ ] Add ClaudeSession authorization tests
- [ ] Add tool authorization denial tests
- [ ] **Target: 80% module coverage**

### T9. `arbor_flow` — 5 modules, 4 tests (80% ratio)
- [ ] Add `watcher.ex` tests (436 lines, 0 tests) — file lifecycle, crash recovery, callbacks

### T10. `arbor_agent` — 46 modules, 38 tests (83% ratio)
- [ ] Add concurrent agent creation tests (identity collision)
- [ ] Add checkpoint race condition tests
- [ ] Add partial failure recovery tests in lifecycle

### T11. `arbor_persistence` — 32 modules, 24 tests (75% ratio)
- [ ] Add eval operation tests (insert_eval_run, update_eval_run)
- [ ] Add authorization rejection path tests

### T12. Property-based and stress tests
- [ ] Add property-based tests for `arbor_security/double_ratchet.ex` (511 lines)
- [ ] Add concurrent identity registration stress tests for `arbor_security/identity/registry.ex` (573 lines)
- [ ] Add key rotation under concurrent sends tests for `arbor_signals`

---

## Phase 5: Architecture Cleanup

### A1. SessionBridge hardcodes orchestrator internal modules
- [ ] `apps/arbor_ai/lib/arbor/ai/session_bridge.ex:28-31` — uses `@session_module Arbor.Orchestrator.Session`
- [ ] Expose stable public API in `Arbor.Orchestrator` facade instead

### A2. Demo reaches into Monitor internals
- [ ] `apps/arbor_demo/lib/arbor/demo.ex:152-156` — calls AnomalyQueue, CascadeDetector directly
- [ ] Expose `Arbor.Monitor.healing_status()` facade function

### A3. File-wide credo:disable for Apply check
- [ ] `apps/arbor_security/lib/arbor/security/events.ex` — reduce scope to per-line pragmas
- [ ] Refactor `apply/3` calls where possible

### A4. Memory reimplements SafeAtom
- [x] `apps/arbor_memory/lib/arbor/memory.ex` — `safe_insight_atom/1` now uses `SafeAtom.to_existing/1` after normalization

### A5. Redundant message envelope structs across contracts
- [ ] Review: `Contracts.Comms.Message`, `Contracts.Comms.ResponseEnvelope`, `Contracts.Session.Message`, `Contracts.Session.Turn`
- [ ] Consider shared `Envelope` base or at least shared validation

### A6. Trust facade verbose 3-level delegation
- [x] `apps/arbor_trust/lib/arbor/trust.ex` — short functions now use `defdelegate` directly to Manager. Verbose contract impls also use `defdelegate` with `:as` option. Eliminated ~40 lines of passthrough.

---

## Phase 6: Simplification & Dead Code

### O1. ChatLive 50+ socket assigns
- [ ] Group into 7 state structs (covered by R1)

### O2. 38 handle_event clauses in one module
- [ ] Split into service modules (covered by R1)

### O3. Taint policy checking spread across 5 functions
- [ ] Extract to `Arbor.Actions.TaintPolicies` module from `apps/arbor_actions/lib/arbor_actions.ex:376-506`

### O4. `generate_text_with_tools` — 97 lines
- [ ] Split into pipeline (covered by R10)

### O5. Persistence auth wrappers take 5-6 positional params
- [ ] Group backend config into context map in `apps/arbor_persistence/lib/arbor/persistence.ex:62-202`

### O6. Unreachable clause in item_parser
- [x] Resolved by D15 refactoring (parse_enum extraction eliminated the dead clause)

### O7. Synchronous checkpoint in terminate
- [ ] `apps/arbor_agent/lib/arbor/agent/server.ex:276-289` — make async to avoid shutdown delay

### O8. Three dispatch functions with identical structure in comms
- [ ] Extract `dispatch_with_logging/5` in `apps/arbor_comms/lib/arbor/comms/dispatcher.ex`

### O9. `Code.ensure_loaded` bridge pattern repeated 5+ times
- [ ] Create `Arbor.Common.LazyLoader` module

### O10. Placeholder phone numbers in non-test code
- [ ] Clean up `apps/arbor_contracts/lib/arbor/contracts/comms/question_registry.ex:36`
- [ ] Clean up similar placeholders in `apps/arbor_comms/`

### DC1. TODO comments without tracking
- [ ] `apps/arbor_cartographer/lib/arbor/cartographer.ex:290` — "TODO: Implement model detection"
- [ ] `apps/arbor_ai/lib/arbor/ai/session_bridge.ex:157` — "TODO: Thread usage through Session adapters"
