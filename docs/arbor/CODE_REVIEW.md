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
- [x] Refactored with `@enum_definitions` compile-time code generation. `define_enum` generates `to_atom/1`, `valid?/1`, and `all/0` functions for each enum from a single keyword list declaration. Replaced ~200 lines of repetitive code. `safe_atom.ex` now 409 lines.

### D8. Shell authorization pattern repeated 3 times identically
- [x] Extracted `authorize_and_dispatch/4` in `apps/arbor_shell/lib/arbor/shell.ex`. Three `authorize_and_execute*` functions now delegate to shared dispatch.

### D9. Shell sandbox+registration setup repeated 3 times
- [x] Reviewed: Sync and async share 3-line preamble (sandbox check + register). Streaming version is quite different (PortSession). Minimal duplication — not worth extracting.

### D10. Signal subscription boilerplate repeated in 7+ LiveViews
- [x] Created `Arbor.Dashboard.Live.SignalSubscription` (121 lines) with `subscribe_signals/3` function and `use` macro with `@before_compile` for conditional `terminate/2` and `handle_info/2` injection. Updated 9 LiveViews to use the shared helper.

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

### R1. `arbor_dashboard/live/chat_live.ex` — 2,057 lines → 981 lines
- [x] Extract `ChatLive.Components` (~1,088 lines) — render function components (chat interface, sidebars, panels)
- [x] Extract `ChatLive.Helpers` (~162 lines) — data transformation helpers

### R2. `arbor_memory/context_window.ex` — 1,939 lines → 969 lines
- [x] Extract `ContextWindow.Formatting` (~307 lines) — to_prompt_text, build_context, format helpers
- [x] Extract `ContextWindow.Serialization` (~207 lines) — serialize, deserialize, JSON conversion
- [x] Extract `ContextWindow.Compression` (~558 lines) — compression, similarity checks, deduplication

### R3. `arbor_consensus/coordinator.ex` — 1,923 lines → 1,159 lines
- [x] Extract `Coordinator.Voting` (~587 lines) — council spawning, evaluation processing, decision rendering, execution, agent evaluation collection
- [x] Extract `Coordinator.TopicRouting` (~332 lines) — topic matching/routing, council config resolution, organic topic creation

### R4. `arbor_memory/knowledge_graph.ex` — 1,814 lines → 1,150 lines
- [x] Extract `KnowledgeGraph.DecayEngine` (~201 lines) — decay application, time-based decay, cleanup of decayed nodes
- [x] Extract `KnowledgeGraph.GraphSearch` (~590 lines) — BFS/DFS traversal, path finding, related nodes, subgraph extraction, pattern matching, clustering

### R5. `arbor_memory/memory.ex` — 1,680 lines → 333 lines
- [x] Extract `Memory.IndexOps` (~210 lines) — index add/search/query/reindex operations
- [x] Extract `Memory.KnowledgeOps` (~86 lines) — knowledge graph node/edge operations
- [x] Extract `Memory.IdentityOps` (~351 lines) — identity consolidation, personality, capability ops
- [x] Extract `Memory.SessionOps` (~650 lines) — session, working memory, context window operations
- [x] Extract `Memory.GoalIntentOps` (~289 lines) — goal tracking, intent, proposal operations

### R6. `arbor_memory/signals.ex` — 1,382 lines → 748 lines
- [x] Extract `Signals.Reflection` (~125 lines) — reflection-related signal emission
- [x] Extract `Signals.Proposals` (~140 lines) — proposal/consensus signal emission
- [x] Extract `Signals.Identity` (~154 lines) — identity/consolidation signal emission
- [x] Extract `Signals.WorkingMemory` (~98 lines) — working memory signal emission
- [x] Extract `Signals.Lifecycle` (~232 lines) — lifecycle/session signal emission

### R7. `arbor_orchestrator/engine.ex` — 1,290 lines → 733 lines
- [x] Extract `Engine.Executor` (~362 lines) — step execution, action handlers, error recovery, retry logic
- [x] Extract `Engine.Router` (~252 lines) — step routing, condition evaluation, transition logic

