# Agent Seed Design: Identity and Memory Architecture

> Updated: 2026-02-18
> Scope: How Arbor creates, persists, and evolves agent identity and memory

---

## Overview

Every Arbor agent begins as a **Template** — a static archetype defining personality, capabilities, and goals. The `Lifecycle.create/2` pipeline transforms a template into a running agent with:

- A **cryptographic identity** (Ed25519 keypair, system endorsement, capability grants)
- A **Profile** manifest persisted to disk
- **Memory stores** (ETS for speed, Postgres for durability)
- A **heartbeat pipeline** (DOT graph) that drives autonomous cognition

The agent's identity evolves over time through a proposal-based system: the consolidation subsystem detects patterns and creates proposals, the LLM reviews and accepts/rejects them, and accepted changes promote into permanent self-knowledge.

---

## 1. Identity Creation Pipeline

### Template → Character → Profile

```
Template (behaviour module)
  └─ character/0 → Character struct (name, traits, values, tone, knowledge)
  └─ trust_tier/0 → atom (:probationary, :trusted, etc.)
  └─ initial_goals/0 → [%{description, type, priority}]
  └─ required_capabilities/0 → [%{resource: "arbor://..."}]
  └─ values/0, initial_thoughts/0 → identity seeds
```

**Template** (`Arbor.Agent.Template`) is a behaviour with 4 required + 8 optional callbacks. Built-in templates: `Scout`, `ClaudeCode`, `CodeReviewer`, `Diagnostician`, `Monitor`, `Researcher`.

**Character** (`Arbor.Agent.Character`) is the static personality definition — name, role, traits (with 0-1 intensity), values, quirks, tone, style, knowledge facts, and LLM instructions. Rendered to a system prompt via `Character.to_system_prompt/1`.

**Profile** (`Arbor.Agent.Profile`) is the persisted identity manifest. It composes a Character with security fields (agent_id, trust_tier, identity map, keychain ref) and is serialized to `.arbor/agents/<agent_id>.agent.json`.

### Lifecycle.create/2 — The 10-Step Sequence

```
1. resolve_template(opts)           Extract character + options from template module
2. generate_identity(display_name)  Ed25519 keypair → agent_id = "agent_<hex(pubkey)>"
3. register_identity(identity)      Write to Security ETS (in-memory)
4. endorse_identity(identity)       System Authority signs agent's public key
5. create_keychain(identity)        Keychain for encrypted comms
6. persist_signing_key(agent_id)    Private key → AES-256-GCM → Postgres
7. grant_capabilities(agent_id)     Capability URIs → Security ETS
8. init_memory(agent_id)            Start IndexSupervisor, KnowledgeGraph ETS
9. set_initial_goals(agent_id)      Goal structs → GoalStore (ETS + Postgres)
10. seed_template_identity(...)     Knowledge, values, traits, thoughts → stores
```

Step 10 seeds two categories:
- **Knowledge graph** (ETS-only, transient) — re-seeded on every startup from template
- **Durable identity** (ETS + Postgres, idempotent) — values, traits, initial thoughts. Only seeded once; skipped if SelfKnowledge already has values. Ends with a sync flush to prevent async persist race conditions.

### Lifecycle.start/2 — The Restart Path

```
1. Restore Profile from JSON
2. Re-register identity in Security ETS (lost on restart)
3. Re-grant capabilities from template
4. Re-initialize memory (KG ETS, IndexSupervisor)
5. Reload goals + intents from Postgres → ETS (reload_for_agent/1)
6. Start Executor
7. Optionally start SessionManager (heartbeat pipeline)
```

The defensive `reload_for_agent/1` on GoalStore and IntentStore handles edge cases where MemoryStore wasn't available during initial GenServer startup.

### Cryptographic Identity

```
agent_id = "agent_<hex(Ed25519_public_key)>"

Identity map:
  %{agent_id, public_key_hex, endorsement}

Private key storage:
  AES-256-GCM encrypted → SigningKeyStore (BufferedStore → Postgres)

Signing ceremony:
  {:ok, signer} = Lifecycle.build_signer(agent_id)
  signer.("arbor://fs/read") → {:ok, signed_request}

Per-tool-call signing:
  ToolLoop calls signer before each tool execution
  authorize_and_execute/4 binds resource URI + identity
```

