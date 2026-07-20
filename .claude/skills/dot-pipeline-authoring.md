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

## Applied Learning: DOT Pipelines

Read this when authoring or changing DOT graphs, Engine execution, action bindings, context flow, or handler contracts.

<!-- applied-learning: a-jido-action-schema-is-not-automatic-runtime-validation-for-direct-arbor-execution -->
<a id="applied-learning-a-jido-action-schema-is-not-automatic-runtime-validation-for-direct-arbor-execution"></a>
**A Jido action schema is not automatic runtime validation for direct Arbor execution.**
`Arbor.Actions.execute_action/3` invokes `action_module.run/2`; the Zoi schema shapes
the model-facing tool definition but does not enforce its length, encoding, or
duplicate-key constraints on that public path. Security- and protocol-sensitive
actions must repeat their closed bounds behaviorally in `run/2`, reject atom/string
aliases for the same logical key, and test the direct facade path (found 2026-07-17
hardening the binding council terminal report action).

<!-- applied-learning: dot-context-keys-must-match-the-exact-context-keys-producers-emit -->
<a id="applied-learning-dot-context-keys-must-match-the-exact-context-keys-producers-emit"></a>
**DOT `context_keys` must match the exact context keys producers emit.** The
code-review council DOT used `review.review_cycle` while
`CodeReviewRequest.to_context/1` only emitted `review.cycle` / `review_cycle`,
so ExecHandler silently dropped the param and `DecideReview` failed with
`invalid_review_cycle`. Mirror the production dotted key on both sides
(`review.finding_ledger`-style), accept the dotted form in the action param
lookup, and regress with the exact DOT-produced parameter map (found
2026-07-17 when binding council reducers returned invalid_review_cycle).

<!-- applied-learning: schema-negative-tests-must-target-attributes-the-compiler-does-not-intentionally-normalize -->
<a id="applied-learning-schema-negative-tests-must-target-attributes-the-compiler-does-not-intentionally-normalize"></a>
**Schema-negative tests must target attributes the compiler does not intentionally normalize.** A reviewed-template compiler may restore mandatory parameters before schema validation, so injecting a bad value into one of those parameters proves normalization rather than rejection. Test the restored invariant separately, and use an untouched action parameter to exercise the generic schema failure path (found 2026-07-10 after making default validation warnings mandatory).

<!-- applied-learning: node-action-inventory-checks-do-not-prove-graph-policy -->
<a id="applied-learning-node-action-inventory-checks-do-not-prove-graph-policy"></a>
**Node/action inventory checks do not prove graph policy.** A graph can retain every mandatory node and action name while rewiring conditions to bypass them. Inventory is useful Phase 4 template drift detection; publish/review/validation dominance and edge-order invariants require semantic preflight before custom or agent-authored DOT is executable (confirmed 2026-07-10 in the CodingPlan compiler review).

<!-- applied-learning: static-dot-action-parameters-arrive-as-strings -->
<a id="applied-learning-static-dot-action-parameters-arrive-as-strings"></a>
**Static DOT action parameters arrive as strings.** Attributes such as `param.all="true"` cross the parser/context boundary as string values even when the action schema declares a boolean. Schema-bounded actions that are valid DOT targets must normalize their accepted serialized boolean forms at the action boundary; testing only direct Elixir calls with `true` can leave the live pipeline taking a different branch (found 2026-07-10 when `git.commit` skipped staging after a successful Grok edit).

<!-- applied-learning: hot-loading-an-action-does-not-refresh-a-core-locked-actionregistry -->
<a id="applied-learning-hot-loading-an-action-does-not-refresh-a-core-locked-actionregistry"></a>
**Hot-loading an action does not refresh a core-locked `ActionRegistry`.** The action facade can expose a newly compiled module while the boot-populated registry still lacks it, causing CodingPlan compilation to reject the action as unknown even though runtime execution has a facade fallback. Production action-catalog discovery must reconcile dynamic/plugin registry entries with the current `Arbor.Actions.list_actions/0` core facade; treating any running registry as the sole inventory makes hot reload require a full node restart (found 2026-07-10 while dogfooding the `cross_app` coding profile).

<!-- applied-learning: opaque-authority-must-stay-outside-every-action-visible-context-including-nested-option-maps -->
<a id="applied-learning-opaque-authority-must-stay-outside-every-action-visible-context-including-nested-option-maps"></a>
**Opaque authority must stay outside every action-visible context, including nested option maps.**
Removing a top-level `:signing_authority` key is insufficient if `nested_engine_opts` is
passed through `Arbor.Actions.authorize_and_execute/4`. Keep the bearer token at the
orchestrator boundary, project only a fresh exact-resource `SignedRequest` into the
action, and retain a process-local resign path for post-approval retries.