### R8. `arbor_memory/identity_consolidator.ex` — 1,272 lines → 769 lines
- [x] Extract `IdentityConsolidator.InsightIntegration` (~233 lines) — integrate_insight/2, personality/capability/value insight integration, contradicts?/2, trait/capability/value extraction
- [x] Extract `IdentityConsolidator.Promotion` (~405 lines) — find_promotion_candidates/2, block/unblock insight, categorize_insights, emit signals, promote_single_node, pattern analysis, graph helpers

### R9. `arbor_memory/reflection_processor.ex` — 1,215 lines → 887 lines
- [x] Extract `ReflectionProcessor.Integrations` (~366 lines) — insight/learning/knowledge-graph/relationship integration, insight detection, goals-in-KG, post-reflection decay, safe_atom helper

### R10. `arbor_ai/ai.ex` — 1,068 lines → 879 lines
- [x] Extract `Arbor.AI.ToolAuthorization` (~100 lines) — confused deputy prevention bridge to arbor_security
- [x] Extract `Arbor.AI.ToolSignals` (~92 lines) — signal emission + budget/stats recording for tool-calling requests

### R11. `arbor_sdlc/processors/in_progress.ex` — 958 lines → 499 lines
- [x] Extract `InProgress.CompletionProcessing` (~483 lines) — check_and_process_completion/3, hand/session completion, test/quality checks, move_to_completed, failure/error/blocked/interrupted handlers, comms routing, resume_session, serialize_item

### R12. `arbor_orchestrator/session.ex` — 919 lines → 530 lines
- [x] Extract `Session.Builders` (~428 lines) — build_turn_values/2, build_heartbeat_values/1, session_base_values, build_engine_opts, apply_turn/heartbeat_result, apply_goal_changes, emit signals, checkpoint/restore, verify_trust_tier, contracts_available?, normalize_message, safe_to_atom

### R13. `arbor_actions/background_checks.ex` — 892 lines → 169 lines
- [x] Extract `BackgroundChecks.Run.Checks` (~761 lines) — all 6 check functions, result/warning/suggestion helpers, time/date helpers, formatting, threshold module attributes

### R14. `arbor_agent/executor.ex` — 777 lines → 495 lines
- [x] Extract `Executor.ActionDispatch` (~308 lines) — all action dispatch clauses, AI analysis, proposal/hot-load helpers, module discovery

### R15. `arbor_signals/channels.ex` — 796 lines
- [x] Reviewed: GenServer state threading through key rotation and crypto makes extraction complex without clear benefit — acceptable as-is

### R16. `arbor_security/capability_store.ex` — 741 lines → 617 lines
- [x] Extract `CapabilityStore.Serializer` (~125 lines) — serialization/deserialization for capability persistence

### R17. `arbor_security/security.ex` — 730 lines → 683 lines
- [x] Inline 11 event emitter wrappers as direct `Events.record_*` calls — removed unnecessary indirection layer

---

## Phase 4: Testing Gaps

### T1. `arbor_contracts` — 72 modules, 16 tests (22% ratio) → 528 tests
- [x] Add tests for `error.ex` `wrap/1` edge cases — 30 tests covering new/1, redact/1, wrap/2 variants
- [x] Add tests for consensus modules — 8 new test files (proposal, evaluation, council_decision, change_proposal, consensus_event, invariants, agent_mailbox, events)
- [x] Add tests for judge modules — evidence_test.exs (12 tests)
- [x] Add tests for comms contracts — message_test.exs (5), response_envelope_test.exs (6)
- [x] Add tests for persistence contracts — record_test.exs (6), filter_test.exs (17)

### T2. `arbor_dashboard` — 27 modules, 10 tests (37% ratio) → 122 tests
- [x] Add ChatLive event handler tests — 21 tests (toggles, input, start/stop agent, heartbeat)
- [x] Add AgentsLive tests — 6 tests (mount, select, close, stop)
- [x] Add MonitorLive tests — 10 tests (mount, refresh, skill selection)
- [x] Add SignalsLive tests — 14 tests (pause/resume, filter, category toggle)
- [x] Add MemoryLive tests — 21 tests (mount, tabs, section toggles)
- [x] Add EvalLive tests — 15 tests (mount, tabs, filters, run navigation)

