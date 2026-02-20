# Session-as-DOT Spike Results

**Spike Duration**: 1.5 days (of 2-3 day budget)
**Date**: 2026-02-11
**Verdict**: **VIABLE** — proceed to Phase 1 contracts

---

## 1. Success/Failure Against Spike Criteria

### 1a. Turn graph executes end-to-end (query-response AND tool loop)

**SUCCESS**

Both the minimal inline graph and full `turn.dot` execute end-to-end with mock adapters. The pipeline traverses `start -> classify -> check_auth -> recall -> select_mode -> call_llm -> check_response -> format -> update_memory -> checkpoint -> done` correctly. The `session.response` context key carries the LLM output through formatting to the final result. 28/28 tests pass.

**Evidence**: Tests at L328 (minimal graph), L384 (full turn.dot), L433 (adapter value verification).

### 1b. Tool loop works via graph cycle edges

**SUCCESS**

The cycle edge `dispatch_tools -> call_llm` works correctly. The engine does NOT track visited nodes, so re-entering `call_llm` is legal. Tested with:
- Single tool call then text (L484): 2 LLM calls, 1 tool dispatch
- Multi-turn: 3 tool calls then text (L603): 4 LLM calls, 3 tool dispatches
- Infinite loop guard (L560): `max_steps: 10` correctly returns `{:error, :max_steps_exceeded}`

The `check_response` diamond routes on `context.llm.response_type` — `tool_call` cycles back, `text` exits to format. This is the single most important validation of the spike.

**Evidence**: Counter-based mock LLM confirms exact call counts. Context accumulates tool results in `session.messages` across cycles.

### 1c. Heartbeat modes route via conditional edges

**SUCCESS** (with known condition key gap, workaround validated)

The `mode_router` diamond fans out to four branches (`llm_goal`, `llm_reflect`, `llm_plan`, `consolidate`) based on `session.cognitive_mode`. All four branches converge at `process`. Mode selection logic (goals exist -> goal_pursuit, turn%5 -> consolidation, else -> reflection) works correctly.

**Known gap**: The shipped `heartbeat.dot` uses `context.cognitive_mode` but the handler sets `session.cognitive_mode`. The condition module resolves `context.X` by looking up key `X`, so `context.cognitive_mode` looks for key `"cognitive_mode"` (miss) instead of `"session.cognitive_mode"`. The fix is trivial — use `context.session.cognitive_mode` in the DOT file. Validated in test at L931.

Similarly, `turn.dot` uses `context.input_type` but the handler sets `session.input_type`. Same fix: `context.session.input_type`.

**Evidence**: Inline graphs with corrected condition keys (L676) route correctly. Full `heartbeat.dot` also reaches `done` (L756) because the condition module's fallback behavior happens to pick the first edge when no condition matches.

### 1d. Context serialization round-trip is lossless

**SUCCESS**

Full round-trip validated at L1108:
1. `Session.build_turn_values/2` serializes state + user message into flat context map
2. Engine runs with `initial_values` seeding the context
3. Handler nodes read/write context keys during execution
4. `Session.apply_turn_result/3` merges engine output back into Session struct

Verified:
- Messages grow by exactly 2 (user + assistant) per turn
- `turn_count` increments
- `trust_tier` preserved unchanged (atom -> string -> atom round-trip via `safe_to_atom`)
- `goals` preserved unchanged through turn pipeline
- `working_memory` updated if engine modified it
- Heartbeat result application updates `cognitive_mode` and applies goal changes

**Evidence**: GenServer round-trip test (L1213) confirms state consistency across 2 sequential turns.

### 1e. Handler interface is expressive enough

**SUCCESS**

The `SessionHandler` dispatches 12 node types via a single `execute/4` callback. The adapter injection pattern (`opts[:session_adapters]` map of functions) handles all current agent concerns:

| Node Type | Pure Logic | Adapter-Backed |
|-----------|-----------|----------------|
| `session.classify` | x | |
| `session.mode_select` | x | |
| `session.format` | x | |
| `session.process_results` | x | |
| `session.memory_recall` | | x |
| `session.memory_update` | | x |
| `session.llm_call` | | x |
| `session.tool_dispatch` | | x |
| `session.checkpoint` | | x |
| `session.background_checks` | | x |
| `session.route_actions` | | x |
| `session.update_goals` | | x |