<!-- applied-learning: jido-map-schemas-do-not-accept-dynamic-string-keyed-json-maps-and-any-is-not-an-honest-tool-schema-fallback -->
<a id="applied-learning-jido-map-schemas-do-not-accept-dynamic-string-keyed-json-maps-and-any-is-not-an-honest-tool-schema-fallback"></a>
**Jido `:map` schemas do not accept dynamic string-keyed JSON maps, and `:any` is not an honest
tool-schema fallback.** Path-keyed values such as `%{"lib/a.ex" => [[1, 2]]}` fail Nimble schema
validation because Jido expects atom map keys, while Jido's JSON-schema converter publishes
Nimble `:any` as `type=string`. Use a terminating Zoi object/array schema with dynamic string-keyed
maps; when strict conversion would close those nested maps, publish the non-strict schema and close
only the fixed root object. Exercise `validate_params/1` with atom top-level keys because string
top-level keys are treated as unknown passthrough fields, and assert both malformed outer types and
the emitted `to_tool/0` schema (found 2026-07-12 with review `delta_ranges` and finding ledgers).

<!-- applied-learning: dot-constant-transforms-emit-strings-even-when-the-expression-looks-numeric-or-boolean -->
<a id="applied-learning-dot-constant-transforms-emit-strings-even-when-the-expression-looks-numeric-or-boolean"></a>
**DOT `constant` transforms emit strings, even when the expression looks numeric or boolean.** If
the context or downstream contract requires a typed JSON value, put it in a JSON object and extract
it with `json_extract`, or normalize it at the action boundary. A fake executor that accepts the
serialized string can hide a production constructor failure, so executable pipeline fixtures must
exercise the real request/contract constructor for typed action inputs (found 2026-07-12 with
`review_cycle`).

<!-- applied-learning: pipeline-traversal-authority-is-not-resource-authority -->
<a id="applied-learning-pipeline-traversal-authority-is-not-resource-authority"></a>
**Pipeline traversal authority is not resource authority.** A grant such as `arbor://orchestrator/execute/**` may authorize pure graph opcodes, but it must never satisfy bare IR requirements such as `file_write` or `shell_exec`: normalizing those names under the traversal subtree turns a lobby pass into host filesystem and process authority. Map side-effecting handlers to their canonical `arbor://fs/...`, `arbor://shell/...`, or action resource and carry concrete path/task scope into Security (found 2026-07-10 during the DOT coding Phase 5 authorship audit).

<!-- applied-learning: execution-identity-belongs-in-immutable-run-authority-never-mutable-graph-context -->
<a id="applied-learning-execution-identity-belongs-in-immutable-run-authority-never-mutable-graph-context"></a>
**Execution identity belongs in immutable run authority, never mutable graph context.** `session.agent_id` is useful context provenance, but if middleware or handlers derive the principal from it, a graph, nested run, or initial-values merge can spoof or lose authority while the signer comes from unrelated opts. Bind execution principal, caller/author provenance, task/session scope, graph hash, and fixed workdir in trusted Engine state; context may mirror those fields but must not drive authorization (found 2026-07-10 tracing direct, nested, parallel, and remote DOT execution).

<!-- applied-learning: mutating-actions-must-declare-their-conservative-static-effect-class -->
<a id="applied-learning-mutating-actions-must-declare-their-conservative-static-effect-class"></a>
**Mutating actions must declare their conservative static `effect_class`.** `Arbor.Actions.Egress` intentionally defaults an undeclared action to `:read`; that made `git.commit` approval records claim `risk_hints.effect_class=read` even though the trust gate still asked. Declare `:local_write` for actions whose maximum mode mutates local state, including mixed read/write actions such as `Git.Branch`, and regress through the public `Egress.effect_class_for/1` projection (found 2026-07-10 during live approval inspection).

<!-- applied-learning: multi-module-hot-reload-is-not-a-transactional-deployment-boundary -->
<a id="applied-learning-multi-module-hot-reload-is-not-a-transactional-deployment-boundary"></a>
**Multi-module hot reload is not a transactional deployment boundary.** A compiler, profile registry, semantic validator, and template can be individually current while one request still crosses a mixed old/new call path at the end of a reload window. After reloading a policy bundle, run one live compile/authorization probe that exercises the whole bundle before dispatching durable work; retry only tasks that failed before acquiring resources (found 2026-07-11 when the first post-reload security-profile dispatch saw new attestation nodes with old topology expectations).

