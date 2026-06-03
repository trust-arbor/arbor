# DOT Pipeline Authoring

Write or modify Arbor's `.dot` orchestration pipelines. For a syntax-only reference, see [`docs/arbor/DOT_PIPELINE_GUIDE.md`](../../docs/arbor/DOT_PIPELINE_GUIDE.md). For invoking and running already-written pipelines from code, see [`dot-pipeline-execution.md`](./dot-pipeline-execution.md).

## When to write a new pipeline

Reach for a new `.dot` when you need to compose multiple steps with explicit gating, parallelism, or routing — and the policy should be visible to humans reviewing the work, not buried in code. Reach for plain Elixir when the work is a single function call, or when control flow depends on runtime values that don't compose into a graph cleanly (e.g. tight inner loops).

Before writing a new pipeline, search `apps/arbor_orchestrator/specs/pipelines/stdlib/` — there's already `retry-escalate.dot` (LLM-model escalation), `feedback-loop.dot` (generate / critique / revise), `propose-approve.dot`, `synthesize.dot`, and several others. If one fits with `pass_context` parameterization, invoke it rather than copy.

## Canonical node types (15)

The Arbor engine resolves all node `type=` strings to **15 canonical handlers**. Other type strings are aliases that resolve to one of these:

| Domain | Types |
|---|---|
| Control flow | `start`, `exit`, `branch`, `parallel`, `fan_in` |
| Computation | `compute`, `transform`, `exec` |
| State | `read`, `write` |
| Composition | `compose`, `map`, `adapt` |
| Coordination | `wait` |
| Governance | `gate` |

You'll most often reach for `exec` (call an Action), `compute` (LLM call), `transform` (rewrite context), `gate` (pass/fail check), `compose` (invoke a sub-pipeline). `start` and `exit` are inferred from `shape=Mdiamond` / `shape=Msquare`.

## Calling an Action from a DOT

This is the bread-and-butter pattern — the engine reaches into the Action registry, executes the action, flows its return map into context:

```dot
run_test [
  type="exec",
  target="action",
  action="mix_test",
  agent_id="agent_test_mix",
  param.path="/abs/path/to/project",
  param.tags="fast"
]
```

Rules:

- `action="<name>"` must match a registered Action's `name:` field. Discover names via `mix arbor.actions list` or by reading `Arbor.Actions.list_actions/0`. Both dot-form (`mix.test`) and Jido form (`mix_test`) resolve.
- `param.<key>="<value>"` becomes `action_args[<key>]`. Attribute names must NOT be quoted — `"param.path"="..."` breaks DOT parsing; use bare `param.path="..."`.
- `agent_id="agent_<id>"` is the principal that owns the call. The capability check fires on this. Principal IDs MUST start with `agent_` — bare `"system"` is rejected by `CapabilityStore`.
- The action's return map flows into context as `exec.<node_id>.<key>`. E.g. `Mix.Test` returns `%{passed: true, exit_code: 0, stdout: "..."}` so the next nodes can read `context.exec.run_test.passed`, `context.exec.run_test.exit_code`, etc.

## Context flow

The engine passes a key-value context through every node. Nodes read with `context.<dotted.key>` and write via their return value.

| Node type | Where its output lands |
|---|---|
| `exec target=action` | `exec.<node_id>.<each-return-map-key>` |
| `compute` (LLM) | `last_response` + node-specific keys (`exec.<node_id>.result`) |
| `transform` | freeform — the prompt describes what context keys to write |
| `gate` | `gate.<node_id>.passed` (boolean) |
| `compose mode=invoke` | `subgraph.<node_id>.<each-child-context-key>` |

Pass values into action params via `param.foo="bar"` (static) or via `context_keys="key1,key2"` (pull from current context). There is NO `$var` interpolation in attributes — values must be literal at compile time.

## Routing with `branch` / `gate` / conditional edges