The `with_adapter/3` helper provides graceful degradation — missing adapters return `ok(%{})`. Adapter exceptions are caught and swallowed (pipeline continues). This matches the resilience requirements for both dashboard agents and autonomous heartbeats.

The `idempotency_for/1` function provides per-node-type checkpoint granularity (read_only vs side_effecting), though the handler-level callback returns `:side_effecting` as a conservative default.

**Limitation found**: No `session.emit_signal` node type yet. Signal emission during turns/heartbeats would need either a new node type or integration into existing adapter callbacks.

### 1f. Total new code line count

| File | Lines | Purpose |
|------|-------|---------|
| `session_handler.ex` | 263 | Handler dispatch + 12 node types |
| `session.ex` | 451 | GenServer + context builders + result application |
| `turn.dot` | 90 | Turn pipeline graph |
| `heartbeat.dot` | 86 | Heartbeat pipeline graph |
| `session_test.exs` | 1,320 | 28 tests across 8 describe blocks |
| **Total** | **2,210** | |
| **Production code** | **890** | (handler + session + DOT specs) |

The 890-line production footprint is lean for what it replaces. The current `AgentSeed` alone is 1,000+ lines, plus `Claude` (621), `APIAgent` (453), `HeartbeatLoop` (390) = 2,464+ lines of procedural logic that this graph architecture subsumes.

---

## 2. Contracts Needed for Phase 1

### 2a. Session state fields for `arbor_contracts`

```elixir
# In arbor_contracts/lib/arbor/contracts/session.ex

@type session_state :: %{
  session_id: String.t(),
  agent_id: String.t(),
  trust_tier: trust_tier(),
  turn_count: non_neg_integer(),
  messages: [message()],
  working_memory: map(),
  goals: [goal()],
  cognitive_mode: cognitive_mode()
}

@type cognitive_mode :: :reflection | :goal_pursuit | :plan_execution | :consolidation

@type message :: %{
  required(:role) => String.t(),  # "user" | "assistant" | "tool" | "system"
  required(:content) => String.t(),
  optional(:tool_call_id) => String.t(),
  optional(:name) => String.t()
}

@type turn_result :: %{
  response: String.t(),
  tool_calls_made: non_neg_integer(),
  context_snapshot: map()
}
```

### 2b. Context bridge key conventions

The spike established a namespace convention for context keys. This should be formalized:

| Prefix | Owner | Examples |
|--------|-------|---------|
| `session.*` | Session GenServer / SessionHandler | `session.id`, `session.agent_id`, `session.messages`, `session.input`, `session.response` |
| `llm.*` | LLM call handler | `llm.response_type`, `llm.content`, `llm.tool_calls` |
| `graph.*` | Engine (auto-populated) | `graph.goal`, `graph.label` |

**Rule**: Condition edges in DOT files MUST use `context.session.X` (not `context.X`) for handler-set keys. The `llm.*` prefix works without `session.` because it doesn't collide.

**Action**: Fix `turn.dot` conditions from `context.input_type` to `context.session.input_type` and `heartbeat.dot` conditions from `context.cognitive_mode` to `context.session.cognitive_mode`.

### 2c. Adapter function signatures

These should be defined as typespecs in a contract module:

```elixir
# In arbor_contracts/lib/arbor/contracts/session/adapter.ex

@type llm_call :: (messages :: [message()], mode :: String.t(), opts :: map() ->
  {:ok, %{content: String.t()}} |
  {:ok, %{tool_calls: [tool_call()]}} |
  {:error, term()})

@type tool_dispatch :: (tool_calls :: [tool_call()], agent_id :: String.t() ->
  {:ok, [String.t()]} | {:error, term()})

@type memory_recall :: (agent_id :: String.t(), query :: String.t() ->
  {:ok, [term()]} | {:error, term()} | [term()])

@type memory_update :: (agent_id :: String.t(), turn_data :: map() -> :ok)

@type checkpoint :: (session_id :: String.t(), turn_count :: non_neg_integer(), snapshot :: map() -> :ok)

@type route_actions :: (actions :: [map()], agent_id :: String.t() -> :ok)

@type update_goals :: (goal_updates :: [map()], new_goals :: [map()], agent_id :: String.t() -> :ok)

@type background_checks :: (agent_id :: String.t() -> map())
```