Private keys never appear in the Profile or any unencrypted store.

---

## 2. Memory Subsystem

### Architecture

All memory stores follow the same pattern: **ETS for fast reads, async writes to Postgres via MemoryStore/BufferedStore**. The `Arbor.Memory` facade delegates to five sub-facades: `IndexOps`, `KnowledgeOps`, `IdentityOps`, `GoalIntentOps`, `SessionOps`.

### Store Catalog

| Store | ETS Table | Postgres | Key Format | Purpose |
|---|---|---|---|---|
| GoalStore | `:arbor_memory_goals` | Yes | `{agent_id, goal_id}` | BDI goals with status tracking |
| IntentStore | `:arbor_memory_intents` | Yes | `agent_id` | Intentions linked to goals, retry tracking |
| WorkingMemory | `:arbor_working_memory` | Yes | `agent_id` | Present-moment awareness (thoughts, goals, concerns) |
| SelfKnowledge | `:arbor_self_knowledge` | Yes | `agent_id` | Capabilities, traits, values, preferences |
| KnowledgeGraph | `:arbor_memory_graphs` | Yes | `agent_id` | Semantic network with relevance decay |
| Thinking | `:arbor_memory_thinking` | Yes | `agent_id` | Ring buffer of thinking blocks (default 50) |
| CodeStore | `:arbor_memory_code` | Yes | `agent_id` | Code snippets from conversations |
| ChatHistory | `:arbor_chat_history` | Yes | `agent_id` | Conversation history |
| Proposals | `:arbor_memory_proposals` | No (ETS only) | `{agent_id, proposal_id}` | Subconscious proposal queue |
| Preferences | `:arbor_preferences` | Yes | `agent_id` | Behavioral preferences |

### Working Memory

The agent's "present moment" — a versioned struct (v3) containing:
- Identity: agent_id, name
- Relationship: current_human, current_conversation
- Cognitive: recent_thoughts (ring buffer with timestamps), active_goals, active_skills
- Emotional: concerns, curiosity (capped lists), engagement_level (0.0-1.0)
- Budgets: max_tokens, model (for token-budget trimming)

Rendered to LLM context via `WorkingMemory.to_prompt_text/1`. Can be rebuilt from signal event history via `rebuild_from_long_term/1`.

### Goal Store (BDI Goals)

Goals are `Arbor.Contracts.Memory.Goal` structs with `{agent_id, goal_id}` composite keys. Full CRUD with signal emission on every mutation. Goals drive the BDI cognitive mode selection in the heartbeat.

### Intent Store (BDI Intentions)

Intents link to goals via `goal_id`. Lifecycle: created from decompositions → pending → locked (by executor) → completed/failed. Retry tracking with abandonment after 3 failures. Dead-letter detection checks if all intents for a goal are terminal.

### Self-Knowledge

What the agent knows about itself — capabilities (with proficiency 0-1), personality traits (with strength 0-1), values (with importance 0-1), preferences, and a growth log (last 100 events). Supports versioned snapshots (up to 10) for rollback. This is the target of the identity evolution pipeline.

### Knowledge Graph

Semantic network persisted to Postgres via MemoryStore. Nodes have type, content, relevance, confidence, metadata, access count, and timestamps. Relevance decays over time via `DecayEngine`. Nodes mature through access (count ≥ 3, age ≥ 3 days, confidence ≥ 0.75 makes them promotion candidates). On restart, the full graph is loaded from Postgres; template knowledge is re-seeded on top (deduplicated). Pruned/decayed nodes are archived to the Historian via `Events.record_knowledge_archived` before removal, so nothing is silently lost.

### Proposal Queue

The "subconscious proposes, conscious decides" pattern. Types: `:fact`, `:insight`, `:learning`, `:pattern`, `:preconscious`, `:identity`. Deduplication via Jaro-Winkler similarity (≥ 0.85 = duplicate). Max 20 pending per agent. Lifecycle: `create/3` → pending → `accept/2` (promoted to KG with +0.2 confidence) / `reject/2` / `defer/2`.

---

## 3. Persistence Stack

