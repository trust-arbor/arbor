# Arbor Orchestrator Specification

A security-aware DOT pipeline engine that extends the [Attractor specification](../attractor/attractor-spec.md) with mandatory middleware, a three-layer handler architecture, intermediate representation compilation, and self-modifying pipeline support. Built on Elixir/OTP for the Arbor distributed AI agent system.

Arbor implements 100% of the Attractor spec (20/20 features) and adds 13 major extensions. This document specifies Arbor's complete orchestrator behavior, including both Attractor-conformant features and Arbor-specific extensions.

---

## Table of Contents

1. [Overview and Goals](#1-overview-and-goals)
2. [DOT DSL Schema](#2-dot-dsl-schema)
3. [Pipeline Execution Engine](#3-pipeline-execution-engine)
4. [Three-Layer Handler Architecture](#4-three-layer-handler-architecture)
5. [Mandatory Middleware](#5-mandatory-middleware)
6. [Node Handlers](#6-node-handlers)
7. [State and Context](#7-state-and-context)
8. [Human-in-the-Loop](#8-human-in-the-loop)
9. [Intermediate Representation](#9-intermediate-representation)
10. [Validation and Linting](#10-validation-and-linting)
11. [Model Stylesheet](#11-model-stylesheet)
12. [Transforms and Extensibility](#12-transforms-and-extensibility)
13. [Condition Expression Language](#13-condition-expression-language)
14. [Self-Modifying Pipelines](#14-self-modifying-pipelines)
15. [Event System](#15-event-system)

**Appendices**

- [A. Attribute Reference](#appendix-a-attribute-reference)
- [B. Stdlib Alias Map](#appendix-b-stdlib-alias-map)
- [C. Handler Conformance Matrix](#appendix-c-handler-conformance-matrix)

---

## 1. Overview and Goals

### 1.1 Relationship to Attractor

Arbor's orchestrator is a superset of the Attractor pipeline runner. Any valid Attractor pipeline runs unmodified on Arbor. Arbor adds:

- **Security middleware** that gates every node execution against a capability-based authorization system.
- **A three-layer handler architecture** (middleware, core handlers, stdlib aliases) that replaces the flat handler registry.
- **An IR compiler** that statically analyzes graphs for capability requirements, taint reachability, and data classification before execution.
- **Self-modifying pipelines** via the adapt handler, with trust-tier-gated mutation operations.
- **Fan-out/fan-in coordination** for true parallel branch execution with barrier synchronization.

All Attractor-specified features (goal gates, retry logic, backoff presets, context fidelity, model stylesheet, artifact store, run directories, interviewer pattern, edge weight routing, checkpoint resume, edge conditions, custom handlers, duration parsing, subgraph scoping, allow_partial, auto_status, loop_restart) are fully implemented as specified.

### 1.2 Design Principles

**Security is mandatory, not optional.** The middleware chain runs on every node execution. Capability checks, taint tracking, and input sanitization are always-on layers, not handler-level opt-ins. An untrusted pipeline cannot bypass security by choosing a different node type.

**Aliases preserve intent.** Pipeline authors write semantic type names (`"codergen"`, `"code_review"`, `"approval_gate"`) that map to canonical handlers with injected attributes. The alias system decouples authoring vocabulary from execution mechanics.

**Graphs are data.** The IR compiler transforms the DOT graph into a typed intermediate representation before execution. Static analysis catches errors (missing prompts, invalid conditions, unreachable nodes) at compile time rather than mid-execution.

**Self-modification is trust-gated.** Pipelines can modify their own structure at runtime via the adapt handler, but only within bounds set by the agent's trust tier. An untrusted agent cannot add nodes; a probationary agent can only modify attributes.

### 1.3 Layering

```
                    DOT Source
                        |
                   [ Parser ]         -- DOT text -> Graph struct
                        |
                 [ Transforms ]       -- Variable expansion, model stylesheet
                        |
                 [ IR Compiler ]      -- Graph -> TypedGraph (static analysis)
                        |
                  [ Validator ]       -- 10 lint rules
                        |
                    [ Engine ]        -- Graph traversal + state machine
                   /    |    \
            Middleware  Handler  Events
```

---

## 2. DOT DSL Schema

### 2.1 Supported Subset

Arbor accepts the same strict DOT subset as Attractor: one digraph per file, directed edges only, no HTML labels, typed attributes with defaults. Additionally, Arbor's parser provides error accumulation with skip-to-next-statement recovery and line number tracking.

### 2.2 BNF-Style Grammar

```
Graph           ::= 'digraph' Identifier '{' Statement* '}'

Statement       ::= GraphAttrStmt
                   | NodeDefaults
                   | EdgeDefaults
                   | SubgraphStmt
                   | NodeStmt
                   | EdgeStmt
                   | GraphAttrDecl

GraphAttrStmt   ::= 'graph' AttrBlock ';'?
NodeDefaults    ::= 'node' AttrBlock ';'?
EdgeDefaults    ::= 'edge' AttrBlock ';'?
GraphAttrDecl   ::= Identifier '=' Value ';'?

SubgraphStmt    ::= 'subgraph' Identifier? '{' Statement* '}'

NodeStmt        ::= Identifier AttrBlock? ';'?
EdgeStmt        ::= Identifier ( '->' Identifier )+ AttrBlock? ';'?

AttrBlock       ::= '[' Attr ( ',' Attr )* ']'
Attr            ::= Key '=' Value
                   | Key                           -- bare attr, expands to Key="true"

Key             ::= Identifier | QualifiedId
QualifiedId     ::= Identifier ( '.' Identifier )+

Value           ::= String | Integer | Float | Boolean | Duration
Identifier      ::= [A-Za-z_][A-Za-z0-9_]*
String          ::= '"' ( '\\"' | '\\n' | '\\t' | '\\\\' | [^"\\] )* '"'
Integer         ::= '-'? [0-9]+
Float           ::= '-'? [0-9]* '.' [0-9]+
Boolean         ::= 'true' | 'false'
Duration        ::= Integer ( 'ms' | 's' | 'm' | 'h' | 'd' )
```

### 2.3 Key Constraints

- **One digraph per file.** Multiple graphs, undirected graphs, and `strict` modifiers are rejected.
- **Bare identifiers for node IDs.** Must match `[A-Za-z_][A-Za-z0-9_]*`.
- **Commas required between attributes.**
- **Directed edges only.** `--` is rejected.
- **Comments.** `// line` and `/* block */` comments are stripped before parsing. Block comments preserve newline count for accurate line tracking.
- **Semicolons optional.**
- **Bare attributes.** `[nullable]` expands to `%{"nullable" => "true"}`.
- **Qualified keys.** `manager.actions="observe"` is a valid attribute key.

### 2.4 Error Recovery

When the `:accumulate_errors` option is set, the parser does not halt on the first syntax error. Instead it:

1. Records the error with line number.
2. Skips forward to the next `;` or newline boundary.
3. Continues parsing subsequent statements.
4. Returns `{:ok, graph, errors}` with all recoverable errors collected.

Line numbers are computed on demand from the byte offset: `byte_size(source) - byte_size(remaining_input)`, counting newlines in the consumed prefix.

### 2.5 Value Types

| Type     | Syntax                    | Examples                          |
|----------|---------------------------|-----------------------------------|
| String   | Double-quoted with escapes | `"Hello"`, `"line1\nline2"`      |
| Integer  | Optional sign, digits      | `42`, `-1`, `0`                  |
| Float    | Decimal number             | `0.5`, `-3.14`                   |
| Boolean  | Literal keywords           | `true`, `false`                  |
| Duration | Integer + unit suffix      | `900s`, `15m`, `2h`, `250ms`, `1d` |

Duration parsing converts to milliseconds: `ms` (1x), `s` (1000x), `m` (60000x), `h` (3600000x), `d` (86400000x). Bare integer strings are treated as milliseconds. Nil and integer values pass through unchanged.

### 2.6 Graph-Level Attributes

| Key                       | Type     | Default   | Description |
|---------------------------|----------|-----------|-------------|
| `goal`                    | String   | `""`      | Pipeline goal. Exposed as `$goal` in templates, mirrored to context as `graph.goal`. |
| `label`                   | String   | `""`      | Display name for visualization. |
| `model_stylesheet`        | String   | `""`      | CSS-like stylesheet for per-node LLM defaults. See Section 11. |
| `default_max_retry`       | Integer  | `50`      | Global retry ceiling for nodes that omit `max_retries`. |
| `retry_target`            | String   | `""`      | Node to jump to when exit is reached with unsatisfied goal gates. |
| `fallback_retry_target`   | String   | `""`      | Secondary retry target. |
| `default_fidelity`        | String   | `""`      | Default context fidelity mode. See Section 7.4. |
| `mandatory_middleware`    | Boolean  | `true`    | **Arbor extension.** Enable/disable the mandatory middleware chain. |

### 2.7 Node Attributes

| Key                       | Type     | Default     | Description |
|---------------------------|----------|-------------|-------------|
| `label`                   | String   | node ID     | Display name. |
| `shape`                   | String   | `"box"`     | Graphviz shape. Determines default handler type via shape mapping. |
| `type`                    | String   | `""`        | Explicit handler type. Takes precedence over shape. Resolved through the alias system. |
| `prompt`                  | String   | `""`        | Primary instruction. Supports `$goal` variable expansion. |
| `max_retries`             | Integer  | `0`         | Additional attempts beyond initial execution. |
| `goal_gate`               | Boolean  | `false`     | Node must reach SUCCESS before pipeline can exit. |
| `retry_target`            | String   | `""`        | Jump target on failure after retries exhausted. |
| `fallback_retry_target`   | String   | `""`        | Secondary retry target. |
| `fidelity`                | String   | inherited   | Context fidelity mode. See Section 7.4. |
| `thread_id`               | String   | derived     | LLM session identifier for `full` fidelity. |
| `class`                   | String   | `""`        | Comma-separated classes for stylesheet targeting. |
| `timeout`                 | Duration | unset       | Maximum execution time. |
| `llm_model`               | String   | inherited   | LLM model identifier. |
| `auto_status`             | Boolean  | `false`     | Override fail/retry to success. See Section 3.8. |
| `allow_partial`           | Boolean  | `false`     | Return partial_success on exhausted retries instead of fail. |
| `fan_out`                 | Boolean  | `false`     | **Arbor extension.** Enable fan-out from this node. See Section 3.9. |
| `simulate`                | String   | `""`        | Simulation mode for testing. `"true"` returns mock success. |
| `trust_tier`              | String   | `""`        | **Arbor extension.** Minimum trust tier for adapt mutations. |
| `skip_middleware`         | String   | `""`        | **Arbor extension.** Comma-separated middleware to skip. |
| `content_hash`            | String   | computed    | **Arbor extension.** SHA-256 of sorted attrs. For change detection. |

### 2.8 Edge Attributes

| Key                 | Type     | Default | Description |
|---------------------|----------|---------|-------------|
| `label`             | String   | `""`    | Display name. Also used as condition shorthand when no explicit condition set. |
| `condition`         | String   | `""`    | Edge condition expression. See Section 13. |
| `weight`            | Float    | `1.0`   | Selection priority. Higher weight preferred among matching edges. |
| `fidelity`          | String   | `""`    | Override context fidelity for the target node. |
| `thread_id`         | String   | `""`    | Override thread identifier for the target node. |
| `loop_restart`      | Boolean  | `false` | Terminate and restart pipeline from target node. See Section 3.7. |

### 2.9 Subgraph Scoping

Subgraphs define scoped defaults and class derivation:

```dot
subgraph security_checks {
    node [type="gate", max_retries=2]
    auth_check
    perm_check
}
```

- Nodes inside a subgraph inherit its `node [...]` defaults.
- Subgraph labels are converted to CSS class names for stylesheet targeting.
- Subgraphs are flattened into the parent graph during parsing (no nested execution).

---

## 3. Pipeline Execution Engine

### 3.1 Entry Points

The orchestrator exposes two entry points:

```
Orchestrator.run(source, opts)      -- parse + transform + execute
Orchestrator.run_file(path, opts)   -- read file + run
```

Both support options: `initial_values`, `interviewer`, `logs_root`, `max_steps`, `resume`, `resume_from`, `validate`, `cache`, `transforms`, `hmac_secret`.

### 3.2 Execution Loop

The engine is a sequential graph walker implemented as a recursive function `loop/1` operating on a `State` struct.

```
loop(state):
  1. Check max_steps guard.
  2. Read current node from state.node_id.
  3. Run middleware before_node chain.
  4. Execute handler via Executor.execute_with_retry.
  5. Apply auto_status override if applicable.
  6. Record outcome in state.outcomes.
  7. Run middleware after_node chain (reverse order).
  8. Check content hash for skip-on-no-change.
  9. Select outgoing edge via Router.
 10. If edge is loop_restart: call restart_pipeline.
 11. If target is exit node: check goal gates, finish or retry.
 12. If edge has fan-out: track pending siblings, defer fan-in.
 13. Advance to next node, recurse.
```

### 3.3 Edge Selection

Edge selection follows a priority chain:

1. **Condition match.** Evaluate each outgoing edge's condition against the current outcome and context. First match wins (first-match semantics, like `cond`).
2. **Handler suggested IDs.** If the handler's outcome includes `suggested_next_ids`, prefer edges whose target matches.
3. **Weight.** Among remaining candidates, prefer higher weight.
4. **Lexical.** Break ties by target node ID (alphabetical).

```
select_edge(edges, outcome, context):
  matching = edges |> filter(condition_matches(edge, outcome, context))
  if matching is empty:
    return edges |> best_by_weight_then_lexical
  else:
    return matching |> best_by_weight_then_lexical
```

### 3.4 Retry and Backoff

When a handler returns `:retry` or `:fail`:

1. Increment retry counter for the node.
2. If retries < max_retries: compute backoff delay, wait, re-execute.
3. If retries exhausted and `allow_partial=true`: return `:partial_success`.
4. If retries exhausted: return `:fail`.

**Five backoff presets:**

| Preset       | Attempts | Initial Delay | Factor | Max Delay | Jitter |
|-------------|----------|---------------|--------|-----------|--------|
| `standard`  | 5        | 200ms         | 2x     | 10s       | yes    |
| `aggressive`| 5        | 500ms         | 2x     | 30s       | yes    |
| `linear`    | 3        | 500ms         | 1x     | 5s        | yes    |
| `patient`   | 3        | 2s            | 3x     | 60s       | yes    |
| `none`      | 1        | 0             | 0      | 0         | no     |

Custom backoff is also supported via `initial_delay`, `factor`, `max_delay`, `jitter` attributes.

### 3.5 Goal Gates

Nodes with `goal_gate="true"` must reach `:success` or `:partial_success` before the pipeline can exit. When the engine reaches an exit node and any goal gate is unsatisfied:

**Retry target resolution (priority order):**

1. Failed gate node's `retry_target` attribute.
2. Failed gate node's `fallback_retry_target` attribute.
3. Graph-level `retry_target` attribute.
4. Graph-level `fallback_retry_target` attribute.

If no valid target is found: `{:error, :goal_gate_unsatisfied_no_retry_target}`.

### 3.6 Failure Routing

When a handler returns `:fail` and retries are exhausted:

1. Look for an outgoing edge with `label="fail"` from the current node.
2. If no fail edge: use `retry_target` from node attrs.
3. If no retry_target: use `fallback_retry_target` from node attrs.
4. If nothing: terminate pipeline with failure.

### 3.7 Loop Restart

When an edge with `loop_restart=true` is selected:

1. Compute next versioned log directory (e.g., `logs_root-v2`, `logs_root-v3`).
2. Create the directory and write a fresh manifest.
3. Reset engine state: clear `completed`, `retries`, `outcomes`, `pending`.
4. Preserve: `context`, `graph`, `opts`.
5. Re-enter the execution loop at the edge's target node.

Version path computation: if the path already ends with `-vN`, increment N; otherwise append `-v2`.

### 3.8 Auto Status

When `auto_status="true"` on a node and the handler returns `:fail` or `:retry`:

- Override outcome to `:success`.
- Set notes to `"auto-status: handler completed without writing status"`.
- Preserve `context_updates` from the original outcome.

This is checked immediately after `execute_with_retry` returns, before outcome recording.

### 3.9 Fan-Out / Fan-In (Arbor Extension)

Arbor extends Attractor with opt-in fan-out/fan-in gates for parallel branch coordination.

**Fan-out.** When a node has `fan_out="true"` and multiple outgoing edges, the engine:

1. Detects sibling branches (all edges from the fan-out node).
2. Adds sibling targets to the `pending` queue.
3. Executes one branch to completion.
4. Returns to pending queue for next branch.

**Fan-in.** When the engine reaches a node that is the target of multiple fan-out branches:

1. Checks if all predecessor branches have completed.
2. If not all complete: defers execution, returns to pending queue.
3. If all complete: proceeds through the fan-in node.

Fan-in gate only activates when `pending` is non-empty, preserving backwards-compatible behavior for nodes that happen to have multiple incoming edges in non-fan-out graphs.

### 3.10 Content Hash Skip

Each node has a computed content hash (SHA-256 of sorted attributes). If a node's content hash matches its hash from a previous execution in the same run (stored in `state.tracking.content_hashes`), the engine may skip re-execution and reuse the previous outcome.

---

## 4. Three-Layer Handler Architecture

Arbor organizes handler resolution into three layers. This replaces the flat handler registry from Attractor.

### 4.1 Layer Overview

```
Layer 1: Mandatory Middleware (always-on security/observability)
    |
Layer 2: 15 Core Handlers (canonical execution types)
    |
Layer 3: 59+ Stdlib Aliases (semantic authoring vocabulary)
```

**Flow:** Pipeline author writes a semantic type name (e.g., `"codergen"`) -> alias resolution maps to canonical type (`"compute"`) with injected attributes (`%{"purpose" => "llm"}`) -> core handler executes.

### 4.2 Core Handlers (15 Canonical Types)

| Type        | Handler Module     | Purpose |
|-------------|-------------------|---------|
| `start`     | StartHandler       | Pipeline entry point. No-op execution. |
| `exit`      | ExitHandler        | Pipeline termination. Returns final context. |
| `branch`    | BranchHandler      | Conditional routing via edge conditions. |
| `parallel`  | ParallelHandler    | Concurrent execution via `Task.async_stream`. |
| `fan_in`    | FanInHandler       | Barrier synchronization for parallel branches. |
| `compute`   | ComputeHandler     | General computation. LLM calls, transforms, etc. |
| `transform` | TransformHandler   | Data transformation without LLM. |
| `exec`      | ExecHandler        | External command execution (sandboxed). |
| `read`      | ReadHandler        | Read from external source (file, API, DB). |
| `write`     | WriteHandler       | Write to external target (file, API, DB). |
| `compose`   | ComposeHandler     | Sub-pipeline composition. Dispatches by attributes. |
| `map`       | MapHandler         | Apply handler to each item in a collection. |
| `adapt`     | AdaptHandler       | Self-modifying pipeline mutations. See Section 14. |
| `wait`      | WaitHandler        | Human-in-the-loop or timed pause. |
| `gate`      | GateHandler        | Authorization/approval checkpoint. |

### 4.3 Handler Behaviour

All handlers implement the `Handler` behaviour:

```elixir
@callback execute(node, context, graph, opts) :: Outcome.t()
@callback idempotency() :: :idempotent | :idempotent_with_key | :side_effecting | :read_only
```

**Optional three-phase protocol** for handlers that need it:

```elixir
@callback prepare(node, context, graph) :: {:ok, prepared_state} | {:error, reason}
@callback run(prepared_state) :: {:ok, result} | {:error, reason}
@callback apply_result(result, node, context) :: Outcome.t()
```

When all three callbacks are exported, the engine calls them in sequence instead of `execute/4`.

### 4.4 Handler Resolution

The Registry resolves type strings to handler modules:

```
resolve(type_string):
  1. Check custom handlers (persistent_term). -- highest priority
  2. Resolve through Stdlib.Aliases:
     a. Get canonical type + injected attributes.
     b. Merge injected attrs into node.
     c. Look up canonical type in core handler map.
  3. If type is already a canonical type: direct lookup.
  4. Check shape-to-type mapping (for nodes without explicit type).
  5. Fallback: CodergenHandler.
```

**Shape-to-type mapping:**

| Shape            | Default Type           |
|------------------|----------------------|
| `Mdiamond`       | `start`              |
| `Msquare`        | `exit`               |
| `diamond`        | `conditional` (alias) |
| `parallelogram`  | `tool` (alias)       |
| `hexagon`        | `wait.human`         |
| `component`      | `parallel`           |
| `tripleoctagon`  | `parallel.fan_in`    |
| `house`          | `stack.manager_loop` |
| `octagon`        | `graph.adapt`        |
| `box` (default)  | resolved by type attr or fallback |

### 4.5 Custom Handler Registration

External code can register custom handlers at runtime:

```elixir
Registry.register("my_custom_type", MyHandler)
Registry.unregister("my_custom_type")
```

Custom handlers take highest priority in resolution. Storage uses `:persistent_term` for zero-cost reads.

---

## 5. Mandatory Middleware

### 5.1 Middleware Chain

Seven middleware modules run on every node execution when `mandatory_middleware=true` (the default). Middleware is compiled from three sources: engine config, graph-level attributes, and node-level attributes.

**Execution order:**

| Order | Middleware          | Purpose |
|-------|--------------------|---------|
| 1     | CapabilityCheck    | Verify agent has permission to execute this node type. |
| 2     | TaintCheck         | Verify context values meet taint requirements. |
| 3     | Sanitization       | Sanitize prompt and context values against injection. |
| 4     | SafeInput          | Validate input constraints and type safety. |
| 5     | Checkpoint         | Save checkpoint before execution. |
| 6     | Budget             | Enforce token/cost/time budget limits. |
| 7     | SignalEmit         | Emit execution signals to the Arbor signal bus. |

**Protocol:** Each middleware implements `before_node/1` and `after_node/1`, receiving and returning a `Token` struct that carries context, node, graph, and options. A middleware can halt the chain by returning `{:halt, outcome}`.

```
before_node chain: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> [handler]
after_node chain:  7 -> 6 -> 5 -> 4 -> 3 -> 2 -> 1    (reverse order)
```

### 5.2 Capability Check

Bridges to `Arbor.Security.authorize/4` at runtime (via `Code.ensure_loaded?` + `apply/3` to avoid compile-time dependency).

- **Resource URI:** `arbor://orchestrator/execute/{node_type}`
- **Default agent:** `"agent_system"` (configurable via `agent_id` in context or opts)
- **On denial:** Halts chain, returns `:fail` outcome with authorization error.

### 5.3 Skip Middleware

Individual nodes can skip specific middleware via the `skip_middleware` attribute:

```dot
trusted_node [type="compute", skip_middleware="taint_check,sanitization"]
```

The engine filters the middleware chain before execution, removing any middleware whose name appears in the comma-separated skip list.

### 5.4 Feature Flag

The entire middleware chain can be disabled via `mandatory_middleware=false` at the graph level. This is intended for testing and development only. Production pipelines SHOULD always run with middleware enabled.

---

## 6. Node Handlers

### 6.1 Compute Handler (LLM / General Computation)

The compute handler is the primary workhorse. It dispatches based on the `purpose` attribute (often injected by aliases):

- `purpose="llm"` -> LLM call via backend function.
- `purpose="transform"` -> Data transformation.
- `purpose="shell"` -> Shell command execution (sandboxed).
- No purpose -> LLM call (default behavior, Attractor-compatible).

**LLM integration:** The handler accepts an `:llm_backend` function in opts for testability. In production, it bridges to `Arbor.Orchestrator.UnifiedLLM.Client` via runtime module loading.

**Node attributes consumed:**

| Attribute          | Purpose |
|-------------------|---------|
| `prompt`          | LLM instruction (supports `$goal` expansion) |
| `system_prompt`   | System message for LLM |
| `temperature`     | LLM sampling temperature |
| `provider`        | LLM provider identifier |
| `model`           | LLM model identifier |
| `simulate`        | `"true"` returns mock success without LLM call |

**Outcome:** Context updates include `last_response` (LLM output text), `last_prompt` (input), and handler-specific metadata.

### 6.2 Branch Handler (Conditional Routing)

Evaluates outgoing edge conditions and selects the next node. No computation -- routing is handled entirely by the engine's edge selection logic (Section 3.3). The handler returns `:success` to trigger edge evaluation.

### 6.3 Parallel Handler

Executes multiple child nodes concurrently using `Task.async_stream`:

- Collects items from `items_key` context value or `items` attribute.
- Applies `item_handler` to each item with configurable `max_concurrency`.
- Merges results into context.
- Returns `:success` when all items complete, `:partial_success` if some fail.

### 6.4 Fan-In Handler

Barrier synchronization node. Waits for all fan-out branches to complete before allowing execution to proceed. Used with `fan_out="true"` on upstream nodes (Section 3.9).

### 6.5 Wait Handler

Pauses execution for human input or a timed delay:

- `wait.human` (alias) -> delegates to the configured interviewer (Section 8).
- `wait.timer` (alias) -> pauses for `duration` attribute.
- `wait.signal` (alias) -> waits for an external signal.

### 6.6 Gate Handler

Authorization checkpoint. Checks a condition or approval before allowing pipeline to proceed:

- `gate.approval` (alias) -> human approval required.
- `gate.trust` (alias) -> trust tier check.
- `gate.capability` (alias) -> capability authorization.

Returns `:fail` if the gate condition is not met.

### 6.7 Compose Handler

Sub-pipeline composition. Dispatches based on node attributes to run nested pipelines, session handlers, or consensus workflows:

- `compose.pipeline` -> runs a sub-pipeline from a DOT file.
- `session.*` types -> 12 session lifecycle handlers for agent DOT pipelines.
- `consensus.*` types -> 5 consensus decision handlers for council DOT pipelines.

### 6.8 Exec Handler

Executes external commands in a sandboxed environment. Bridges to `Arbor.Shell` at runtime for sandbox enforcement.

- Respects agent trust tier for sandbox level.
- Falls back to fail-closed (no execution) if sandbox is unavailable.
- Explicit `sandbox="none"` attribute required for unsandboxed execution.

### 6.9 Read and Write Handlers

Generalized I/O handlers. The `target` attribute determines the source/destination:

- `target="file"` -> filesystem read/write.
- `target="context"` -> context value read/write.
- `target="api"` -> HTTP API call.

### 6.10 Map Handler

Applies a handler to each item in a collection:

- Reads items from context key specified by `items_key`.
- Resolves item handler from `item_type` attribute.
- Returns merged results in context.

### 6.11 Transform Handler

Data transformation without LLM. Applies transformations specified in the `transform` attribute (JSON path expressions, format conversions, key remapping).

### 6.12 Start and Exit Handlers

- **Start:** No-op. Sets initial context values from node attributes.
- **Exit:** Returns final context. Triggers goal gate check.

---

## 7. State and Context

### 7.1 Engine State

The engine maintains a `State` struct across the execution loop:

| Field               | Type            | Description |
|--------------------|-----------------|-------------|
| `graph`            | Graph.t()       | The pipeline graph. |
| `node_id`          | String.t()      | Current node being executed. |
| `incoming_edge`    | Edge.t() | nil  | Edge that led to current node. |
| `context`          | Context.t()     | Accumulated context values. |
| `logs_root`        | String.t()      | Directory for run artifacts. |
| `max_steps`        | integer()       | Guard against infinite loops. |
| `completed`        | [String.t()]    | Node IDs that have completed. |
| `retries`          | map()           | Per-node retry counters. |
| `outcomes`         | map()           | Per-node execution outcomes. |
| `pending`          | [String.t()]    | Fan-out branches awaiting execution. |
| `opts`             | keyword()       | Engine options. |
| `pipeline_started_at` | DateTime.t() | Timestamp of pipeline start. |
| `tracking`         | map()           | Node durations and content hashes. |

### 7.2 Context

The context is an immutable struct passed through the pipeline. Each handler can return `context_updates` in its outcome, which the engine merges into the context before advancing.

```elixir
%Context{
  values: %{String.t() => term()},
  logs: [%{node_id: String.t(), message: String.t(), timestamp: String.t()}],
  lineage: %{String.t() => %{node_id: String.t(), timestamp: String.t(), operation: atom()}}
}
```

**Lineage tracking (Arbor extension).** Every context key records which node last set it, when, and what operation was performed. This enables tracing data provenance through the pipeline.

### 7.3 Checkpoint and Resume

After each node completes, the engine can save a checkpoint:

```json
{
  "timestamp": "2026-02-19T12:00:00Z",
  "current_node": "review",
  "completed_nodes": ["start", "generate", "test"],
  "node_retries": {"generate": 1},
  "context_values": { ... },
  "node_outcomes": { ... },
  "context_lineage": { ... },
  "content_hashes": { ... },
  "__hmac": "a1b2c3..."
}
```

**HMAC-SHA256 signing.** When an `hmac_secret` is provided, checkpoints are signed with `:crypto.mac(:hmac, :sha256, secret, canonical_json)`. The signature is hex-encoded and stored as `__hmac`. Verification uses constant-time comparison via `:crypto.hash_equals/2`. Tampered checkpoints return `{:error, :tampered}`.

**Resume options:**

| Option        | Description |
|---------------|-------------|
| `resume: true` | Resume from latest checkpoint in `logs_root`. |
| `resume_from: path` | Resume from specific checkpoint file. |
| `hmac_secret: binary` | Verify checkpoint signature before resuming. |

**Sanitization.** Internal context keys (`__adapted_graph__`, `__completed_nodes__`) are stripped before serialization.

### 7.4 Context Fidelity

Fidelity controls how much context is passed to LLM nodes. Six modes:

| Mode             | Behavior |
|-----------------|----------|
| `full`          | Complete context. Thread ID resolved for session reuse. |
| `truncate`      | Truncate context values beyond a size threshold. |
| `compact`       | Remove nil values and empty strings. |
| `summary:low`   | Minimal summarization. |
| `summary:medium` | Moderate summarization. |
| `summary:high`  | Aggressive summarization, minimal context. |

**Resolution chain:** incoming edge fidelity -> node fidelity -> graph default fidelity. Thread ID is only resolved in `full` mode.

### 7.5 Artifact Store

Per-run artifact storage with size-based tiering:

- **Small artifacts** (< 100KB): Stored in ETS only (`:memory` storage type).
- **Large artifacts** (>= 100KB): Written to disk at `logs_root/artifacts/node_id/name`, ETS stores metadata (`:file` storage type with `file_path`).

**API:** `store/4`, `retrieve/3`, `list/2`, `clear/1`.

Each pipeline run gets its own ArtifactStore process for isolation.

### 7.6 Run Directory

Each pipeline execution creates a log directory structure:

```
{logs_root}/
  manifest.json        -- graph metadata
  {node_id}/
    prompt.md          -- input prompt (if LLM node)
    response.md        -- LLM response
    status.json        -- outcome metadata
  artifacts/
    {node_id}/
      {name}           -- large artifacts
  checkpoint.json      -- latest checkpoint
```

---

## 8. Human-in-the-Loop

### 8.1 Interviewer Behaviour

```elixir
@callback ask(Question.t(), keyword()) :: Answer.t()
```

Questions include a prompt, available options, and metadata. Answers include a value and optional selected option.

### 8.2 Implementations

| Implementation           | Behavior |
|-------------------------|----------|
| `AutoApproveInterviewer` | Always selects first option, or `:skipped` if none. |
| `ConsoleInterviewer`     | Prompts via IO, parses response against options. |
| `CallbackInterviewer`    | Delegates to user-provided function (1 or 2 arity). |
| `QueueInterviewer`       | Pops from pre-configured answer queue. Supports per-stage queues. |
| `RecordingInterviewer`   | Wraps another interviewer, records all Q&A pairs via callback. |

### 8.3 Integration

Wait and gate nodes delegate to the configured interviewer via the `:interviewer` engine option. The `QueueInterviewer` supports both global answer queues (`:answers`) and per-stage queues (`:answers_by_stage`).

---

## 9. Intermediate Representation

### 9.1 IR Compiler (Arbor Extension)

The IR compiler transforms a `Graph` into a `TypedGraph` with static analysis:

```
Graph.t() -> Compiler.compile/1 -> {:ok, TypedGraph.t()}
```

**Analysis passes:**

1. **Handler resolution.** Resolve each node's type to a handler module.
2. **Attribute validation.** Validate node attributes against the handler's expected schema.
3. **Capability extraction.** Determine what capabilities each node requires.
4. **Data classification.** Classify each node's data sensitivity level.
5. **Taint reachability.** Compute which tainted inputs can reach which nodes.
6. **Edge condition parsing.** Pre-parse condition expressions for validation.
7. **Resource bounds.** Extract timeout, budget, and concurrency limits.

### 9.2 TypedNode

The IR produces `TypedNode` structs enriching each node with analysis results:

| Field                  | Type | Description |
|-----------------------|------|-------------|
| `handler_type`        | String | Resolved canonical type. |
| `handler_module`      | module | Resolved handler module. |
| `capabilities_required` | [String] | Required capability URIs. |
| `data_classification` | atom | `:public`, `:internal`, `:sensitive`, or `:secret`. |
| `idempotency`         | atom | Handler's declared idempotency class. |
| `resource_bounds`     | map | Timeout, budget, concurrency constraints. |
| `schema_errors`       | [String] | Validation errors found during compilation. |

### 9.3 Data Classification

Four levels, determined by node type and attributes:

| Level       | Description |
|------------|-------------|
| `:public`   | No sensitivity. Default for transform, branch. |
| `:internal` | Internal data. Default for compute, exec. |
| `:sensitive`| PII or credentials. Nodes with `sensitive="true"`. |
| `:secret`   | Cryptographic material. Nodes handling keys or secrets. |

---

## 10. Validation and Linting

### 10.1 LintRule Behaviour (Arbor Extension)

Arbor replaces monolithic validation with modular lint rules:

```elixir
@callback name() :: String.t()
@callback validate(Graph.t()) :: [Diagnostic.t()]
```

Each rule returns a list of `Diagnostic` structs with severity (`:error`, `:warning`, `:info`), message, and optional node/edge reference.

### 10.2 Lint Rules

| Rule                  | Severity | Description |
|----------------------|----------|-------------|
| `start_node`         | error    | Exactly one start node required. |
| `terminal_node`      | error    | At least one exit/terminal node required. |
| `start_no_incoming`  | error    | Start node cannot have incoming edges. |
| `exit_no_outgoing`   | error    | Exit nodes cannot have outgoing edges. |
| `edge_target_exists` | error    | All edge targets must reference existing nodes. |
| `reachability`       | error    | All nodes must be reachable from start. |
| `codergen_prompt`    | warning  | LLM nodes should have non-empty prompt. |
| `condition_syntax`   | error    | Branch conditions must be valid expressions. |
| `retry_target_exists`| error    | Retry targets must reference existing nodes. |
| `goal_gate_retry`    | warning  | Goal gates should have valid retry target. |

### 10.3 Validation Options

```elixir
Orchestrator.run(source, validate: true)     # run lint rules before execution
Orchestrator.validate(source)                 # validate without executing
```

---

## 11. Model Stylesheet

### 11.1 Syntax

The model stylesheet uses CSS-like selectors to assign LLM properties to nodes:

```
* { llm_model: "claude-sonnet-4-5-20250929" }
box { llm_provider: "anthropic" }
.review { reasoning_effort: "high" }
#final_review { llm_model: "claude-opus-4-6" }
```

### 11.2 Selectors and Specificity

| Selector | Syntax     | Specificity | Matches |
|----------|-----------|-------------|---------|
| Universal | `*`      | 0           | All nodes |
| Shape    | `box`     | 1           | Nodes with matching shape |
| Class    | `.name`   | 2           | Nodes with class containing name |
| ID       | `#name`   | 3           | Node with matching ID |

Higher specificity wins. Declaration order breaks ties.

### 11.3 Supported Properties

| Property          | Description |
|------------------|-------------|
| `llm_model`      | LLM model identifier. |
| `llm_provider`   | LLM provider name. |
| `reasoning_effort` | Reasoning effort level. |

Properties from the stylesheet only apply when the node does not already have the attribute set. Node-level attributes always take precedence.

---

## 12. Transforms and Extensibility

### 12.1 Transform Pipeline

Before execution, the graph passes through a transform pipeline:

```
parse -> [VariableExpansion, ModelStylesheet, ...custom transforms...] -> execute
```

Transforms are functions `Graph.t() -> Graph.t()` applied in order.

### 12.2 Variable Expansion

Expands `$variable` references in node `prompt` and `label` attributes:

| Variable  | Source |
|-----------|--------|
| `$goal`   | `graph.attrs["goal"]` |
| `$label`  | `graph.attrs["label"]` |
| `$id`     | `graph.id` |
| `$custom` | `graph.attrs["custom"]` |

Pattern: `$[a-zA-Z_][a-zA-Z0-9_]*`. Unresolved variables are left as-is.

### 12.3 DOT Parse Cache (Arbor Extension)

Repeated parsing of identical DOT sources is cached via ETS:

- **Cache key:** SHA-256 of DOT source string (hex-encoded).
- **Cache value:** Parsed `Graph.t()` struct.
- **Max entries:** Configurable (default 100). LRU eviction on overflow.
- **Invalidation:** `DotCache.invalidate/1` by hash, `DotCache.clear/0` for all.
- **Bypass:** `cache: false` option on `run/2`.

GenServer manages writes and eviction; reads go directly to ETS for concurrency.

### 12.4 DOT Serializer (Arbor Extension)

Round-trip serialization from `Graph.t()` back to canonical DOT text:

- Preserves all nodes, edges, subgraphs, and attributes.
- Sorts nodes by ID and attributes by key for deterministic output.
- Strips internal attributes (`content_hash`, `auto_status`) by default.
- Handles string escaping and simple identifier detection.

### 12.5 Custom Handlers

As specified in Attractor. `Registry.register/2` and `Registry.unregister/1` add/remove handlers at runtime via `:persistent_term`.

### 12.6 Tool Hooks

Pre/post hooks for handler execution at graph and node level:

```dot
graph [pre_hook="./scripts/setup.sh", post_hook="./scripts/cleanup.sh"]
validate [pre_hook="echo 'validating...'"]
```

Hooks execute via shell or callback function. Graph-level hooks run once per pipeline; node-level hooks run per node execution.

---

## 13. Condition Expression Language

### 13.1 Syntax

Edge conditions are string expressions evaluated at runtime:

```dot
a -> b [condition="outcome = success"]
a -> c [condition="outcome = fail && context.retry_count != 3"]
```

### 13.2 Operators

| Operator | Meaning |
|----------|---------|
| `=`      | Equality |
| `!=`     | Inequality |
| `&&`     | Logical AND (conjunction) |

### 13.3 Value Resolution

| Reference             | Resolves To |
|----------------------|-------------|
| `outcome`            | Outcome status as string (`"success"`, `"fail"`, etc.) |
| `preferred_label`    | Outcome's preferred label |
| `context.key`        | Value from context at `key` |

Unresolved references evaluate to `nil`.

---

## 14. Self-Modifying Pipelines (Arbor Extension)

### 14.1 Adapt Handler

The adapt handler allows pipelines to modify their own structure at runtime. Mutations are expressed as a JSON DSL.

### 14.2 Mutation Operations

| Operation      | Description |
|---------------|-------------|
| `modify_attrs` | Change attributes on existing nodes. |
| `add_edge`     | Add new edge between nodes. |
| `remove_edge`  | Remove existing edge. |
| `add_node`     | Add new node (veteran+ trust tier). |
| `remove_node`  | Remove existing node (autonomous only, non-leaf restriction for veteran). |

### 14.3 Trust Tier Constraints

Mutations are gated by the agent's trust tier when the adapt node has a `trust_tier` attribute:

| Tier           | Allowed Operations |
|---------------|-------------------|
| `untrusted`    | None (always fails) |
| `probationary` | `modify_attrs` only |
| `trusted`      | `modify_attrs`, `add_edge`, `remove_edge` |
| `veteran`      | All except `remove_node` on non-leaf nodes |
| `autonomous`   | Unrestricted |

### 14.4 Node Attributes

| Attribute        | Type    | Description |
|-----------------|---------|-------------|
| `mutations`      | String  | Static JSON mutation operations. |
| `mutations_key`  | String  | Context key for dynamic mutations (takes precedence over `mutations`). |
| `max_mutations`  | Integer | Maximum operations per execution (default 10). |
| `dry_run`        | Boolean | Validate without applying (default false). |
| `trust_tier`     | String  | Minimum tier required for mutations. |

### 14.5 Engine Integration

When the adapt handler returns, it stores the modified graph in `context["__adapted_graph__"]`. The engine detects this special key and replaces the graph for all subsequent execution. Version metadata is stored in `context["adapt.{node_id}.version"]` and `context["adapt.{node_id}.applied_ops"]`.

---

## 15. Event System

### 15.1 Event Types

The engine emits events throughout execution via the `EventEmitter` module:

**Pipeline lifecycle:**

| Event                  | Data |
|-----------------------|------|
| `:pipeline_started`    | `graph_id`, `logs_root`, `node_count` |
| `:pipeline_completed`  | `completed_nodes`, `duration_ms` |
| `:pipeline_failed`     | `reason`, `duration_ms` |
| `:pipeline_resumed`    | `checkpoint`, `current_node` |

**Stage lifecycle:**

| Event                | Data |
|---------------------|------|
| `:stage_started`     | `node_id` |
| `:stage_completed`   | `node_id`, `status`, `duration_ms` |
| `:stage_failed`      | `node_id`, `error`, `will_retry`, `duration_ms` |
| `:stage_retrying`    | `node_id`, `attempt`, `delay_ms` |
| `:stage_skipped`     | `node_id`, `reason` |

**Fidelity and checkpoints:**

| Event                 | Data |
|----------------------|------|
| `:fidelity_resolved`  | `node_id`, `mode`, `thread_id` |
| `:checkpoint_saved`   | `node_id`, `path` |

**Fan-out / fan-in:**

| Event                       | Data |
|----------------------------|------|
| `:fan_out_detected`         | `node_id`, `branch_count`, `targets` |
| `:fan_out_branch_resuming`  | `node_id`, `pending_count` |
| `:fan_in_deferred`          | `node_id`, `waiting_for` |

**Control flow:**

| Event                   | Data |
|------------------------|------|
| `:goal_gate_retrying`   | `target` |
| `:loop_restart`         | `edge` (`from`, `to`), `reason` |

### 15.2 Signal Integration (Arbor Extension)

When the `SignalEmit` middleware is active, events are also emitted as Arbor signals on the signal bus. This enables LiveView dashboards, external subscribers, and cross-system observability to react to pipeline execution in real time.

---

## Appendix A. Attribute Reference

### A.1 Graph Attributes

| Attribute                 | Type     | Default  | Section |
|--------------------------|----------|----------|---------|
| `goal`                   | String   | `""`     | 2.6     |
| `label`                  | String   | `""`     | 2.6     |
| `model_stylesheet`       | String   | `""`     | 11      |
| `default_max_retry`      | Integer  | `50`     | 3.4     |
| `retry_target`           | String   | `""`     | 3.5     |
| `fallback_retry_target`  | String   | `""`     | 3.5     |
| `default_fidelity`       | String   | `""`     | 7.4     |
| `mandatory_middleware`   | Boolean  | `true`   | 5.4     |
| `pre_hook`               | String   | `""`     | 12.6    |
| `post_hook`              | String   | `""`     | 12.6    |

### A.2 Node Attributes

| Attribute                 | Type     | Default     | Section |
|--------------------------|----------|-------------|---------|
| `label`                  | String   | node ID     | 2.7     |
| `shape`                  | String   | `"box"`     | 2.7     |
| `type`                   | String   | `""`        | 4.4     |
| `prompt`                 | String   | `""`        | 6.1     |
| `system_prompt`          | String   | `""`        | 6.1     |
| `max_retries`            | Integer  | `0`         | 3.4     |
| `goal_gate`              | Boolean  | `false`     | 3.5     |
| `retry_target`           | String   | `""`        | 3.5     |
| `fallback_retry_target`  | String   | `""`        | 3.5     |
| `fidelity`               | String   | inherited   | 7.4     |
| `thread_id`              | String   | derived     | 7.4     |
| `class`                  | String   | `""`        | 11      |
| `timeout`                | Duration | unset       | 2.7     |
| `llm_model`              | String   | inherited   | 11      |
| `llm_provider`           | String   | inherited   | 11      |
| `temperature`            | Float    | unset       | 6.1     |
| `auto_status`            | Boolean  | `false`     | 3.8     |
| `allow_partial`          | Boolean  | `false`     | 3.4     |
| `fan_out`                | Boolean  | `false`     | 3.9     |
| `simulate`               | String   | `""`        | 6.1     |
| `trust_tier`             | String   | `""`        | 14.3    |
| `skip_middleware`        | String   | `""`        | 5.3     |
| `content_hash`           | String   | computed    | 3.10    |
| `pre_hook`               | String   | `""`        | 12.6    |
| `post_hook`              | String   | `""`        | 12.6    |
| `items_key`              | String   | `""`        | 6.3     |
| `item_type`              | String   | `""`        | 6.10    |
| `max_concurrency`        | Integer  | `4`         | 6.3     |
| `mutations`              | String   | `""`        | 14.4    |
| `mutations_key`          | String   | `""`        | 14.4    |
| `max_mutations`          | Integer  | `10`        | 14.4    |
| `dry_run`                | Boolean  | `false`     | 14.4    |
| `target`                 | String   | `""`        | 6.9     |
| `sandbox`                | String   | `""`        | 6.8     |

### A.3 Edge Attributes

| Attribute     | Type     | Default | Section |
|--------------|----------|---------|---------|
| `label`      | String   | `""`    | 2.8     |
| `condition`  | String   | `""`    | 13      |
| `weight`     | Float    | `1.0`   | 3.3     |
| `fidelity`   | String   | `""`    | 7.4     |
| `thread_id`  | String   | `""`    | 7.4     |
| `loop_restart` | Boolean | `false` | 3.7    |

---

## Appendix B. Stdlib Alias Map

The alias system maps 55 semantic type names (plus 15 canonical identity mappings = 70 total entries) to 15 canonical handler types. Aliases listed in the resolve map inject attributes to preserve semantic intent. Aliases not in the resolve map use type mapping only.

### B.1 Control Flow Aliases

| Alias             | Canonical  | Injected Attributes |
|------------------|------------|-------------------|
| `conditional`    | `branch`   | (none) |
| `parallel.fan_in`| `fan_in`   | (none) |

### B.2 Compute Aliases

| Alias             | Canonical | Injected Attributes |
|------------------|-----------|-------------------|
| `codergen`       | `compute` | `%{"purpose" => "llm"}` |
| `routing.select` | `compute` | `%{"purpose" => "routing"}` |
| `prompt.ab_test` | `compute` | `%{"purpose" => "ab_test"}` |
| `drift_detect`   | `compute` | `%{"purpose" => "drift_detect"}` |
| `retry.escalate` | `compute` | `%{"purpose" => "retry_escalate"}` |
| `eval.run`       | `compute` | `%{"purpose" => "eval_run"}` |
| `eval.aggregate` | `compute` | `%{"purpose" => "eval_aggregate"}` |

### B.3 Exec Aliases

| Alias   | Canonical | Injected Attributes |
|--------|-----------|-------------------|
| `tool`  | `exec`    | `%{"target" => "tool"}` |
| `shell` | `exec`    | `%{"target" => "shell"}` |

### B.4 Read Aliases

| Alias                | Canonical | Injected Attributes |
|---------------------|-----------|-------------------|
| `memory.recall`      | `read`    | `%{"source" => "memory", "op" => "recall"}` |
| `memory.working_load`| `read`    | `%{"source" => "memory", "op" => "working_load"}` |
| `memory.stats`       | `read`    | `%{"source" => "memory", "op" => "stats"}` |
| `memory.recall_store`| `read`    | `%{"source" => "memory", "op" => "recall_store"}` |
| `eval.dataset`       | `read`    | `%{"source" => "eval_dataset"}` |

### B.5 Write Aliases

| Alias                | Canonical | Injected Attributes |
|---------------------|-----------|-------------------|
| `file.write`        | `write`   | `%{"target" => "file"}` |
| `memory.consolidate`| `write`   | `%{"target" => "memory", "op" => "consolidate"}` |
| `memory.index`      | `write`   | `%{"target" => "memory", "op" => "index"}` |
| `memory.working_save`| `write`  | `%{"target" => "memory", "op" => "working_save"}` |
| `memory.store_file` | `write`   | `%{"target" => "memory", "op" => "store_file"}` |
| `accumulator`       | `write`   | `%{"target" => "accumulator", "mode" => "append"}` |
| `eval.persist`      | `write`   | `%{"target" => "eval", "op" => "persist"}` |
| `eval.report`       | `write`   | `%{"target" => "eval", "op" => "report"}` |

### B.6 Compose Aliases

| Alias              | Canonical  | Injected Attributes |
|-------------------|------------|-------------------|
| `graph.invoke`    | `compose`  | `%{"mode" => "invoke"}` |
| `graph.compose`   | `compose`  | `%{"mode" => "compose"}` |
| `pipeline.run`    | `compose`  | `%{"mode" => "pipeline"}` |
| `feedback.loop`   | `compose`  | `%{"mode" => "feedback"}` |
| `stack.manager_loop` | `compose` | `%{"mode" => "manager_loop"}` |

### B.7 Session Aliases (17 types)

All session aliases resolve to `compose` with `%{"mode" => "session"}`:

| Alias |
|-------|
| `session.classify` |
| `session.memory_recall` |
| `session.mode_select` |
| `session.llm_call` |
| `session.tool_dispatch` |
| `session.format` |
| `session.memory_update` |
| `session.checkpoint` |
| `session.background_checks` |
| `session.process_results` |
| `session.route_actions` |
| `session.update_goals` |
| `session.store_decompositions` |
| `session.process_proposal_decisions` |
| `session.consolidate` |
| `session.update_working_memory` |
| `session.store_identity` |

### B.8 Consensus Aliases (5 types)

All consensus aliases resolve to `compose` with `%{"mode" => "consensus"}`:

| Alias |
|-------|
| `consensus.propose` |
| `consensus.ask` |
| `consensus.await` |
| `consensus.check` |
| `consensus.decide` |

### B.9 Adapt Alias

| Alias          | Canonical | Injected Attributes |
|---------------|-----------|-------------------|
| `graph.adapt` | `adapt`   | (none — alias map only, not in resolve map) |

### B.10 Wait Alias

| Alias        | Canonical | Injected Attributes |
|-------------|-----------|-------------------|
| `wait.human` | `wait`   | `%{"source" => "human"}` |

### B.11 Gate Aliases

| Alias              | Canonical | Injected Attributes |
|-------------------|-----------|-------------------|
| `output.validate`  | `gate`   | `%{"predicate" => "output_valid"}` |
| `pipeline.validate` | `gate`  | `%{"predicate" => "pipeline_valid"}` |

---

## Appendix C. Handler Conformance Matrix

All 15 core handlers and key aliases pass the conformance test suite (34/34 tests). Each handler is tested for:

| Test                    | Description |
|------------------------|-------------|
| `execute/4 returns Outcome` | Handler returns valid `%Outcome{}` struct. |
| `idempotency/0`         | Returns valid idempotency class. |
| `success path`          | Produces `:success` on valid input. |
| `failure path`          | Produces `:fail` on invalid input. |
| `context updates`       | Returns correct `context_updates` map. |

**Current test counts:**

- Orchestrator total: ~1830 tests
- Handler conformance: 34/34
- Middleware tests: 30
- IR compiler tests: included in total
- Parser tests: included in total
- Lint rule tests: included in total