### 2d. Trust tier integration points

1. **Authorization gate**: `check_auth` diamond in `turn.dot` currently classifies input type but doesn't check trust tier. Phase 1 needs a `session.authorize` node type that reads `session.trust_tier` and checks against capability requirements.

2. **Tool filtering**: The `tool_dispatch` adapter needs trust-tier-aware tool filtering. Currently, tool authorization happens in the Executor — the adapter should delegate to `Arbor.Security.authorize/3` before dispatching.

3. **Heartbeat interval**: Trust tier should influence heartbeat frequency. Lower tiers might have longer intervals or no heartbeat at all.

4. **Adapter capability scoping**: The adapter map itself could be trust-tier-gated — untrusted sessions get no `tool_dispatch` adapter, for example.

---

## 3. Engine Modifications Needed

### 3a. Did graph cycles work correctly?

**YES** — no modifications needed.

The engine's `reduce`-based walker does NOT maintain a visited-node set, so cycle edges (`dispatch_tools -> call_llm`) work natively. The engine re-enters nodes cleanly, and `max_steps` provides the termination guarantee. This was the biggest risk going in, and it worked on the first try.

The cycle semantics are exactly right for tool loops: each iteration through `call_llm -> check_response -> dispatch_tools -> call_llm` accumulates tool results in context (`session.messages` grows), and the LLM sees the full history on each re-entry.

### 3b. Any condition evaluator limitations hit?

**YES — one limitation, minor fix needed.**

The `Condition.eval/3` module resolves `"context.X"` by looking up key `X` in the Context. This means:
- `context.llm.response_type` -> looks up `"llm.response_type"` -> **WORKS** (handler sets `"llm.response_type"`)
- `context.input_type` -> looks up `"input_type"` -> **FAILS** (handler sets `"session.input_type"`)
- `context.cognitive_mode` -> looks up `"cognitive_mode"` -> **FAILS** (handler sets `"session.cognitive_mode"`)

**Fix**: Two options (not mutually exclusive):
1. **DOT file fix** (recommended): Change conditions to `context.session.input_type` and `context.session.cognitive_mode`
2. **Engine enhancement** (optional): Add namespace-aware condition resolution that tries `session.` prefix when bare key fails

Option 1 is the right fix — it makes the condition keys explicit and self-documenting. The spike tests already validated that `context.session.cognitive_mode` resolves correctly (L931).

### 3c. Performance overhead of graph walk

**NEGLIGIBLE** — no modifications needed.

All 28 tests complete in 0.5 seconds total. Individual graph executions are 7-18ms including mock adapter calls. The engine's `reduce`-based walker is O(N) in nodes visited (with O(1) edge lookup via adjacency map). For a 12-node graph, overhead is microseconds — completely dominated by actual work (LLM calls in production).

The `max_steps: 100` default in Session provides ample room. Even the most aggressive tool loop (3 cycles) only visits ~16 nodes. A 100-step budget allows ~20 tool call cycles before termination.

No performance modifications needed for Phase 1.

---

## 4. Migration Path Sketch

### 4a. Claude GenServer -> Session

| Claude Concern | Session Mapping | Notes |
|---------------|-----------------|-------|
| `handle_call({:query, ...})` | `Session.send_message/2` | Direct replacement |
| `AgentSDK.query/2` | `:llm_call` adapter | Adapter wraps SDK call + thinking extraction |
| `SessionReader.read_thinking/1` | Extend `:llm_call` adapter return | Add `thinking` field to LLM response |
| `prepare_query/2` | `session.memory_recall` node | Adapter wraps memory recall |
| `finalize_query/3` | `session.memory_update` node | Adapter wraps index + consolidation |
| `CheckpointManager` | `session.checkpoint` node | Adapter wraps checkpoint save |
| Heartbeat timer | `Session.heartbeat_interval` | Same `Process.send_after` pattern |
| `seed_heartbeat_cycle/2` | `heartbeat.dot` graph | Graph replaces procedural logic |