```
ETS (fast, transient)
  ↕ MemoryStore (write-through helpers)
  ↕ BufferedStore GenServer (serializes writes, ETS + backend)
  ↕ QueryableStore.Postgres (records table, JSONB, upsert)
```

### Key Format

All stores use composite keys to prevent the namespace prefix loss bug:

```elixir
composite_key = "#{namespace}:#{original_key}"
# e.g., "self_knowledge:agent_abc123"
# e.g., "goals:agent_abc123:goal_xyz"
```

The `Record.key` in Postgres matches the ETS key exactly. Old records without the prefix are found via a `Record.id` fallback during `load_all`.

### BufferedStore

GenServer implementing the `Store` behaviour. Reads bypass the GenServer (direct ETS lookup). Writes serialize through the GenServer to both ETS and the configured backend. On init, loads all data from the backend into ETS. Configurable write mode: `:async` (default) or `:sync`.

### QueryableStore.Postgres

Uses a single `records` table with `(namespace, key)` composite unique constraint. Upserts via `on_conflict: [set: [...]]`. JSONB `data` and `metadata` columns.

---

## 4. The Seed Manifest

`Arbor.Agent.Seed` is a portable snapshot of all agent state. It implements `Arbor.Persistence.Checkpoint` for serialization.

### Contents

| Group | Fields |
|---|---|
| Metadata | id, agent_id, seed_version, captured_at, captured_on_node, capture_reason |
| Identity | name, profile, self_model (versioned, max 10 snapshots), identity_rate_limit |
| Learned State | learned_capabilities (attempts/successes per action), action_history |
| Subsystem Snapshots | working_memory, context_window, knowledge_graph, self_knowledge, preferences, goals, recent_intents, recent_percepts |
| Tracking | consolidation_state, checkpoint_ref, last_checkpoint_at, version |

### Operations

- `Seed.capture/2` — gathers state from all stores into one struct
- `Seed.restore/2` — pushes state back (skippable subsystems via `:skip`)
- `Seed.serialize/1` / `deserialize/1` — ETF binary (`:erlang.term_to_binary`)
- `Seed.to_map/1` / `from_map/1` — JSON-safe map (ISO8601 datetimes)
- `Seed.save_to_file/2` / `load_from_file/1` — ETF on disk
- `Seed.update_self_model/2` — rate-limited (max 3/day, 4hr cooldown)
- `Seed.record_action_outcome/4` — tracks learned capabilities

---

## 5. Identity Evolution

### The Consolidation Pipeline

Identity evolves through a three-stage pipeline: detect → propose → decide.

**Stage 1: Detection** (automatic, runs in consolidation heartbeat mode)

```
IdentityConsolidator.consolidate/2:
  1. Rate limit check (max 3/day, 4hr cooldown)
  2. InsightDetector.detect → high-confidence insights (≥ 0.7)
  3. Promotion.find_promotion_candidates from KnowledgeGraph:
     - age ≥ 3 days
     - confidence ≥ 0.75
     - access_count ≥ 3
     - relevance ≥ 0.5
     - has evidence
     - not already promoted
  4. Categorize → {promoted, deferred, blocked}
  5. SelfKnowledge.snapshot (for rollback safety)
  6. Integrate insights + synthesize from KG candidates
  7. Create :identity proposals → Proposal queue
```

**Stage 2: Proposal** (queued in ETS)

Identity proposals sit in the proposal queue until the next heartbeat cycle reaches `process_proposal_decisions`. The LLM sees pending proposals in its context and returns accept/reject/defer decisions.

**Stage 3: Decision** (LLM-driven, runs in heartbeat)

```
process_proposal_decisions adapter:
  "accept" → Proposal.accept/2
    → For :identity type: IdentityConsolidator.apply_accepted_change/2
      → SelfKnowledge.add_trait/add_capability/add_value (ETS + Postgres)
  "reject" → Proposal.reject/3 (calibration record)
  "defer"  → no-op (stays in queue for next cycle)
```

### Design Principle: Nothing Stores Without Review

The consolidation subsystem never writes directly to SelfKnowledge. It creates proposals that the LLM must explicitly accept. This is the "conscious gatekeeper" pattern — the agent's subconscious detects patterns, but only the conscious agent decides what becomes part of its identity.