`branch` is the routing primitive: "the engine picks the outgoing edge whose condition evaluates true." It does NOT execute anything itself — the work happens in surrounding nodes.

`gate` is the pass/fail primitive: it evaluates a predicate and writes a `gate.<node_id>.passed` boolean; the engine then routes via edge conditions.

Edge condition syntax (parsed by `Arbor.Orchestrator.Engine.Condition`):

```dot
check -> mark_pass [condition="context.exec.run_test.passed=true"]
check -> mark_fail [condition="context.exec.run_test.passed!=true"]
```

Rules:

- Operators: `=`, `!=`, `>=`, `<=`, `>`, `<`, `~` (contains). Note `=`, not `==`.
- Keys: `context.<dotted.path>` or a fixed `outcome`/`status` shortcut. **Regex `^[A-Za-z_][A-Za-z0-9_.]*$`** — no `?` in keys. (So name your Action return fields `passed`, not `passed?`.)
- Combine clauses with ` && `.
- Always cover BOTH outcomes on a branching diamond. An unreachable node with no matching condition silently freezes the pipeline.

## Sub-pipeline composition

Two patterns:

**Invoke a named or file-referenced child:**

```dot
merge [
  type="graph.invoke",
  graph_file="apps/arbor_orchestrator/specs/pipelines/stdlib/synthesize.dot",
  pass_context="synthesize.input,synthesize.instructions,session.llm_provider"
]
```

- `type` is `graph.invoke` (the alias) — NOT bare `invoke`. The alias resolves to `compose mode=invoke`.
- The child starts with an EMPTY context unless `pass_context` (CSV of keys) or `pass_all_context="true"` lifts values in. No implicit inheritance.
- Child results land at `subgraph.<invoke_node_id>.<key>`. Override via `result_prefix=` or remap via `result_mapping="child_key:parent_key,..."`.

**Compose inline (DOT-as-data):**

```dot
inline [
  type="graph.compose",
  source_key="generated_dot",
  pass_context="x,y"
]
```

The child DOT string is read from `context.generated_dot`. Use this when an upstream node produces a DOT dynamically.

## Anti-patterns

| Don't | Do |
|---|---|
| `"param.foo"="bar"` (quoted attr name) | `param.foo="bar"` |
| Multiple `shape=Msquare` exits | One `done [shape=Msquare]`; converge branches to it |
| `?` in context keys (e.g. `passed?`) | Plain names (`passed`) |
| `type="invoke"` | `type="graph.invoke"` |
| `$repo_path` in attrs | Set the literal value, or read via `context_keys="..."` |
| Reach for raw `Shell.Execute` for a recurring tool (`git`, `mix`) | Wrap as a Jido Action (`Arbor.Actions.Git.*`, `Arbor.Actions.Mix.*`) — capability URIs become precise, taint roles get declared once |
| Write a whole new handler module | First check whether a stdlib DOT + the 15 canonical types can express it. Handlers are a heavy primitive; most "new node types" are subgraph compositions |

## Validating before running

```bash
mix arbor.pipeline.validate path/to/pipeline.dot
```

Catches: invalid edge condition syntax, multiple terminal nodes, unknown handler types in strict mode, missing prompts on compute/codergen nodes.

## See also

- [`docs/arbor/DOT_PIPELINE_GUIDE.md`](../../docs/arbor/DOT_PIPELINE_GUIDE.md) — full attribute reference
- [`apps/arbor_orchestrator/lib/arbor/orchestrator/stdlib/aliases.ex`](../../apps/arbor_orchestrator/lib/arbor/orchestrator/stdlib/aliases.ex) — the alias map (all known type strings → 15 canonical)
- [`apps/arbor_orchestrator/specs/pipelines/stdlib/`](../../apps/arbor_orchestrator/specs/pipelines/stdlib/) — reference subpipelines (read before writing similar)
- [`dot-pipeline-execution.md`](./dot-pipeline-execution.md) — running pipelines from code