<!-- applied-learning: closed-json-schemas-need-exact-scalar-types-not-only-keys-and-loose-equality -->
<a id="applied-learning-closed-json-schemas-need-exact-scalar-types-not-only-keys-and-loose-equality"></a>
**Closed JSON schemas need exact scalar types, not only keys and loose equality.** Elixir considers `1 == 1.0`, so a summary cross-check using `!=` can accept float aliases for integer counters. Validate bounded integer fields explicitly and use type-strict comparisons (`!==`) when the serialized contract distinguishes numeric representations (found 2026-07-11 reviewing coding benchmark summary validation).

<!-- applied-learning: do-not-put-workflow-specific-result-policy-in-a-generic-engine-handler -->
<a id="applied-learning-do-not-put-workflow-specific-result-policy-in-a-generic-engine-handler"></a>
**Do not put workflow-specific result policy in a generic Engine handler.** Teaching `ExecHandler` that a `git_commit` denial can become branchable success violates the handler-as-opcode invariant and creates an author-controlled denial-bypass surface. Put commit approval/deny/rework semantics in a capability-gated Jido action and let the reviewed graph branch on ordinary action data; keep handler schemas generic (found 2026-07-11 reviewing commit-approval rework).

<!-- applied-learning: a-grapheme-count-limit-is-not-a-byte-or-work-limit -->
<a id="applied-learning-a-grapheme-count-limit-is-not-a-byte-or-work-limit"></a>
**A grapheme-count limit is not a byte or work limit.** One valid Unicode grapheme can contain arbitrarily many combining codepoints, so `String.slice(text, 0, 512)` can retain and traverse many kilobytes while claiming a 512-character bound. Resource ceilings for prompts, diagnostics, and persisted output must check bytes first and truncate on a valid UTF-8 byte boundary; add combining-sequence regressions that assert `byte_size/1` (found 2026-07-11 reviewing AI eval output bounds).

<!-- applied-learning: a-bearer-stripped-from-public-views-can-still-leak-through-action-results -->
<a id="applied-learning-a-bearer-stripped-from-public-views-can-still-leak-through-action-results"></a>
**A bearer stripped from public views can still leak through action results.** Returning a lease credential from a Jido action puts it into Engine context, checkpoints, and node status even if `public_view/1`, receipts, and signals redact it. Keep compatibility credentials inside the owning registry boundary; graph actions should use authenticated task/principal authority and return only non-authority descriptors (found 2026-07-11 reviewing workspace cleanup R2).

<!-- applied-learning: a-nested-map-inside-action-context-is-still-action-visible-authority -->
<a id="applied-learning-a-nested-map-inside-action-context-is-still-action-visible-authority"></a>
**A nested map inside action context is still action-visible authority.** Moving a bearer from `context.signing_authority` to `context.nested_engine_opts.signing_authority` does not make it process-private; every Jido action receiving that context can still inspect, return, or log it. Carry secret nested-engine controls through an exact-action private facade/envelope, or expose them only to modules with an explicit facade-owned need declaration; ordinary actions must receive neither the top-level nor nested bearer (found 2026-07-11 from the full Orchestrator signing-authority regression).

<!-- applied-learning: every-engine-handler-must-derive-principal-identity-from-runauthorization-not-node-attributes -->
<a id="applied-learning-every-engine-handler-must-derive-principal-identity-from-runauthorization-not-node-attributes"></a>
**Every Engine handler must derive principal identity from `RunAuthorization`, not node attributes.** Fixing the action handler is insufficient if `ShellHandler` or `ToolHandler` still prefers author-controlled `agent_id` or falls back to `"system"`; a graph can then move authorization to a different principal. Bind all side-effecting handler branches to the immutable execution principal and reject absent authority on agent-authored runs (found 2026-07-11 reviewing the shell boundary correction).

<!-- applied-learning: a-generic-engine-node-capability-does-not-replace-the-syscall-s-exact-capability-gate -->
<a id="applied-learning-a-generic-engine-node-capability-does-not-replace-the-syscall-s-exact-capability-gate"></a>
**A generic Engine node capability does not replace the syscall's exact capability gate.** `ToolHandler` executing a prepared command under `arbor://orchestrator/execute/tool` still bypasses `arbor://shell/exec/<command>` if it calls the shell executor directly. Every handler branch that crosses into a side-effecting subsystem must invoke that subsystem's public authorized facade with the immutable run principal before hooks or execution (found 2026-07-11 reviewing the DOT tool-command path).