### T3. `arbor_common` — 43 modules, 15 tests (35% ratio) → 407 tests
- [x] Add tests for `sessions/` parsers — content_edge_cases_test (14), claude_edge_cases_test (24)
- [x] Add tests for `skill_library.ex` — skill_library_test (34), plus 3 adapter tests (fabric 7, skill 14, raw 9)

### T4. `arbor_orchestrator` — 167 modules, 105 tests (63% ratio) → 165 new tests
- [x] Add integration tests for full graph execution — 8 tests (linear pipeline, goal threading, max_steps)
- [x] Add handler edge case tests — 35 tests (error conditions, retry, authorization, registry resolution)
- [x] Add context threading tests — 14 tests (context flow, snapshots, outcome propagation)

### T5. `arbor_ai` — 42 modules, 27 tests (64% ratio) → 118 tests
- [x] Add tests for `ResponseNormalizer` — 31 tests (normalize, format, extract functions)
- [x] Add tests for `RoutingConfig` — 35 tests (+12 new edge cases)
- [x] Add tests for `BackendRegistry` — 17 tests (metadata, TTL, ETS expiration)
- [x] Add tests for `route_task/2` tier-based routing — 35 tests (+10 new tier/strategy tests)

### T6. `arbor_web` — 12 modules, 8 tests (67% ratio) → 132 tests
- [x] Add tests for hooks.ex — 16 tests (hook_name, all, names)
- [x] Add tests for signal_live.ex — 10 tests (subscribe, unsubscribe, lifecycle hooks)
- [x] Add tests for telemetry.ex — 19 tests (setup, metrics, handle_event boundary cases)

### T7. `arbor_monitor` — 20 modules, 14 tests (70% ratio) → 93 tests
- [x] Add CascadeDetector state machine tests — full lifecycle, boundary, crash resilience
- [x] Add HealingSupervisor integration tests — child count, restart, strategy, config passthrough
- [x] Add RejectionTracker three-strike logic tests — strategy mapping, suppression, escalation, cleanup

### T8. `arbor_gateway` — 14 modules, 6 tests (43% ratio) → 130 tests
- [x] Add ClaudeSession authorization tests — 27 tests (fail-closed, exit handling)
- [x] Add tool authorization denial tests — 25 bridge_router tests + 12 auth plug tests

### T9. `arbor_flow` — 5 modules, 4 tests (80% ratio) → 38 tests
- [x] Add `watcher.ex` tests — 38 tests (file lifecycle, crash recovery, callbacks, debouncing, edge cases)

### T10. `arbor_agent` — 46 modules, 38 tests (83% ratio) → 41 new tests
- [x] Add concurrent agent creation tests — 9 tests (10-way race, 20-way registration, rapid cycles)
- [x] Add checkpoint race condition tests — 20 tests (concurrent saves, threshold boundaries, schedule races)
- [x] Add partial failure recovery tests — 12 tests (template resolution, corrupted JSON, concurrent restore)

### T11. `arbor_persistence` — 32 modules, 24 tests (75% ratio) → 48 tests
- [x] Add eval operation tests — 33 tests (EvalRun/EvalResult changeset validation, defaults, updates)
- [x] Add authorization rejection path tests — 15 tests (write/read/append/stream denial, error wrapping)

### T12. Property-based and stress tests — 26 tests
- [x] Add property-based tests for double_ratchet.ex — 12 tests (round-trip, chain uniqueness, out-of-order, serialization, AAD binding)
- [x] Add concurrent identity registration stress tests — 7 tests (20-way race, duplicate rejection, lifecycle transitions)
- [x] Add key rotation under concurrent sends tests — 7 tests (10-way concurrent sends, rotation uniqueness, member leave)

---

## Phase 5: Architecture Cleanup

### A1. SessionBridge hardcodes orchestrator internal modules
- [x] Reviewed: module attributes (`@session_module`, etc.) are used exclusively via `Code.ensure_loaded?` + `apply/3` — correct cross-level pattern, no compile-time coupling. Module names centralized in attributes for easy change.
- [x] No facade expansion needed — runtime resolution is the established pattern for Standalone→Level 0 calls.