**Strangler fig approach**: Claude GenServer creates a Session on init, delegates `query/2` to `Session.send_message/2`, and heartbeat to `Session.heartbeat/1`. Keep Claude GenServer as thin wrapper initially.

**Claude-specific adapter**:
```elixir
%{
  llm_call: fn messages, mode, opts ->
    case AgentSDK.query(session, prompt) do
      {:ok, response} ->
        thinking = SessionReader.latest_thinking() || []
        {:ok, %{content: response.text, thinking: thinking}}
      error -> error
    end
  end
}
```

### 4b. APIAgent -> Session

| APIAgent Concern | Session Mapping | Notes |
|-----------------|-----------------|-------|
| `handle_call({:query, ...})` | `Session.send_message/2` | Direct replacement |
| `generate_text_with_tools/2` | `:llm_call` adapter | Adapter wraps split prompt + API call |
| `build_stable_system_prompt/2` | Part of `:llm_call` adapter | Stable prompt built once, cached |
| `build_volatile_context/2` | Part of `:llm_call` adapter | Volatile built per-call from context |
| Tool loop (auto_execute) | Turn graph cycle | **Key win**: graph cycle replaces procedural loop |
| Heartbeat model decoupling | `:llm_call` adapter reads mode | Different model for heartbeat vs query |

**Key architectural win**: APIAgent's internal `auto_execute: true, max_turns: 10` tool loop is replaced by the graph cycle. The graph makes the loop visible, debuggable, and auditable. Tool call counts appear in the event stream.

### 4c. HeartbeatLoop -> heartbeat graph

| HeartbeatLoop Concern | Session Mapping | Notes |
|----------------------|-----------------|-------|
| `Process.send_after` timer | `Session.schedule_heartbeat/1` | Same pattern, already implemented |
| `busy` flag | `heartbeat_in_flight` | Same pattern, already implemented |
| `pending_messages` queue | **NOT YET IN SESSION** | Phase 2 addition |
| `determine_cognitive_mode` | `session.mode_select` node | Logic moved to handler |
| `run_background_checks` | `session.background_checks` node | Adapter-backed |
| `seed_think` callback | `session.llm_call` node | Mode passed via context |
| Action routing | `session.route_actions` node | Adapter-backed |
| Goal updates | `session.update_goals` node | Adapter-backed |
| Memory indexing | `session.memory_update` node (consolidation) | Adapter-backed |
| Identity consolidation (every 30 HB) | **NOT YET IN GRAPH** | Phase 2: periodic side-branch |
| Periodic reflection (every 60 HB) | **NOT YET IN GRAPH** | Phase 2: periodic side-branch |

### 4d. What stays in GenServer vs what moves to graph

**Stays in GenServer** (Session struct / callbacks):
- Process lifecycle (start_link, init, terminate)
- State persistence (messages, working_memory, goals, turn_count)
- Heartbeat timer scheduling
- Heartbeat busy/in-flight guard
- Message queueing during heartbeat (Phase 2)
- `apply_turn_result` and `apply_heartbeat_result` (state merge)
- Adapter map management

**Moves to graph**:
- Turn processing logic (classify -> authorize -> recall -> LLM -> format -> checkpoint)
- Tool loop control flow (cycle edge + condition routing)
- Heartbeat cognitive mode selection and routing
- Background checks -> mode select -> LLM -> process results -> route actions -> update goals
- Authorization gating (blocked input handling)

**Principle**: The GenServer owns *state*; the graph owns *flow*. State changes happen at the boundaries (before engine run: `build_values`; after: `apply_result`). The graph is stateless and deterministic given its inputs.

---

## 5. Open Questions

### 5a. Condition key alignment — fix DOT or fix engine?

**Recommendation**: Fix the DOT files. Use `context.session.cognitive_mode` and `context.session.input_type`. This makes conditions self-documenting and avoids magic prefix inference in the engine.