<!-- applied-learning: an-action-cannot-self-declare-access-to-private-nested-authority -->
<a id="applied-learning-an-action-cannot-self-declare-access-to-private-nested-authority"></a>
**An action cannot self-declare access to private nested authority.** A callback such as `nested_engine_context_keys/0` is implemented by the action module itself, so treating it as an allowlist lets any newly loaded action request signer, permit, or private-key material. Keep the permitted module/operation set in the trusted facade, expose exact closed methods for those operations, and never insert a generic credential bag into action context (found 2026-07-11 stealing nested signing authority from a test action).

<!-- applied-learning: do-not-let-a-diagnostic-output-pipeline-hide-the-command-under-test-s-exit-status -->
<a id="applied-learning-do-not-let-a-diagnostic-output-pipeline-hide-the-command-under-test-s-exit-status"></a>
**Do not let a diagnostic output pipeline hide the command under test's exit status.** Shell pipelines such as `mix test ... | tail` or `... | rg` normally report the final filter's status, so a failed Mix startup can appear as exit code 0. Enable `pipefail`, capture the producer status explicitly, or run the producer without a filter when validation success is load-bearing (found 2026-07-16 when an umbrella `:eaddrinuse` failure was masked by `tail`).

<!-- applied-learning: a-reachable-distributed-node-is-not-an-application-ready-arbor-server -->
<a id="applied-learning-a-reachable-distributed-node-is-not-an-application-ready-arbor-server"></a>
**A reachable distributed node is not an application-ready Arbor server.** `mix arbor.start` can answer RPC while the umbrella is still starting sequentially, so a process lookup or action call may return `:noproc` / `:registry_unavailable` after the CLI already printed success. Readiness must positively verify the required application boundary (or a dedicated boot sentinel), not only `net_adm` reachability. A 2026-07-17 cold boot took about 296 seconds, so a 300-second application deadline had no operational margin; keep the short node-ping deadline separate from a measured, conservatively larger application deadline (found 2026-07-16 and remeasured 2026-07-17 after rebuilding the startup-pinned Shell launcher).

<!-- applied-learning: nested-actions-that-mint-fresh-exact-resource-proofs-must-consume-the-process-local-signing-boundary -->
<a id="applied-learning-nested-actions-that-mint-fresh-exact-resource-proofs-must-consume-the-process-local-signing-boundary"></a>
**Nested actions that mint fresh exact-resource proofs must consume the process-local signing boundary.** An authority-signed outer action does not give a composite action the fresh nonce/signature needed for its inner syscall, and the bearer `SigningAuthority` must never enter JSON Engine context. Project an ephemeral signer only to explicitly trusted nested actions, consume it from owner-only `nested_engine_opts`, preserve malformed direct-credential fail-closed precedence, and pin the action BEAM in the execution manifest so an in-flight reload fails closed (found 2026-07-17 when `coding_reviewed_commit` validation passed but clean-HEAD adoption could not sign its nested Git resource).

<!-- applied-learning: composite-actions-must-declare-every-nested-action-as-an-execution-dependency -->
<a id="applied-learning-composite-actions-must-declare-every-nested-action-as-an-execution-dependency"></a>
**Composite actions must declare every nested action as an execution dependency.** Pinning only the outer action BEAM lets reviewed code call a different inner syscall implementation than the compiled graph bound. Expose module-valued dependency metadata through the owning library facade, bind it into the catalog digest, expand a deterministic cycle-safe transitive closure, and strip catalog-only metadata from the final backward-compatible manifest shape; missing dependencies must fail before execution (found 2026-07-17 when `coding_reviewed_commit` invoked unbound `git_commit`).

<!-- applied-learning: an-engine-ok-run-result-is-an-execution-envelope-not-a-success-verdict -->
<a id="applied-learning-an-engine-ok-run-result-is-an-execution-envelope-not-a-success-verdict"></a>
**An Engine `{:ok, run_result}` is an execution envelope, not a success verdict.** Nested consumers such as council adapters must inspect `final_outcome` before reading decision keys from context. When a non-nil outcome is present, admit only the explicitly supported success statuses; reject `:fail`, `:retry`, `:skipped`, unknown, and malformed outcomes before stale context can escape (found 2026-07-18 when an all-failed council fan-in was masked as `:no_decision_in_result`).