Exceptions:
- Knowledge graph decay/pruning (maintenance, not identity change)
- Memory indexing during queries (the LLM chose to say it, so it's already endorsed)

---

## 6. Heartbeat Pipeline

The heartbeat is a DOT graph (`heartbeat.dot`) executed by the orchestrator engine every 30 seconds.

### Pipeline Structure

```
start → bg_checks → select_mode → mode_router
                                      ├── goal_pursuit   → llm_goal
                                      ├── reflection     → llm_reflect
                                      ├── plan_execution → llm_plan
                                      └── consolidation  → consolidate
                                   (all branches merge)
                                          ↓
                                       process
                                          ↓
                                  store_decompositions
                                          ↓
                                  process_proposals
                                          ↓
                                    route_actions
                                          ↓
                                    update_goals
                                          ↓
                                        done
```

### Node Types

| Node | Handler Type | What It Does |
|---|---|---|
| bg_checks | `session.background_checks` | 6 health checks (memory freshness, timing) |
| select_mode | `session.mode_select` | BDI cognitive mode selection |
| mode_router | condition (diamond) | Fan-out on `cognitive_mode` value |
| llm_goal/reflect/plan | `session.llm_call` | LLM call with mode-specific prompt |
| consolidate | `session.consolidate` | KG decay + identity consolidation |
| process | `session.process_results` | Parse LLM JSON response |
| store_decompositions | `session.store_decompositions` | Goal decompositions → Intent structs |
| process_proposals | `session.process_proposal_decisions` | Accept/reject/defer proposals |
| route_actions | `session.route_actions` | Execute actions via Executor |
| update_goals | `session.update_goals` | Apply goal status changes |

### Mode Selection Logic

```
Active goals exist          → goal_pursuit
turn_count % 5 == 0         → consolidation (maintenance floor)
Undecomposed goals exist    → plan_execution
Otherwise                   → reflection
```

### Adapter Wiring

The `Adapters` module is a pure factory — zero compile-time dependencies. Every cross-library call goes through `bridge/4` (`Code.ensure_loaded?` + `apply/3`), catching `:exit` signals for unavailable processes.

| Adapter | Bridges To |
|---|---|
| `:llm_call` | `UnifiedLLM.Client.complete/2` |
| `:tool_dispatch` | `ToolBridge.authorize_and_execute/4` |
| `:memory_recall` | `Arbor.Memory.recall/3` |
| `:recall_goals` | `GoalStore.get_active_goals/1` |
| `:recall_intents` | `Arbor.Memory.pending_intentions/1` |
| `:recall_beliefs` | `SelfKnowledge` via `Arbor.Memory.get_self_knowledge/1` |
| `:memory_update` | `Arbor.Memory.index_memory_notes/2` |
| `:store_decompositions` | `Arbor.Memory.record_intent/2` |
| `:process_proposal_decisions` | `Proposal.accept/2`, `reject/3` |
| `:consolidate` | `Memory.consolidate/2` + `IdentityConsolidator.consolidate/2` |
| `:apply_identity_insights` | `Arbor.Memory.add_insight/4` |
| `:update_goals` | `GoalStore.update_goal/2` + `add_goal/3` |
| `:background_checks` | `BackgroundChecks.run/2` |
| `:trust_tier_resolver` | `Arbor.Trust.get_tier/1` |
| `:checkpoint` | `Persistence.Checkpoint.write/3` |

---

## 7. AgentSeed Mixin

The `use Arbor.Agent.AgentSeed` mixin wires memory into any GenServer host agent. It provides:

**`init_seed/2`** — called during GenServer init:
1. `Memory.init_for_agent/1`
2. Loads working memory from ETS/Postgres
3. Initializes context window via `ContextManager`
4. Starts Executor GenServer
5. Subscribes to percept results from Executor
6. Subscribes to memory signals (consolidation, insights, preconscious, facts)

**Query hooks:**
- `prepare_query/2` — inject recalled memories + timing + self-knowledge into prompt
- `finalize_query/3` — index response, update working memory, trigger consolidation (every 10 queries)

**Percept handling** — when Executor completes an action:
- `:success` → `Memory.complete_intent/2`
- `:failure` → `Memory.fail_intent/3`, retry counter, abandon after 3 retries
- Abandoned goals checked via dead-letter detection (all intents terminal)

---

## 8. End-to-End Data Flow

```
TEMPLATE DEFINITION
  │
  ▼
LIFECYCLE.create ─── Crypto Identity ──→ Security ETS
  │                  (Ed25519 keypair)    (identity, endorsement, capabilities)
  │                       │
  │                       └──→ Postgres (encrypted private key)
  │
  ├── Goals ──→ GoalStore (ETS + Postgres)
  ├── Knowledge ──→ KnowledgeGraph (ETS only, transient)
  ├── Values/Traits ──→ SelfKnowledge (ETS + Postgres, durable)
  ├── Thoughts ──→ Thinking (ETS + Postgres)
  └── Profile ──→ .arbor/agents/<id>.agent.json
       │
       ▼
LIFECYCLE.start ─── Restore from Postgres/JSON ──→ ETS
       │
       ▼
HEARTBEAT CYCLE (every 30s via heartbeat.dot)
  │
  ├── bg_checks → health monitoring
  ├── select_mode → BDI cognitive mode
  │
  ├── [LLM call] ← context: goals + intents + beliefs + working memory
  │       │
  │       ▼
  │   process_results → extracts structured response
  │       │
  │       ├── decompositions → IntentStore (new intents)
  │       ├── proposal_decisions → Proposal.accept/reject/defer
  │       │       └── :identity accepted → SelfKnowledge update
  │       ├── identity_insights → SelfKnowledge (via add_insight)
  │       ├── actions → Executor → percept results
  │       ├── goal_updates → GoalStore
  │       └── new_goals → GoalStore
  │
  └── [consolidation mode]
          ├── KG decay + prune
          └── IdentityConsolidator
                  ├── detect high-confidence insights
                  ├── find promotion candidates
                  └── create :identity proposals → Proposal queue
                          │
                          └── (next heartbeat) → LLM reviews → accept/reject
                                                      │
                                                      └── SelfKnowledge evolves

PERSISTENCE (all stores)
  ETS ←→ MemoryStore ←→ BufferedStore ←→ QueryableStore.Postgres
  (fast)                 (GenServer)        (records table, JSONB)
```

---

## Module Reference

| Module | App | Role |
|---|---|---|
| `Arbor.Agent.Template` | arbor_agent | Behaviour for agent archetypes |
| `Arbor.Agent.Character` | arbor_agent | Static personality schema |
| `Arbor.Agent.Profile` | arbor_agent | Persisted identity manifest |
| `Arbor.Agent.Lifecycle` | arbor_agent | Create/start/stop/destroy orchestrator |
| `Arbor.Agent.Seed` | arbor_agent | Portable state snapshot + checkpoint |
| `Arbor.Agent.AgentSeed` | arbor_agent | Host mixin for memory integration |
| `Arbor.Memory` | arbor_memory | Public facade (5 sub-facades) |
| `Arbor.Memory.WorkingMemory` | arbor_memory | Present-moment awareness struct |
| `Arbor.Memory.GoalStore` | arbor_memory | BDI goal CRUD + signals |
| `Arbor.Memory.IntentStore` | arbor_memory | BDI intent lifecycle + retries |
| `Arbor.Memory.SelfKnowledge` | arbor_memory | Agent self-model (versioned) |
| `Arbor.Memory.KnowledgeGraph` | arbor_memory | Semantic network (ETS, transient) |
| `Arbor.Memory.Thinking` | arbor_memory | Thinking block ring buffer |
| `Arbor.Memory.Proposal` | arbor_memory | Subconscious proposal queue |
| `Arbor.Memory.IdentityConsolidator` | arbor_memory | Insight detection + identity proposals |
| `Arbor.Memory.MemoryStore` | arbor_memory | Write-through persistence helpers |
| `Arbor.Persistence.BufferedStore` | arbor_persistence | ETS cache + pluggable backend |
| `Arbor.Persistence.QueryableStore.Postgres` | arbor_persistence | Postgres upsert backend |
| `Arbor.Orchestrator.Session.Adapters` | arbor_orchestrator | Heartbeat adapter factory |
| `Arbor.Orchestrator.Handlers.SessionHandler` | arbor_orchestrator | DOT node type dispatcher |