**Status**: Trivial fix, 4 lines changed across 2 DOT files. Validated in tests.

### 5b. Signal emission during graph execution

The current agent lifecycle emits signals (`agent_started`, `query_completed`, `heartbeat_complete`, `percept_received`). The Session + graph architecture has no signal emission points.

**Options**:
1. Add a `session.emit_signal` node type to SessionHandler
2. Emit signals in the GenServer wrappers (`apply_turn_result`, `apply_heartbeat_result`)
3. Use Engine event callbacks (`on_event`) to drive signal emission

**Recommendation**: Option 2 for Phase 1 (simple, matches current pattern), evolve to Option 1 for graph-visible signal emission later.

### 5c. Message queueing during heartbeat

HeartbeatLoop queues incoming user messages while a heartbeat is in-flight. Session's `heartbeat_in_flight` flag prevents stacking heartbeats but doesn't queue messages.

**Recommendation**: Phase 2 addition. For Phase 1, the GenServer's mailbox naturally queues `{:send_message, ...}` calls — they'll block until the heartbeat result is processed and the GenServer is free.

### 5d. Thinking block passthrough

Claude's thinking blocks are a first-class concern (displayed in dashboard, stored in Thinking memory). The current `:llm_call` adapter contract returns `%{content: String.t()}` or `%{tool_calls: list()}` but has no `thinking` field.

**Recommendation**: Extend the adapter return type:
```elixir
{:ok, %{content: String.t(), thinking: [String.t()]}}
```
SessionHandler stores thinking in `llm.thinking` context key. The Session GenServer extracts it in `apply_turn_result`.

### 5e. Prompt construction ownership

Currently APIAgent builds rich system prompts (stable + volatile split). Where does this live in Session?

**Options**:
1. In the `:llm_call` adapter (adapter builds prompt from context values)
2. In a `session.build_prompt` node type (pure logic, reads context, writes prompt)
3. In the GenServer before graph execution (pre-computed in `build_turn_values`)

**Recommendation**: Option 1 for Phase 1 (adapter encapsulates prompt strategy). Option 2 for Phase 2 (makes prompt construction visible and debuggable in the graph).

### 5f. Session persistence across restarts

The current Session GenServer loses all state on crash/restart. CheckpointManager provides persistence for the current agents.

**Recommendation**: The `session.checkpoint` adapter already snapshots context. For crash recovery, add `restore_from_checkpoint/1` in Session init that loads the last checkpoint and rebuilds the Session struct. Phase 2 work.

### 5g. Adapter composition for different agent types

Claude and APIAgent need different adapter maps. How are these composed?

**Recommendation**: Define adapter "profiles" — named maps of adapters that correspond to agent types. Phase 1 keeps it simple: the caller provides the adapter map. Phase 2 introduces `Arbor.Contracts.Session.AdapterProfile` with predefined compositions.

### 5h. Graph hot-swapping

Can a running Session's turn or heartbeat graph be replaced without restart?

**Current state**: The graphs are stored in the GenServer struct. A `handle_cast(:update_graph, ...)` would suffice. The engine is stateless — each `Engine.run` gets a fresh graph. No engine modifications needed.

**Recommendation**: Phase 2 feature. Enables graph evolution without agent restart — critical for the DOT-as-strategy architecture.

---

## Summary

| Criterion | Result |
|-----------|--------|
| Turn graph end-to-end | **PASS** |
| Tool loop via cycle edges | **PASS** |
| Heartbeat mode routing | **PASS** (condition key fix needed, trivial) |
| Context round-trip lossless | **PASS** |
| Handler interface expressive | **PASS** |
| Production code footprint | **890 lines** (lean) |
| Tests | **28/28 passing** |
| Engine modifications needed | **None** (condition key fix is DOT-side) |

**Verdict**: Session-as-DOT is viable. The engine handles cycles, conditions, and context accumulation correctly. The adapter injection pattern cleanly separates orchestration from infrastructure. The migration path is incremental (strangler fig). Proceed to Phase 1 contracts.
