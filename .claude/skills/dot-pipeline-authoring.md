# DOT Pipeline Authoring

Write or modify Arbor's `.dot` orchestration pipelines. For a syntax-only reference, see [`docs/arbor/DOT_PIPELINE_GUIDE.md`](../../docs/arbor/DOT_PIPELINE_GUIDE.md). For invoking and running already-written pipelines from code, see [`dot-pipeline-execution.md`](./dot-pipeline-execution.md).

For the coding-change workflow, read [`docs/arbor/CODING_TASK_DISPATCH.md`](../../docs/arbor/CODING_TASK_DISPATCH.md).
It owns Grok 4.5 runtime isolation, attested native-tool profiles, immutable
MCP/workspace binding, provider-versus-workspace continuity, and
owner-observed approval/cancellation behavior. Keep those operational rules
there; this skill covers DOT authoring and generic execution semantics.

## When to write a new pipeline

Reach for a new `.dot` when you need to compose multiple steps with explicit gating, parallelism, or routing — and the policy should be visible to humans reviewing the work, not buried in code. Reach for plain Elixir when the work is a single function call, or when control flow depends on runtime values that don't compose into a graph cleanly (e.g. tight inner loops).

Before writing a new pipeline, search `apps/arbor_orchestrator/specs/pipelines/stdlib/` — there's already `retry-escalate.dot` (LLM-model escalation), `feedback-loop.dot` (generate / critique / revise), `propose-approve.dot`, `synthesize.dot`, and several others. If one fits with `pass_context` parameterization, invoke it rather than copy.

## Authoring invariants

- Treat the graph, compiled execution manifest, and `RunAuthorization` as
  immutable after preflight. Let the executor bind the caller's principal;
  do not use node attributes or context to impersonate another principal.
- Keep context JSON-clean because the Engine checkpoints it after nodes. Pass
  identifiers and bounded data, then reconstruct typed runtime values at the
  action or handler boundary.
- Use graph validation for structure and declared placement, capability
  middleware for runtime authority, and Jido actions for capability-gated side
  effects. Do not move business policy into a generic handler.
- For reviewable changes, make commit/tree identity and owner-observed
  workspace state explicit in the action contracts. Worker prose is not a
  substitute for inspection or a review-bound tree snapshot.

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

## Common traps (the ones that bit me when wiring real pipelines)

### LLM compute nodes REQUIRE an explicit `simulate=` (no default)