### A2. Demo reaches into Monitor internals
- [x] Added `Arbor.Monitor.healing_status/0` facade function that aggregates AnomalyQueue, CascadeDetector, Verification, RejectionTracker stats
- [x] `arbor_demo/demo.ex` now uses `defdelegate healing_status(), to: Arbor.Monitor` — removed internal module aliases and safe_call boilerplate

### A3. File-wide credo:disable for Apply check
- [x] `apps/arbor_security/lib/arbor/security/events.ex` — replaced file-wide disable with 3 per-line `credo:disable-for-next-line` pragmas
- [x] `apply/3` calls are intentional (cycle prevention) — documented, per-line suppressed

### A4. Memory reimplements SafeAtom
- [x] `apps/arbor_memory/lib/arbor/memory.ex` — `safe_insight_atom/1` now uses `SafeAtom.to_existing/1` after normalization

### A5. Redundant message envelope structs across contracts
- [x] Reviewed: four structs model two distinct domains (comms = external channels, session = LLM conversation). Fields, semantics, and lifecycles differ fundamentally. Shared `Envelope` base would create artificial coupling.
- [x] Shared validation patterns (`validate_optional_string`, `validate_optional_map`) already addressed by D11 in error.ex.

### A6. Trust facade verbose 3-level delegation
- [x] `apps/arbor_trust/lib/arbor/trust.ex` — short functions now use `defdelegate` directly to Manager. Verbose contract impls also use `defdelegate` with `:as` option. Eliminated ~40 lines of passthrough.

---

## Phase 6: Simplification & Dead Code

### O1. ChatLive 50+ socket assigns
- [x] Addressed by R1: ChatLive split from 2,057→981 lines. Components and Helpers extracted. Socket assigns reduced via component encapsulation.

### O2. 38 handle_event clauses in one module
- [x] Addressed by R1: Event handling simplified. GroupChat handles group events, Helpers handle data transformation. Parent retains core LiveView events.

### O3. Taint policy checking spread across 5 functions
- [x] Extracted to `Arbor.Actions.TaintEnforcement` module (~130 lines). Facade calls `TaintEnforcement.check/3` and `TaintEnforcement.maybe_emit_propagated/3`.

### O4. `generate_text_with_tools` — 97 lines
- [x] Addressed by R10: serialization and signal extraction refactored. Function retained as single pipeline entry point with delegated internals.

### O5. Persistence auth wrappers take 5-6 positional params
- [x] Reviewed: each param (agent_id, name, backend, key/stream, value, opts) is semantically distinct. Grouping into context map would obscure the API. Four functions follow identical pattern. Acceptable as-is.

### O6. Unreachable clause in item_parser
- [x] Resolved by D15 refactoring (parse_enum extraction eliminated the dead clause)

### O7. Synchronous checkpoint in terminate
- [ ] `apps/arbor_agent/lib/arbor/agent/server.ex:276-289` — DEFERRED: making terminate async risks data loss on shutdown. Needs careful design with async-then-confirm pattern.

### O8. Three dispatch functions with identical structure in comms
- [x] Reviewed: `send/4`, `reply/2`, `deliver_envelope/3` share signal emission but differ meaningfully in recipient resolution, option building, and message construction. Extraction would reduce readability. Acceptable as-is.

### O9. `Code.ensure_loaded` bridge pattern repeated 5+ times
- [ ] DEFERRED: Create `Arbor.Common.LazyLoader` module. Touches 5+ apps across library hierarchy — needs dedicated PR with thorough testing.

### O10. Placeholder phone numbers in non-test code
- [x] `question_registry.ex:36` — uses `+1XXXXXXXXXX` in `@moduledoc` example, not in executable code. Standard doc format.
- [x] `arbor_comms/` — only doc reference is `"kim@example.com"` in dispatcher.ex moduledoc. No placeholder values in production paths.

### DC1. TODO comments without tracking
- [x] `apps/arbor_cartographer/lib/arbor/cartographer.ex:290` — "TODO: Implement model detection" — legitimate future work marker, no roadmap infrastructure exists yet
- [x] `apps/arbor_ai/lib/arbor/ai/session_bridge.ex:157` — "TODO: Thread usage through Session adapters" — legitimate future work marker, tracked here