Every node that calls a model — `compute purpose=llm` (the default), a bare-prompt `codergen` node, or `type="llm"` — **must** declare `simulate`. There is no default: omit it and `mix arbor.pipeline.validate` flags it as an error (`compute/llm node must declare an explicit simulate= attribute`), and at runtime the node **fails loud** instead of silently mocking. (This used to default to silent simulation — the node returned a deterministic mock string and the pipeline "succeeded" with plausible-but-totally-fake output; it had 9 of 13 stdlib pipelines silently mocking. Declaring intent is now mandatory so you — or an agent composing a DOT — can't accidentally ship a fake-output pipeline.)

- `simulate="false"` → real LLM call (fails loudly if no provider configured)
- `simulate="true"` → deterministic mock string (tests / dry runs)

```dot
generate [type="compute", purpose="llm", simulate="false", llm_provider="...", llm_model="...", prompt_context_key="..."]
```

Non-LLM compute purposes (e.g. `purpose="routing"`) do **not** require `simulate`.

### Don't hardcode `agent_id="…"` on a single exec node

It looks like a harmless override. But the signer you thread through `Orchestrator.run/2` signs as agent X, and the auth path on this node checks agent Y — capability check fails with `:unauthorized`. Let `agent_id` fall through to `session.agent_id` from context unless you actually mean "this node runs as a different identity than the rest of the pipeline."

### `mix arbor.pipeline.validate` passing ≠ runtime success

Validation is a *syntax* checker — terminal-node, edge-condition syntax, prompt presence on compute nodes, and `simulate=` presence on LLM nodes. It does NOT catch: missing capabilities, unstarted services (NonceCache, IdentityRegistry, ExecutionRegistry), unregistered identities, missing LLM providers, missing action registrations. Treat validate-pass as "the graph parses," nothing more.

### `arbor://fs/<op>/<root>` — the URI encodes the path scope

Capability URIs aren't just opaque tokens passed to a matcher. For `arbor://fs/*` URIs, **FileGuard parses the URI to extract the allowed root path**. So:

- `arbor://fs/write` alone is malformed for FileGuard's purposes — no root component → no path validation can run.
- `arbor://fs/write/workspace/project` grants write under `/workspace/project`.
- `arbor://fs/**` is the explicit wildcard literal — recognized as "all paths."

Generalize the lesson: capability URI granularity is part of the design surface, not just a security knob. Sketch the URIs alongside the DOT, not after.

### `transform=identity` is the canonical "rename a context key"

When the next node's action schema wants `content` but the upstream produced `last_response`, you don't need to modify either — drop in:

```dot
prepare_content [type="transform", transform="identity", source_key="last_response", output_key="content"]
```

Pure rename, no LLM call, no side effects. The unstructured `transform` with a freeform `prompt=` is for LLM-driven transformation — different tool.

### No variable interpolation in attrs

`$language` in a node attribute is literal — it does not get substituted. To parameterize a node by runtime context:

- Set the value in `initial_values` when invoking `Orchestrator.run/2`.
- Reference it via `context_keys="key1,key2"` on the consuming node (which pulls those context values into the action's args).
- For string-template substitution into a generated prompt, use `transform="template"` with a `{value}` placeholder.

If you find yourself wanting interpolation, you almost always want a transform stage between the source and the consumer.

### Bypasses belong in Elixir, not in CLI flags

`Arbor.Orchestrator.run/2` accepts `authorization: false` to skip the mandatory capability check — useful in tests and operator scripts. **Do not surface this opt as a flag on a public mix task.** A `--no-auth` CLI flag converts mix into a privilege-escalation primitive: any agent capable of invoking shell now can also bypass capability checks on any pipeline. The Elixir-API opt is fine because the calling code is itself the trust boundary; the CLI flag isn't because the shell isn't.

Same principle: keep auth-relaxation primitives behind API surfaces that already require code-edit access.

### `authorization: false` only bypasses the engine — not action-layer caps

Important nuance, surfaced by the HITL example pipeline. `authorization: false` on `Orchestrator.run/2` turns off the **engine-level** per-node capability middleware (the `CapabilityCheck` that runs before each handler — `arbor://orchestrator/execute/<node_type>`). It does NOT turn off the **action-layer** capability check that `Arbor.Actions.authorize_and_execute/4` does for every `exec target=action` invocation.

So a pipeline running with `authorization: false` will still hit `{:error, :unauthorized}` from `file_write`, `mix_test`, `git_commit`, or any other Action whose canonical URI the calling principal hasn't been granted. The two checks are independent layers.

For tests that need to skip BOTH:
- Use `authorization: false` to silence the engine layer.
- Grant the action URIs (e.g. `arbor://fs/**`) to your test principal via `CapabilityStore.put/1` to satisfy the action layer.
- The HITL example test (`deployment_decision_gate_example_test.exs`) shows the canonical pattern.

## Validating before running

```bash
mix arbor.pipeline.validate path/to/pipeline.dot
```

Catches: invalid edge condition syntax, multiple terminal nodes, unknown handler types in strict mode, missing prompts on compute/codergen nodes. Does NOT catch the runtime issues listed above — see "Common traps."

## See also

- [`docs/arbor/DOT_PIPELINE_GUIDE.md`](../../docs/arbor/DOT_PIPELINE_GUIDE.md) — full attribute reference
- [`apps/arbor_orchestrator/lib/arbor/orchestrator/stdlib/aliases.ex`](../../apps/arbor_orchestrator/lib/arbor/orchestrator/stdlib/aliases.ex) — the alias map (all known type strings → 15 canonical)
- [`apps/arbor_orchestrator/specs/pipelines/stdlib/`](../../apps/arbor_orchestrator/specs/pipelines/stdlib/) — reference subpipelines (read before writing similar)
- [`dot-pipeline-execution.md`](./dot-pipeline-execution.md) — running pipelines from code
